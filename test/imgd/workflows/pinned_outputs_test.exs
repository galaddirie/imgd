defmodule Imgd.Workflows.PinnedOutputsTest do
  use Imgd.DataCase, async: true

  import Imgd.AccountsFixtures

  alias Imgd.Workflows
  alias Imgd.Workflows.EditingSessions

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
    {:ok, pin} = Workflows.pin_node_output(scope, workflow, "a", %{"value" => 42})

    assert pin.data == %{"value" => 42}
    assert pin.user_id == scope.user.id

    {:ok, session} = EditingSessions.get_or_create_session(scope, workflow)
    pins = EditingSessions.get_pins_with_status(session, workflow)
    assert %{"a" => %{"data" => %{"value" => 42}}} = pins

    {:ok, _} = Workflows.unpin_node_output(scope, workflow, "a")
    assert EditingSessions.list_pins(session) == []
  end

  test "staleness is detected when node config changes", %{scope: scope, workflow: workflow} do
    {:ok, _pin} = Workflows.pin_node_output(scope, workflow, "a", %{"ok" => true})

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

    {:ok, session} = EditingSessions.get_or_create_session(scope, updated_workflow)
    pins = EditingSessions.get_pins_with_status(session, updated_workflow)
    assert pins["a"]["stale"]
    assert pins["a"]["node_exists"]
  end
end
