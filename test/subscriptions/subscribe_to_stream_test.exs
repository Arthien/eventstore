defmodule EventStore.Subscriptions.SubscribeToStreamTest do
  use EventStore.StorageCase

  alias EventStore.{Config, EventFactory, ProcessHelper, Subscriptions, Subscriber, Wait}
  alias EventStore.Subscriptions.Subscription
  alias EventStore.Support.CollectingSubscriber

  @conn EventStore.Postgrex

  setup do
    subscription_name = UUID.uuid4()

    {:ok, %{subscription_name: subscription_name}}
  end

  describe "single stream subscription" do
    setup [:append_events_to_another_stream]

    test "should receive `:subscribed` message once subscribed", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4()

      {:ok, subscription} = Subscriptions.subscribe_to_stream(stream_uuid, subscription_name, self())

      assert_receive {:subscribed, ^subscription}
    end

    test "subscribe to single stream from origin should receive all its events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4()
      events = EventFactory.create_events(3)

      {:ok, _subscription} = subscribe_to_stream(stream_uuid, subscription_name, self())

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      assert_receive {:events, received_events}
      assert pluck(received_events, :event_number) == [1, 2, 3]
      assert pluck(received_events, :stream_uuid) == [stream_uuid, stream_uuid, stream_uuid]
      assert pluck(received_events, :stream_version) == [1, 2, 3]
      assert pluck(received_events, :correlation_id) == pluck(events, :correlation_id)
      assert pluck(received_events, :causation_id) == pluck(events, :causation_id)
      assert pluck(received_events, :event_type) == pluck(events, :event_type)
      assert pluck(received_events, :data) == pluck(events, :data)
      assert pluck(received_events, :metadata) == pluck(events, :metadata)
      refute pluck(received_events, :created_at) |> Enum.any?(&is_nil/1)
    end

    test "subscribe to single stream from given stream version should only receive later events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      initial_events = EventFactory.create_events(1)
      new_events = EventFactory.create_events(1, 2)

      :ok = EventStore.append_to_stream(stream_uuid, 0, initial_events)

      {:ok, _subscription} = subscribe_to_stream(stream_uuid, subscription_name, self(), start_from: 1)

      :ok = EventStore.append_to_stream(stream_uuid, 1, new_events)

      assert_receive {:events, received_events}
      assert pluck(received_events, :event_number) == [2]
      assert pluck(received_events, :stream_uuid) == [stream_uuid]
      assert pluck(received_events, :stream_version) == [2]
      assert pluck(received_events, :correlation_id) == pluck(new_events, :correlation_id)
      assert pluck(received_events, :causation_id) == pluck(new_events, :causation_id)
      assert pluck(received_events, :event_type) == pluck(new_events, :event_type)
      assert pluck(received_events, :data) == pluck(new_events, :data)
      assert pluck(received_events, :metadata) == pluck(new_events, :metadata)
      refute pluck(received_events, :created_at) |> Enum.any?(&is_nil/1)
    end

    test "subscribe to stream more than once using same subscription name should error", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4

      assert {:ok, _subscription} = EventStore.subscribe_to_stream(stream_uuid, subscription_name, self())
      assert {:error, :subscription_already_exists} = EventStore.subscribe_to_stream(stream_uuid, subscription_name, self())
    end

    test "subscribe to single stream should ignore events from another stream", %{subscription_name: subscription_name} do
      interested_stream_uuid = UUID.uuid4
      other_stream_uuid = UUID.uuid4

      interested_events = EventFactory.create_events(1)
      other_events = EventFactory.create_events(1)

      {:ok, _subscription} = subscribe_to_stream(interested_stream_uuid, subscription_name, self())

      :ok = EventStore.append_to_stream(interested_stream_uuid, 0, interested_events)
      :ok = EventStore.append_to_stream(other_stream_uuid, 0, other_events)

      # received events should not include events from the other stream
      assert_receive {:events, received_events}
      assert pluck(received_events, :data) == pluck(interested_events, :data)
      refute_receive {:events, _received_events}
    end

    test "subscribe to single stream with mapper function should receive all its mapped events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      events = EventFactory.create_events(3)

      {:ok, _subscription} = subscribe_to_stream(stream_uuid, subscription_name, self(), mapper: fn event -> event.event_number end)

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      assert_receive {:events, received_mapped_events}
      assert received_mapped_events == [1, 2, 3]
    end

    test "subscribe to single stream with selector function should receive only filtered events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      events = EventFactory.create_events(4)

      {:ok, _subscription} = subscribe_to_stream(stream_uuid, subscription_name, self(), selector: fn event -> rem(event.event_number, 2) == 0 end)

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      assert_receive {:events, received_filtered_events}
      assert length(received_filtered_events) == 2
      assert pluck(received_filtered_events, :event_number) == [2, 4]
    end

    test "subscribe to single stream with selector function should continue to receive only filtered events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4()
      events = EventFactory.create_events(3)

      {:ok, subscription} = subscribe_to_stream(stream_uuid, subscription_name, self(), selector: fn event -> rem(event.event_number, 2) == 0 end)

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      assert_receive {:events, received_filtered_events}
      assert length(received_filtered_events) == 1
      assert pluck(received_filtered_events, :event_number) == [2]

      Subscription.ack(subscription, received_filtered_events)

      :ok = EventStore.append_to_stream(stream_uuid, 3, events)

      assert_receive {:events, received_filtered_events}
      assert length(received_filtered_events) == 2
      assert pluck(received_filtered_events, :event_number) == [4, 6]

      Subscription.ack(subscription, received_filtered_events)

      refute_receive {:events, _received_filtered_events}
    end

    test "subscribe to single stream with selector function during catch-up should continue to receive only filtered events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4()

      :ok = EventStore.append_to_stream(stream_uuid, 0, EventFactory.create_events(3))
      :ok = EventStore.append_to_stream(stream_uuid, 3, EventFactory.create_events(3))

      {:ok, subscription} = subscribe_to_stream(stream_uuid, subscription_name, self(), selector: fn event -> rem(event.event_number, 2) == 0 end)

      assert_receive {:events, received_filtered_events}
      assert length(received_filtered_events) == 1
      assert pluck(received_filtered_events, :event_number) == [2]

      Subscription.ack(subscription, received_filtered_events)

      assert_receive {:events, received_filtered_events}
      assert length(received_filtered_events) == 2
      assert pluck(received_filtered_events, :event_number) == [4, 6]

      Subscription.ack(subscription, received_filtered_events)

      refute_receive {:events, _received_filtered_events}
    end

    test "subscribe to single stream with selector function and mapper function should receive only filtered events and mapped events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      events = EventFactory.create_events(4)

      selector = fn event -> rem(event.event_number, 2) == 0 end
      mapper = fn event -> event.event_number end
      {:ok, _subscription} = subscribe_to_stream(stream_uuid, subscription_name, self(), selector: selector, mapper: mapper)

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      assert_receive {:events, [2, 4]}
    end

    test "subscribe to single stream should continue receiving events after ack", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      initial_events = EventFactory.create_events(1)
      new_events = EventFactory.create_events(1, 2)

      :ok = EventStore.append_to_stream(stream_uuid, 0, initial_events)
      :ok = EventStore.append_to_stream(stream_uuid, 1, new_events)

      {:ok, subscription} = EventStore.subscribe_to_stream(stream_uuid, subscription_name, self())

      assert_receive {:subscribed, ^subscription}
      assert_receive {:events, received_events}
      assert pluck(received_events, :data) == pluck(initial_events, :data)

      Subscription.ack(subscription, received_events)

      assert_receive {:events, received_events}
      assert pluck(received_events, :data) == pluck(new_events, :data)

      Subscription.ack(subscription, received_events)

      refute_receive {:events, _received_events}
    end

    test "should support ack received events by `stream_version`", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      initial_events = EventFactory.create_events(1)
      new_events = EventFactory.create_events(1, 2)

      :ok = EventStore.append_to_stream(stream_uuid, 0, initial_events)
      :ok = EventStore.append_to_stream(stream_uuid, 1, new_events)

      {:ok, subscription} = EventStore.subscribe_to_stream(stream_uuid, subscription_name, self())

      assert_receive {:subscribed, ^subscription}
      assert_receive {:events, received_events}
      assert pluck(received_events, :data) == pluck(initial_events, :data)

      Subscription.ack(subscription, 1)

      assert_receive {:events, received_events}
      assert pluck(received_events, :data) == pluck(new_events, :data)

      Subscription.ack(subscription, 2)

      refute_receive {:events, _received_events}
    end

    test "should catch-up from unseen events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4()

      :ok = EventStore.append_to_stream(stream_uuid, 0, EventFactory.create_events(1))
      :ok = EventStore.append_to_stream(stream_uuid, 1, EventFactory.create_events(2))
      :ok = EventStore.append_to_stream(stream_uuid, 3, EventFactory.create_events(3))
      :ok = EventStore.append_to_stream(stream_uuid, 6, EventFactory.create_events(4))

      {:ok, subscription} = subscribe_to_stream(stream_uuid, subscription_name, self())

      assert_receive_events(subscription, [1])
      assert_receive_events(subscription, [2, 3])
      assert_receive_events(subscription, [4, 5, 6])
      assert_receive_events(subscription, [7, 8, 9, 10])

      :ok = EventStore.append_to_stream(stream_uuid, 10, EventFactory.create_events(5))

      assert_receive_events(subscription, [11, 12, 13, 14, 15])

      refute_receive {:events, _received_filtered_events}
    end

    defp assert_receive_events(subscription, expected_event_numbers) do
      assert_receive {:events, received_events}
      assert pluck(received_events, :event_number) == expected_event_numbers

      Subscription.ack(subscription, received_events)
    end
  end

  describe "all stream subscription" do
    test "subscribe to all streams should receive events from all streams", %{subscription_name: subscription_name} do
      stream1_uuid = UUID.uuid4
      stream2_uuid = UUID.uuid4

      stream1_events = EventFactory.create_events(1)
      stream2_events = EventFactory.create_events(1)

      {:ok, subscription} = subscribe_to_all_streams(subscription_name, self())

      :ok = EventStore.append_to_stream(stream1_uuid, 0, stream1_events)
      :ok = EventStore.append_to_stream(stream2_uuid, 0, stream2_events)

      assert_receive {:events, stream1_received_events}
      assert pluck(stream1_received_events, :event_number) == [1]
      assert pluck(stream1_received_events, :stream_uuid) == [stream1_uuid]
      assert pluck(stream1_received_events, :stream_version) == [1]
      assert pluck(stream1_received_events, :correlation_id) == pluck(stream1_events, :correlation_id)
      assert pluck(stream1_received_events, :causation_id) == pluck(stream1_events, :causation_id)
      assert pluck(stream1_received_events, :event_type) == pluck(stream1_events, :event_type)
      assert pluck(stream1_received_events, :data) == pluck(stream1_events, :data)
      assert pluck(stream1_received_events, :metadata) == pluck(stream1_events, :metadata)
      refute pluck(stream1_received_events, :created_at) |> Enum.any?(&is_nil/1)

      Subscription.ack(subscription, stream1_received_events)

      assert_receive {:events, stream2_received_events}
      assert pluck(stream2_received_events, :event_number) == [2]
      assert pluck(stream2_received_events, :stream_uuid) == [stream2_uuid]
      assert pluck(stream2_received_events, :stream_version) == [1]
      assert pluck(stream2_received_events, :correlation_id) == pluck(stream2_events, :correlation_id)
      assert pluck(stream2_received_events, :causation_id) == pluck(stream2_events, :causation_id)
      assert pluck(stream2_received_events, :event_type) == pluck(stream2_events, :event_type)
      assert pluck(stream2_received_events, :data) == pluck(stream2_events, :data)
      assert pluck(stream2_received_events, :metadata) == pluck(stream2_events, :metadata)
      refute pluck(stream2_received_events, :created_at) |> Enum.any?(&is_nil/1)
    end

    test "subscribe to all streams from given stream id should only receive later events from all streams", %{subscription_name: subscription_name} do
      stream1_uuid = UUID.uuid4
      stream2_uuid = UUID.uuid4

      stream1_initial_events = EventFactory.create_events(1)
      stream2_initial_events = EventFactory.create_events(1)
      stream1_new_events = EventFactory.create_events(1, 2)
      stream2_new_events = EventFactory.create_events(1, 2)

      :ok = EventStore.append_to_stream(stream1_uuid, 0, stream1_initial_events)
      :ok = EventStore.append_to_stream(stream2_uuid, 0, stream2_initial_events)

      {:ok, subscription} = subscribe_to_all_streams(subscription_name, self(), start_from: 2)

      :ok = EventStore.append_to_stream(stream1_uuid, 1, stream1_new_events)
      :ok = EventStore.append_to_stream(stream2_uuid, 1, stream2_new_events)

      assert_receive {:events, stream1_received_events}
      Subscription.ack(subscription, stream1_received_events)

      assert_receive {:events, stream2_received_events}

      assert pluck(stream1_received_events, :data) == pluck(stream1_new_events, :data)
      assert pluck(stream2_received_events, :data) == pluck(stream2_new_events, :data)
      assert stream1_received_events != stream2_received_events
    end

    test "should ignore already received events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4()
      events = EventFactory.create_events(3, 1)
      recorded_events = EventFactory.create_recorded_events(3, stream_uuid, 1)

      {:ok, subscription} = subscribe_to_all_streams(subscription_name, self())

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      assert_receive {:events, received_events}
      assert length(received_events) == 3
      assert pluck(received_events, :data) == pluck(events, :data)

      # notify duplicate events, should be ignored
      send(subscription, {:events, recorded_events})

      refute_receive {:events, _events}
    end

    test "should monitor all stream subscription, terminate subscription and subscriber on error", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      events = EventFactory.create_events(1)

      {:ok, subscriber1} = Subscriber.start(self())
      {:ok, subscriber2} = Subscriber.start_link(self())

      {:ok, subscription1} = subscribe_to_all_streams(subscription_name <> "1", subscriber1)
      {:ok, subscription2} = subscribe_to_all_streams(subscription_name <> "2", subscriber2)

      ProcessHelper.shutdown(subscription1)

      # should kill subscription and subscriber
      assert Process.alive?(subscription1) == false
      assert Process.alive?(subscriber1) == false

      # other subscription should be unaffected
      assert Process.alive?(subscription2) == true
      assert Process.alive?(subscriber2) == true

      # appending events to stream should notify subscription 2
      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      # subscription 2 should still receive events
      assert_receive {:events, received_events}
      refute_receive {:events, _events}

      assert pluck(received_events, :data) == pluck(events, :data)
      assert pluck(Subscriber.received_events(subscriber2), :data) == pluck(events, :data)
    end

    test "should ack received events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      stream_events = EventFactory.create_events(6)
      initial_events = Enum.take(stream_events, 3)
      remaining_events = Enum.drop(stream_events, 3)

      {:ok, subscription} = subscribe_to_all_streams(subscription_name, self())

      :ok = EventStore.append_to_stream(stream_uuid, 0, initial_events)

      assert_receive {:events, initial_received_events}
      assert length(initial_received_events) == 3
      assert pluck(initial_received_events, :data) == pluck(initial_events, :data)

      # acknowledge receipt of first event only
      Subscription.ack(subscription, hd(initial_received_events))

      refute_receive {:events, _events}

      # should not send further events until ack'd all previous
      :ok = EventStore.append_to_stream(stream_uuid, 3, remaining_events)

      refute_receive {:events, _events}

      # acknowledge receipt of all initial events
      Subscription.ack(subscription, initial_received_events)

      assert_receive {:events, remaining_received_events}
      assert length(remaining_received_events) == 3
      assert pluck(remaining_received_events, :data) == pluck(remaining_events, :data)
    end

    test "should support ack received events by `event_number`", %{subscription_name: subscription_name} do
      stream1_uuid = UUID.uuid4
      stream2_uuid = UUID.uuid4

      stream1_events = EventFactory.create_events(1)
      stream2_events = EventFactory.create_events(1)

      {:ok, subscription} = subscribe_to_all_streams(subscription_name, self())

      :ok = EventStore.append_to_stream(stream1_uuid, 0, stream1_events)
      :ok = EventStore.append_to_stream(stream2_uuid, 0, stream2_events)

      assert_receive {:events, stream1_received_events}
      Subscription.ack(subscription, 1)

      assert_receive {:events, stream2_received_events}

      assert pluck(stream1_received_events, :data) == pluck(stream1_events, :data)
      assert pluck(stream2_received_events, :data) == pluck(stream2_events, :data)
      assert stream1_received_events != stream2_received_events
    end
  end

  describe "monitor single stream subscription" do
    test "should monitor subscription and terminate subscription and subscriber on error", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      events = EventFactory.create_events(1)

      {:ok, subscriber1} = Subscriber.start_link(self())
      {:ok, subscriber2} = Subscriber.start_link(self())

      {:ok, subscription1} = subscribe_to_stream(stream_uuid, subscription_name <> "-1", subscriber1)
      {:ok, subscription2} = subscribe_to_stream(stream_uuid, subscription_name <> "-2", subscriber2)

      refute_receive {:events, _events}

      # unlink subscriber so we don't crash the test when it is terminated by the subscription shutdown
      Process.unlink(subscriber1)

      ProcessHelper.shutdown(subscription1)

      # should kill subscription and subscriber
      assert Process.alive?(subscription1) == false
      assert Process.alive?(subscriber1) == false

      # other subscription should be unaffected
      assert Process.alive?(subscription2) == true
      assert Process.alive?(subscriber2) == true

      # should still notify subscription 2
      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      # subscription 2 should still receive events
      assert_receive {:events, received_events}
      refute_receive {:events, _events}

      assert pluck(received_events, :data) == pluck(events, :data)
      assert pluck(Subscriber.received_events(subscriber2), :data) == pluck(events, :data)
    end

    test "should monitor subscriber and terminate subscription on error", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      events = EventFactory.create_events(1)

      {:ok, subscriber1} = Subscriber.start_link(self())
      {:ok, subscriber2} = Subscriber.start_link(self())

      {:ok, subscription1} = subscribe_to_stream(stream_uuid, subscription_name <> "-1", subscriber1)
      {:ok, subscription2} = subscribe_to_stream(stream_uuid, subscription_name <> "-2", subscriber2)

      refute_receive {:events, _events}

      # unlink subscriber so we don't crash the test when it is terminated by the subscription shutdown
      Process.unlink(subscriber1)

      ProcessHelper.shutdown(subscriber1)

      # should kill subscription and subscriber
      assert Process.alive?(subscription1) == false
      assert Process.alive?(subscriber1) == false

      # other subscription should be unaffected
      assert Process.alive?(subscription2) == true
      assert Process.alive?(subscriber2) == true

      # should still notify subscription 2
      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      # subscription 2 should still receive events
      assert_receive {:events, received_events}
      refute_receive {:events, _events}

      assert pluck(received_events, :data) == pluck(events, :data)
      assert pluck(Subscriber.received_events(subscriber2), :data) == pluck(events, :data)
    end

    test "unsubscribe from a single stream subscription should stop subscriber from receiving events", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4
      events = EventFactory.create_events(1)

      {:ok, subscription} = subscribe_to_stream(stream_uuid, subscription_name, self())

      :ok = Subscriptions.unsubscribe_from_stream(stream_uuid, subscription_name)

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      refute_receive {:events, _received_events}
      assert Process.alive?(subscription) == false
    end
  end

  describe "both single and all stream subscriptions" do
    setup [:append_events_to_another_stream]

    test "should receive events from both subscriptions", %{subscription_name: subscription_name} do
      stream_uuid = UUID.uuid4()
      events = EventFactory.create_events(3)

      {:ok, _subscription} = subscribe_to_stream(stream_uuid, subscription_name <> "-single", self())
      {:ok, _subscription} = subscribe_to_all_streams(subscription_name <> "-all", self(), start_from: 3)

      :ok = EventStore.append_to_stream(stream_uuid, 0, events)

      # should receive events twice
      assert_receive_events(stream_uuid, events, [1, 2, 3])
      assert_receive_events(stream_uuid, events, [4, 5, 6])
      refute_receive {:events, _received_events}
    end

    defp assert_receive_events(stream_uuid, expected_events, expected_event_numbers) do
      assert_receive {:events, received_events}
      assert pluck(received_events, :event_number) == expected_event_numbers
      assert pluck(received_events, :stream_uuid) == [stream_uuid, stream_uuid, stream_uuid]
      assert pluck(received_events, :stream_version) == [1, 2, 3]
      assert pluck(received_events, :correlation_id) == pluck(expected_events, :correlation_id)
      assert pluck(received_events, :causation_id) == pluck(expected_events, :causation_id)
      assert pluck(received_events, :event_type) == pluck(expected_events, :event_type)
      assert pluck(received_events, :data) == pluck(expected_events, :data)
      assert pluck(received_events, :metadata) == pluck(expected_events, :metadata)
      refute pluck(received_events, :created_at) |> Enum.any?(&is_nil/1)
    end
  end

  describe "duplicate subscriptions" do
    setup [:lock_subscription, :create_subscription]

    test "should only allow single active subscription", context do
      %{conn2: conn2, subscription: subscription} = context

      stream1_uuid = append_events_to_stream(1)

      # subscriber should not receive events until subscribed
      refute_receive {:events, _received_events}

      # release lock, allowing subscriber to subscribe
      ProcessHelper.shutdown(conn2)

      # subscription should now be subscribed
      assert_receive {:subscribed, ^subscription}

      stream2_uuid = append_events_to_stream(2)

      # subscriber should now start receiving events
      assert_receive {:events, received_events}, 5_000
      assert length(received_events) == 1
      Enum.each(received_events, fn event ->
        assert event.stream_uuid == stream1_uuid
      end)

      :ok = Subscription.ack(subscription, received_events)

      assert_receive {:events, received_events}, 5_000
      assert length(received_events) == 2
      Enum.each(received_events, fn event ->
        assert event.stream_uuid == stream2_uuid
      end)

      :ok = Subscription.ack(subscription, received_events)

      refute_receive {:events, _received_events}
    end

    defp lock_subscription(_context) do
      config = Config.parsed() |> Config.sync_connect_postgrex_opts()

      {:ok, conn} = Postgrex.start_link(config)

      EventStore.Storage.Lock.try_acquire_exclusive_lock(conn, 1)

      on_exit fn ->
        ProcessHelper.shutdown(conn)
      end

      [conn2: conn]
    end

    defp create_subscription(%{subscription_name: subscription_name}) do
      {:ok, subscription} = EventStore.Subscriptions.Subscription.start_link(@conn, "$all", subscription_name, self(), start_from: 0)
      refute_receive {:subscribed, ^subscription}

      [subscription: subscription]
    end

    defp append_events_to_stream(count) do
      stream_uuid = UUID.uuid4()
      stream_events = EventFactory.create_events(count)

      :ok = EventStore.append_to_stream(stream_uuid, 0, stream_events)

      stream_uuid
    end
  end

  describe "many subscriptions to all stream" do
    test "should all receive events from any stream", %{subscription_name: subscription_name} do
      stream1_uuid = UUID.uuid4()
      stream2_uuid = UUID.uuid4()

      stream1_events = EventFactory.create_events(3)
      stream2_events = EventFactory.create_events(3)

      {:ok, subscriber1} = CollectingSubscriber.start_link(subscription_name <> "-1", self())
      {:ok, subscriber2} = CollectingSubscriber.start_link(subscription_name <> "-2", self())
      {:ok, subscriber3} = CollectingSubscriber.start_link(subscription_name <> "-3", self())
      {:ok, subscriber4} = CollectingSubscriber.start_link(subscription_name <> "-4", self())

      assert_receive {:subscribed, ^subscriber1}
      assert_receive {:subscribed, ^subscriber2}
      assert_receive {:subscribed, ^subscriber3}
      assert_receive {:subscribed, ^subscriber4}

      :ok = EventStore.append_to_stream(stream1_uuid, 0, stream1_events)
      :ok = EventStore.append_to_stream(stream2_uuid, 0, stream2_events)

      Wait.until(fn ->
        all_received_events =
          [subscriber1, subscriber2, subscriber3, subscriber4]
          |> Enum.reduce([], fn (subscriber, events) ->
            events ++ CollectingSubscriber.received_events(subscriber)
          end)

        assert length(all_received_events) == 4 * 6
      end)

      ProcessHelper.shutdown(subscriber1)
      ProcessHelper.shutdown(subscriber2)
      ProcessHelper.shutdown(subscriber3)
      ProcessHelper.shutdown(subscriber4)
    end
  end

  # append events to another stream so that for single stream subscription tests the
  # event id does not match the stream version
  def append_events_to_another_stream(_context) do
    stream_uuid = UUID.uuid4()
    events = EventFactory.create_events(3)

    :ok = EventStore.append_to_stream(stream_uuid, 0, events)
  end

  # subscribe to a single stream and wait for the subscription to be subscribed
  defp subscribe_to_stream(stream_uuid, subscription_name, subscriber, opts \\ []) do
    {:ok, subscription} = EventStore.subscribe_to_stream(stream_uuid, subscription_name, subscriber, opts)

    assert_receive {:subscribed, ^subscription}

    {:ok, subscription}
  end

  # subscribe to all streams and wait for the subscription to be subscribed
  defp subscribe_to_all_streams(subscription_name, subscriber, opts \\ []) do
    {:ok, subscription} = EventStore.subscribe_to_all_streams(subscription_name, subscriber, opts)

    assert_receive {:subscribed, ^subscription}

    {:ok, subscription}
  end

  defp pluck(enumerable, field) do
    Enum.map(enumerable, &Map.get(&1, field))
  end
end
