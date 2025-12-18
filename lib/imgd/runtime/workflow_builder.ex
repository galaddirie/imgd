defmodule Imgd.Runtime.WorkflowBuilder do
  @moduledoc """
  Facade for building executable workflows from WorkflowVersions.

  This module delegates to the configured `ExecutionEngine` for actual
  workflow construction. It provides a stable API that doesn't change
  when the underlying engine is swapped.

  ## Usage

      {:ok, workflow} = WorkflowBuilder.build(version, context, execution)
      {:ok, partial} = WorkflowBuilder.build_partial(version, context, execution, opts)

  ## Engine Configuration

  The underlying engine can be configured via:

      config :imgd, :execution_engine, Imgd.Runtime.Engines.Runic

  See `Imgd.Runtime.ExecutionEngine` for implementing custom engines.
  """

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.{Context, Execution}
  alias Imgd.Runtime.ExecutionState

  @type build_result :: {:ok, term()} | {:error, term()}

  @doc """
  Builds an executable workflow from a WorkflowVersion.

  ## Parameters

  - `version` - The WorkflowVersion containing nodes and connections
  - `context` - The execution context for resolving expressions and variables
  - `execution` - The Execution record (for hooks to broadcast events)
  - `state_store` - The state store module (optional, defaults to ExecutionState)

  ## Returns

  - `{:ok, executable}` - Successfully built workflow
  - `{:error, reason}` - Failed to build workflow
  """
  @spec build(WorkflowVersion.t(), Context.t(), Execution.t() | nil, module()) ::
          build_result()
  def build(version, context, execution, state_store \\ ExecutionState) do
    engine().build(version, context, execution, state_store)
  end

  @doc """
  Builds an executable workflow without observability hooks.
  """
  @spec build(WorkflowVersion.t(), Context.t()) :: build_result()
  def build(version, context) do
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
  """
  @spec build_partial(WorkflowVersion.t(), Context.t(), Execution.t(), keyword(), module()) ::
          build_result()
  def build_partial(version, context, execution, opts, state_store \\ ExecutionState) do
    engine().build_partial(version, context, execution, opts, state_store)
  end

  @doc """
  Executes a built workflow.
  """
  @spec execute(term(), term(), Context.t(), module()) :: {:ok, map()} | {:error, term()}
  def execute(executable, trigger_data, context, state_store \\ ExecutionState) do
    engine().execute(executable, trigger_data, context, state_store)
  end

  defp engine, do: Imgd.Runtime.Engine.Behaviour.engine()
end
