defmodule Imgd.Runtime.WorkflowBuilder do
  @moduledoc """
  Facade for building executable workflows from WorkflowVersions.

  This module delegates to the configured engine module for actual workflow
  construction and execution. It provides a stable API that doesn't change
  when the underlying engine is swapped.

  ## Usage

      {:ok, workflow} = WorkflowBuilder.build(version, context, execution)
      {:ok, partial} = WorkflowBuilder.build_partial(version, context, execution, opts)

  ## Engine Configuration

  The underlying engine can be configured via:

      config :imgd, :execution_engine, Imgd.Runtime.Engines.Runic

  See `Imgd.Runtime.Engine.Behaviour` for implementing custom engines.
  """

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.{Context, Execution}
  alias Imgd.Runtime.ExecutionState
  alias Imgd.Runtime.Engine.Behaviour

  @type executable :: Behaviour.executable()
  @type build_result :: {:ok, executable()} | {:error, Behaviour.build_error()}
  @type execute_result ::
          {:ok, Behaviour.execution_result()} | {:error, Behaviour.execution_error()}
  @type state_store :: Behaviour.state_store()

  @doc """
  Returns the configured execution engine module.
  """
  @spec engine() :: module()
  def engine, do: Behaviour.engine()

  @doc """
  Builds an executable workflow from a WorkflowVersion.

  ## Parameters

  - `version` - The WorkflowVersion containing nodes and connections
  - `context` - The execution context for resolving expressions and variables
  - `execution` - The Execution record (for hooks to broadcast events)

  ## Returns

  - `{:ok, executable}` - Successfully built workflow
  - `{:error, reason}` - Failed to build workflow
  """
  @spec build(WorkflowVersion.t(), Context.t(), Execution.t() | nil, state_store()) ::
          build_result()
  def build(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        state_store
      ) do
    engine().build(version, context, execution, state_store)
  end

  def build(%WorkflowVersion{} = version, %Context{} = context, nil, state_store) do
    engine().build(version, context, nil, state_store)
  end

  @spec build(WorkflowVersion.t(), Context.t(), Execution.t() | nil) :: build_result()
  def build(%WorkflowVersion{} = version, %Context{} = context, %Execution{} = execution) do
    build(version, context, execution, ExecutionState)
  end

  def build(%WorkflowVersion{} = version, %Context{} = context, nil) do
    build(version, context, nil, ExecutionState)
  end

  @doc """
  Builds an executable workflow without observability hooks.

  Use this variant for testing or preview mode where you don't need
  real-time node tracking.
  """
  @spec build(WorkflowVersion.t(), Context.t()) :: build_result()
  def build(%WorkflowVersion{} = version, %Context{} = context) do
    build(version, context, nil, ExecutionState)
  end

  @doc """
  Builds an executable workflow or raises on error.
  """
  @spec build!(WorkflowVersion.t(), Context.t()) :: term()
  def build!(%WorkflowVersion{} = version, %Context{} = context) do
    case build(version, context) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise "Failed to build workflow: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a partial workflow for executing a subset of nodes.

  ## Options

  - `:target_nodes` - List of node IDs to execute to (plus their dependencies)
  - `:pinned_outputs` - Map of node_id => output for nodes to skip
  - `:include_targets` - Whether to include target nodes in execution (default: true)

  ## Example

      # Execute all nodes needed to reach "transform_1", using pinned data
      {:ok, workflow} = build_partial(version, context, execution,
        target_nodes: ["transform_1"],
        pinned_outputs: %{"http_request" => %{"status" => 200}}
      )
  """
  @spec build_partial(WorkflowVersion.t(), Context.t(), Execution.t(), keyword(), state_store()) ::
          build_result()
  def build_partial(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        opts,
        state_store
      ) do
    engine().build_partial(version, context, execution, opts, state_store)
  end

  @spec build_partial(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
          build_result()
  def build_partial(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        opts \\ []
      ) do
    build_partial(version, context, execution, opts, ExecutionState)
  end

  @doc """
  Builds a partial workflow for executing downstream from a starting node.

  The starting node must have pinned output. All downstream nodes will
  execute using the pinned data as their input source.

  ## Options

  - `:from_node` - The node ID to start from (must be pinned)
  - `:pinned_outputs` - Map of all pinned outputs (required)

  ## Example

      # Run all nodes downstream of "http_request" using its pinned output
      {:ok, workflow} = build_downstream(version, context, execution,
        from_node: "http_request",
        pinned_outputs: %{"http_request" => %{"status" => 200, ...}}
      )
  """
  @spec build_downstream(
          WorkflowVersion.t(),
          Context.t(),
          Execution.t(),
          keyword(),
          state_store()
        ) :: build_result()
  def build_downstream(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        opts,
        state_store
      ) do
    engine().build_downstream(version, context, execution, opts, state_store)
  end

  @spec build_downstream(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
          build_result()
  def build_downstream(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        opts \\ []
      ) do
    build_downstream(version, context, execution, opts, ExecutionState)
  end

  @doc """
  Builds a workflow that executes a single node only.

  Assumes all upstream dependencies are satisfied (via pins or prior execution).
  Useful for re-running a single node during debugging.
  """
  @spec build_single_node(
          WorkflowVersion.t(),
          Context.t(),
          Execution.t(),
          String.t(),
          map(),
          state_store()
        ) ::
          build_result()
  def build_single_node(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        node_id,
        input_data,
        state_store
      ) do
    engine().build_single_node(version, context, execution, node_id, input_data, state_store)
  end

  @spec build_single_node(WorkflowVersion.t(), Context.t(), Execution.t(), String.t(), map()) ::
          build_result()
  def build_single_node(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        node_id,
        input_data
      ) do
    build_single_node(version, context, execution, node_id, input_data, ExecutionState)
  end

  @doc """
  Executes a workflow using the configured engine.
  """
  @spec execute(executable(), term(), Context.t(), state_store()) :: execute_result()
  def execute(executable, input, %Context{} = context, state_store) do
    engine().execute(executable, input, context, state_store)
  end

  @spec execute(executable(), term(), Context.t()) :: execute_result()
  def execute(executable, input, %Context{} = context) do
    execute(executable, input, context, ExecutionState)
  end
end
