defmodule ImgdWeb.Plugs.WebhookTestTriggerTest do
  use ImgdWeb.ConnCase, async: false

  alias Imgd.Accounts
  alias Imgd.Repo
  # alias Imgd.Workflows.Workflow # unused
  alias Imgd.Executions.Execution
  alias Imgd.Collaboration.EditSession.Server
  import Imgd.Factory

  describe "POST /api/hook-test/:path" do
    setup do
      user = insert(:user)
      # Create a workflow in DRAFT mode (unpublished)
      workflow = insert(:workflow, user: user, status: :draft, public: false)
      {:ok, {_api_key, api_token}} = Accounts.create_api_key(user, %{name: "Test key"})

      # Create a draft with a webhook trigger
      draft =
        %Imgd.Workflows.WorkflowDraft{
          workflow_id: workflow.id,
          steps: [
            %{id: "step_1", type_id: "debug", name: "Debug 1", config: %{}, position: %{}},
            %{
              id: "webhook_1",
              type_id: "webhook_trigger",
              name: "Webhook",
              config: %{"path" => "my-test-path", "response_mode" => "immediate"},
              position: %{}
            }
          ],
          connections: [],
          settings: %{}
        }
        |> Repo.insert!()

      _pid = start_supervised!({Imgd.Collaboration.EditSession.Server, workflow_id: workflow.id})

      %{workflow: workflow, user: user, draft: draft, api_token: api_token}
    end

    test "successfully triggers a DRAFT workflow via test endpoint", %{
      conn: conn,
      workflow: workflow,
      user: user,
      api_token: api_token
    } do
      payload = %{"test" => "data"}

      # Use the test endpoint with the path defined in the draft trigger
      {:ok, _} =
        Server.enable_test_webhook(workflow.id, %{
          path: "my-test-path",
          method: "POST",
          user_id: user.id
        })

      conn =
        conn
        |> auth_conn(api_token)
        |> post(~p"/api/hook-test/my-test-path", payload)

      assert json_response(conn, 202)["status"] == "accepted"

      # Verify execution was created with type :preview
      execution = Repo.one(Execution)
      assert execution.workflow_id == workflow.id
      assert execution.execution_type == :preview
      assert execution.trigger.type == :webhook
      assert execution.trigger.data["body"] == payload
    end

    test "fails if workflow logic requires published version but we access via prod endpoint", %{
      conn: conn,
      workflow: _workflow
    } do
      # Confirm that accessing via /api/hooks/ (prod) fails because it's not published/active
      conn = post(conn, ~p"/api/hooks/my-test-path", %{})
      # Or 400 depending on exact logic, but definitely not success
      assert json_response(conn, 404)
    end

    test "requires an API key for test webhooks", %{conn: conn} do
      conn = post(conn, ~p"/api/hook-test/my-test-path", %{})
      assert json_response(conn, 401)["errors"]["detail"] == "API key required"
    end

    test "returns 404 when test webhook is not enabled", %{conn: conn, api_token: api_token} do
      conn =
        conn
        |> auth_conn(api_token)
        |> post(~p"/api/hook-test/my-test-path", %{})

      assert json_response(conn, 404)["errors"]["detail"] == "Test webhook is not enabled"
    end
  end

  defp auth_conn(conn, api_token) do
    put_req_header(conn, "authorization", "Bearer #{api_token}")
  end
end
