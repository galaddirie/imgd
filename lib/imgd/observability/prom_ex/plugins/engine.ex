defmodule Imgd.Observability.PromEx.Plugins.Engine do
  @moduledoc """
  PromEx plugin for imgd workflow engine metrics.

  ## Metrics Exposed

  ### Execution Metrics
  - `imgd_engine_execution_total` - Counter of workflow executions by status
  - `imgd_engine_execution_duration_milliseconds` - Histogram of execution duration
  - `imgd_engine_execution_active` - Gauge of currently active executions

  ### Node Metrics
  - `imgd_engine_node_total` - Counter of node executions by status and type
  - `imgd_engine_node_duration_milliseconds` - Histogram of node duration
  - `imgd_engine_node_exception_total` - Counter of node exceptions
  """

  use PromEx.Plugin

  require Logger

  alias Imgd.Executions.{Execution, NodeExecution}

  @execution_duration_buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000]
  @node_duration_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :imgd_engine_event_metrics,
      [
        # ====================================================================
        # Execution Metrics
        # ====================================================================

        counter(
          [:imgd, :engine, :execution, :total],
          event_name: [:imgd, :engine, :execution, :stop],
          description: "Total number of workflow executions",
          tags: [
            :workflow_id,
            :workflow_version_id,
            :workflow_version_tag,
            :status,
            :trigger_type
          ],
          tag_values: &execution_tag_values/1
        ),
        distribution(
          [:imgd, :engine, :execution, :duration, :milliseconds],
          event_name: [:imgd, :engine, :execution, :stop],
          description: "Workflow execution duration in milliseconds",
          measurement: :duration_ms,
          tags: [:workflow_id, :workflow_version_id, :workflow_version_tag, :status],
          tag_values: &execution_tag_values/1,
          reporter_options: [buckets: @execution_duration_buckets],
          unit: :millisecond
        ),
        counter(
          [:imgd, :engine, :execution, :exception, :total],
          event_name: [:imgd, :engine, :execution, :exception],
          description: "Total number of workflow execution exceptions",
          tags: [:workflow_id, :workflow_version_id, :workflow_version_tag, :exception_type],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              workflow_version_id: safe_string(meta.workflow_version_id),
              workflow_version_tag: safe_string(meta[:workflow_version_tag]),
              exception_type: exception_type(meta.exception)
            }
          end
        ),

        # ====================================================================
        # Node Metrics
        # ====================================================================

        counter(
          [:imgd, :engine, :node, :total],
          event_name: [:imgd, :engine, :node, :stop],
          description: "Total number of node executions",
          tags: [:workflow_id, :workflow_version_id, :node_id, :node_type_id, :status],
          tag_values: &node_tag_values/1
        ),
        distribution(
          [:imgd, :engine, :node, :duration, :milliseconds],
          event_name: [:imgd, :engine, :node, :stop],
          description: "Node execution duration in milliseconds",
          measurement: :duration_ms,
          tags: [:workflow_id, :workflow_version_id, :node_id, :node_type_id, :status],
          tag_values: &node_tag_values/1,
          reporter_options: [buckets: @node_duration_buckets],
          unit: :millisecond
        ),
        counter(
          [:imgd, :engine, :node, :exception, :total],
          event_name: [:imgd, :engine, :node, :exception],
          description: "Total number of node execution exceptions",
          tags: [:workflow_id, :workflow_version_id, :node_id, :node_type_id, :exception_type],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              workflow_version_id: safe_string(meta.workflow_version_id),
              node_id: safe_string(meta.node_id),
              node_type_id: safe_string(meta.node_type_id),
              exception_type: exception_type(meta.exception)
            }
          end
        )
      ]
    )
  end

  @impl true
  def polling_metrics(_opts) do
    Polling.build(
      :imgd_engine_polling_metrics,
      5_000,
      {__MODULE__, :poll_engine_stats, []},
      [
        last_value(
          [:imgd, :engine, :executions, :active],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of currently active workflow executions",
          measurement: :active_executions
        ),
        last_value(
          [:imgd, :engine, :executions, :pending],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of pending workflow executions",
          measurement: :pending_executions
        ),
        last_value(
          [:imgd, :engine, :nodes, :running],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of currently running nodes",
          measurement: :running_nodes
        )
      ]
    )
  end

  @doc false
  def poll_engine_stats do
    import Ecto.Query

    # Count active executions
    active_executions =
      Execution
      |> where([e], e.status == :running)
      |> Imgd.Repo.aggregate(:count, :id)

    pending_executions =
      Execution
      |> where([e], e.status == :pending)
      |> Imgd.Repo.aggregate(:count, :id)

    running_nodes =
      NodeExecution
      |> where([ne], ne.status == :running)
      |> Imgd.Repo.aggregate(:count, :id)

    :telemetry.execute(
      [:imgd, :engine, :stats, :poll],
      %{
        active_executions: active_executions,
        pending_executions: pending_executions,
        running_nodes: running_nodes
      },
      %{}
    )
  rescue
    e ->
      Logger.warning("Failed to poll engine stats: #{Exception.message(e)}")

      :telemetry.execute(
        [:imgd, :engine, :stats, :poll],
        %{active_executions: 0, pending_executions: 0, running_nodes: 0},
        %{}
      )
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp execution_tag_values(meta) do
    %{
      workflow_id: safe_string(meta.workflow_id),
      workflow_version_id: safe_string(meta.workflow_version_id),
      workflow_version_tag: safe_string(meta[:workflow_version_tag]),
      status: safe_atom(meta.status),
      trigger_type: safe_atom(meta[:trigger_type])
    }
  end

  defp node_tag_values(meta) do
    %{
      workflow_id: safe_string(meta.workflow_id),
      workflow_version_id: safe_string(meta.workflow_version_id),
      node_id: safe_string(meta.node_id),
      node_type_id: safe_string(meta.node_type_id),
      status: safe_atom(meta.status)
    }
  end

  defp exception_type(%{__struct__: struct}), do: struct |> Module.split() |> List.last()
  defp exception_type(_), do: "unknown"

  defp safe_string(nil), do: "unknown"
  defp safe_string(val) when is_binary(val), do: val
  defp safe_string(val), do: to_string(val)

  defp safe_atom(nil), do: "unknown"
  defp safe_atom(val) when is_atom(val), do: to_string(val)
  defp safe_atom(val), do: to_string(val)
end
