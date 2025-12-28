defmodule ImgdWeb.WorkflowLive.CollaborationTest do
  use ImgdWeb.ConnCase
  import Phoenix.LiveViewTest
  import Imgd.AccountsFixtures
  alias Imgd.Workflows

  @moduletag :capture_log

  describe "Collaborative Editing" do
    test "live updates are propagated immediately between sessions", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      scope = %Imgd.Accounts.Scope{user: user}

      {:ok, workflow} =
        Workflows.create_workflow(
          scope,
          %{name: "Collab Test"}
        )

      # Ensure draft exists
      {:ok, _} = Workflows.update_workflow_draft(scope, workflow, %{})

      # Session 1
      {:ok, view1, _html} = live(conn, ~p"/workflows/#{workflow.id}/edit")

      # Session 2
      {:ok, view2, _html} = live(conn, ~p"/workflows/#{workflow.id}/edit")

      # Initial state check
      vue1 = LiveVue.Test.get_vue(view1)
      assert vue1.props["workflow"]["draft"]["steps"] == []

      # Add step in Session 1
      # Note: We need a valid step type. Assuming 'webhook' or 'manual' exists.
      # Checking registry might be safer but 'webhook' is usually there.
      type_id = "manual_input"

      render_hook(view1, "add_step", %{
        "type_id" => type_id,
        "position" => %{"x" => 100, "y" => 100}
      })

      # Wait for broadcast and processing
      # We assertions with a small retries/sleep implicitly via assert_receive usually,
      # but here we are checking the view state which is updated via handle_info.
      # render(view2) triggers a re-render check.

      # We need to ensure view2 processed the message.
      # The easiest way is to push a sync event or just sleep briefly since it's an async test.
      Process.sleep(200)

      # Force a render to ensure the view has processed all messages
      render(view2)

      # Check Session 2
      vue2 = LiveVue.Test.get_vue(view2)
      steps = vue2.props["workflow"]["draft"]["steps"]

      assert length(steps) == 1
      assert hd(steps)["type_id"] == type_id
    end
  end
end
