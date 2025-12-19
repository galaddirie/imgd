defmodule Imgd.Runtime.Engines.Behaviour do
  @moduledoc """
  Behavior for workflow execution engines.

  Engines are responsible for:
  - Building an executable representation from a WorkflowVersion
  - Executing the workflow and returning results
  - Managing node execution lifecycle (via hooks)

  ## Runtime State

  All runtime state (node outputs, timing, etc.) is managed by the
  `state_store` module (typically `ExecutionState`). The engine reads
  and writes to this store during execution.
  """

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.Execution

  @type executable :: term()
  @type execution_result :: %{output: map() | nil, node_outputs: map(), engine_logs: map()}

  @type build_error ::
          {:cycle_detected, [String.t()]}
          | {:invalid_connections, [map()]}
          | {:build_failed, String.t()}
          | term()

  @type execution_error ::
          {:node_failed, String.t(), term()}
          | {:timeout, map()}
          | {:unexpected_error, String.t()}
          | term()

  @doc """
  Builds an executable workflow from a WorkflowVersion.

  ## Parameters

  - `source` - WorkflowVersion or Workflow containing nodes and connections
  - `execution` - The Execution record (for hooks and metadata)
  - `state_store` - Module for runtime state storage
  - `opts` - Additional build options
  """
  @callback build(
              WorkflowVersion.t() | Imgd.Workflows.Workflow.t(),
              Execution.t() | nil,
              module(),
              keyword()
            ) ::
              {:ok, executable()} | {:error, build_error()}

  @doc """
  Executes a built workflow.

  ## Parameters

  - `executable` - The built workflow from `build/4`
  - `trigger_data` - Initial input data for the workflow
  - `execution` - The Execution record
  - `state_store` - Module for runtime state storage
  """
  @callback execute(executable(), term(), Execution.t(), module()) ::
              {:ok, execution_result()} | {:error, execution_error()}

  @doc """
  Builds a partial workflow for executing a subset of nodes.

  ## Parameters

  - `source` - WorkflowVersion or Workflow
  - `execution` - The Execution record
  - `opts` - Options including :target_nodes and :pinned_outputs
  - `state_store` - Module for runtime state storage
  """
  @callback build_partial(
              WorkflowVersion.t() | Imgd.Workflows.Workflow.t(),
              Execution.t(),
              keyword(),
              module()
            ) ::
              {:ok, executable()} | {:error, build_error()}

  @optional_callbacks [build_partial: 4]

  @doc "Returns the configured execution engine module."
  @spec engine() :: module()
  def engine, do: Application.get_env(:imgd, :execution_engine, Imgd.Runtime.Engines.Runic)
end
