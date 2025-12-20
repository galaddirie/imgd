defmodule ImgdWeb.WorkflowLive.RunnerTest do
  use ImgdWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Imgd.Factory

  setup %{conn: conn} do
    user = insert(:user)
    workflow = insert(:workflow, user: user)
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, workflow: workflow}
  end

  test "mounts successfully with a workflow snapshot execution", %{
    conn: conn,
    workflow: workflow,
    user: user
  } do
    # Create an execution with a snapshot
    snapshot = insert(:workflow_snapshot, workflow: workflow, created_by: user)

    execution =
      insert(:execution,
        workflow: workflow,
        workflow_version: nil,
        workflow_snapshot: snapshot,
        execution_type: :preview
      )

    # Navigate to the runner with the execution_id
    {:ok, _view, html} =
      live(conn, ~p"/workflows/#{workflow.id}/run?execution_id=#{execution.id}")

    assert html =~ "Run: #{workflow.name}"
    assert html =~ "Debug 1"
  end
end
