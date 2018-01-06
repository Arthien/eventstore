defmodule EventStore.Supervisor do
  @moduledoc false
  use Supervisor

  alias EventStore.{Config,Registration}

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init([config, serializer]) do
    postgrex_config = Config.postgrex_opts(config)
    subscription_postgrex_config = Config.subscription_postgrex_opts(config)

    children = [
      {Postgrex, postgrex_config},
      Supervisor.child_spec({Registry, keys: :unique, name: EventStore.Subscriptions.Subscription}, id: EventStore.Subscriptions.Subscription),
      Supervisor.child_spec({Registry, keys: :duplicate, name: EventStore.Subscriptions.PubSub, partitions: System.schedulers_online}, id: EventStore.Subscriptions.PubSub),
      {EventStore.Subscriptions.Supervisor, subscription_postgrex_config},
      {EventStore.Publisher, serializer},
    ] ++ Registration.child_spec()

    Supervisor.init(children, strategy: :one_for_one)
  end
end
