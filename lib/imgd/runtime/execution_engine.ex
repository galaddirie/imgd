defmodule Imgd.Runtime.ExecutionEngine do
  @moduledoc """
  Behavior for workflow execution engines.

  This abstraction allows swapping the underlying execution mechanism
  (Runic, custom interpreter, etc.) without affecting the rest of the system.

  ## Responsibilities

  An execution engine is responsible for:
  - Building an executable workflow from a WorkflowVersion
  - Running the workflow with given input
  - Managing node execution hooks for observability
  - Extracting results and logs after execution

  ## Configuration

  The engine can be configured in your application config:

      config :imgd, :execution_engine, Imgd.Runtime.Engines.Runic

  ## Implementing a Custom Engine

      defmodule MyApp.Runtime.Engines.Custom do
        @behaviour Imgd.Runtime.ExecutionEngine

        @impl true
        def build(version, context, execution) do
          # Build your executable representation
          {:ok, %{nodes: version.nodes, ...}}
        end

        @impl true
        def execute(executable, input, context) do
          # Run the workflow
          {:ok, %{output: result, node_outputs: outputs, engine_logs: %{}}}
        end
      end
  """

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.{Context, Execution}

  @type executable :: term()

  @type execution_result :: %{
          output: map() | nil,
          node_outputs: map(),
          engine_logs: map()
        }

  @type build_error ::
          {:cycle_detected, [String.t()]}
          | {:invalid_connections, [map()]}
          | {:build_failed, String.t()}
          | term()

  @type execution_error ::
          {:node_failed, node_id :: String.t(), reason :: term()}
          | {:timeout, Context.t()}
          | {:unexpected_error, String.t()}
          | term()

  @doc """
  Build an executable workflow from a WorkflowVersion.

  ## Parameters

  - `version` - The workflow version containing nodes, connections, triggers
  - `context` - Runtime context with variables, node outputs, etc.
  - `execution` - The execution record (optional). When provided, the engine
    should install hooks for real-time observability (PubSub, telemetry, etc.)

  ## Returns

  - `{:ok, executable}` - An opaque executable that can be passed to `execute/3`
  - `{:error, reason}` - Build failed with the given reason
  """
  @callback build(WorkflowVersion.t(), Context.t(), Execution.t() | nil) ::
              {:ok, executable()} | {:error, build_error()}

  @doc """
  Execute the workflow with the given input.

  ## Parameters

  - `executable` - The compiled workflow from `build/3`
  - `input` - Initial input data (usually from trigger)
  - `context` - Runtime context for expression evaluation

  ## Returns

  - `{:ok, result}` - Execution completed with output, node outputs, and logs
  - `{:error, reason}` - Execution failed
  """
  @callback execute(executable(), input :: term(), Context.t()) ::
              {:ok, execution_result()} | {:error, execution_error()}

  @doc """
  Build a partial workflow for executing a subset of nodes.

  Used for features like "execute to here" where only upstream dependencies
  of target nodes need to run.

  ## Options

  - `:target_nodes` - List of node IDs to execute (plus their dependencies)
  - `:pinned_outputs` - Map of node_id => output for nodes to skip
  - `:include_targets` - Whether to include target nodes in execution (default: true)
  """
  @callback build_partial(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
              {:ok, executable()} | {:error, build_error()}

  @doc """
  Build a workflow for executing downstream from a starting node.

  The starting node must have pinned output in the options.

  ## Options

  - `:from_node` - The node ID to start from (required)
  - `:pinned_outputs` - Map of node_id => output (required, must include from_node)
  """
  @callback build_downstream(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
              {:ok, executable()} | {:error, build_error()}

  @doc """
  Build a workflow for executing a single node.

  Assumes all upstream dependencies are satisfied via the provided input_data.

  ## Parameters

  - `version` - The workflow version
  - `context` - Runtime context
  - `execution` - The execution record
  - `node_id` - The specific node to execute
  - `input_data` - Input data for the node
  """
  @callback build_single_node(
              WorkflowVersion.t(),
              Context.t(),
              Execution.t(),
              node_id :: String.t(),
              input_data :: map()
            ) :: {:ok, executable()} | {:error, build_error()}

  @optional_callbacks [build_partial: 4, build_downstream: 4, build_single_node: 5]

  # ===========================================================================
  # Engine Resolution
  # ===========================================================================

  @doc """
  Returns the configured execution engine module.

  Defaults to `Imgd.Runtime.Engines.Runic` if not configured.
  """
  @spec engine() :: module()
  def engine do
    Application.get_env(:imgd, :execution_engine, Imgd.Runtime.Engines.Runic)
  end

  # ===========================================================================
  # Delegated API (convenience functions that use the configured engine)
  # ===========================================================================

  @doc """
  Build a workflow using the configured engine.
  """
  @spec build(WorkflowVersion.t(), Context.t(), Execution.t() | nil) ::
          {:ok, executable()} | {:error, build_error()}
  def build(version, context, execution \\ nil) do
    engine().build(version, context, execution)
  end

  @doc """
  Execute a workflow using the configured engine.
  """
  @spec execute(executable(), term(), Context.t()) ::
          {:ok, execution_result()} | {:error, execution_error()}
  def execute(executable, input, context) do
    engine().execute(executable, input, context)
  end

  @doc """
  Build a partial workflow using the configured engine.
  """
  @spec build_partial(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
          {:ok, executable()} | {:error, build_error()}
  def build_partial(version, context, execution, opts) do
    engine().build_partial(version, context, execution, opts)
  end

  @doc """
  Build a downstream workflow using the configured engine.
  """
  @spec build_downstream(WorkflowVersion.t(), Context.t(), Execution.t(), keyword()) ::
          {:ok, executable()} | {:error, build_error()}
  def build_downstream(version, context, execution, opts) do
    engine().build_downstream(version, context, execution, opts)
  end

  @doc """
  Build a single-node workflow using the configured engine.
  """
  @spec build_single_node(WorkflowVersion.t(), Context.t(), Execution.t(), String.t(), map()) ::
          {:ok, executable()} | {:error, build_error()}
  def build_single_node(version, context, execution, node_id, input_data) do
    engine().build_single_node(version, context, execution, node_id, input_data)
  end
end
