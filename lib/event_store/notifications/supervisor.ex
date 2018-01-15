defmodule EventStore.Notifications.Supervisor do
  @moduledoc false

  use Supervisor

  alias EventStore.Config
  alias EventStore.Notifications.{
    AllStreamBroadcaster,
    Listener,
    Reader,
    StreamBroadcaster
  }

  @doc """
  Starts a globally named supervisor process.

  This is to ensure only a single instance of the supervisor, and its
  supervised children, is kept running on a cluster of nodes.
  """
  def start_link(args) do
    case Supervisor.start_link(__MODULE__, args, name: {:global, __MODULE__}) do
      {:ok, pid} ->
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        Process.link(pid)
        {:ok, pid}
      :ignore ->
        :ignore
    end
  end

  def init(config) do
    notification_opts = Config.notification_postgrex_opts(config)

    Supervisor.init([
      %{
        id: EventStore.Notifications,
        start: {Postgrex.Notifications, :start_link, [notification_opts]},
        restart: :permanent,
        shutdown: 5000,
        type: :worker
      },
      {Listener, []},
      {Reader, []},
      {AllStreamBroadcaster, []},
      {StreamBroadcaster, []},
    ], strategy: :one_for_all)
  end
end
