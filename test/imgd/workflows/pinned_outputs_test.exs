defmodule Imgd.Workflows.PinnedOutputsTest do
  use Imgd.DataCase, async: false

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

    session_pid =
      start_supervised!(
        {Imgd.Workflows.EditingSession.Server, [scope: scope, workflow: workflow]}
      )

    %{scope: scope, workflow: workflow, session_pid: session_pid}
  end

  test "pins and unpins output", %{scope: scope, workflow: workflow, session_pid: session_pid} do
    :ok = Workflows.pin_node_output(scope, workflow, "a", %{"value" => 42})

    state = :sys.get_state(session_pid)
    pin = Map.get(state.pinned_outputs, "a")
    assert pin.data == %{"value" => 42}
    assert pin.user_id == scope.user.id

    pins = EditingSessions.get_pins_with_status_from_server(session_pid, workflow)
    assert %{"a" => %{"data" => %{"value" => 42}}} = pins

    {:ok, session} = EditingSessions.get_or_create_session(scope, workflow)
    {:ok, _} = Workflows.unpin_node_output(scope, workflow, "a")
    assert EditingSessions.list_pins(session) == []
  end

  test "staleness is detected when node config changes", %{
    scope: scope,
    workflow: workflow,
    session_pid: session_pid
  } do
    :ok = Workflows.pin_node_output(scope, workflow, "a", %{"ok" => true})

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

    pins = EditingSessions.get_pins_with_status_from_server(session_pid, updated_workflow)
    assert pins["a"]["stale"]
    assert pins["a"]["node_exists"]
  end
end
