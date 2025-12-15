defmodule Imgd.Workflows.Embeds.PinnedOutput do
  @moduledoc """
  Embedded schema for pinned node outputs.

  Pins freeze a node's output data at the workflow draft level for
  iterative development. When a node is pinned, execution skips the
  node's work function and injects the pinned data directly into context.

  ## Fields

  - `data` - The actual output data (any JSON-serializable value)
  - `pinned_at` - Timestamp when the output was pinned
  - `pinned_by` - User ID who created the pin
  - `config_hash` - Hash of the node's config at pin time (for staleness detection)
  - `source_execution_id` - Optional execution ID the data came from
  - `label` - Optional user-provided description
  """
  @derive Jason.Encoder
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{
          data: map() | any(),
          pinned_at: DateTime.t(),
          pinned_by: Ecto.UUID.t(),
          config_hash: String.t(),
          source_execution_id: Ecto.UUID.t() | nil,
          label: String.t() | nil
        }

  embedded_schema do
    field :data, :map
    field :pinned_at, :utc_datetime_usec
    field :pinned_by, :binary_id
    field :config_hash, :string
    field :source_execution_id, :binary_id
    field :label, :string
  end

  def changeset(pinned_output, attrs) do
    pinned_output
    |> cast(attrs, [:data, :pinned_at, :pinned_by, :config_hash, :source_execution_id, :label])
    |> validate_required([:data, :pinned_at, :pinned_by, :config_hash])
  end

  @doc """
  Creates a new pinned output struct.
  """
  def new(data, user_id, config_hash, opts \\ []) do
    %__MODULE__{
      data: data,
      pinned_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      pinned_by: user_id,
      config_hash: config_hash,
      source_execution_id: Keyword.get(opts, :execution_id),
      label: Keyword.get(opts, :label)
    }
  end

  @doc """
  Converts a PinnedOutput struct to a map suitable for JSON storage.
  """
  def to_map(%__MODULE__{} = pin) do
    %{
      "data" => pin.data,
      "pinned_at" => DateTime.to_iso8601(pin.pinned_at),
      "pinned_by" => pin.pinned_by,
      "config_hash" => pin.config_hash,
      "source_execution_id" => pin.source_execution_id,
      "label" => pin.label
    }
  end

  @doc """
  Parses a map from JSON storage back into a PinnedOutput-like map.
  Returns a map with atom keys for consistency.
  """
  def from_map(nil), do: nil

  def from_map(map) when is_map(map) do
    %{
      data: Map.get(map, "data") || Map.get(map, :data),
      pinned_at: parse_datetime(Map.get(map, "pinned_at") || Map.get(map, :pinned_at)),
      pinned_by: Map.get(map, "pinned_by") || Map.get(map, :pinned_by),
      config_hash: Map.get(map, "config_hash") || Map.get(map, :config_hash),
      source_execution_id:
        Map.get(map, "source_execution_id") || Map.get(map, :source_execution_id),
      label: Map.get(map, "label") || Map.get(map, :label)
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
