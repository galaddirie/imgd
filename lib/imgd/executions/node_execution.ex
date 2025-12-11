defmodule Imgd.Executions.NodeExecution do
  @moduledoc """
  Tracks individual node execution within a workflow execution.
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

  @type status :: :pending | :running | :completed | :failed | :skipped

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          execution_id: Ecto.UUID.t(),
          node_id: String.t(),
          node_type_id: String.t(),
          status: status(),
          input_data: map() | nil,
          output_data: map() | nil,
          error: map() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          attempt: pos_integer(),
          retry_of_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "node_executions" do
    belongs_to :execution, Execution

    field :node_id, :string
    field :node_type_id, :string

    field :status, Ecto.Enum,
      values: [:pending, :running, :completed, :failed, :skipped],
      default: :pending

    field :input_data, :map
    field :output_data, :map
    field :error, :map

    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    field :attempt, :integer, default: 1
    field :retry_of_id, :binary_id

    timestamps()
  end

  def changeset(node_execution, attrs) do
    node_execution
    |> cast(
      attrs,
      [
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
        :retry_of_id
      ],
      empty_values: []
    )
    |> validate_required([:execution_id, :node_id, :node_type_id, :status])
    |> validate_number(:attempt, greater_than: 0)
    |> validate_map_field(:input_data, allow_nil: true)
    |> validate_map_field(:output_data, allow_nil: true)
    |> validate_map_field(:error, allow_nil: true)
  end

  defp validate_map_field(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_map(value) -> []
        is_nil(value) and Keyword.get(opts, :allow_nil, false) -> []
        true -> [{field, "must be a map"}]
      end
    end)
  end
end
