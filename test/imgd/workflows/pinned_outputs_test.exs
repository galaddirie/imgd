defmodule Imgd.Workflows.PinnedOutputsTest do
  use Imgd.DataCase, async: true

  import Imgd.AccountsFixtures

  alias Imgd.Workflows

  setup do
    scope = user_scope_fixture()

    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        name: "Test workflow",
        nodes: [
          %{
            id: "a",
            type_id: "test.node",
            name: "Node A",
            config: %{"foo" => "bar"}
          }
        ],
        connections: []
      })

    %{scope: scope, workflow: workflow}
  end

  test "pins and unpins output", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.pin_node_output(scope, workflow, "a", %{"value" => 42})

    assert %{"a" => %{"data" => %{"value" => 42}}} = workflow.pinned_outputs
    assert get_in(workflow.pinned_outputs, ["a", "pinned_by"]) == scope.user.id

    {:ok, workflow} = Workflows.unpin_node_output(scope, workflow, "a")
    assert workflow.pinned_outputs == %{}
  end

  test "staleness is detected when node config changes", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.pin_node_output(scope, workflow, "a", %{"ok" => true})

    {:ok, updated_workflow} =
      Workflows.update_workflow(scope, workflow, %{
        nodes: [
          %{
            id: "a",
            type_id: "test.node",
            name: "Node A",
            config: %{"foo" => "updated"}
          }
        ]
      })

    pins = Workflows.get_pinned_outputs_with_status(updated_workflow)
    assert pins["a"]["stale"]
    assert pins["a"]["node_exists"]
  end
end
