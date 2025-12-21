defmodule Imgd.Runtime.Hooks.ObservabilityTest do
  use ExUnit.Case, async: false

  require Runic
  alias Runic.Workflow
  alias Imgd.Runtime.Hooks.Observability
  alias Imgd.Executions.PubSub

  setup do
    ensure_pubsub_started()
    :ok
  end

  describe "count_output_items/1" do
    test "counts list outputs and handles nil" do
      assert Observability.count_output_items([1, 2, 3]) == 3
      assert Observability.count_output_items([]) == 0
      assert Observability.count_output_items(nil) == 0
      assert Observability.count_output_items("single") == 1
    end
  end

  describe "attach_all_hooks/2" do
    test "emits telemetry and pubsub events for step completion" do
      execution_id = "exec-observe-1"
      handler_id = "obs-telemetry-#{System.unique_integer([:positive])}"

      PubSub.subscribe_execution(execution_id)

      :telemetry.attach(
        handler_id,
        [:imgd, :node, :stop],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        PubSub.unsubscribe_execution(execution_id)
        :telemetry.detach(handler_id)
      end)

      workflow =
        Workflow.new(name: "obs_test")
        |> Workflow.add(Runic.step(fn _ -> [1, 2, 3] end, name: "list_step"))
        |> Observability.attach_all_hooks(execution_id: execution_id, workflow_id: "wf-1")

      _finished = Workflow.react_until_satisfied(workflow, :input)

      assert_receive {:node_completed, payload}
      assert payload.node_id == "list_step"
      assert payload.output_item_count == 3

      assert_receive {:telemetry_event, [:imgd, :node, :stop], measurements, metadata}
      assert measurements.duration_us >= 0
      assert metadata.output_item_count == 3
    end
  end

  defp ensure_pubsub_started do
    if Process.whereis(Imgd.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: Imgd.PubSub})
    end
  end
end
