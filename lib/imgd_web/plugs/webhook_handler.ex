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
    path_segments = conn.params["path"] || []
    path = Enum.join(path_segments, "/")
    scope = conn.assigns[:current_scope]

    # 1. Try lookup by path first (new way)
    workflow = Imgd.Workflows.get_active_workflow_by_webhook(path, conn.method)

    # 2. Try lookup by ID if first segment is a UUID (legacy way)
    workflow =
      if is_nil(workflow) do
        case List.first(path_segments) do
          nil ->
            nil

          id ->
            case Ecto.UUID.cast(id) do
              {:ok, uuid} ->
                Repo.get(Workflow, uuid)

              _ ->
                nil
            end
        end
      else
        workflow
      end

    case workflow do
      nil ->
        send_error(conn, 404, "Workflow not found")

      %Workflow{status: status} when status != :active ->
        send_error(conn, 403, "Workflow is not active")

      %Workflow{published_version_id: nil} ->
        send_error(conn, 400, "Workflow is not published")

      %Workflow{status: :active, published_version_id: _pub_id} = workflow ->
        if Scope.can_view_workflow?(scope, workflow) do
          # Preload triggers to find the right one
          workflow = Repo.preload(workflow, :published_version)
          trigger = find_webhook_trigger(workflow.published_version.triggers)
          handle_trigger(conn, workflow, scope, trigger)
        else
          send_error(conn, 404, "Workflow not found")
        end
    end
  end

  defp find_webhook_trigger(triggers) do
    Enum.find(triggers, fn t -> t.type == :webhook end)
  end

  defp handle_trigger(conn, workflow, scope, trigger) do
    config = (trigger && trigger.config) || %{}
    response_mode = Map.get(config, "response_mode", "immediate")

    # 1. Extract payload
    payload = %{
      "body" => conn.body_params,
      "params" => conn.params,
      "headers" => Enum.into(conn.req_headers, %{}),
      "method" => conn.method
    }

    # 2. Create execution record base attributes
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

    case response_mode do
      "on_respond_node" ->
        # Pass handler PID as ephemeral option
        case Executions.create_execution(scope, attrs) do
          {:ok, execution} ->
            # Start execution directly (do not use run_sync as it blocks)
            # Pass webhook_handler_pid to Server via Supervisor
            case Imgd.Runtime.Execution.Supervisor.start_execution(execution.id,
                   webhook_handler_pid: self()
                 ) do
              {:ok, pid} ->
                monitor_ref = Process.monitor(pid)
                wait_for_response(conn, monitor_ref, execution.id)

              {:error, {:already_started, pid}} ->
                monitor_ref = Process.monitor(pid)
                wait_for_response(conn, monitor_ref, execution.id)

              {:error, reason} ->
                handle_creation_error(conn, reason)
            end

          {:error, reason} ->
            handle_creation_error(conn, reason)
        end

      "on_completion" ->
        case Executions.create_execution(scope, attrs) do
          {:ok, execution} ->
            ExecutionWorker.run_sync(execution.id)
            # Re-fetch to get output
            execution = Repo.get!(Imgd.Executions.Execution, execution.id)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(execution.output || %{}))

          {:error, reason} ->
            handle_creation_error(conn, reason)
        end

      _ ->
        # "immediate" or default
        case Executions.create_execution(scope, attrs) do
          {:ok, execution} ->
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
            handle_creation_error(conn, reason)
        end
    end
  end

  defp handle_creation_error(conn, reason) do
    Logger.error("Failed to create execution for webhook: #{inspect(reason)}")
    send_error(conn, 500, "Internal error")
  end

  defp wait_for_response(conn, monitor_ref, _execution_id) do
    receive do
      {:webhook_response, data} ->
        # We got the response we wanted!
        Process.demonitor(monitor_ref, [:flush])

        conn
        |> put_resp_content_type(Map.get(data, :content_type, "application/json"))
        |> send_resp(Map.get(data, :status, 200), Jason.encode!(Map.get(data, :body, %{})))

      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        # Process died before sending response
        send_error(conn, 502, "Workflow completed without sending a response")
    after
      30_000 ->
        Process.demonitor(monitor_ref, [:flush])
        send_error(conn, 504, "Workflow timed out waiting for response")
    end
  end

  defp send_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{errors: %{detail: message}}))
    |> halt()
  end
end
