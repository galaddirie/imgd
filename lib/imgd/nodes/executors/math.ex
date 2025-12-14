defmodule Imgd.Nodes.Executors.Math do
  @moduledoc """
  Executor for Math nodes.

  Performs arithmetic and mathematical operations on the input.

  ## Configuration

  - `operation` (required) - One of: add, subtract, multiply, divide, modulo, power, square_root, abs, round, ceil, floor
  - `operand` (required for binary operations: add, subtract, multiply, divide, modulo, power) - The number to operate with (right-hand side)
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
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "title" => "Operation",
        "enum" => [
          "add",
          "subtract",
          "multiply",
          "divide",
          "modulo",
          "power",
          "square_root",
          "abs",
          "round",
          "ceil",
          "floor"
        ],
        "description" => "The mathematical operation to perform"
      },
      "operand" => %{
        "type" => "number",
        "title" => "Operand",
        "description" =>
          "The right-hand value for binary operations (not needed for unary operations like square_root, abs, etc.)"
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

  @supported_operations ~w(add subtract multiply divide modulo power square_root abs round ceil floor)

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

    unary_operations = ~w(square_root abs round ceil floor)

    if operation in unary_operations do
      # Unary operations only need the input value
      with {:ok, number} <- validate_number(value),
           {:ok, result} <- calculate(operation, number) do
        {:ok, result}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      # Binary operations need both input value and operand
      with {:ok, number} <- validate_number(value),
           {:ok, operand_num} <- validate_number(operand),
           {:ok, result} <- calculate(operation, number, operand_num) do
        {:ok, result}
      else
        {:error, reason} -> {:error, reason}
      end
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

    operation = Map.get(config, "operation")
    unary_operations = ~w(square_root abs round ceil floor)

    errors =
      if operation in unary_operations do
        # For unary operations, operand is not required
        errors
      else
        # For binary operations, operand is required
        case Map.get(config, "operand") do
          nil ->
            [{:operand, "is required for binary operations"} | errors]

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
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  # Binary operations
  defp calculate("add", a, b), do: {:ok, a + b}
  defp calculate("subtract", a, b), do: {:ok, a - b}
  defp calculate("multiply", a, b), do: {:ok, a * b}
  defp calculate("divide", _a, 0), do: {:error, "division by zero"}
  defp calculate("divide", a, b), do: {:ok, a / b}
  defp calculate("modulo", _a, b) when b == 0, do: {:error, "modulo by zero"}
  defp calculate("modulo", a, b), do: {:ok, rem(trunc(a), trunc(b))}
  defp calculate("power", a, b), do: {:ok, :math.pow(a, b)}

  # Unary operations
  defp calculate("square_root", a) when a < 0, do: {:error, "square root of negative number"}
  defp calculate("square_root", a), do: {:ok, :math.sqrt(a)}
  defp calculate("abs", a), do: {:ok, abs(a)}
  defp calculate("round", a), do: {:ok, round(a)}
  defp calculate("ceil", a), do: {:ok, Float.ceil(a)}
  defp calculate("floor", a), do: {:ok, Float.floor(a)}

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
