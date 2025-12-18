defmodule Imgd.Nodes.Executors.StringSplit do
  @moduledoc """
  Executor for String Split nodes.

  Splits a string into a list of substrings based on a delimiter.

  ## Configuration

  - `delimiter` (optional) - String to split on. Defaults to whitespace.
  - `limit` (optional) - Maximum number of parts to split into. If not specified, splits all occurrences.
  - `trim_parts` (optional) - Whether to trim whitespace from each part. Defaults to false.
  - `input_field` (optional) - Field name containing the string to split (if input is a map).

  ## Input

  Accepts either:
  - A string: `"hello world"`
  - A map with a string field: `%{text: "hello world"}`

  ## Output

  A list of strings resulting from the split operation.
  """

  use Imgd.Nodes.Definition,
    id: "string_split",
    name: "Split String",
    category: "Text",
    description: "Split a string into parts using a delimiter",
    icon: "hero-scissors",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "delimiter" => %{
        "type" => "string",
        "title" => "Delimiter",
        "description" => "String to split on (leave empty for whitespace)",
        "default" => ""
      },
      "limit" => %{
        "type" => "integer",
        "title" => "Limit",
        "description" => "Maximum number of parts to split into",
        "minimum" => 1
      },
      "trim_parts" => %{
        "type" => "boolean",
        "title" => "Trim Parts",
        "description" => "Remove whitespace from each split part",
        "default" => false
      },
      "input_field" => %{
        "type" => "string",
        "title" => "Input Field",
        "description" => "Field name containing the string to split"
      }
    }
  }

  @input_schema %{
    "description" => "String to split, or map containing string field"
  }

  @output_schema %{
    "type" => "array",
    "items" => %{"type" => "string"},
    "description" => "List of split string parts"
  }

  @behaviour Imgd.Runtime.NodeExecutor

  @impl true
  def execute(config, input, _context) do
    delimiter = Map.get(config, "delimiter", "")
    limit = Map.get(config, "limit")
    trim_parts = Map.get(config, "trim_parts", false)
    input_field = Map.get(config, "input_field")

    text = extract_text(input, input_field)

    # Handle empty delimiter (split on whitespace)
    parts =
      if delimiter == "" do
        String.split(text)
      else
        case limit do
          nil -> String.split(text, delimiter)
          n when is_integer(n) -> String.split(text, delimiter, parts: n)
        end
      end

    # Trim parts if requested
    parts =
      if trim_parts do
        Enum.map(parts, &String.trim/1)
      else
        parts
      end

    {:ok, parts}
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "limit") do
        nil -> errors
        n when is_integer(n) and n > 0 -> errors
        n -> [{:limit, "must be a positive integer, got: #{inspect(n)}"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
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
