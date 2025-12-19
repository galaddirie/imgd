defmodule Imgd.Nodes.Executors.Transform do
  @moduledoc """
  Executor for Transform nodes.

  Transforms input data using configured operations. This is a general-purpose
  data transformation node that supports various operations.

  ## Supported Operations

  - `map` - Apply a mapping to each item in a list
  - `filter` - Filter items based on a condition
  - `pick` - Select specific fields from the input
  - `omit` - Remove specific fields from the input
  - `merge` - Merge additional data into the input
  - `set` - Set a specific field value
  - `rename` - Rename fields
  - `flatten` - Flatten nested arrays
  - `passthrough` - Pass input unchanged (useful for testing)
  """

  use Imgd.Nodes.Definition,
    id: "transform",
    name: "Transform",
    category: "Data",
    description: "Transform and reshape data using various operations",
    icon: "hero-arrows-right-left",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "title" => "Operation",
        "enum" => [
          "map",
          "filter",
          "pick",
          "omit",
          "merge",
          "set",
          "rename",
          "flatten",
          "passthrough"
        ],
        "description" => "The transformation operation to perform"
      },
      "options" => %{
        "type" => "object",
        "title" => "Options",
        "description" => "Operation-specific options",
        "properties" => %{
          "field" => %{"type" => "string", "description" => "Field name to operate on"},
          "fields" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of field names"
          },
          "value" => %{"description" => "Value to use in the operation"},
          "operator" => %{
            "type" => "string",
            "enum" => ["eq", "neq", "gt", "gte", "lt", "lte", "contains"],
            "description" => "Comparison operator for filter"
          },
          "data" => %{"type" => "object", "description" => "Data to merge"},
          "mapping" => %{"type" => "object", "description" => "Field rename mapping"},
          "depth" => %{"type" => "integer", "minimum" => 1, "description" => "Flatten depth"}
        }
      }
    }
  }

  @input_schema %{
    "description" => "Data to transform (object, array, or primitive)"
  }

  @output_schema %{
    "description" => "Transformed data"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @supported_operations ~w(map filter pick omit merge set rename flatten passthrough)

  @impl true
  def execute(config, input, _context) do
    operation = Map.fetch!(config, "operation")
    options = Map.get(config, "options", %{})

    case execute_operation(operation, input, options) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "operation") do
        nil ->
          [{:operation, "is required"} | errors]

        op when op in @supported_operations ->
          errors

        op when is_binary(op) ->
          [{:operation, "must be one of: #{Enum.join(@supported_operations, ", ")}"} | errors]

        _ ->
          [{:operation, "must be a string"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  # ============================================================================
  # Operations
  # ============================================================================

  defp execute_operation("passthrough", input, _options) do
    {:ok, input}
  end

  defp execute_operation("map", input, options) when is_list(input) do
    field = Map.get(options, "field")

    result =
      if field do
        Enum.map(input, &get_nested(&1, field))
      else
        input
      end

    {:ok, result}
  end

  defp execute_operation("map", input, _options) do
    {:ok, input}
  end

  defp execute_operation("filter", input, options) when is_list(input) do
    field = Map.get(options, "field")
    operator = Map.get(options, "operator", "eq")
    value = Map.get(options, "value")

    result =
      Enum.filter(input, fn item ->
        item_value = get_nested(item, field)
        compare(item_value, operator, value)
      end)

    {:ok, result}
  end

  defp execute_operation("filter", input, _options) do
    {:ok, input}
  end

  defp execute_operation("pick", input, options) when is_map(input) do
    fields = Map.get(options, "fields", [])
    result = Map.take(input, fields)
    {:ok, result}
  end

  defp execute_operation("pick", input, _options) do
    {:ok, input}
  end

  defp execute_operation("omit", input, options) when is_map(input) do
    fields = Map.get(options, "fields", [])
    result = Map.drop(input, fields)
    {:ok, result}
  end

  defp execute_operation("omit", input, _options) do
    {:ok, input}
  end

  defp execute_operation("merge", input, options) when is_map(input) do
    data = Map.get(options, "data", %{})
    result = Map.merge(input, data)
    {:ok, result}
  end

  defp execute_operation("merge", input, _options) do
    {:ok, input}
  end

  defp execute_operation("set", input, options) when is_map(input) do
    field = Map.get(options, "field")
    value = Map.get(options, "value")

    if field do
      result = put_nested(input, field, value)
      {:ok, result}
    else
      {:ok, input}
    end
  end

  defp execute_operation("set", input, _options) do
    {:ok, input}
  end

  defp execute_operation("rename", input, options) when is_map(input) do
    mapping = Map.get(options, "mapping", %{})

    result =
      Enum.reduce(mapping, input, fn {old_key, new_key}, acc ->
        if Map.has_key?(acc, old_key) do
          {value, acc} = Map.pop(acc, old_key)
          Map.put(acc, new_key, value)
        else
          acc
        end
      end)

    {:ok, result}
  end

  defp execute_operation("rename", input, _options) do
    {:ok, input}
  end

  defp execute_operation("flatten", input, options) when is_list(input) do
    depth = Map.get(options, "depth", 1)
    result = do_flatten(input, depth)
    {:ok, result}
  end

  defp execute_operation("flatten", input, _options) do
    {:ok, input}
  end

  defp execute_operation(unknown, _input, _options) do
    {:error, {:unknown_operation, unknown}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_nested(map, path) when is_map(map) and is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(map, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, acc -> acc
    end)
  end

  defp get_nested(value, _path), do: value

  defp put_nested(map, path, value) when is_map(map) and is_binary(path) do
    keys = String.split(path, ".")
    do_put_nested(map, keys, value)
  end

  defp put_nested(map, _path, _value), do: map

  defp do_put_nested(map, [key], value), do: Map.put(map, key, value)

  defp do_put_nested(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, do_put_nested(nested, rest, value))
  end

  defp compare(left, "eq", right), do: left == right
  defp compare(left, "neq", right), do: left != right
  defp compare(left, "gt", right) when is_number(left) and is_number(right), do: left > right
  defp compare(left, "gte", right) when is_number(left) and is_number(right), do: left >= right
  defp compare(left, "lt", right) when is_number(left) and is_number(right), do: left < right
  defp compare(left, "lte", right) when is_number(left) and is_number(right), do: left <= right

  defp compare(left, "contains", right) when is_binary(left) and is_binary(right) do
    String.contains?(left, right)
  end

  defp compare(left, "contains", right) when is_list(left), do: right in left
  defp compare(_left, _operator, _right), do: false

  defp do_flatten(list, 0), do: list

  defp do_flatten(list, depth) when is_list(list) and depth > 0 do
    list
    |> Enum.flat_map(fn
      item when is_list(item) -> do_flatten(item, depth - 1)
      item -> [item]
    end)
  end
end
