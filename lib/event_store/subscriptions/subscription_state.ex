defmodule EventStore.Subscriptions.SubscriptionState do
  @moduledoc false
  
  defstruct catch_up_pid: nil,
            conn: nil,
            stream_uuid: nil,
            subscription_name: nil,
            subscriber: nil,
            subscription_id: nil,
            mapper: nil,
            last_seen: 0,
            last_ack: 0,
            last_received: nil,
            pending_events: [],
            max_size: nil
end
