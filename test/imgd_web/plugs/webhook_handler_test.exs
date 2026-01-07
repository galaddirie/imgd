defmodule ImgdWeb.Plugs.WebhookHandlerTest do
  use ImgdWeb.ConnCase, async: true

  alias Imgd.Repo
  alias Imgd.Workflows.Workflow
  alias Imgd.Executions.Execution
  import Imgd.Factory

  describe "POST /api/hooks/:workflow_id" do
    setup do
      user = insert(:user)
      workflow = insert(:workflow, user: user, status: :active, public: true)

      # Use Repo.insert directly for version to ensure correct associations
      version =
        %Imgd.Workflows.WorkflowVersion{
          workflow_id: workflow.id,
          version_tag: "1.0.0",
          source_hash: "0000000000000000000000000000000000000000000000000000000000000000",
          steps: [%{id: "step_1", type_id: "debug", name: "Debug 1", config: %{}, position: %{}}],
          connections: [],
          triggers: []
        }
        |> Repo.insert!()

      Repo.update_all(Workflow, set: [published_version_id: version.id])

      %{workflow: workflow, version: version}
    end

    test "successfully triggers a workflow with JSON payload", %{conn: conn, workflow: workflow} do
      payload = %{"event" => "order_created", "id" => 123}

      conn = post(conn, ~p"/api/hooks/#{workflow.id}", payload)

      assert json_response(conn, 202)["status"] == "accepted"

      # Verify execution was created
      execution = Repo.one(Execution)
      assert execution.workflow_id == workflow.id
      assert execution.trigger.type == :webhook
      assert execution.trigger.data["body"] == payload
      assert execution.status == :pending
    end

    test "successfully triggers with complex nested JSON and query params", %{
      conn: conn,
      workflow: workflow
    } do
      payload = %{
        "user" => %{"id" => 123, "meta" => %{"role" => "admin"}},
        "items" => [1, 2, 3]
      }

      conn =
        conn
        |> put_req_header("x-custom-event", "test_event")
        |> post(~p"/api/hooks/#{workflow.id}?debug=true", payload)

      assert json_response(conn, 202)["status"] == "accepted"

      execution = Repo.one(Execution)
      trigger_data = execution.trigger.data

      # Verify nested body
      assert trigger_data["body"]["user"]["meta"]["role"] == "admin"
      assert trigger_data["body"]["items"] == [1, 2, 3]

      # Verify query params
      assert trigger_data["params"]["debug"] == "true"

      # Verify headers (case-insensitive keys in Plug usually)
      assert trigger_data["headers"]["x-custom-event"] == "test_event"
    end

    test "returns 400 for malformed JSON body", %{conn: conn, workflow: workflow} do
      # Bypass Phoenix's automatic JSON parsing to send malformed string
      assert_raise Plug.Parsers.ParseError, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> dispatch_raw(
          ImgdWeb.Endpoint,
          :post,
          ~p"/api/hooks/#{workflow.id}",
          "{\"invalid\": json"
        )
      end
    end

    test "returns 404 for non-existent workflow", %{conn: conn} do
      id = Ecto.UUID.generate()
      conn = post(conn, ~p"/api/hooks/#{id}", %{})
      assert json_response(conn, 404)["errors"]["detail"] == "Workflow not found"
    end

    test "returns 403 if workflow is not active", %{conn: conn} do
      workflow = insert(:workflow, status: :archived, public: true)
      conn = post(conn, ~p"/api/hooks/#{workflow.id}", %{})
      assert json_response(conn, 403)["errors"]["detail"] == "Workflow is not active"
    end

    test "returns 400 if workflow has no published version", %{conn: conn} do
      workflow = insert(:workflow, status: :active, public: true)
      conn = post(conn, ~p"/api/hooks/#{workflow.id}", %{})
      assert json_response(conn, 400)["errors"]["detail"] == "Workflow is not published"
    end
  end

  # Helper to dispatch raw requests
  defp dispatch_raw(conn, endpoint, method, path, body) do
    Phoenix.ConnTest.dispatch(conn, endpoint, method, path, body)
  end
end
