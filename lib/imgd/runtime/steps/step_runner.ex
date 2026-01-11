defmodule Imgd.Runtime.Steps.StepRunner do
  @moduledoc """
  Creates Runic Steps from Imgd workflow steps.

  This module bridges Imgd's step system with Runic's step-based execution.
  It handles:
  - Expression evaluation in step configs before execution
  - Building execution context from Runic workflow state
  - Error handling with controlled throws for proper error propagation

  ## Usage

      step = %Imgd.Workflows.Embeds.Step{id: "step_1", type_id: "debug", config: %{}}
      step = StepRunner.create(step, execution_id: "exec_123")

      # The step can then be added to a Runic workflow
      Workflow.add(workflow, step)
  """

  require Runic
  alias Imgd.Runtime.ExecutionContext
  alias Imgd.Runtime.Expression
  alias Imgd.Steps.Executors.Behaviour, as: ExecutorBehaviour

  @type workflow_step :: Imgd.Workflows.Embeds.Step.t()
  @type step_opts :: [
          execution_id: String.t(),
          workflow_id: String.t(),
          variables: map(),
          metadata: map(),
          step_outputs: map(),
          trigger_data: map(),
          trigger_type: atom()
        ]

  @doc """
  Creates a Runic step from an Imgd step.

  The step wraps the step's executor and handles:
  - Building context from the Runic fact input
  - Evaluating expressions in the step's config
  - Executing the step via its registered executor
  - Error handling with controlled throws

  ## Options

  - `:execution_id` - The Imgd Execution record ID
  - `:workflow_id` - The source workflow ID
  - `:variables` - Workflow-level variables for expression evaluation
  - `:metadata` - Execution metadata
  """
  @spec create(workflow_step(), step_opts()) :: Runic.Workflow.Step.t()
  def create(step, opts \\ []) do
    # Capture step and opts in the closure
    # Runic will call this function with the input from parent steps

    # Determine execution target
    # Priority: Step Config > Workflow Default (via opts) > Local
    target = determine_compute_target(step, opts)

    runic_step =
      Runic.step(
        fn input ->
          # Dispatch execution to the target
          # We pass the MFA: {StepRunner, :execute_with_context, [step, input, opts]}
          case Imgd.Compute.run(target, __MODULE__, :execute_with_context, [step, input, opts]) do
            {:ok, result} ->
              result

            {:error, {:throw, reason}} ->
              # Propagate thrown errors (e.g. from ComputeNode catch)
              throw(reason)

            {:error, reason} ->
              # Wrap other errors (e.g. RPC failure)
              throw({:step_error, step.id, {:compute_error, reason}})
          end
        end,
        name: step.id
      )

    # Ensure unique hash for programmatic steps to avoid graph vertex collisions
    # We use phash2 on the combination of the original hash and the step id
    unique_hash = :erlang.phash2({runic_step.hash, step.id}, 4_294_967_296)
    %{runic_step | hash: unique_hash}
  end

  defp determine_compute_target(step, opts) do
    # check step config first
    step_config_target = Map.get(step.config, "compute")

    if step_config_target do
      Imgd.Compute.Target.parse(step_config_target)
    else
      # check workflow default
      Keyword.get(opts, :default_compute, Imgd.Compute.Target.local())
    end
  end

  # Mapping of trigger step types to their corresponding trigger_type atoms
  @trigger_type_mapping %{
    "manual_input" => :manual,
    "webhook_trigger" => :webhook,
    "schedule_trigger" => :schedule,
    "event_trigger" => :event
  }

  @doc """
  Executes a step with full context building and expression evaluation.

  This is the core execution logic that:
  1. Builds an ExecutionContext from the input
  2. Evaluates expressions in the step's config
  3. Calls the step's executor
  4. Handles errors appropriately
  """
  @spec execute_with_context(workflow_step(), term(), step_opts()) :: term()
  def execute_with_context(step, input, opts) do
    # Build context from options and input
    ctx = build_context(step, input, opts)

    # Check if this is a non-active trigger that should be skipped
    if should_skip_trigger?(step.type_id, ctx.trigger_type) do
      Process.put(:imgd_step_skipped, true)
      # Return nil to avoid propagating input from skipped triggers (prevents duplicates in joins)
      nil
    else
      do_execute(step, input, ctx)
    end
  end

  defp should_skip_trigger?(step_type_id, current_trigger_type) do
    case Map.get(@trigger_type_mapping, step_type_id) do
      # Not a trigger step, don't skip
      nil -> false
      expected_type -> expected_type != current_trigger_type
    end
  end

  defp do_execute(step, input, ctx) do
    evaluated_config =
      case evaluate_config(step.config, ctx) do
        {:ok, config} ->
          # Persist evaluated config for UI/Debug purposes
          if ctx.execution_id do
            Imgd.Executions.update_step_execution_metadata(ctx.execution_id, ctx.step_id, %{
              "evaluated_config" => config
            })
          end

          config

        {:error, reason} ->
          throw({:step_error, step.id, {:expression_error, reason}})
      end

    # Resolve and execute the step
    executor = ExecutorBehaviour.resolve!(step.type_id)

    case executor.execute(evaluated_config, input, ctx) do
      {:ok, result} ->
        result

      {:error, reason} ->
        throw({:step_error, step.id, reason})

      {:skip, _reason} ->
        # Signal observability hook that this step was skipped
        Process.put(:imgd_step_skipped, true)
        # Skip produces nil, which Runic will handle appropriately
        nil
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_context(step, input, opts) do
    ExecutionContext.new(
      execution_id: Keyword.get(opts, :execution_id),
      workflow_id: Keyword.get(opts, :workflow_id),
      step_id: step.id,
      variables: Keyword.get(opts, :variables, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      input: input,
      step_outputs: Keyword.get(opts, :step_outputs, %{}),
      trigger: Keyword.get(opts, :trigger_data, %{}),
      trigger_type: Keyword.get(opts, :trigger_type)
    )
  end

  defp evaluate_config(config, ctx) when is_map(config) do
    # Build variables for expression evaluation
    vars = build_expression_vars(ctx)

    Expression.evaluate_deep(config, vars)
  end

  defp evaluate_config(config, _ctx), do: {:ok, config}

  defp build_expression_vars(ctx) do
    normalized_input = Expression.Context.normalize_value(ctx.input)

    %{
      "json" => normalized_input,
      "input" => normalized_input,
      "steps" => build_steps_var(ctx.step_outputs),
      "execution" => %{
        "id" => ctx.execution_id
      },
      "workflow" => %{
        "id" => ctx.workflow_id
      },
      "variables" => ctx.variables,
      "metadata" => ctx.metadata,
      "trigger" => %{"data" => ctx.trigger}
    }
  end

  defp build_steps_var(step_outputs) when is_map(step_outputs) do
    # Transform step outputs into the steps.StepName.json format
    Map.new(step_outputs, fn {step_id, output} ->
      {step_id, %{"json" => output}}
    end)
  end

  defp build_steps_var(_), do: %{}
end
