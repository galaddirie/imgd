defmodule Imgd.Nodes.Executors.AggregateItems do
  @moduledoc """
  Executor for Aggregate Items nodes.

  Combines multiple items back into a single value (fan-in operation).
  This is the counterpart to Split Items for completing map-reduce patterns.

  ## Aggregation Modes

  - `array` - Collect all items into an array (default)
  - `first` - Take only the first item
  - `last` - Take only the last item
  - `reduce` - Apply custom reducer expression
  - `group_by` - Group items by a field value
  - `summarize` - Compute statistics (count, sum, avg, min, max)

  ## Examples

  ### Array Mode
      Input items: [%{total: 10}, %{total: 20}, %{total: 30}]
      Output: [%{total: 10}, %{total: 20}, %{total: 30}]

  ### Summarize Mode
      Config: %{"mode" => "summarize", "field" => "total", "operations" => ["sum", "avg"]}
      Output: %{"sum" => 60, "avg" => 20, "count" => 3}

  ### Group By Mode
      Config: %{"mode" => "group_by", "group_field" => "category"}
      Output: %{"electronics" => [...], "clothing" => [...]}
  """

  use Imgd.Nodes.Definition,
    id: "aggregate_items",
    name: "Aggregate Items",
    category: "Data",
    description: "Combine multiple items into a single result",
    icon: "hero-funnel",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "mode" => %{
        "type" => "string",
        "title" => "Aggregation Mode",
        "enum" => ["array", "first", "last", "reduce", "group_by", "summarize"],
        "default" => "array"
      },
      "field" => %{
        "type" => "string",
        "title" => "Field to Aggregate",
        "description" => "For summarize mode: which field to compute statistics on"
      },
      "group_field" => %{
        "type" => "string",
        "title" => "Group By Field",
        "description" => "For group_by mode: field to group items by"
      },
      "operations" => %{
        "type" => "array",
        "title" => "Operations",
        "items" => %{
          "type" => "string",
          "enum" => ["count", "sum", "avg", "min", "max"]
        },
        "default" => ["count"],
        "description" => "For summarize mode: which statistics to compute"
      },
      "output_field" => %{
        "type" => "string",
        "title" => "Output Field",
        "description" => "Wrap result in an object with this field name"
      },
      "include_errors" => %{
        "type" => "boolean",
        "title" => "Include Failed Items",
        "default" => false,
        "description" => "Include items that had errors during processing"
      }
    }
  }

  @input_schema %{
    "type" => "array",
    "description" => "Token containing items to aggregate",
    "x-items" => true
  }

  @output_schema %{
    "type" => "object",
    "description" => "Aggregated result based on mode"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  alias Imgd.Runtime.{Token, Item}

  @impl true
  def execute(config, input, _execution) do
    mode = Map.get(config, "mode", "array")
    include_errors = Map.get(config, "include_errors", false)
    output_field = Map.get(config, "output_field")

    # Extract items from input
    items = extract_items(input, include_errors)

    # Apply aggregation
    result =
      case mode do
        "array" -> aggregate_array(items)
        "first" -> aggregate_first(items)
        "last" -> aggregate_last(items)
        "group_by" -> aggregate_group_by(items, config)
        "summarize" -> aggregate_summarize(items, config)
        _ -> aggregate_array(items)
      end

    # Optionally wrap in output field
    output =
      if output_field do
        %{output_field => result}
      else
        result
      end

    {:ok, output}
  end

  @impl true
  def validate_config(config) do
    mode = Map.get(config, "mode", "array")
    errors = []

    errors =
      case mode do
        "group_by" ->
          if Map.get(config, "group_field") do
            errors
          else
            [{:group_field, "is required for group_by mode"} | errors]
          end

        "summarize" ->
          if Map.get(config, "field") do
            errors
          else
            [{:field, "is required for summarize mode"} | errors]
          end

        _ ->
          errors
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  # ============================================================================
  # Item Extraction
  # ============================================================================

  defp extract_items(%Token{items: items}, include_errors) when is_list(items) do
    if include_errors do
      items
    else
      Enum.reject(items, &Item.failed?/1)
    end
  end

  defp extract_items(%Token{data: data}, _include_errors) when is_list(data) do
    Item.from_list(data)
  end

  defp extract_items(list, _include_errors) when is_list(list) do
    Item.from_list(list)
  end

  defp extract_items(data, _include_errors) do
    [Item.new(data, 0)]
  end

  # ============================================================================
  # Aggregation Modes
  # ============================================================================

  defp aggregate_array(items) do
    Enum.map(items, & &1.json)
  end

  defp aggregate_first([]), do: nil
  defp aggregate_first([first | _]), do: first.json

  defp aggregate_last([]), do: nil
  defp aggregate_last(items), do: List.last(items).json

  defp aggregate_group_by(items, config) do
    group_field = Map.fetch!(config, "group_field")

    items
    |> Enum.group_by(fn item ->
      get_nested(item.json, group_field)
    end)
    |> Map.new(fn {key, grouped_items} ->
      {to_string(key), Enum.map(grouped_items, & &1.json)}
    end)
  end

  defp aggregate_summarize(items, config) do
    field = Map.fetch!(config, "field")
    operations = Map.get(config, "operations", ["count"])

    values =
      items
      |> Enum.map(fn item -> get_nested(item.json, field) end)
      |> Enum.filter(&is_number/1)

    compute_statistics(values, operations, length(items))
  end

  defp compute_statistics(values, operations, total_count) do
    Map.new(operations, fn op ->
      value =
        case op do
          "count" -> total_count
          "sum" -> Enum.sum(values)
          "avg" -> if values != [], do: Enum.sum(values) / length(values), else: nil
          "min" -> if values != [], do: Enum.min(values), else: nil
          "max" -> if values != [], do: Enum.max(values), else: nil
          _ -> nil
        end

      {op, value}
    end)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_nested(data, path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(data, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end
end
