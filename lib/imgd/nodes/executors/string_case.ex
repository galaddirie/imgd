defmodule Imgd.Nodes.Executors.StringCase do
  @moduledoc """
  Executor for String Case nodes.

  Converts the case of a string.

  ## Configuration

  - `operation` (required) - Case conversion operation:
    - `upper` - Convert to uppercase
    - `lower` - Convert to lowercase
    - `title` - Convert to title case
    - `camel` - Convert to camelCase
    - `snake` - Convert to snake_case
    - `kebab` - Convert to kebab-case
  - `input_field` (optional) - Field name containing the string to process (if input is a map)

  ## Input

  Accepts either:
  - A string: `"hello world"`
  - A map with a string field: `%{text: "hello world"}`

  ## Output

  The string with case conversion applied.
  """

  use Imgd.Nodes.Definition,
    id: "string_case",
    name: "Change Case",
    category: "Text",
    description: "Convert text case (upper, lower, title, etc.)",
    icon: "hero-bars-arrow-up",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "title" => "Case Operation",
        "enum" => ["upper", "lower", "title", "camel", "snake", "kebab"],
        "description" => "Type of case conversion to apply"
      },
      "input_field" => %{
        "type" => "string",
        "title" => "Input Field",
        "description" => "Field name containing the string to process"
      }
    }
  }

  @input_schema %{
    "description" => "String to convert, or map containing string field"
  }

  @output_schema %{
    "type" => "string",
    "description" => "String with case conversion applied"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @supported_operations ~w(upper lower title camel snake kebab)

  @impl true
  def execute(config, input, _context) do
    operation = Map.fetch!(config, "operation")
    input_field = Map.get(config, "input_field")

    text = extract_text(input, input_field)

    result = apply_case_operation(text, operation)
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    case Map.get(config, "operation") do
      nil ->
        {:error, [operation: "is required"]}

      op when op in @supported_operations ->
        :ok

      op when is_binary(op) ->
        {:error, [operation: "must be one of: #{Enum.join(@supported_operations, ", ")}"]}

      _ ->
        {:error, [operation: "must be a string"]}
    end
  end

  # Apply case conversion operation
  defp apply_case_operation(text, "upper") do
    String.upcase(text)
  end

  defp apply_case_operation(text, "lower") do
    String.downcase(text)
  end

  defp apply_case_operation(text, "title") do
    text
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp apply_case_operation(text, "camel") do
    text
    |> String.split(~r/[\s_-]+/)
    |> Enum.map(&String.capitalize/1)
    |> case do
      [first | rest] -> String.downcase(first) <> Enum.join(rest, "")
      [] -> ""
    end
  end

  defp apply_case_operation(text, "snake") do
    text
    |> String.replace(~r/([A-Z])/, "_\\1")
    |> String.replace(~r/[\s-]+/, "_")
    |> String.downcase()
    |> String.replace(~r/^_+|_+$/, "")
    |> String.replace(~r/__+/, "_")
  end

  defp apply_case_operation(text, "kebab") do
    text
    |> String.replace(~r/([A-Z])/, "-\\1")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.downcase()
    |> String.replace(~r/^-+|-+$/, "")
    |> String.replace(~r/--+/, "-")
  end

  # Extract text from input
  defp extract_text(input, nil) when is_binary(input) do
    input
  end

  defp extract_text(input, field) when is_map(input) and is_binary(field) do
    case Map.get(input, field) do
      value when is_binary(value) -> value
      nil -> ""
      value -> to_string(value)
    end
  end

  defp extract_text(input, _field) do
    # Fallback: convert input to string
    to_string(input)
  end
end
