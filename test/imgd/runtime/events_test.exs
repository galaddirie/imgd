defmodule Imgd.Runtime.EventsTest do
  use ExUnit.Case, async: false

  alias Imgd.Runtime.Events

  setup do
    ensure_pubsub_started()
    :ok
  end

  test "emit/3 broadcasts and emits telemetry with sanitized data" do
    execution_id = "exec-events-1"
    handler_id = "events-telemetry-#{System.unique_integer([:positive])}"

    Events.subscribe(execution_id)

    :telemetry.attach(
      handler_id,
      [:imgd, :execution, :event],
      fn event, measurements, metadata, _config ->
        send(self(), {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      Events.unsubscribe(execution_id)
      :telemetry.detach(handler_id)
    end)

    assert :ok = Events.emit(:step_completed, execution_id, %{status: :ok})

    assert_receive {:execution_event, event}
    assert event.type == :step_completed
    assert event.data["status"] == "ok"

    assert_receive {:telemetry_event, [:imgd, :execution, :event], _measurements, metadata}
    assert metadata.type == :step_completed
    assert metadata.execution_id == execution_id
  end

  defp ensure_pubsub_started do
    if Process.whereis(Imgd.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: Imgd.PubSub})
    end
  end
end
