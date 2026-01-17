defmodule Imgd.Runtime.ProductionsCounter do
  @moduledoc """
  Production-aware item counting for workflow step executions.

  Integrates with Runic's fact/production system to track items
  as they flow through the workflow graph, providing accurate counts
  for all step types including streaming scenarios.

  ## Production Semantics

  Unlike naive array-length counting, this module understands
  Runic's production model:

  - **Regular steps**: 1 input fact → 1 output fact = 1 production
  - **FanOut (splitter)**: 1 input fact → N output facts = N productions
  - **FanIn/Reduce (aggregator)**: N input facts → 1 output fact = 1 production
  - **Skipped steps**: 0 productions (nil output)

  ## Real-time Tracking

  Productions are recorded as they occur, enabling:
  - Progress tracking during long-running executions
  - Accurate counts for streaming/incremental outputs
  - Consistent semantics across all step types

  ## Usage

      # Initialize at execution start
      ProductionsCounter.init(execution_id)

      # Record production during/after step execution
      count = ProductionsCounter.record(execution_id, step_id, output_value, opts)

      # Get current count for a step
      count = ProductionsCounter.get(execution_id, step_id)

      # Get all counts at execution end
      counts = ProductionsCounter.finalize(execution_id)

  ## Process Dictionary Storage

  State is stored in the process dictionary keyed by execution_id,
  ensuring isolation between concurrent executions in the same process
  (though typically each execution runs in its own Server process).
  """

  @type execution_id :: String.t()
  @type step_id :: String.t()
  @type step_type :: :regular | :fan_out | :fan_in | :reduce
  @type production_entry :: %{
          count: non_neg_integer(),
          step_type: step_type() | nil,
          recorded_at: DateTime.t()
        }
  @type production_state :: %{step_id() => production_entry()}

  @doc """
  Initializes production tracking for an execution.

  Call this at execution start before any steps run.
  """
  @spec init(execution_id()) :: :ok
  def init(execution_id) when is_binary(execution_id) do
    Process.put(storage_key(execution_id), %{})
    :ok
  end

  @doc """
  Records a production for a step based on its output value.

  ## Options

  - `:step_type` - The semantic type of the step (:regular, :fan_out, :fan_in, :reduce)
  - `:explicit_count` - Override automatic counting with an explicit value

  ## Counting Rules

  The count is determined by the output value and step type:

  1. If `:explicit_count` is provided, use that value
  2. For `:fan_out` steps with list output, count = length(list)
  3. For `:fan_in`/`:reduce` steps, count = 1 (always produces single aggregate)
  4. For nil/empty output, count = 0
  5. For other values, count = 1

  Returns the recorded count.
  """
  @spec record(execution_id(), step_id(), term(), keyword()) :: non_neg_integer()
  def record(execution_id, step_id, output_value, opts \\ []) do
    step_type = Keyword.get(opts, :step_type)
    explicit_count = Keyword.get(opts, :explicit_count)

    count = determine_count(output_value, step_type, explicit_count)

    entry = %{
      count: count,
      step_type: step_type,
      recorded_at: DateTime.utc_now()
    }

    state = get_state(execution_id)
    Process.put(storage_key(execution_id), Map.put(state, step_id, entry))

    count
  end

  @doc """
  Increments the production count for a step.

  Use this for streaming scenarios where items are produced incrementally.
  """
  @spec increment(execution_id(), step_id(), non_neg_integer()) :: non_neg_integer()
  def increment(execution_id, step_id, amount \\ 1) when is_integer(amount) and amount >= 0 do
    state = get_state(execution_id)

    entry =
      case Map.get(state, step_id) do
        nil ->
          %{count: amount, step_type: nil, recorded_at: DateTime.utc_now()}

        existing ->
          %{existing | count: existing.count + amount, recorded_at: DateTime.utc_now()}
      end

    Process.put(storage_key(execution_id), Map.put(state, step_id, entry))

    entry.count
  end

  @doc """
  Gets the current production count for a step.

  Returns 0 if no productions have been recorded.
  """
  @spec get(execution_id(), step_id()) :: non_neg_integer()
  def get(execution_id, step_id) do
    case get_entry(execution_id, step_id) do
      nil -> 0
      entry -> entry.count
    end
  end

  @doc """
  Gets the full production entry for a step, including metadata.

  Returns nil if no productions have been recorded.
  """
  @spec get_entry(execution_id(), step_id()) :: production_entry() | nil
  def get_entry(execution_id, step_id) do
    execution_id
    |> get_state()
    |> Map.get(step_id)
  end

  @doc """
  Gets all production counts as a simple map of step_id => count.

  Useful for persisting counts to step execution records.
  """
  @spec get_all_counts(execution_id()) :: %{step_id() => non_neg_integer()}
  def get_all_counts(execution_id) do
    execution_id
    |> get_state()
    |> Map.new(fn {step_id, entry} -> {step_id, entry.count} end)
  end

  @doc """
  Gets the full production state including all metadata.
  """
  @spec get_state(execution_id()) :: production_state()
  def get_state(execution_id) do
    Process.get(storage_key(execution_id), %{})
  end

  @doc """
  Finalizes production tracking and returns all counts.

  Clears the state from the process dictionary.
  """
  @spec finalize(execution_id()) :: %{step_id() => non_neg_integer()}
  def finalize(execution_id) do
    counts = get_all_counts(execution_id)
    clear(execution_id)
    counts
  end

  @doc """
  Clears production tracking state for an execution.
  """
  @spec clear(execution_id()) :: :ok
  def clear(execution_id) do
    Process.delete(storage_key(execution_id))
    :ok
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp storage_key(execution_id), do: {:imgd_production_counts, execution_id}

  @doc false
  @spec determine_count(term(), step_type() | nil, non_neg_integer() | nil) :: non_neg_integer()
  def determine_count(_output, _step_type, explicit) when is_integer(explicit), do: explicit

  def determine_count(output, step_type, nil) do
    case {output, step_type} do
      # Nil or empty = no production
      {nil, _} ->
        0

      {[], _} ->
        0

      # FanOut with list = N productions (one per item fanned out)
      {list, :fan_out} when is_list(list) ->
        length(list)

      # FanIn/Reduce always produces single aggregate result
      {_, :fan_in} ->
        1

      {_, :reduce} ->
        1

      # Regular step with list output = 1 production (the list itself)
      # This is different from FanOut which iterates the list
      {_list, :regular} ->
        1

      {list, nil} when is_list(list) ->
        # When step_type is unknown, check if this looks like a fan-out
        # by checking the fan-out context
        if Process.get(:imgd_fan_out_items_total) do
          # We're in a fan-out context, this is being iterated
          length(list)
        else
          # Regular list output, count as 1
          1
        end

      # Any other value = 1 production
      {_value, _} ->
        1
    end
  end
end
