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

  """

  require Logger
  alias Runic.Workflow
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
    |> attach_context_hooks()
    |> attach_logging_hooks()
    |> attach_telemetry_hooks(execution_id)
  end

  @doc """
  Attaches context hooks that pass accumulated step outputs to step functions.
  """
  @spec attach_context_hooks(Workflow.t()) :: Workflow.t()
  def attach_context_hooks(workflow) do
    workflow.components
    |> Enum.reduce(workflow, fn {component_name, _component}, wf ->
      Workflow.attach_before_hook(wf, component_name, &before_step_context/3)
    end)
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

  # Pass accumulated step outputs to the step function via process dictionary
  defp before_step_context(_step, workflow, _fact) do
    outputs = Process.get(:imgd_accumulated_outputs, %{})
    Process.put(:imgd_step_outputs, outputs)
    workflow
  end

  defp before_step_logging(_step, workflow, _fact) do
    # Logging removed for performance
    workflow
  end

  defp before_step_telemetry(step, workflow, fact, execution_id) do
    step_name = get_step_name(step)
    start_time = System.monotonic_time()
    started_at = DateTime.utc_now()
    step_type_id = get_step_type_id(step, workflow)
    original_step_id = get_original_step_id(step, workflow)

    # Check if we're in a fan-out context and get/set the item index for this step
    {item_index, items_total} = get_fan_out_item_context(original_step_id, workflow, step)

    # Store the current fan-out context for the after_step_telemetry hook
    if item_index do
      Process.put(:imgd_fan_out_context, %{item_index: item_index, items_total: items_total})
    else
      Process.delete(:imgd_fan_out_context)
    end

    # Store start time and input for duration and complete payloads
    workflow =
      workflow
      |> put_step_start_time(step_name, start_time)
      |> put_step_started_at(step_name, started_at)
      |> put_step_input_data(step_name, fact.value)

    # Buffer the "started" event instead of persisting immediately
    push_step_event(%{
      execution_id: execution_id,
      step_id: original_step_id,
      step_type_id: step_type_id || "unknown",
      status: :running,
      input_data: fact.value,
      item_index: item_index,
      items_total: items_total,
      started_at: started_at
    })

    # Async broadcast for UI updates
    Task.start(fn ->
      state =
        StepExecutionState.started(execution_id, original_step_id, fact.value,
          step_type_id: step_type_id,
          item_index: item_index,
          items_total: items_total,
          started_at: started_at
        )

      Imgd.Executions.PubSub.broadcast_step(:step_started, execution_id, nil, state)
    end)

    workflow
  end

  # ===========================================================================
  # After Hooks
  # ===========================================================================

  defp after_step_logging(_step, workflow, _result_fact) do
    # Logging removed for performance
    workflow
  end

  defp after_step_telemetry(step, workflow, result_fact, execution_id) do
    step_name = get_step_name(step)
    step_type_id = get_step_type_id(step, workflow)
    original_step_id = get_original_step_id(step, workflow)

    # Calculate duration
    start_time = get_step_start_time(workflow, step_name)
    duration_us = if start_time, do: System.monotonic_time() - start_time, else: 0
    duration_us = System.convert_time_unit(duration_us, :native, :microsecond)

    # Check if step was skipped via process flag
    skipped? = Process.get(:imgd_step_skipped, false)
    Process.delete(:imgd_step_skipped)

    # Get fan-out context if we're processing an item in a fan-out batch
    fan_out_ctx = Process.get(:imgd_fan_out_context)
    item_index = if fan_out_ctx, do: fan_out_ctx[:item_index], else: nil
    items_total = if fan_out_ctx, do: fan_out_ctx[:items_total], else: nil

    # Count output items - splitter steps can produce multiple items
    output_item_count = do_count_output_items(result_fact.value)

    input_data = get_step_input_data(workflow, step_name)
    started_at = get_step_started_at(workflow, step_name)

    # Buffer the "completed" / "skipped" event
    push_step_event(%{
      execution_id: execution_id,
      step_id: original_step_id,
      step_type_id: step_type_id || "unknown",
      status: if(skipped?, do: :skipped, else: :completed),
      input_data: input_data,
      output_data: result_fact.value,
      output_item_count: output_item_count,
      item_index: item_index,
      items_total: items_total,
      started_at: started_at,
      completed_at: DateTime.utc_now()
    })

    unless skipped? do
      acc_outputs = Process.get(:imgd_accumulated_outputs, %{})
      Process.put(:imgd_accumulated_outputs, Map.put(acc_outputs, step_name, result_fact.value))
    end

    # Async broadcast for UI updates
    Task.start(fn ->
      state_opts = [
        step_type_id: step_type_id,
        duration_us: duration_us,
        item_index: item_index,
        items_total: items_total,
        started_at: started_at,
        completed_at: DateTime.utc_now(),
        output_item_count: output_item_count
      ]

      state =
        if skipped? do
          StepExecutionState.skipped(execution_id, original_step_id, input_data, state_opts)
        else
          StepExecutionState.completed(
            execution_id,
            original_step_id,
            input_data,
            result_fact.value,
            state_opts
          )
        end

      Imgd.Executions.PubSub.broadcast_step(
        if(skipped?, do: :step_skipped, else: :step_completed),
        execution_id,
        nil,
        state
      )
    end)

    workflow
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp get_step_name(%{name: name}) when is_binary(name), do: name
  defp get_step_name(%{name: name}) when is_atom(name), do: Atom.to_string(name)
  defp get_step_name(_), do: "unknown"

  defp get_step_metadata(step, workflow) do
    step_name = get_step_name(step)

    workflow
    # LiveView snapshot hack
    |> Map.get(:__changed__, %{})
    |> Map.get(:__step_metadata__, workflow |> Map.get(:__step_metadata__, %{}))
    |> Map.get(step_name, %{})
  end

  defp get_step_type_id(step, workflow) do
    get_step_metadata(step, workflow)[:type_id]
  end

  defp get_original_step_id(step, workflow) do
    get_step_metadata(step, workflow)[:step_id] || get_step_name(step)
  end

  @spec do_count_output_items(term()) :: non_neg_integer()
  defp do_count_output_items(nil), do: 0
  defp do_count_output_items([]), do: 0
  defp do_count_output_items(value) when is_list(value), do: length(value)
  defp do_count_output_items(_), do: 1

  # Get the fan-out item context for a step (item_index, items_total)
  # Returns {item_index, items_total} if in fan-out context, {nil, nil} otherwise
  defp get_fan_out_item_context(step_id, workflow, step) do
    items_total = Process.get(:imgd_fan_out_items_total)

    if items_total && in_fan_out_path?(workflow, step) do
      # Get the per-step item counters map
      counters = Process.get(:imgd_step_item_counters, %{})

      # Get current index for this step (defaults to 0)
      current_index = Map.get(counters, step_id, 0)

      # Increment the counter for next time this step processes an item
      Process.put(:imgd_step_item_counters, Map.put(counters, step_id, current_index + 1))

      {current_index, items_total}
    else
      {nil, nil}
    end
  end

  # Check if this step is in a fan-out path (between a FanOut and FanIn)
  # Excludes FanIn/Reduce steps since they aggregate, not process individual items
  defp in_fan_out_path?(workflow, step) do
    # Exclude aggregator steps - they produce one output, not N
    case step do
      %Runic.Workflow.FanIn{} ->
        false

      %Runic.Workflow.Reduce{} ->
        false

      %Runic.Workflow.FanOut{} ->
        # FanOut itself is the splitter - it produces N items, not processes them
        false

      _ ->
        mapped_paths = workflow.mapped[:mapped_paths] || MapSet.new()
        step_hash = Map.get(step, :hash)

        step_hash && MapSet.member?(mapped_paths, step_hash)
    end
  end

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

  # ===========================================================================
  # Event Buffering
  # ===========================================================================

  @doc """
  Pushes a step event to the process-local buffer for batch persistence.
  """
  def push_step_event(event) do
    events = Process.get(:imgd_step_events, [])
    Process.put(:imgd_step_events, [event | events])
  end

  @doc """
  Retrieves and clears the process-local event buffer.
  """
  def flush_step_events do
    events = Process.get(:imgd_step_events, [])
    Process.put(:imgd_step_events, [])
    Enum.reverse(events)
  end
end
