defmodule Imgd.Runtime.Hooks.Observability do
  @moduledoc """
  Runic workflow hooks for observability: logging, telemetry, and events.

  These hooks are attached to Runic workflows to provide:
  - Structured logging at step entry/exit
  - Telemetry events for metrics collection
  - PubSub events for real-time UI updates

  ## Usage

      workflow
      |> Observability.attach_all_hooks(execution_id: "exec_123")

  ## Telemetry Events

  - `[:imgd, :workflow, :step, :start]` - Step is about to execute
  - `[:imgd, :workflow, :step, :stop]` - Step completed successfully
  - `[:imgd, :workflow, :step, :exception]` - Step raised an exception
  """

  require Logger
  alias Runic.Workflow
  alias Imgd.Executions
  alias Imgd.Runtime.StepExecutionState

  @type hook_opts :: [execution_id: String.t(), workflow_id: String.t()]

  @doc """
  Counts the number of items produced by a step.

  For splitter steps: returns the length of the output list (multiple items)
  For aggregator steps: returns 1 (single aggregated result)
  For other steps: returns 1 (single output)
  For nil/skipped: returns 0

  ## Examples

      iex> count_output_items([1, 2, 3])
      3

      iex> count_output_items("single")
      1

      iex> count_output_items([])
      0

      iex> count_output_items(nil)
      0
  """
  @spec count_output_items(term()) :: non_neg_integer()
  def count_output_items(value) do
    do_count_output_items(value)
  end

  @doc """
  Attaches all observability hooks to a Runic workflow.
  """
  @spec attach_all_hooks(Workflow.t(), hook_opts()) :: Workflow.t()
  def attach_all_hooks(workflow, opts \\ []) do
    execution_id = Keyword.get(opts, :execution_id, "unknown")
    workflow_id = Keyword.get(opts, :workflow_id, "unknown")

    # Store context in workflow metadata for access in hooks
    workflow = put_hook_context(workflow, execution_id, workflow_id)

    # Attach hooks to all steps
    workflow
    |> attach_logging_hooks()
    |> attach_telemetry_hooks(execution_id)
  end

  @doc """
  Attaches logging hooks that log step entry and exit.
  """
  @spec attach_logging_hooks(Workflow.t()) :: Workflow.t()
  def attach_logging_hooks(workflow) do
    # Attach logging hooks to all steps
    workflow.components
    |> Enum.reduce(workflow, fn {component_name, _component}, wf ->
      wf
      |> Workflow.attach_before_hook(component_name, &before_step_logging/3)
      |> Workflow.attach_after_hook(component_name, &after_step_logging/3)
    end)
  end

  @doc """
  Attaches telemetry hooks for metrics collection.
  """
  @spec attach_telemetry_hooks(Workflow.t(), String.t()) :: Workflow.t()
  def attach_telemetry_hooks(workflow, execution_id) do
    # We use a closure to capture execution_id
    before_fn = fn step, wf, fact ->
      before_step_telemetry(step, wf, fact, execution_id)
    end

    after_fn = fn step, wf, fact ->
      after_step_telemetry(step, wf, fact, execution_id)
    end

    # Attach telemetry hooks to all steps
    workflow.components
    |> Enum.reduce(workflow, fn {component_name, _component}, wf ->
      wf
      |> Workflow.attach_before_hook(component_name, before_fn)
      |> Workflow.attach_after_hook(component_name, after_fn)
    end)
  end

  # ===========================================================================
  # Before Hooks
  # ===========================================================================

  defp before_step_logging(step, workflow, fact) do
    step_name = get_step_name(step)
    input_preview = preview_value(fact.value)

    Logger.debug("Starting step",
      step: step_name,
      input: input_preview
    )

    workflow
  end

  defp before_step_telemetry(step, workflow, fact, execution_id) do
    step_name = get_step_name(step)
    start_time = System.monotonic_time()
    started_at = DateTime.utc_now()
    step_type_id = get_step_type_id(step, workflow)
    persisted_step_type_id = step_type_id || "unknown"

    # Store start time and input for duration and complete payloads
    workflow =
      workflow
      |> put_step_start_time(step_name, start_time)
      |> put_step_started_at(step_name, started_at)
      |> put_step_input_data(step_name, fact.value)

    workflow =
      case Executions.record_step_execution_started(
             execution_id,
             step_name,
             persisted_step_type_id,
             fact.value
           ) do
        {:ok, step_execution} ->
          put_step_execution_id(workflow, step_name, step_execution.id)

        {:error, reason} ->
          Logger.warning("Failed to persist step execution start",
            execution_id: execution_id,
            step_id: step_name,
            reason: inspect(reason)
          )

          workflow
      end

    :telemetry.execute(
      [:imgd, :step, :start],
      %{system_time: System.system_time()},
      %{
        step_name: step_name,
        execution_id: execution_id
      }
    )

    state =
      StepExecutionState.started(execution_id, step_name, fact.value,
        step_type_id: step_type_id,
        started_at: started_at
      )

    Imgd.Executions.PubSub.broadcast_step(:step_started, execution_id, nil, state)

    workflow
  end

  # ===========================================================================
  # After Hooks
  # ===========================================================================

  defp after_step_logging(step, workflow, result_fact) do
    step_name = get_step_name(step)
    output_preview = preview_value(result_fact.value)

    Logger.debug("Completed step",
      step: step_name,
      output: output_preview
    )

    workflow
  end

  defp after_step_telemetry(step, workflow, result_fact, execution_id) do
    step_name = get_step_name(step)
    step_type_id = get_step_type_id(step, workflow)

    # Calculate duration
    start_time = get_step_start_time(workflow, step_name)
    duration_us = if start_time, do: System.monotonic_time() - start_time, else: 0
    duration_us = System.convert_time_unit(duration_us, :native, :microsecond)

    # Check if step was skipped via process flag
    skipped? = Process.get(:imgd_step_skipped, false)
    Process.delete(:imgd_step_skipped)

    # Count output items - splitter steps can produce multiple items
    output_item_count = do_count_output_items(result_fact.value)

    :telemetry.execute(
      [:imgd, :step, :stop],
      %{
        duration_us: duration_us,
        system_time: System.system_time(),
        output_item_count: output_item_count
      },
      %{
        step_name: step_name,
        execution_id: execution_id,
        result_type: get_result_type(result_fact.value),
        output_item_count: output_item_count,
        skipped: skipped?
      }
    )

    # Retrieve input data if possible (though we should have it from Runic fact)
    # Runic fact in after_hook is the RESULT of the step, not the input.
    # We need the input data which was used to start the step.
    # In Runic, the input to a step is available in the workflow data or the before_hook.
    # However, our observability hook doesn't easily store the input.
    # Let's see if we can get it from the workflow metadata where we might have stored it.

    # Actually, Runic's after_hook receives (step, workflow, result_fact).
    # The input data is not directly in the after_hook.
    # We should have stored it in the before_hook if we wanted it here.
    # Wait, Runic fact.value in before_hook is the input.
    # In after_hook, result_fact.value is the output.

    # However, our StepExecutionState.completed needs both.
    # Since we can't easily get input here without storing it in metadata,
    # let's modify before_step_telemetry to store input in workflow metadata.

    input_data = get_step_input_data(workflow, step_name)

    started_at = get_step_started_at(workflow, step_name)

    state_opts = [
      step_type_id: step_type_id,
      duration_us: duration_us,
      started_at: started_at,
      completed_at: DateTime.utc_now()
    ]

    state =
      if skipped? do
        StepExecutionState.skipped(execution_id, step_name, input_data, state_opts)
      else
        StepExecutionState.completed(
          execution_id,
          step_name,
          input_data,
          result_fact.value,
          state_opts
        )
      end

    if skipped? do
      Executions.record_step_execution_skipped_by_step(execution_id, step_name)
    else
      case get_step_execution_id(workflow, step_name) do
        nil ->
          Executions.record_step_execution_completed_by_step(
            execution_id,
            step_name,
            result_fact.value
          )

        step_execution_id ->
          Executions.record_step_execution_completed_by_id(step_execution_id, result_fact.value)
      end
    end

    Logger.debug("Broadcasting #{if skipped?, do: "step_skipped", else: "step_completed"}",
      payload: state
    )

    Imgd.Executions.PubSub.broadcast_step(
      if(skipped?, do: :step_skipped, else: :step_completed),
      execution_id,
      nil,
      state
    )

    workflow
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp get_step_name(%{name: name}) when is_binary(name), do: name
  defp get_step_name(%{name: name}) when is_atom(name), do: Atom.to_string(name)
  defp get_step_name(_), do: "unknown"

  defp get_step_type_id(step, workflow) do
    step_name = get_step_name(step)

    workflow
    |> Map.get(:__step_types__, %{})
    |> Map.get(step_name)
  end

  defp preview_value(value) when is_binary(value) do
    if String.length(value) > 100 do
      String.slice(value, 0, 100) <> "..."
    else
      value
    end
  end

  defp preview_value(value) when is_map(value), do: "[Map with #{map_size(value)} keys]"
  defp preview_value(value) when is_list(value), do: "[List with #{length(value)} items]"
  defp preview_value(value), do: inspect(value, limit: 5)

  defp get_result_type(nil), do: nil
  defp get_result_type(value) when is_map(value), do: :map
  defp get_result_type(value) when is_list(value), do: :list
  defp get_result_type(value) when is_binary(value), do: :string
  defp get_result_type(value) when is_number(value), do: :number
  defp get_result_type(value) when is_boolean(value), do: :boolean
  defp get_result_type(_), do: :other

  @spec do_count_output_items(term()) :: non_neg_integer()
  defp do_count_output_items(nil), do: 0
  defp do_count_output_items([]), do: 0
  defp do_count_output_items(value) when is_list(value), do: length(value)
  defp do_count_output_items(_), do: 1

  # Workflow metadata helpers
  defp put_hook_context(workflow, execution_id, workflow_id) do
    # Store in a way that doesn't interfere with Runic internals
    # We use the graph's labeled edge system or a separate holder
    # For now, just return the workflow - context is passed via closures
    workflow
    |> Map.put(:__hook_context__, %{
      execution_id: execution_id,
      workflow_id: workflow_id
    })
  end

  defp put_step_start_time(workflow, step_name, time) do
    times = Map.get(workflow, :__step_times__, %{})
    Map.put(workflow, :__step_times__, Map.put(times, step_name, time))
  end

  defp get_step_start_time(workflow, step_name) do
    workflow
    |> Map.get(:__step_times__, %{})
    |> Map.get(step_name)
  end

  defp put_step_execution_id(workflow, step_name, id) do
    ids = Map.get(workflow, :__step_exec_ids__, %{})
    Map.put(workflow, :__step_exec_ids__, Map.put(ids, step_name, id))
  end

  defp get_step_execution_id(workflow, step_name) do
    workflow
    |> Map.get(:__step_exec_ids__, %{})
    |> Map.get(step_name)
  end

  defp put_step_started_at(workflow, step_name, time) do
    times = Map.get(workflow, :__step_started_ats__, %{})
    Map.put(workflow, :__step_started_ats__, Map.put(times, step_name, time))
  end

  defp get_step_started_at(workflow, step_name) do
    workflow
    |> Map.get(:__step_started_ats__, %{})
    |> Map.get(step_name)
  end

  defp put_step_input_data(workflow, step_name, data) do
    inputs = Map.get(workflow, :__step_inputs__, %{})
    Map.put(workflow, :__step_inputs__, Map.put(inputs, step_name, data))
  end

  defp get_step_input_data(workflow, step_name) do
    workflow
    |> Map.get(:__step_inputs__, %{})
    |> Map.get(step_name)
  end
end
