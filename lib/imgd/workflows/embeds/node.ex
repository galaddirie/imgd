defmodule Imgd.Workflows.Embeds.Node do
  @moduledoc """
  Embedded schema for workflow nodes.
  Shared between Workflow (mutable) and WorkflowVersion (immutable).

  ## Execution Modes

  Nodes can operate in different modes for collection processing:

  - `:passthrough` (default) - Process all data as single unit
  - `:map` - Execute once per item, in parallel
  - `:reduce` - Receive all items, emit single aggregated result

  ## Example

      %Node{
        id: "http_request_1",
        type_id: "http_request",
        name: "Fetch User Details",
        execution_mode: :map,      # Process each item individually
        batch_size: 5,             # Max 5 concurrent executions
        config: %{"url" => "{{ json.api_url }}"}
      }
  """
  @derive Jason.Encoder
  use Ecto.Schema
  import Ecto.Changeset
  import Imgd.ChangesetHelpers

  @primary_key false

  @type execution_mode :: :passthrough | :map | :reduce

  @type t :: %__MODULE__{
          id: String.t(),
          type_id: String.t(),
          name: String.t(),
          config: map(),
          position: map(),
          notes: String.t() | nil,
          execution_mode: execution_mode(),
          batch_size: pos_integer() | nil,
          retry_config: map()
        }

  @execution_modes [:passthrough, :map, :reduce]

  embedded_schema do
    field :id, :string
    field :type_id, :string
    field :name, :string
    field :config, :map, default: %{}
    field :position, :map, default: %{}
    field :notes, :string

    # Execution mode for collection processing
    field :execution_mode, Ecto.Enum, values: @execution_modes, default: :passthrough

    # For map mode: max concurrent item executions (nil = unlimited)
    field :batch_size, :integer

    # Retry configuration for failed items
    field :retry_config, :map, default: %{}
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :id,
      :type_id,
      :name,
      :config,
      :position,
      :notes,
      :execution_mode,
      :batch_size,
      :retry_config
    ])
    |> validate_required([:id, :type_id, :name])
    |> validate_map_field(:config)
    |> validate_map_field(:position)
    |> validate_map_field(:retry_config)
    |> validate_number(:batch_size, greater_than: 0)
    |> validate_batch_size_with_mode()
  end

  defp validate_batch_size_with_mode(changeset) do
    mode = get_field(changeset, :execution_mode)
    batch_size = get_field(changeset, :batch_size)

    if batch_size && mode != :map do
      add_error(changeset, :batch_size, "can only be set when execution_mode is :map")
    else
      changeset
    end
  end

  # ============================================================================
  # Convenience Functions
  # ============================================================================

  @doc """
  Returns true if this node processes items individually.
  """
  def map_mode?(%__MODULE__{execution_mode: :map}), do: true
  def map_mode?(_), do: false

  @doc """
  Returns true if this node aggregates items.
  """
  def reduce_mode?(%__MODULE__{execution_mode: :reduce}), do: true
  def reduce_mode?(_), do: false

  @doc """
  Returns the effective batch size for map mode execution.
  """
  def effective_batch_size(%__MODULE__{execution_mode: :map, batch_size: nil}), do: :unlimited
  def effective_batch_size(%__MODULE__{execution_mode: :map, batch_size: n}), do: n
  def effective_batch_size(_), do: nil
end
