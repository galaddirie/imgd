defmodule Imgd.Nodes.Executors.Splitter do
  @moduledoc """
  Executor for Splitter nodes.

  Splits a collection into individual items for parallel processing.
  In Runic, this creates a `Runic.map` component that iterates over items.

  ## Configuration

  - `field` (optional) - Dot-path to the field containing the collection.
    If not specified, treats the entire input as the collection.

  ## Input

  Receives a map or list. If `field` is specified, extracts the collection
  from that field.

  ## Output

  When used with Runic's map, each item becomes a separate fact that flows
  to downstream nodes.

  ## Example

      # Input: %{"items" => [1, 2, 3]}
      # Config: %{"field" => "items"}
      # Output: Each of 1, 2, 3 flows as separate facts
  """

  use Imgd.Nodes.Definition,
    id: "splitter",
    name: "Split Items",
    category: "Data",
    description: "Split a list into individual items for parallel processing",
    icon: "hero-arrows-pointing-out",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "field" => %{
        "type" => "string",
        "title" => "Source Field",
        "description" => "Dot-path to field containing the collection (optional)"
      }
    }
  }

  @input_schema %{
    "description" => "A map containing a collection, or the collection itself"
  }

  @output_schema %{
    "description" => "Each item from the collection as a separate output"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(config, input, _ctx) do
    field = Map.get(config, "field")

    items =
      if field && is_binary(field) && field != "" do
        # Extract from nested field
        get_nested(input, String.split(field, "."))
      else
        # Use input directly
        input
      end

    case items do
      list when is_list(list) ->
        {:ok, list}

      %Range{} = range ->
        {:ok, Enum.to_list(range)}

      map when is_map(map) ->
        # Convert map to list of {key, value} tuples
        {:ok, Map.to_list(map)}

      nil ->
        {:ok, []}

      other ->
        # Wrap single item in list
        {:ok, [other]}
    end
  end

  @impl true
  def validate_config(_config), do: :ok

  defp get_nested(data, []), do: data
  defp get_nested(data, [key | rest]) when is_map(data), do: get_nested(Map.get(data, key), rest)
  defp get_nested(_, _), do: nil
end
