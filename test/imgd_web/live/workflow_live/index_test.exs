defmodule ImgdWeb.WorkflowLive.IndexTest do
  use ImgdWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Imgd.AccountsFixtures
  import Imgd.WorkflowsFixtures

  describe "authentication" do
    test "redirects guests to log in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/workflows")
      assert {:redirect, %{to: path}} = redirect
      assert path == ~p"/users/log-in"
    end
  end

  describe "index" do
    setup [:register_and_log_in_user]

    test "renders workflows for the current user", %{
      conn: conn,
      scope: scope
    } do
      draft = draft_workflow_fixture(scope)
      published = published_workflow_fixture(scope)
      archived = archived_workflow_fixture(scope)

      # Another user's workflows should never leak into this view
      other_scope = Imgd.Accounts.Scope.for_user(user_fixture())
      other_workflow = draft_workflow_fixture(other_scope)

      {:ok, view, _html} = live(conn, ~p"/workflows")

      assert has_element?(
               view,
               "#workflow-#{draft.id} [data-role=\"status\"][data-status=\"draft\"]"
             )

      assert has_element?(
               view,
               "#workflow-#{published.id} [data-role=\"status\"][data-status=\"published\"]"
             )

      assert has_element?(
               view,
               "#workflow-#{archived.id} [data-role=\"status\"][data-status=\"archived\"]"
             )

      refute has_element?(view, "#workflow-#{other_workflow.id}")
    end
  end
end
