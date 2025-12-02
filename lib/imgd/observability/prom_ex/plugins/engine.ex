defmodule Imgd.Observability.PromEx.Plugins.Engine do
  @moduledoc """
  PromEx plugin for imgd workflow engine metrics.

  ## Metrics Exposed

  ### Execution Metrics
  - `imgd_engine_execution_total` - Counter of workflow executions by status
  - `imgd_engine_execution_duration_milliseconds` - Histogram of execution duration
  - `imgd_engine_execution_active` - Gauge of currently active executions

  ### Step Metrics
  - `imgd_engine_step_total` - Counter of step executions by status and type
  - `imgd_engine_step_duration_milliseconds` - Histogram of step duration
  - `imgd_engine_step_retries_total` - Counter of step retries

  ### Checkpoint Metrics
  - `imgd_engine_checkpoint_total` - Counter of checkpoints by reason
  - `imgd_engine_checkpoint_duration_milliseconds` - Histogram of checkpoint creation time
  - `imgd_engine_checkpoint_size_bytes` - Histogram of checkpoint sizes

  ### Generation Metrics
  - `imgd_engine_generation_duration_milliseconds` - Histogram of generation completion time
  """

  use PromEx.Plugin

  require Logger

  @execution_duration_buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000]
  @step_duration_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]
  @checkpoint_size_buckets [1_000, 10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000]

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
          tags: [:workflow_id, :workflow_name, :status, :trigger_type],
          tag_values: &execution_tag_values/1
        ),

        distribution(
          [:imgd, :engine, :execution, :duration, :milliseconds],
          event_name: [:imgd, :engine, :execution, :stop],
          description: "Workflow execution duration in milliseconds",
          measurement: :duration_ms,
          tags: [:workflow_id, :workflow_name, :status],
          tag_values: &execution_tag_values/1,
          reporter_options: [buckets: @execution_duration_buckets],
          unit: :millisecond
        ),

        counter(
          [:imgd, :engine, :execution, :exception, :total],
          event_name: [:imgd, :engine, :execution, :exception],
          description: "Total number of workflow execution exceptions",
          tags: [:workflow_id, :workflow_name, :exception_type],
          tag_values: fn meta ->
            %{
              workflow_id: meta.workflow_id || "unknown",
              workflow_name: meta[:workflow_name] || "unknown",
              exception_type: exception_type(meta.exception)
            }
          end
        ),

        # ====================================================================
        # Step Metrics
        # ====================================================================

        counter(
          [:imgd, :engine, :step, :total],
          event_name: [:imgd, :engine, :step, :stop],
          description: "Total number of step executions",
          tags: [:workflow_id, :step_name, :step_type, :status],
          tag_values: &step_tag_values/1
        ),

        distribution(
          [:imgd, :engine, :step, :duration, :milliseconds],
          event_name: [:imgd, :engine, :step, :stop],
          description: "Step execution duration in milliseconds",
          measurement: :duration_ms,
          tags: [:workflow_id, :step_name, :step_type, :status],
          tag_values: &step_tag_values/1,
          reporter_options: [buckets: @step_duration_buckets],
          unit: :millisecond
        ),

        counter(
          [:imgd, :engine, :step, :exception, :total],
          event_name: [:imgd, :engine, :step, :exception],
          description: "Total number of step execution exceptions",
          tags: [:workflow_id, :step_name, :step_type, :exception_type],
          tag_values: fn meta ->
            %{
              workflow_id: meta.workflow_id || "unknown",
              step_name: meta.step_name || "unknown",
              step_type: meta.step_type || "unknown",
              exception_type: exception_type(meta.exception)
            }
          end
        ),

        # ====================================================================
        # Checkpoint Metrics
        # ====================================================================

        counter(
          [:imgd, :engine, :checkpoint, :total],
          event_name: [:imgd, :engine, :checkpoint, :stop],
          description: "Total number of checkpoints created",
          tags: [:reason, :success],
          tag_values: fn meta ->
            %{
              reason: meta.reason || "unknown",
              success: meta.success
            }
          end
        ),

        distribution(
          [:imgd, :engine, :checkpoint, :duration, :milliseconds],
          event_name: [:imgd, :engine, :checkpoint, :stop],
          description: "Checkpoint creation duration in milliseconds",
          measurement: :duration_ms,
          tags: [:reason],
          tag_values: fn meta -> %{reason: meta.reason || "unknown"} end,
          reporter_options: [buckets: @step_duration_buckets],
          unit: :millisecond
        ),

        # ====================================================================
        # Generation Metrics
        # ====================================================================

        counter(
          [:imgd, :engine, :generation, :complete, :total],
          event_name: [:imgd, :engine, :generation, :complete],
          description: "Total number of generation completions",
          tags: [:workflow_id],
          tag_values: fn meta -> %{workflow_id: meta.workflow_id || "unknown"} end
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
          [:imgd, :engine, :steps, :running],
          event_name: [:imgd, :engine, :stats, :poll],
          description: "Number of currently running steps",
          measurement: :running_steps
        )
      ]
    )
  end

  @doc false
  def poll_engine_stats do
    import Ecto.Query

    # Count active executions
    active_executions =
      Imgd.Workflows.Execution
      |> where([e], e.status == :running)
      |> Imgd.Repo.aggregate(:count)

    pending_executions =
      Imgd.Workflows.Execution
      |> where([e], e.status == :pending)
      |> Imgd.Repo.aggregate(:count)

    running_steps =
      Imgd.Workflows.ExecutionStep
      |> where([s], s.status == :running)
      |> Imgd.Repo.aggregate(:count)

    :telemetry.execute(
      [:imgd, :engine, :stats, :poll],
      %{
        active_executions: active_executions,
        pending_executions: pending_executions,
        running_steps: running_steps
      },
      %{}
    )
  rescue
    e ->
      Logger.warning("Failed to poll engine stats: #{Exception.message(e)}")

      :telemetry.execute(
        [:imgd, :engine, :stats, :poll],
        %{active_executions: 0, pending_executions: 0, running_steps: 0},
        %{}
      )
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp execution_tag_values(meta) do
    %{
      workflow_id: safe_string(meta.workflow_id),
      workflow_name: safe_string(meta[:workflow_name]),
      status: safe_atom(meta.status),
      trigger_type: safe_atom(meta[:trigger_type])
    }
  end

  defp step_tag_values(meta) do
    %{
      workflow_id: safe_string(meta.workflow_id),
      step_name: safe_string(meta.step_name),
      step_type: safe_string(meta.step_type),
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
