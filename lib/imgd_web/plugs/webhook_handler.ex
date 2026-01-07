defmodule ImgdWeb.Plugs.WebhookHandler do
  @moduledoc """
  Plug to handle incoming webhook triggers.

  Routes requests to `/api/hooks/:workflow_id`.
  """
  import Plug.Conn
  require Logger

  alias Imgd.Repo
  alias Imgd.Workflows.Workflow
  alias Imgd.Executions
  alias Imgd.Workers.ExecutionWorker
  alias Imgd.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    workflow_id = conn.params["workflow_id"]
    scope = conn.assigns[:current_scope]

    case Repo.get(Workflow, workflow_id) do
      %Workflow{status: :active, published_version_id: pub_id} = workflow
      when not is_nil(pub_id) ->
        if Scope.can_view_workflow?(scope, workflow) do
          handle_trigger(conn, workflow, scope)
        else
          send_error(conn, 404, "Workflow not found")
        end

      %Workflow{status: :active} ->
        send_error(conn, 400, "Workflow is not published")

      %Workflow{} ->
        send_error(conn, 403, "Workflow is not active")

      nil ->
        send_error(conn, 404, "Workflow not found")
    end
  end

  defp handle_trigger(conn, workflow, scope) do
    # 1. Extract payload
    payload = %{
      "body" => conn.body_params,
      "params" => conn.params,
      "headers" => Enum.into(conn.req_headers, %{}),
      "method" => conn.method
    }

    # 2. Create execution record
    attrs = %{
      workflow_id: workflow.id,
      execution_type: :production,
      trigger: %{
        "type" => "webhook",
        "data" => payload
      },
      metadata: %{
        "source" => "webhook",
        "remote_ip" => to_string(:inet.ntoa(conn.remote_ip))
      }
    }

    case Executions.create_execution(scope, attrs) do
      {:ok, execution} ->
        # 3. Enqueue for background execution
        ExecutionWorker.enqueue(execution.id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          202,
          Jason.encode!(%{
            status: "accepted",
            execution_id: execution.id
          })
        )

      {:error, reason} ->
        Logger.error("Failed to create execution for webhook: #{inspect(reason)}")
        send_error(conn, 500, "Internal error")
    end
  end

  defp send_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{errors: %{detail: message}}))
    |> halt()
  end
end
