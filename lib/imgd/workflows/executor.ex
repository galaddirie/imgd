defmodule Imgd.Workflows.Executor do
  @moduledoc """
  Simple synchronous workflow executor for development and testing.

  Executes a Runic workflow directly without the full Oban-based
  durable execution pipeline. Useful for quick testing and demonstration.

  For production use, prefer the full Engine pipeline which provides:
  - Durable execution with checkpointing
  - Distributed execution via Oban
  - Full observability and recovery
  """

  alias Imgd.Workflows.Workflow

  require Logger

  @type execution_result :: %{
          status: :completed | :failed,
          input: term(),
          output: term(),
          productions: [term()],
          productions_by_component: map(),
          generations: non_neg_integer(),
          duration_ms: non_neg_integer(),
          error: term() | nil
        }

  @doc """
  Executes a workflow synchronously with the given input.

  Returns a result map containing the execution status, output, and timing.

  ## Examples

      iex> Executor.run(workflow, 5)
      {:ok, %{status: :completed, output: [10, 20, "Result: 20"], ...}}

      iex> Executor.run(workflow, nil)
      {:error, %{status: :failed, error: %{message: "..."}, ...}}
  """
  @spec run(Workflow.t(), term()) :: {:ok, execution_result()} | {:error, execution_result()}
  def run(%Workflow{definition: nil}, _input) do
    {:error,
     %{
       status: :failed,
       input: nil,
       output: nil,
       productions: [],
       productions_by_component: %{},
       generations: 0,
       duration_ms: 0,
       error: %{type: "InvalidWorkflow", message: "Workflow has no definition"}
     }}
  end

  def run(%Workflow{definition: definition}, input) do
    start_time = System.monotonic_time(:millisecond)

    try do
      # Rebuild the Runic workflow from definition
      runic_workflow = rebuild_workflow(definition)

      {linear_outputs, root_step_count} = compute_linear_outputs(runic_workflow, input)

      # Execute until satisfied
      result_workflow =
        runic_workflow
        |> Runic.Workflow.plan_eagerly(input)
        |> Runic.Workflow.react_until_satisfied()

      # Extract results
      productions = Runic.Workflow.raw_productions(result_workflow)
      productions_by_component = Runic.Workflow.raw_productions_by_component(result_workflow)

      base_productions =
        if root_step_count > 1 do
          merge_productions(linear_outputs, productions)
        else
          productions
        end

      rule_results =
        apply_rules(runic_workflow, List.last(linear_outputs) || List.last(productions) || input)

      all_productions = base_productions ++ rule_results

      duration_ms = System.monotonic_time(:millisecond) - start_time

      {:ok,
       %{
         status: :completed,
         input: input,
         output: List.last(all_productions),
         productions: all_productions,
         productions_by_component: productions_by_component || %{},
         generations: result_workflow.generations,
         duration_ms: duration_ms,
         error: nil
       }}
    rescue
      e ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Logger.error(
          "Workflow execution failed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        {:error,
         %{
           status: :failed,
           input: input,
           output: nil,
           productions: [],
           productions_by_component: %{},
           generations: 0,
           duration_ms: duration_ms,
           error: %{
             type: inspect(e.__struct__),
             message: Exception.message(e)
           }
         }}
    end
  end

  @doc """
  Runs a workflow and records the execution in the database.

  This creates an Execution record with the results for audit/history.
  """
  @spec run_and_record(Imgd.Accounts.Scope.t(), Workflow.t(), term()) ::
          {:ok, Imgd.Workflows.Execution.t()} | {:error, term()}
  def run_and_record(scope, %Workflow{} = workflow, input) do
    alias Imgd.Repo
    alias Imgd.Workflows
    alias Imgd.Workflows.Execution

    # Create execution record
    execution_attrs = %{
      workflow_id: workflow.id,
      workflow_version: workflow.version,
      triggered_by_user_id: scope.user.id,
      trigger_type: :manual,
      input: %{value: input},
      metadata: %{}
    }

    with {:ok, execution} <-
           %Execution{} |> Execution.changeset(execution_attrs) |> Repo.insert(),
         {:ok, execution} <- execution |> Execution.start_changeset() |> Repo.update() do
      # Run the workflow
      case run(workflow, input) do
        {:ok, result} ->
          output = %{
            productions: result.productions,
            productions_by_component: result.productions_by_component,
            generation: result.generations
          }

          Workflows.complete_execution(scope, execution, normalize_for_json(output))

        {:error, result} ->
          Workflows.fail_execution(scope, execution, result.error)
      end
    end
  end

  # Private helpers

  defp rebuild_workflow(definition) do
    events = Workflow.deserialize_definition(definition)
    Runic.Workflow.from_log(events)
  end

  defp compute_linear_outputs(%Runic.Workflow{} = workflow, input) do
    root_steps =
      workflow.build_log
      |> Enum.reverse()
      |> Enum.filter(fn
        %Runic.Workflow.ComponentAdded{name: name, to: to} ->
          is_nil(to) and match?(%Runic.Workflow.Step{}, Map.get(workflow.components, name))

        _ ->
          false
      end)

    {outputs, _last_value} =
      Enum.reduce(root_steps, {[], input}, fn %Runic.Workflow.ComponentAdded{name: name},
                                              {acc, current_value} ->
        step = Map.fetch!(workflow.components, name)
        result = Runic.Workflow.Step.run(step, current_value)
        {[result | acc], result}
      end)

    {Enum.reverse(outputs), length(root_steps)}
  end

  defp apply_rules(%Runic.Workflow{} = workflow, value) do
    workflow.components
    |> Enum.filter(fn {_name, component} -> match?(%Runic.Workflow.Rule{}, component) end)
    |> Enum.map(fn {_name, rule} ->
      try do
        case Runic.Workflow.Rule.run(rule, value) do
          {:error, _reason} -> nil
          result -> result
        end
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp merge_productions(linear_outputs, productions) do
    (linear_outputs ++ productions)
    |> Enum.reduce([], fn item, acc ->
      if item in acc, do: acc, else: acc ++ [item]
    end)
  end

  defp normalize_for_json(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, normalize_for_json(v)} end)
    |> Enum.into(%{})
  end

  defp normalize_for_json(value) when is_list(value) do
    Enum.map(value, &normalize_for_json/1)
  end

  defp normalize_for_json(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_for_json/1)
  end

  defp normalize_for_json(other), do: other
end
