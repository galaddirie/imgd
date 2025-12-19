defmodule Imgd.Runtime.WorkflowBuilder do
  @moduledoc """
  Facade for building executable workflows from WorkflowVersions.

  This module delegates to the configured execution engine for actual
  workflow construction. It provides a stable API that doesn't change
  when the underlying engine is swapped.

  ## Usage

      {:ok, workflow} = WorkflowBuilder.build(version, execution, state_store, opts)
      {:ok, partial} = WorkflowBuilder.build_partial(version, execution, opts, state_store)
      {:ok, result} = WorkflowBuilder.execute(workflow, trigger_data, execution, state_store)

  ## Engine Configuration

  The underlying engine can be configured via:

      config :imgd, :execution_engine, Imgd.Runtime.Engines.Runic

  See `Imgd.Runtime.Engines.Behaviour` for implementing custom engines.
  """

  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Executions.Execution
  alias Imgd.Runtime.ExecutionState

  @type build_result :: {:ok, term()} | {:error, term()}

  @doc """
  Builds an executable workflow from a WorkflowVersion or Workflow.

  ## Parameters

  - `source` - The WorkflowVersion or Workflow containing nodes and connections
  - `execution` - The Execution record (for hooks to broadcast events), or nil
  - `state_store` - The state store module (default: ExecutionState)
  - `opts` - Additional build options

  ## Returns

  - `{:ok, executable}` - Successfully built workflow
  - `{:error, reason}` - Failed to build workflow
  """
  @spec build(
          WorkflowVersion.t() | Workflow.t(),
          Execution.t() | nil,
          module(),
          keyword()
        ) :: build_result()
  def build(source, execution, state_store, opts) do
    engine().build(source, execution, state_store, opts)
  end

  @doc """
  Builds an executable workflow with default state store.
  """
  @spec build(WorkflowVersion.t() | Workflow.t(), Execution.t() | nil) :: build_result()
  def build(source, execution) do
    build(source, execution, ExecutionState, [])
  end

  @doc """
  Builds an executable workflow with options.
  """
  @spec build(WorkflowVersion.t() | Workflow.t(), Execution.t() | nil, keyword()) ::
          build_result()
  def build(source, execution, opts) when is_list(opts) do
    build(source, execution, ExecutionState, opts)
  end

  @doc """
  Builds an executable workflow or raises on error.
  """
  @spec build!(WorkflowVersion.t() | Workflow.t(), Execution.t() | nil) :: term()
  def build!(source, execution) do
    case build(source, execution) do
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
  """
  @spec build_partial(
          WorkflowVersion.t() | Workflow.t(),
          Execution.t(),
          keyword(),
          module()
        ) :: build_result()
  def build_partial(source, execution, opts, state_store \\ ExecutionState) do
    engine().build_partial(source, execution, opts, state_store)
  end

  @doc """
  Executes a built workflow.

  ## Parameters

  - `executable` - The built workflow from `build/4`
  - `trigger_data` - Initial input data for the workflow
  - `execution` - The Execution record
  - `state_store` - The state store module (default: ExecutionState)
  """
  @spec execute(term(), term(), Execution.t(), module()) :: {:ok, map()} | {:error, term()}
  def execute(executable, trigger_data, execution, state_store \\ ExecutionState) do
    engine().execute(executable, trigger_data, execution, state_store)
  end

  @doc false
  def engine, do: Imgd.Runtime.Engines.Behaviour.engine()
end
