defmodule EventStore.Sql.Statements do
  @moduledoc """
  PostgreSQL statements to intialize the event store schema and read/write streams and events.
  """

  alias EventStore.Config

  def initializers do
    [
      create_streams_table(),
      create_stream_uuid_index(),
      seed_all_stream(),
      create_events_table(),
      prevent_event_update(),
      prevent_event_delete(),
      create_stream_events_table(),
      create_stream_events_index(),
      prevent_stream_events_update(),
      prevent_stream_events_delete(),
      # create_notify_events_function(),
      # create_event_notification_trigger(),
      create_subscriptions_table(),
      create_subscription_index(),
      create_snapshots_table(),
      create_schema_migrations_table(),
      record_event_store_schema_version(),
    ]
  end

  def reset do
    [
      drop_rule("no_update_stream_events", "stream_events"),
      drop_rule("no_delete_stream_events", "stream_events"),
      drop_rule("no_update_events", "events"),
      drop_rule("no_delete_events", "events"),
      truncate_tables(),
      seed_all_stream(),
      prevent_event_update(),
      prevent_event_delete(),
      prevent_stream_events_update(),
      prevent_stream_events_delete()
    ]
  end

  defp drop_rule(name, table) do
    "DROP RULE #{name} ON #{table}"
  end

  defp truncate_tables do
"""
TRUNCATE TABLE snapshots, subscriptions, stream_events, streams, events
RESTART IDENTITY;
"""
  end

  defp create_streams_table do
"""
CREATE TABLE streams
(
    stream_id bigserial PRIMARY KEY NOT NULL,
    stream_uuid text NOT NULL,
    stream_version bigint default 0 NOT NULL,
    created_at timestamp without time zone default (now() at time zone 'utc') NOT NULL
);
"""
  end

  defp create_stream_uuid_index do
"""
CREATE UNIQUE INDEX ix_streams_stream_uuid ON streams (stream_uuid);
"""
  end

  # create `$all` stream
  defp seed_all_stream do
"""
INSERT INTO streams (stream_id, stream_uuid, stream_version) VALUES (0, '$all', 0);
"""
  end

  defp create_events_table do
"""
CREATE TABLE events
(
    event_id uuid PRIMARY KEY NOT NULL,
    event_type text NOT NULL,
    causation_id uuid NULL,
    correlation_id uuid NULL,
    data #{column_data_type()} NOT NULL,
    metadata #{column_data_type()} NULL,
    created_at timestamp without time zone default (now() at time zone 'utc') NOT NULL
);
"""
  end

  # prevent updates to `events` table
  defp prevent_event_update do
"""
CREATE RULE no_update_events AS ON UPDATE TO events DO INSTEAD NOTHING;
"""
  end

  # prevent deletion from `events` table
  defp prevent_event_delete do
"""
CREATE RULE no_delete_events AS ON DELETE TO events DO INSTEAD NOTHING;
"""
  end

  defp create_stream_events_table do
"""
CREATE TABLE stream_events
(
  stream_id bigint NOT NULL REFERENCES streams (stream_id),
  stream_version bigint NOT NULL,
  event_id uuid NOT NULL REFERENCES events (event_id),
  PRIMARY KEY(stream_id, event_id)
);
"""
  end

  defp create_stream_events_index do
"""
CREATE UNIQUE INDEX ix_stream_events ON stream_events (stream_id, stream_version);
"""
  end

  # prevent updates to `stream_events` table
  defp prevent_stream_events_update do
"""
CREATE RULE no_update_stream_events AS ON UPDATE TO stream_events DO INSTEAD NOTHING;
"""
  end

  # prevent deletion from `stream_events` table
  defp prevent_stream_events_delete do
"""
CREATE RULE no_delete_stream_events AS ON DELETE TO stream_events DO INSTEAD NOTHING;
"""
  end

  defp create_notify_events_function do
"""
CREATE OR REPLACE FUNCTION notify_events()
  RETURNS trigger AS $$
DECLARE
  payload text;
BEGIN
    -- Payload text contains first and last event numbers separated by a comma (e.g. '1,5')
    payload := (OLD.event_number + 1) || ',' || NEW.event_number;

    -- Notify events to listeners
    PERFORM pg_notify('events', payload);

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
"""
  end

  defp create_event_notification_trigger do
"""
CREATE TRIGGER event_notification
AFTER UPDATE ON streams
FOR EACH ROW EXECUTE PROCEDURE notify_events();
"""
  end

  defp create_subscriptions_table do
"""
CREATE TABLE subscriptions
(
    subscription_id bigserial PRIMARY KEY NOT NULL,
    stream_uuid text NOT NULL,
    subscription_name text NOT NULL,
    last_seen bigint NULL,
    created_at timestamp without time zone default (now() at time zone 'utc') NOT NULL
);
"""
  end

  defp create_subscription_index do
"""
CREATE UNIQUE INDEX ix_subscriptions_stream_uuid_subscription_name ON subscriptions (stream_uuid, subscription_name);
"""
  end

  defp create_snapshots_table do
"""
CREATE TABLE snapshots
(
    source_uuid text PRIMARY KEY NOT NULL,
    source_version bigint NOT NULL,
    source_type text NOT NULL,
    data #{column_data_type()} NOT NULL,
    metadata #{column_data_type()} NULL,
    created_at timestamp without time zone default (now() at time zone 'utc') NOT NULL
);
"""
  end

  # record execution of upgrade scripts
  defp create_schema_migrations_table do
"""
CREATE TABLE schema_migrations
(
    major_version int NOT NULL,
    minor_version int NOT NULL,
    patch_version int NOT NULL,
    migrated_at timestamp without time zone default (now() at time zone 'UTC') NOT NULL,
    PRIMARY KEY(major_version, minor_version, patch_version)
);
"""
  end

  # record current event store schema version
  defp record_event_store_schema_version do
"""
INSERT INTO schema_migrations (major_version, minor_version, patch_version)
VALUES (0, 14, 0);
"""
  end

  def create_stream do
"""
INSERT INTO streams (stream_uuid)
VALUES ($1)
RETURNING stream_id;
"""
  end

  def create_events(number_of_events) do
    params =
      1..number_of_events
      |> Stream.map(fn event_number ->
        index = (event_number - 1) * 7
        params = [
          Integer.to_string(index + 1),  # event_id
          Integer.to_string(index + 2),  # event_type
          Integer.to_string(index + 3),  # causation_id
          Integer.to_string(index + 4),  # correlation_id
          Integer.to_string(index + 5),  # data
          Integer.to_string(index + 6),  # metadata
          Integer.to_string(index + 7)   # created_at
        ]

        [
          "($",
          Enum.intersperse(params, ", $"),
          ")"
        ]
      end)
      |> Enum.intersperse(",")

    [
      """
      INSERT INTO events
        (
          event_id,
          event_type,
          causation_id,
          correlation_id,
          data,
          metadata,
          created_at
        )
      VALUES
      """,
      params,
      ";",
    ]
  end

  def create_stream_events(number_of_events) do
    params =
      1..number_of_events
      |> Stream.map(fn
        1 ->
          # first row of values define their types
          [
            "($3::bigint, $4::uuid)"
          ]

        event_number ->
          index = (event_number - 1) * 2 + 2
          params = [
            Integer.to_string(index + 1),  # index
            Integer.to_string(index + 2),  # event_id
          ]

          [
            "($",
            Enum.intersperse(params, ", $"),
            ")"
          ]
      end)
      |> Enum.intersperse(",")

    [
      """
      WITH
        stream AS (
          UPDATE streams SET stream_version = stream_version + $2
          WHERE stream_id = $1
          RETURNING stream_id, stream_version - $2 as stream_version
        ),
      events (index, event_id)
      AS (
        VALUES
    """,
    params,
    """
      )
      INSERT INTO stream_events
        (
          stream_id,
          stream_version,
          event_id
        )
      SELECT
        stream.stream_id,
        stream.stream_version + events.index,
        events.event_id
      FROM events, stream;
      """,
    ]
  end

  def create_subscription do
"""
INSERT INTO subscriptions (stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version)
VALUES ($1, $2, $3, $4)
RETURNING subscription_id, stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version, created_at;
"""
  end

  def delete_subscription do
"""
DELETE FROM subscriptions
WHERE stream_uuid = $1 AND subscription_name = $2;
"""
  end

  def try_advisory_lock do
"""
SELECT pg_try_advisory_lock($1);
"""
  end

  def ack_last_seen_event do
"""
UPDATE subscriptions
SET last_seen_event_number = $3, last_seen_stream_version = $4
WHERE stream_uuid = $1 AND subscription_name = $2;
"""
  end

  def record_snapshot do
"""
INSERT INTO snapshots (source_uuid, source_version, source_type, data, metadata)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (source_uuid)
DO UPDATE SET source_version = $2, source_type = $3, data = $4, metadata = $5;
"""
  end

  def delete_snapshot do
"""
DELETE FROM snapshots
WHERE source_uuid = $1;
"""
  end

  def query_all_subscriptions do
"""
SELECT subscription_id, stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version, created_at
FROM subscriptions
ORDER BY created_at;
"""
  end

  def query_get_subscription do
"""
SELECT subscription_id, stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version, created_at
FROM subscriptions
WHERE stream_uuid = $1 AND subscription_name = $2;
"""
  end

  def query_stream_id do
"""
SELECT stream_id
FROM streams
WHERE stream_uuid = $1;
"""
  end

  def query_stream_id_and_latest_version do
"""
SELECT stream_id, stream_version
FROM streams
WHERE stream_uuid = $1;
"""
  end

  def query_get_snapshot do
"""
SELECT source_uuid, source_version, source_type, data, metadata, created_at
FROM snapshots
WHERE source_uuid = $1;
"""
  end

  def read_events_forward do
"""
SELECT
  e.event_id,
  e.event_number,
  s.stream_uuid,
  e.stream_version,
  e.event_type,
  e.correlation_id,
  e.causation_id,
  e.data,
  e.metadata,
  e.created_at
FROM events e
INNER JOIN streams s ON s.stream_id = e.stream_id
WHERE e.stream_id = $1 and e.stream_version >= $2
ORDER BY e.stream_version ASC
LIMIT $3;
"""
  end

  def read_all_events_forward do
"""
SELECT
  e.event_id,
  e.event_number,
  s.stream_uuid,
  e.stream_version,
  e.event_type,
  e.correlation_id,
  e.causation_id,
  e.data,
  e.metadata,
  e.created_at
FROM events e
INNER JOIN streams s ON s.stream_id = e.stream_id
WHERE e.event_number >= $1
ORDER BY e.event_number ASC
LIMIT $2;
"""
  end

  defp column_data_type, do: Config.column_data_type()
end
