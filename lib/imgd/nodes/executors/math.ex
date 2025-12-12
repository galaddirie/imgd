defmodule Imgd.Nodes.Executors.Math do
  @moduledoc """
  Executor for Math nodes.

  Performs basic arithmetic operations on the input.

  ## Configuration

  - `operation` (required) - One of: add, subtract, multiply, divide
  - `operand` (required) - The number to operate with (right-hand side)
  - `field` (optional) - If input is a map, the field to use as the left-hand value.
                         If not provided, the entire input is treated as the number.
  """

  use Imgd.Nodes.Definition,
    id: "math",
    name: "Math",
    category: "Data",
    description: "Perform arithmetic operations on numeric data",
    icon: "hero-calculator",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["operation", "operand"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "title" => "Operation",
        "enum" => ["add", "subtract", "multiply", "divide"],
        "description" => "The arithmetic operation to perform"
      },
      "operand" => %{
        "type" => "number",
        "title" => "Operand",
        "description" => "The right-hand value for the operation"
      },
      "field" => %{
        "type" => "string",
        "title" => "Input Field",
        "description" => "If input is an object, the field to use as the left-hand value"
      }
    }
  }

  @input_schema %{
    "description" => "A number or object containing a numeric field"
  }

  @output_schema %{
    "type" => "number",
    "description" => "The result of the arithmetic operation"
  }

  @behaviour Imgd.Runtime.NodeExecutor

  @supported_operations ~w(add subtract multiply divide)

  @impl true
  def execute(config, input, _context) do
    operation = Map.fetch!(config, "operation")
    operand = Map.get(config, "operand")

    # Extract value from input if needed
    value =
      if is_map(input) and Map.get(config, "field") do
        get_nested(input, config["field"])
      else
        input
      end

    with {:ok, number} <- validate_number(value),
         {:ok, operand_num} <- validate_number(operand),
         {:ok, result} <- calculate(operation, number, operand_num) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "operation") do
        nil -> [{:operation, "is required"} | errors]
        op when op in @supported_operations -> errors
        _ -> [{:operation, "must be one of: #{Enum.join(@supported_operations, ", ")}"} | errors]
      end

    errors =
      case Map.get(config, "operand") do
        nil ->
          [{:operand, "is required"} | errors]

        val when is_number(val) ->
          errors

        val when is_binary(val) ->
          case Float.parse(val) do
            {_, ""} -> errors
            _ -> [{:operand, "must be a number"} | errors]
          end

        _ ->
          [{:operand, "must be a number"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp calculate("add", a, b), do: {:ok, a + b}
  defp calculate("subtract", a, b), do: {:ok, a - b}
  defp calculate("multiply", a, b), do: {:ok, a * b}
  defp calculate("divide", _a, 0), do: {:error, "division by zero"}
  defp calculate("divide", a, b), do: {:ok, a / b}

  defp validate_number(n) when is_number(n), do: {:ok, n}

  defp validate_number(n) when is_binary(n) do
    case Float.parse(n) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "invalid number: #{inspect(n)}"}
    end
  end

  defp validate_number(other), do: {:error, "expected a number, got: #{inspect(other)}"}

  defp get_nested(map, path) do
    path
    |> String.split(".")
    |> Enum.reduce(map, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end
end
