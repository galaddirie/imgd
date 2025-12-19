defmodule Imgd.Runtime.Engines.Behaviour do
  @moduledoc """
  Behavior for workflow execution engines.
  """

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.{Context, Execution}

  @type executable :: term()
  @type execution_result :: %{output: map() | nil, node_outputs: map(), engine_logs: map()}

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

  @callback build(WorkflowVersion.t(), Context.t(), Execution.t() | nil, module(), keyword()) ::
              {:ok, executable()} | {:error, build_error()}

  @callback execute(executable(), term(), Context.t(), module()) ::
              {:ok, execution_result()} | {:error, execution_error()}

  @callback build_partial(WorkflowVersion.t(), Context.t(), Execution.t(), keyword(), module()) ::
              {:ok, executable()} | {:error, build_error()}

  @optional_callbacks [build_partial: 5]

  @doc "Returns the configured execution engine module."
  @spec engine() :: module()
  def engine, do: Application.get_env(:imgd, :execution_engine, Imgd.Runtime.Engines.Runic)
end
