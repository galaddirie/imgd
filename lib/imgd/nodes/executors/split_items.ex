defmodule Imgd.Nodes.Executors.SplitItems do
  @moduledoc """
  Executor for Split Items nodes.

  Converts a single value (array field) into multiple items for parallel processing.
  This is the "fan-out" operation that enables map-style execution.

  ## Configuration

  - `field` (required) - Expression pointing to array to split on
  - `include_parent` (optional) - Include parent data in each item
  - `flatten` (optional) - Flatten nested arrays

  ## Example

      Input: %{"users" => [%{"name" => "Alice"}, %{"name" => "Bob"}]}
      Config: %{"field" => "{{ json.users }}"}

      Output: Token with items:
        [
          %Item{json: %{"name" => "Alice"}, index: 0},
          %Item{json: %{"name" => "Bob"}, index: 1}
        ]

  Downstream nodes in "map" mode will execute once per item.
  """

  use Imgd.Nodes.Definition,
    id: "split_items",
    name: "Split Into Items",
    category: "Data",
    description: "Convert an array into individual items for parallel processing",
    icon: "hero-rectangle-stack",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["field"],
    "properties" => %{
      "field" => %{
        "type" => "string",
        "title" => "Array Field",
        "description" => "Expression for the array to split. Example: {{ json.items }}"
      },
      "include_parent" => %{
        "type" => "boolean",
        "title" => "Include Parent Data",
        "default" => false,
        "description" => "Merge parent object fields into each item"
      },
      "flatten" => %{
        "type" => "boolean",
        "title" => "Flatten Nested Arrays",
        "default" => false,
        "description" => "Flatten nested arrays into single level"
      },
      "key_field" => %{
        "type" => "string",
        "title" => "Key Field",
        "description" => "Optional: store original index or key in this field"
      }
    }
  }

  @input_schema %{
    "type" => "object",
    "description" => "Object containing array to split"
  }

  @output_schema %{
    "type" => "array",
    "description" => "Token containing items from the split array",
    "x-items" => true
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  alias Imgd.Runtime.{Token, Item}

  @impl true
  def execute(config, input, _execution) do
    field_expr = Map.fetch!(config, "field")
    include_parent = Map.get(config, "include_parent", false)
    flatten = Map.get(config, "flatten", false)
    key_field = Map.get(config, "key_field")

    context = %{"json" => input}

    with {:ok, array} <- extract_array(field_expr, context, flatten) do
      items = build_items(array, input, include_parent, key_field)
      {:ok, Token.with_items(items)}
    end
  end

  @impl true
  def validate_config(config) do
    case Map.get(config, "field") do
      nil -> {:error, [field: "is required"]}
      f when is_binary(f) -> :ok
      _ -> {:error, [field: "must be a string expression"]}
    end
  end

  defp extract_array(expression, context, flatten) do
    template = build_array_template(expression)

    case Imgd.Runtime.Core.Expression.evaluate_with_vars(template, context) do
      {:ok, result} ->
        parsed = parse_result(result)

        case parsed do
          list when is_list(list) ->
            final = if flatten, do: List.flatten(list), else: list
            {:ok, final}

          _ ->
            {:error, {:not_an_array, parsed}}
        end

      {:error, reason} ->
        {:error, {:expression_failed, reason}}
    end
  end

  defp build_array_template(expression) do
    expression
    |> unwrap_expression()
    |> ensure_json_filter()
    |> then(&"{{ #{&1} }}")
  end

  defp unwrap_expression(expression) do
    trimmed = String.trim(expression)

    case Regex.run(~r/^\{\{\s*(.*?)\s*\}\}\s*$/s, trimmed) do
      [_, inner] -> inner
      _ -> trimmed
    end
  end

  defp ensure_json_filter(expression) do
    trimmed = String.trim(expression)

    if Regex.match?(~r/\|\s*json\b/, trimmed) do
      trimmed
    else
      trimmed <> " | json"
    end
  end

  defp parse_result(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, decoded} -> decoded
      _ -> result
    end
  end

  defp parse_result(result), do: result

  defp build_items(array, parent_data, include_parent, key_field) do
    array
    |> Enum.with_index()
    |> Enum.map(fn {element, index} ->
      json = build_item_json(element, parent_data, include_parent, key_field, index)
      Item.new(json, index)
    end)
  end

  defp build_item_json(element, parent_data, include_parent, key_field, index) do
    base =
      cond do
        is_map(element) -> element
        true -> %{"value" => element}
      end

    base =
      if include_parent and is_map(parent_data) do
        # Merge parent but element takes precedence
        Map.merge(parent_data, base)
      else
        base
      end

    if key_field do
      Map.put(base, key_field, index)
    else
      base
    end
  end
end
