defmodule Imgd.Runtime.ExecutionEngine do
  @moduledoc """
  Delegated API for the configured execution engine.

  Use `Imgd.Runtime.WorkflowBuilder` for the public build API and
  `Imgd.Runtime.Engines.Behaviour` when implementing custom engines.
  """

  alias Imgd.Executions.{Context, Execution}
  alias Imgd.Runtime.Engines.Behaviour
  alias Imgd.Workflows.WorkflowVersion

  @doc """
  Returns the configured execution engine module.
  """
  @spec engine() :: module()
  def engine, do: Behaviour.engine()

  # ===========================================================================
  # Delegated API (convenience functions that use the configured engine)
  # ===========================================================================

  @doc """
  Build a workflow using the configured engine.
  """
  @spec build(WorkflowVersion.t(), Context.t(), Execution.t() | nil) ::
          {:ok, Behaviour.executable()} | {:error, Behaviour.build_error()}
  def build(version, context, execution \\ nil) do
    engine().build(version, context, execution)
  end

  @doc """
  Execute a workflow using the configured engine.
  """
  @spec execute(Behaviour.executable(), term(), Context.t()) ::
          {:ok, Behaviour.execution_result()} | {:error, Behaviour.execution_error()}
  def execute(executable, input, context) do
    engine().execute(executable, input, context)
  end

  @doc """
  Build a partial workflow using the configured engine.
  """
  @spec build_partial(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
          {:ok, Behaviour.executable()} | {:error, Behaviour.build_error()}
  def build_partial(version, context, execution, opts) do
    engine().build_partial(version, context, execution, opts)
  end

  @doc """
  Build a downstream workflow using the configured engine.
  """
  @spec build_downstream(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
          {:ok, Behaviour.executable()} | {:error, Behaviour.build_error()}
  def build_downstream(version, context, execution, opts) do
    engine().build_downstream(version, context, execution, opts)
  end

  @doc """
  Build a single-node workflow using the configured engine.
  """
  @spec build_single_node(WorkflowVersion.t(), Context.t(), Execution.t(), String.t(), map()) ::
          {:ok, Behaviour.executable()} | {:error, Behaviour.build_error()}
  def build_single_node(version, context, execution, node_id, input_data) do
    engine().build_single_node(version, context, execution, node_id, input_data)
  end
end
