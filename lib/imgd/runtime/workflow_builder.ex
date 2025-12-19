defmodule Imgd.Runtime.WorkflowBuilder do
  @moduledoc """
  Facade for building executable workflows from WorkflowVersions.

  This module delegates to the configured `WorkflowBuilder` for actual
  workflow construction. It provides a stable API that doesn't change
  when the underlying engine is swapped.

  ## Usage

      {:ok, workflow} = WorkflowBuilder.build(version, context, execution)
      {:ok, partial} = WorkflowBuilder.build_partial(version, context, execution, opts)

  ## Engine Configuration

  The underlying engine can be configured via:

      config :imgd, :execution_engine, Imgd.Runtime.Engines.Runic

  See `Imgd.Runtime.Engines.Behaviour` for implementing custom engines.
  """

  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Executions.{Context, Execution}
  alias Imgd.Runtime.ExecutionState

  @type build_result :: {:ok, term()} | {:error, term()}

  @doc """
  Builds an executable workflow from a WorkflowVersion or Workflow.

  ## Parameters

  - `source` - The WorkflowVersion or Workflow containing nodes and connections
  - `context` - The execution context for resolving expressions and variables
  - `execution` - The Execution record (for hooks to broadcast events)
  - `state_store` - The state store module (optional, defaults to ExecutionState)
  - `opts` - Additional build options (optional)

  ## Returns

  - `{:ok, executable}` - Successfully built workflow
  - `{:error, reason}` - Failed to build workflow
  """
  @spec build(
          WorkflowVersion.t() | Workflow.t(),
          Context.t(),
          Execution.t() | nil,
          module(),
          keyword()
        ) ::
          build_result()
  def build(source, context, execution, state_store, opts) do
    engine().build(source, context, execution, state_store, opts)
  end

  @doc false
  @spec build(WorkflowVersion.t() | Workflow.t(), Context.t(), Execution.t() | nil) ::
          build_result()
  def build(source, context, execution)
      when is_nil(execution) or is_struct(execution, Execution) do
    build(source, context, execution, ExecutionState, [])
  end

  @doc false
  @spec build(WorkflowVersion.t() | Workflow.t(), Context.t(), keyword()) :: build_result()
  def build(source, context, opts) when is_list(opts) do
    build(source, context, nil, ExecutionState, opts)
  end

  @doc false
  @spec build(WorkflowVersion.t() | Workflow.t(), Context.t()) :: build_result()
  def build(source, context) do
    build(source, context, nil, ExecutionState, [])
  end

  @doc """
  Builds an executable workflow or raises on error.
  """
  @spec build!(WorkflowVersion.t() | Workflow.t(), Context.t()) :: term()
  def build!(source, %Context{} = context) do
    case build(source, context) do
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
          Context.t(),
          Execution.t(),
          keyword(),
          module()
        ) ::
          build_result()
  def build_partial(source, context, execution, opts, state_store \\ ExecutionState) do
    engine().build_partial(source, context, execution, opts, state_store)
  end

  @doc """
  Executes a built workflow.
  """
  @spec execute(term(), term(), Context.t(), module()) :: {:ok, map()} | {:error, term()}
  def execute(executable, trigger_data, context, state_store \\ ExecutionState) do
    engine().execute(executable, trigger_data, context, state_store)
  end

  @doc false
  def engine, do: Imgd.Runtime.Engines.Behaviour.engine()
end
