defmodule Imgd.Runtime.RunicAdapter do
  @moduledoc """
  Bridges Imgd workflow definitions (Steps/Connections) with the Runic execution engine.

  This adapter handles the conversion of a design-time workflow into a
  run-time Runic `%Workflow{}` struct, which acts as the single source
  of truth for execution state.

  ## Design Philosophy

  Runic is NOT just a wrapper - it's the execution substrate. This adapter:
  - Converts Imgd steps to appropriate Runic components (Steps, Rules, Map, Reduce)
  - Uses Runic's native graph-building API (`Workflow.add/3`)
  - Respects Runic's dataflow semantics (joins, fan-out)

  ## Step Type Mapping

  | Imgd Step Kind    | Runic Component        |
  |-------------------|------------------------|
  | :action, :trigger | `Runic.step`           |
  | :transform        | `Runic.step`           |
  | :control_flow     | `Runic.rule` or custom |
  | splitter          | `Runic.map`            |
  | aggregator        | `Runic.reduce`         |
  """

  require Runic
  alias Runic.Component
  alias Runic.Workflow
  alias Imgd.Runtime.Steps.StepRunner

  @type source :: Imgd.Workflows.WorkflowDraft.t() | map()
  @type build_opts :: [
          execution_id: String.t(),
          variables: map(),
          metadata: map(),
          step_outputs: map(),
          trigger_data: map(),
          trigger_type: atom(),
          default_compute: term()
        ]

  @doc """
  Converts an Imgd workflow source (draft or snapshot) into a Runic Workflow.

  ## Options

  - `:execution_id` - The execution ID for context
  - `:variables` - Workflow-level variables for expressions
  - `:variables` - Workflow-level variables for experiments
  - `:metadata` - Execution metadata
  - `:step_outputs` - Precomputed step outputs (e.g., pinned outputs)
  - `:default_compute` - Default compute target for all steps

  ## Returns

  A `%Runic.Workflow{}` struct ready for execution via `Workflow.react_until_satisfied/2`.
  """
  @spec to_runic_workflow(source(), build_opts()) :: Workflow.t()
  def to_runic_workflow(source, opts \\ []) do
    # Build options for StepRunner creation
    step_outputs =
      Keyword.get(opts, :step_outputs, Keyword.get(opts, :pinned_outputs, %{}))

    step_opts = [
      execution_id: Keyword.get(opts, :execution_id),
      workflow_id: extract_source_id(source),
      variables: Keyword.get(opts, :variables, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      step_outputs: step_outputs,
      trigger_data: Keyword.get(opts, :trigger_data, %{}),
      trigger_type: Keyword.get(opts, :trigger_type),
      default_compute: Keyword.get(opts, :default_compute)
    ]

    # Initialize Runic workflow
    wrk = Workflow.new(name: "execution_#{extract_source_id(source)}")

    # Build lookup for parent relationships
    parent_lookup = build_parent_lookup(source.connections)

    # Sort steps topologically to ensure parents are added before children
    sorted_steps = topological_sort_steps(source.steps, source.connections)

    # Add each step as a Runic component
    wrk =
      Enum.reduce(sorted_steps, wrk, fn step, acc ->
        add_step_to_workflow(step, acc, parent_lookup, step_opts)
      end)

    put_step_metadata(wrk, source.steps)
  end

  @doc """
  Creates a Runic component from an Imgd step.

  Dispatches to the appropriate Runic primitive based on step type.
  """
  @spec create_component(Imgd.Workflows.Embeds.Step.t(), String.t(), build_opts()) :: term()
  def create_component(step, component_name, opts \\ []) do
    case step.type_id do
      "splitter" ->
        create_splitter(step, component_name)

      "aggregator" ->
        create_aggregator(step, component_name)

      "condition" ->
        create_condition(step, component_name, opts)

      "switch" ->
        create_switch(step, component_name, opts)

      _ ->
        # Default: create a Runic step via StepRunner
        StepRunner.create(step, opts)
    end
  end

  # ===========================================================================
  # Private: Workflow Building
  # ===========================================================================

  defp add_step_to_workflow(step, workflow, parent_lookup, step_opts) do
    component_name = step.id
    component = create_component(step, component_name, step_opts)

    parent_ids =
      parent_lookup
      |> Map.get(step.id, [])
      |> Enum.uniq()

    case parent_ids do
      [] ->
        # Root step - add to workflow root
        Workflow.add(workflow, component)

      [parent_id] ->
        Workflow.add(workflow, component, to: parent_id)

      _ ->
        {workflow, join} = ensure_join(workflow, parent_ids)
        Workflow.add(workflow, component, to: join)
    end
  end

  defp ensure_join(%Workflow{} = workflow, parent_ids) when is_list(parent_ids) do
    parent_steps = Enum.map(parent_ids, &Workflow.get_component!(workflow, &1))
    parent_hashes = Enum.map(parent_steps, &Component.hash/1)
    join = Workflow.Join.new(parent_hashes)

    case Map.get(workflow.graph.vertices, join.hash) do
      %Workflow.Join{} = existing_join ->
        {workflow, existing_join}

      nil ->
        {Workflow.add_step(workflow, parent_steps, join), join}
    end
  end

  defp extract_source_id(source) do
    # todo: why?
    Map.get(source, :id) || Map.get(source, :workflow_id) || "unknown"
  end

  defp build_parent_lookup(connections) do
    # Group connections by target_step_id to find parents
    Enum.group_by(connections, & &1.target_step_id, & &1.source_step_id)
  end

  defp topological_sort_steps(steps, connections) do
    step_ids = Enum.map(steps, & &1.id)
    step_map = Map.new(steps, &{&1.id, &1})

    # 1. Initialize in-degrees
    in_degrees = Map.new(step_ids, &{&1, 0})

    in_degrees =
      Enum.reduce(connections, in_degrees, fn conn, acc ->
        Map.update(acc, conn.target_step_id, 0, &(&1 + 1))
      end)

    # 2. Build adjacency list (parent -> [children])
    adjacency =
      Enum.reduce(connections, %{}, fn conn, acc ->
        Map.update(acc, conn.source_step_id, [conn.target_step_id], &[conn.target_step_id | &1])
      end)

    # 3. Find initial roots (in-degree 0)
    # We preserve the original relative order of steps when picking roots
    roots = Enum.filter(step_ids, &(Map.get(in_degrees, &1) == 0))

    # 4. Kahn's algorithm
    sorted_ids = do_kahn_sort(roots, in_degrees, adjacency, [])

    # Map back to step structs
    Enum.map(sorted_ids, &Map.get(step_map, &1))
  end

  defp do_kahn_sort([], _in_degrees, _adjacency, sorted), do: Enum.reverse(sorted)

  defp do_kahn_sort([id | rest], in_degrees, adjacency, sorted) do
    children = Map.get(adjacency, id, [])

    {new_rest, new_in_degrees} =
      Enum.reduce(children, {rest, in_degrees}, fn child, {r, degs} ->
        new_deg = Map.get(degs, child) - 1
        degs = Map.put(degs, child, new_deg)

        if new_deg == 0 do
          # Add to queue if all dependencies met
          {r ++ [child], degs}
        else
          {r, degs}
        end
      end)

    do_kahn_sort(new_rest, new_in_degrees, adjacency, [id | sorted])
  end

  defp put_step_metadata(workflow, steps) when is_list(steps) do
    step_metadata =
      Enum.reduce(steps, %{}, fn step, acc ->
        Map.put(acc, step.id, %{
          type_id: step.type_id,
          step_id: step.id,
          name: step.name
        })
      end)

    Map.put(workflow, :__step_metadata__, step_metadata)
  end

  defp put_step_metadata(workflow, _steps), do: workflow

  # ===========================================================================
  # Private: Component Creation
  # ===========================================================================

  defp create_splitter(_step, component_name) do
    # Splitter creates a Runic.map that iterates over the input collection
    # The inner step passes each item through unchanged (for downstream processing)
    Runic.map(
      fn item -> item end,
      name: component_name
    )
  end

  defp create_aggregator(step, component_name) do
    # Aggregator creates a Runic.reduce
    # Note: Runic.reduce is a macro that requires inline anonymous functions
    operation = Map.get(step.config, "operation", "collect")
    name = component_name

    case operation do
      "sum" ->
        Runic.reduce(0, fn item, acc -> acc + (item || 0) end, name: name)

      "count" ->
        Runic.reduce(0, fn _item, acc -> acc + 1 end, name: name)

      "concat" ->
        Runic.reduce("", fn item, acc -> acc <> to_string(item) end, name: name)

      "first" ->
        Runic.reduce(
          nil,
          fn
            item, nil -> item
            _item, acc -> acc
          end,
          name: name
        )

      "last" ->
        Runic.reduce(nil, fn item, _acc -> item end, name: name)

      "min" ->
        Runic.reduce(
          nil,
          fn
            item, nil -> item
            item, acc -> min(item, acc)
          end,
          name: name
        )

      "max" ->
        Runic.reduce(
          nil,
          fn
            item, nil -> item
            item, acc -> max(item, acc)
          end,
          name: name
        )

      # "collect" and default
      _ ->
        Runic.reduce([], fn item, acc -> acc ++ [item] end, name: name)
    end
  end

  defp create_condition(step, component_name, opts) do
    # Condition creates a Runic.rule
    condition_expr = Map.get(step.config, "condition", "true")

    Runic.rule(
      name: component_name,
      if: fn input -> evaluate_condition(condition_expr, input, opts) end,
      do: fn input -> input end
    )
  end

  defp create_switch(step, _component_name, opts) do
    # Switch creates multiple rules, but for now we create a step that
    # outputs a tagged tuple for routing
    StepRunner.create(step, opts)
  end

  # Condition evaluation helper
  defp evaluate_condition(expr, input, opts) when is_binary(expr) do
    vars = %{
      "json" => input,
      "variables" => Keyword.get(opts, :variables, %{})
    }

    case Imgd.Runtime.Expression.evaluate_with_vars(expr, vars) do
      {:ok, "true"} -> true
      {:ok, "false"} -> false
      {:ok, result} when is_binary(result) -> result != "" and result != "0"
      {:ok, result} -> !!result
      {:error, _} -> false
    end
  end

  defp evaluate_condition(_, _, _), do: true
end
