defmodule Imgd.Runtime.Engine.Behaviour do
  @moduledoc """
  Behavior for workflow execution engines.
  """

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.{Context, Execution}

  @type executable :: term()
  @type execution_result :: %{output: map() | nil, node_outputs: map(), engine_logs: map()}
  @type state_store :: module()

  @type build_error ::
          {:cycle_detected, [String.t()]}
          | {:invalid_connections, [map()]}
          | {:build_failed, String.t()}
          | term()

  @type execution_error ::
          {:node_failed, String.t(), term()}
          | {:timeout, Context.t()}
          | {:unexpected_error, String.t()}
          | term()

  @callback build(WorkflowVersion.t(), Context.t(), Execution.t() | nil, state_store()) ::
              {:ok, executable()} | {:error, build_error()}

  @callback execute(executable(), term(), Context.t(), state_store()) ::
              {:ok, execution_result()} | {:error, execution_error()}

  @callback build_partial(
              WorkflowVersion.t(),
              Context.t(),
              Execution.t(),
              keyword(),
              state_store()
            ) ::
              {:ok, executable()} | {:error, build_error()}

  @callback build_downstream(
              WorkflowVersion.t(),
              Context.t(),
              Execution.t(),
              keyword(),
              state_store()
            ) ::
              {:ok, executable()} | {:error, build_error()}

  @callback build_single_node(
              WorkflowVersion.t(),
              Context.t(),
              Execution.t(),
              String.t(),
              map(),
              state_store()
            ) ::
              {:ok, executable()} | {:error, build_error()}

  @optional_callbacks [build_partial: 5, build_downstream: 5, build_single_node: 6]

  @doc "Returns the configured execution engine module."
  @spec engine() :: module()
  def engine, do: Application.get_env(:imgd, :execution_engine, Imgd.Runtime.Engines.Runic)
end
