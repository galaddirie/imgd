defmodule Imgd.Observability.PromEx.Plugins.Engine do
  @moduledoc """
  PromEx plugin for imgd workflow engine metrics.

  ## Metrics Exposed

  ### Execution Metrics
  - `imgd_engine_execution_total` - Counter of workflow executions by status
  - `imgd_engine_execution_duration_milliseconds` - Histogram of execution duration
  - `imgd_engine_execution_active` - Gauge of currently active executions
  - `imgd_engine_execution_pending` - Gauge of pending executions

  ### Node Metrics
  - `imgd_engine_node_total` - Counter of node executions by status and type
  - `imgd_engine_node_duration_milliseconds` - Histogram of node duration
  - `imgd_engine_node_queue_time_milliseconds` - Histogram of node queue wait time
  - `imgd_engine_node_exception_total` - Counter of node exceptions
  - `imgd_engine_node_retry_total` - Counter of node retries
  - `imgd_engine_nodes_running` - Gauge of currently running nodes

  ### Expression Metrics
  - `imgd_engine_expression_total` - Counter of expression evaluations
  - `imgd_engine_expression_duration_microseconds` - Histogram of expression evaluation time

  ## Cardinality Notes

  Be careful with high-cardinality labels. The following are safe:
  - `status` - bounded set of statuses
  - `trigger_type` - bounded set (manual, webhook, schedule, event)
  - `node_type_id` - bounded by registered node types

  Avoid using `execution_id` or `node_id` as labels - use trace correlation instead.
  """

  use PromEx.Plugin

  require Logger

  alias Imgd.Executions.{Execution, NodeExecution}

  @execution_duration_buckets [
    10,
    50,
    100,
    250,
    500,
    1_000,
    2_500,
    5_000,
    10_000,
    30_000,
    60_000,
    300_000
  ]
  @node_duration_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
  @queue_time_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]
  @expression_duration_buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :imgd_engine_event_metrics,
      [
        # ==================================================================
        # Execution Metrics
        # ==================================================================

        counter(
          [:imgd, :engine, :execution, :total],
          event_name: [:imgd, :engine, :execution, :stop],
          description: "Total number of workflow executions",
          tags: [:workflow_id, :status, :trigger_type],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              status: safe_atom(meta.status),
              trigger_type: safe_atom(meta[:trigger_type])
            }
          end
        ),
        distribution(
          [:imgd, :engine, :execution, :duration, :milliseconds],
          event_name: [:imgd, :engine, :execution, :stop],
          description: "Workflow execution duration in milliseconds",
          measurement: :duration_ms,
          tags: [:workflow_id, :status],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              status: safe_atom(meta.status)
            }
          end,
          reporter_options: [buckets: @execution_duration_buckets],
          unit: :millisecond
        ),
        counter(
          [:imgd, :engine, :execution, :exception, :total],
          event_name: [:imgd, :engine, :execution, :exception],
          description: "Total number of workflow execution exceptions",
          tags: [:workflow_id, :exception_type],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              exception_type: exception_type(meta[:exception])
            }
          end
        ),

        # ==================================================================
        # Node Metrics
        # ==================================================================

        counter(
          [:imgd, :engine, :node, :total],
          event_name: [:imgd, :engine, :node, :stop],
          description: "Total number of node executions",
          tags: [:workflow_id, :node_type_id, :status],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              node_type_id: safe_string(meta.node_type_id),
              status: safe_atom(meta.status)
            }
          end
        ),
        distribution(
          [:imgd, :engine, :node, :duration, :milliseconds],
          event_name: [:imgd, :engine, :node, :stop],
          description: "Node execution duration in milliseconds",
          measurement: :duration_ms,
          tags: [:workflow_id, :node_type_id, :status],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              node_type_id: safe_string(meta.node_type_id),
              status: safe_atom(meta.status)
            }
          end,
          reporter_options: [buckets: @node_duration_buckets],
          unit: :millisecond
        ),

        # Queue time - how long nodes wait before starting
        distribution(
          [:imgd, :engine, :node, :queue_time, :milliseconds],
          event_name: [:imgd, :engine, :node, :start],
          description: "Node queue wait time in milliseconds",
          measurement: fn measurements ->
            # Return nil if not present, which will skip the measurement
            measurements[:queue_time_ms]
          end,
          tags: [:workflow_id, :node_type_id],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              node_type_id: safe_string(meta.node_type_id)
            }
          end,
          reporter_options: [buckets: @queue_time_buckets],
          unit: :millisecond
        ),
        counter(
          [:imgd, :engine, :node, :exception, :total],
          event_name: [:imgd, :engine, :node, :exception],
          description: "Total number of node execution exceptions",
          tags: [:workflow_id, :node_type_id, :exception_type],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              node_type_id: safe_string(meta.node_type_id),
              exception_type: exception_type(meta[:exception])
            }
          end
        ),

        # Retry tracking
        counter(
          [:imgd, :engine, :node, :retry, :total],
          event_name: [:imgd, :engine, :node, :retry],
          description: "Total number of node retries",
          tags: [:workflow_id, :node_type_id],
          tag_values: fn meta ->
            %{
              workflow_id: safe_string(meta.workflow_id),
              node_type_id: safe_string(meta.node_type_id)
            }
          end
        ),
        distribution(
          [:imgd, :engine, :node, :retry, :backoff, :milliseconds],
          event_name: [:imgd, :engine, :node, :retry],
          description: "Node retry backoff time in milliseconds",
          measurement: :backoff_ms,
          tags: [:node_type_id],
          tag_values: fn meta ->
            %{node_type_id: safe_string(meta.node_type_id)}
          end,
          reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 30_000, 60_000]],
          unit: :millisecond
        ),

        # ==================================================================
        # Expression Metrics (lightweight, high-frequency)
        # ==================================================================

        counter(
          [:imgd, :engine, :expression, :total],
          event_name: [:imgd, :engine, :expression, :evaluate],
          description: "Total number of expression evaluations",
          tags: [:expression_type, :status],
          tag_values: fn meta ->
            %{
              expression_type: safe_atom(meta[:expression_type]),
              status: safe_atom(meta[:status])
            }
          end
        ),
        distribution(
          [:imgd, :engine, :expression, :duration, :microseconds],
          event_name: [:imgd, :engine, :expression, :evaluate],
          description: "Expression evaluation duration in microseconds",
          measurement: :duration_us,
          tags: [:expression_type],
          tag_values: fn meta ->
            %{expression_type: safe_atom(meta[:expression_type])}
          end,
          reporter_options: [buckets: @expression_duration_buckets],
          unit: :microsecond
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
          description: "Number of currently active (running) workflow executions",
          measurement: :active_executions
        ),
        last_value(
          [:imgd, :engine, :executions, :pending],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of pending workflow executions",
          measurement: :pending_executions
        ),
        last_value(
          [:imgd, :engine, :executions, :paused],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of paused workflow executions (waiting for callback)",
          measurement: :paused_executions
        ),
        last_value(
          [:imgd, :engine, :nodes, :running],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of currently running nodes",
          measurement: :running_nodes
        ),
        last_value(
          [:imgd, :engine, :nodes, :queued],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of queued nodes waiting to run",
          measurement: :queued_nodes
        )
      ]
    )
  end

  @doc false
  def poll_engine_stats do
    import Ecto.Query

    stats = %{
      active_executions: count_executions(:running),
      pending_executions: count_executions(:pending),
      paused_executions: count_executions(:paused),
      running_nodes: count_nodes(:running),
      queued_nodes: count_nodes(:queued)
    }

    :telemetry.execute([:imgd, :engine, :stats, :poll], stats, %{})
  rescue
    e ->
      Logger.warning("Failed to poll engine stats: #{Exception.message(e)}")

      :telemetry.execute(
        [:imgd, :engine, :stats, :poll],
        %{
          active_executions: 0,
          pending_executions: 0,
          paused_executions: 0,
          running_nodes: 0,
          queued_nodes: 0
        },
        %{}
      )
  end

  defp count_executions(status) do
    import Ecto.Query

    Execution
    |> where([e], e.status == ^status)
    |> Imgd.Repo.aggregate(:count, :id)
  end

  defp count_nodes(status) do
    import Ecto.Query

    NodeExecution
    |> where([ne], ne.status == ^status)
    |> Imgd.Repo.aggregate(:count, :id)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp exception_type(%{__struct__: struct}), do: struct |> Module.split() |> List.last()

  defp exception_type(%{__exception__: true} = e),
    do: e.__struct__ |> Module.split() |> List.last()

  defp exception_type(_), do: "unknown"

  defp safe_string(nil), do: "unknown"
  defp safe_string(val) when is_binary(val), do: val
  defp safe_string(val) when is_atom(val), do: Atom.to_string(val)
  defp safe_string(val), do: to_string(val)

  defp safe_atom(nil), do: "unknown"
  defp safe_atom(val) when is_atom(val), do: Atom.to_string(val)
  defp safe_atom(val) when is_binary(val), do: val
  defp safe_atom(val), do: to_string(val)
end
