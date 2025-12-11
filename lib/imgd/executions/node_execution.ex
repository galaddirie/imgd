defmodule Imgd.Executions.NodeExecution do
  @moduledoc """
  Tracks individual node execution within a workflow execution..
  """

  use Imgd.Schema

  @derive {Jason.Encoder,
           only: [
             :id,
             :execution_id,
             :node_id,
             :node_type_id,
             :status,
             :input_data,
             :output_data,
             :error,
             :started_at,
             :finished_at,
             :attempt,
             :retry_of_id,
             :inserted_at,
             :updated_at
           ]}

  alias Imgd.Executions.Execution

  # Todo: add types
  schema "node_executions" do
    belongs_to :execution, Execution

    field :node_id, :string
    field :node_type_id, :string
    field :status, Ecto.Enum, values: [:pending, :running, :completed, :failed, :skipped]

    field :input_data, :map
    field :output_data, :map
    field :error, :map

    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    field :attempt, :integer, default: 1
    field :retry_of_id, :integer

    timestamps()
  end

  # Todo: changesets
end
