defmodule EventStore.Storage.Subscription do
  @moduledoc """
  Support persistent subscriptions to an event stream
  """

  require Logger

  alias EventStore.Sql.Statements
  alias EventStore.Storage.Subscription

  @type t :: %EventStore.Storage.Subscription{
    subscription_id: non_neg_integer(),
    stream_uuid: String.t,
    subscription_name: String.t,
    last_seen_event_number: nil | non_neg_integer(),
    last_seen_stream_version: nil | non_neg_integer(),
    created_at: NaiveDateTime.t,
  }

  defstruct [
    subscription_id: nil,
    stream_uuid: nil,
    subscription_name: nil,
    last_seen_event_number: nil,
    last_seen_stream_version: nil,
    created_at: nil,
  ]

  @doc """
  List all known subscriptions
  """
  def subscriptions(conn, opts \\ []),
    do: Subscription.All.execute(conn, opts)

  def subscribe_to_stream(conn, stream_uuid, subscription_name, start_from_event_number, start_from_stream_version, opts \\ []) do
    with {:ok, subscription} <- Subscription.Query.execute(conn, stream_uuid, subscription_name, opts) do
      {:ok, subscription}
    else
      {:error, :subscription_not_found} ->
        Subscription.Subscribe.execute(conn, stream_uuid, subscription_name, start_from_event_number, start_from_stream_version, opts)
    end
  end

  def try_acquire_exclusive_lock(conn, subscription_id, opts \\ []),
    do: Subscription.TryAdvisoryLock.execute(conn, subscription_id, opts)

  def ack_last_seen_event(conn, stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version, opts \\ []) do
    Subscription.Ack.execute(conn, stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version, opts)
  end

  def unsubscribe_from_stream(conn, stream_uuid, subscription_name, opts \\ []),
    do: Subscription.Unsubscribe.execute(conn, stream_uuid, subscription_name, opts)

  defmodule All do
    def execute(conn, opts) do
      conn
      |> Postgrex.query(Statements.query_all_subscriptions, [], opts)
      |> handle_response()
    end

    defp handle_response({:ok, %Postgrex.Result{num_rows: 0}}),
      do: {:ok, []}

    defp handle_response({:ok, %Postgrex.Result{rows: rows}}),
      do: {:ok, Subscription.Adapter.to_subscriptions(rows)}
  end

  defmodule Query do
    def execute(conn, stream_uuid, subscription_name, opts) do
      conn
      |> Postgrex.query(Statements.query_get_subscription, [stream_uuid, subscription_name], opts)
      |> handle_response()
    end

    defp handle_response({:ok, %Postgrex.Result{num_rows: 0}}),
      do: {:error, :subscription_not_found}

    defp handle_response({:ok, %Postgrex.Result{rows: rows}}),
      do: {:ok, Subscription.Adapter.to_subscription(rows)}
  end

  defmodule Subscribe do
    def execute(conn, stream_uuid, subscription_name, start_from_event_number, start_from_stream_version, opts) do
      _ = Logger.debug(fn -> "Attempting to create subscription on stream \"#{stream_uuid}\" named \"#{subscription_name}\"" end)

      conn
      |> Postgrex.query(Statements.create_subscription, [stream_uuid, subscription_name, start_from_event_number, start_from_stream_version], opts)
      |> handle_response(stream_uuid, subscription_name)
    end

    defp handle_response({:ok, %Postgrex.Result{rows: rows}}, stream_uuid, subscription_name) do
      _ = Logger.debug(fn -> "Created subscription on stream \"#{stream_uuid}\" named \"#{subscription_name}\"" end)
      {:ok, Subscription.Adapter.to_subscription(rows)}
    end

    defp handle_response({:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}, stream_uuid, subscription_name) do
      _ = Logger.debug(fn -> "Failed to create subscription on stream #{stream_uuid} named #{subscription_name}, already exists" end)
      {:error, :subscription_already_exists}
    end

    defp handle_response({:error, error}, stream_uuid, subscription_name) do
      _ = Logger.warn(fn -> "Failed to create stream create subscription on stream \"#{stream_uuid}\" named \"#{subscription_name}\" due to: #{error}" end)
      {:error, error}
    end
  end

  defmodule TryAdvisoryLock do
    def execute(conn, subscription_id, opts) do
      conn
      |> Postgrex.query(Statements.try_advisory_lock(), [subscription_id], opts)
      |> handle_response()
    end

    defp handle_response({:ok, %Postgrex.Result{rows: [[true]]}}) do
      :ok
    end

    defp handle_response({:ok, %Postgrex.Result{rows: [[false]]}}) do
      {:error, :lock_already_taken}
    end

    defp handle_response({:error, error}) do
      {:error, error}
    end
  end

  defmodule Ack do
    def execute(conn, stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version, opts) do
      conn
      |> Postgrex.query(Statements.ack_last_seen_event, [stream_uuid, subscription_name, last_seen_event_number, last_seen_stream_version], opts)
      |> handle_response(stream_uuid, subscription_name)
    end

    defp handle_response({:ok, _result}, _stream_uuid, _subscription_name) do
      :ok
    end

    defp handle_response({:error, error}, stream_uuid, subscription_name) do
      _ = Logger.warn(fn -> "Failed to ack last seen event on stream \"#{stream_uuid}\" named \"#{subscription_name}\" due to: #{error}" end)
      {:error, error}
    end
  end

  defmodule Unsubscribe do
    def execute(conn, stream_uuid, subscription_name, opts) do
      _ = Logger.debug(fn -> "Attempting to unsubscribe from stream \"#{stream_uuid}\" named \"#{subscription_name}\"" end)

      conn
      |> Postgrex.query(Statements.delete_subscription, [stream_uuid, subscription_name], opts)
      |> handle_response(stream_uuid, subscription_name)
    end

    defp handle_response({:ok, _result}, stream_uuid, subscription_name) do
      _ = Logger.debug(fn -> "Unsubscribed from stream \"#{stream_uuid}\" named \"#{subscription_name}\"" end)
      :ok
    end

    defp handle_response({:error, error}, stream_uuid, subscription_name) do
      _ = Logger.warn(fn -> "Failed to unsubscribe from stream \"#{stream_uuid}\" named \"#{subscription_name}\" due to: #{error}" end)
      {:error, error}
    end
  end

  defmodule Adapter do
    def to_subscriptions(rows), do: Enum.map(rows, &to_subscription_from_row/1)

    def to_subscription([row | _]), do: to_subscription_from_row(row)

    defp to_subscription_from_row(row) do
      [
        subscription_id,
        stream_uuid,
        subscription_name,
        last_seen_event_number,
        last_seen_stream_version,
        created_at,
      ] = row

      %Subscription{
        subscription_id: subscription_id,
        stream_uuid: stream_uuid,
        subscription_name: subscription_name,
        last_seen_event_number: last_seen_event_number,
        last_seen_stream_version: last_seen_stream_version,
        created_at: created_at
      }
    end
  end
end
