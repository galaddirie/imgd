defmodule Imgd.Runtime.Item do
  @moduledoc """
  Individual data item for collection processing.

  Items are the fundamental unit of data in fan-out/fan-in workflows.
  When a node runs in "map" mode, it processes each item independently.

  ## Structure

  - `json` - The item's data payload (must be JSON-serializable)
  - `index` - Original position in the collection
  - `binary` - Optional binary attachment (file contents, etc.)
  - `metadata` - Execution metadata (pairing info, errors, timing)

  ## n8n Compatibility

  This structure mirrors n8n's item concept for familiarity:
  - `json` field contains the main data
  - Binary data is separate from JSON data
  - Pairing/indexing enables error recovery and debugging

  ## Examples

      # Simple item
      Item.new(%{"name" => "Alice", "email" => "alice@example.com"}, 0)

      # Item with binary attachment
      Item.new(%{"filename" => "doc.pdf"}, 0, pdf_bytes)

      # Item with metadata
      item = Item.new(data, 0)
      item = Item.with_metadata(item, %{source_row: 42})
  """

  @derive Jason.Encoder

  @type t :: %__MODULE__{
          json: map(),
          index: non_neg_integer(),
          binary: binary() | nil,
          metadata: map()
        }

  @enforce_keys [:json, :index]
  defstruct [
    :json,
    :index,
    :binary,
    metadata: %{}
  ]

  @doc """
  Creates a new item with the given data.

  ## Examples

      Item.new(%{"id" => 1, "name" => "Test"}, 0)
      Item.new(%{"file" => "data.csv"}, 0, csv_bytes)
  """
  @spec new(map() | term(), non_neg_integer(), binary() | nil) :: t()
  def new(json, index, binary \\ nil)

  def new(json, index, binary) when is_map(json) do
    %__MODULE__{
      json: json,
      index: index,
      binary: binary,
      metadata: %{}
    }
  end

  # Wrap non-map values in a map for consistency
  def new(value, index, binary) do
    %__MODULE__{
      json: %{"value" => value},
      index: index,
      binary: binary,
      metadata: %{}
    }
  end

  @doc """
  Creates items from a list of values.
  """
  @spec from_list([map() | term()]) :: [t()]
  def from_list(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> new(value, index) end)
  end

  @doc """
  Updates the json data of an item.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = item, new_json) when is_map(new_json) do
    %{item | json: new_json}
  end

  @doc """
  Merges additional data into the item's json.
  """
  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{json: json} = item, additional) when is_map(additional) do
    %{item | json: Map.merge(json, additional)}
  end

  @doc """
  Adds metadata to an item.
  """
  @spec with_metadata(t(), map()) :: t()
  def with_metadata(%__MODULE__{metadata: existing} = item, metadata) when is_map(metadata) do
    %{item | metadata: Map.merge(existing, metadata)}
  end

  @doc """
  Marks an item as failed with an error.
  """
  @spec with_error(t(), term()) :: t()
  def with_error(%__MODULE__{} = item, error) do
    with_metadata(item, %{
      error: format_error(error),
      failed_at: DateTime.utc_now()
    })
  end

  @doc """
  Returns true if the item has an error.
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{metadata: %{error: _}}), do: true
  def failed?(_), do: false

  @doc """
  Gets a value from the item's json using a path.

  ## Examples

      Item.get(item, "user.name")
      Item.get(item, ["user", "email"])
  """
  @spec get(t(), String.t() | [String.t()], term()) :: term()
  def get(item, path, default \\ nil)

  def get(%__MODULE__{json: json}, path, default) when is_binary(path) do
    get_in_path(json, String.split(path, "."), default)
  end

  def get(%__MODULE__{json: json}, path, default) when is_list(path) do
    get_in_path(json, path, default)
  end

  @doc """
  Sets a value in the item's json using a path.
  """
  @spec put(t(), String.t() | [String.t()], term()) :: t()
  def put(%__MODULE__{json: json} = item, path, value) when is_binary(path) do
    %{item | json: put_in_path(json, String.split(path, "."), value)}
  end

  def put(%__MODULE__{json: json} = item, path, value) when is_list(path) do
    %{item | json: put_in_path(json, path, value)}
  end

  @doc """
  Converts an item to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = item) do
    base = %{"json" => item.json, "index" => item.index}

    base =
      if item.binary do
        Map.put(base, "binary", Base.encode64(item.binary))
      else
        base
      end

    if map_size(item.metadata) > 0 do
      Map.put(base, "metadata", item.metadata)
    else
      base
    end
  end

  @doc """
  Creates an item from a serialized map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    binary =
      case Map.get(map, "binary") do
        nil -> nil
        b64 when is_binary(b64) -> Base.decode64!(b64)
      end

    %__MODULE__{
      json: Map.get(map, "json", %{}),
      index: Map.get(map, "index", 0),
      binary: binary,
      metadata: Map.get(map, "metadata", %{})
    }
  end

  # Private helpers

  defp get_in_path(data, [], _default), do: data
  defp get_in_path(nil, _path, default), do: default

  defp get_in_path(data, [key | rest], default) when is_map(data) do
    case Map.get(data, key) do
      nil -> default
      value -> get_in_path(value, rest, default)
    end
  end

  defp get_in_path(_data, _path, default), do: default

  defp put_in_path(_data, [], value), do: value

  defp put_in_path(data, [key | rest], value) when is_map(data) do
    existing = Map.get(data, key, %{})
    Map.put(data, key, put_in_path(existing, rest, value))
  end

  defp put_in_path(_data, [key | rest], value) do
    %{key => put_in_path(%{}, rest, value)}
  end

  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
