defmodule Imgd.Nodes.Executors.StringTrim do
  @moduledoc """
  Executor for String Trim nodes.

  Removes whitespace (or other characters) from the beginning and end of a string.

  ## Configuration

  - `characters` (optional) - Characters to trim. If not specified, trims whitespace.
  - `side` (optional) - Which side to trim:
    - `both` - Trim from both ends (default)
    - `leading` - Trim from the beginning only
    - `trailing` - Trim from the end only
  - `input_field` (optional) - Field name containing the string to trim (if input is a map)

  ## Input

  Accepts either:
  - A string: `"  hello world  "`
  - A map with a string field: `%{text: "  hello world  "}`

  ## Output

  The trimmed string.
  """

  use Imgd.Nodes.Definition,
    id: "string_trim",
    name: "Trim String",
    category: "Text",
    description: "Remove whitespace or characters from string ends",
    icon: "hero-minus-circle",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "characters" => %{
        "type" => "string",
        "title" => "Characters to Trim",
        "description" => "Characters to remove (leave empty for whitespace)"
      },
      "side" => %{
        "type" => "string",
        "title" => "Trim Side",
        "enum" => ["both", "leading", "trailing"],
        "description" => "Which side of the string to trim",
        "default" => "both"
      },
      "input_field" => %{
        "type" => "string",
        "title" => "Input Field",
        "description" => "Field name containing the string to trim"
      }
    }
  }

  @input_schema %{
    "description" => "String to trim, or map containing string field"
  }

  @output_schema %{
    "type" => "string",
    "description" => "Trimmed string"
  }

  @behaviour Imgd.Runtime.NodeExecutor

  @supported_sides ~w(both leading trailing)

  @impl true
  def execute(config, input, _context) do
    characters = Map.get(config, "characters")
    side = Map.get(config, "side", "both")
    input_field = Map.get(config, "input_field")

    text = extract_text(input, input_field)

    result = apply_trim(text, side, characters)
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    case Map.get(config, "side") do
      nil ->
        :ok

      side when side in @supported_sides ->
        :ok

      side when is_binary(side) ->
        {:error, [side: "must be one of: #{Enum.join(@supported_sides, ", ")}"]}

      _ ->
        {:error, [side: "must be a string"]}
    end
  end

  # Apply trim operation
  defp apply_trim(text, "both", nil) do
    String.trim(text)
  end

  defp apply_trim(text, "both", characters) when is_binary(characters) do
    String.trim(text, characters)
  end

  defp apply_trim(text, "leading", nil) do
    String.trim_leading(text)
  end

  defp apply_trim(text, "leading", characters) when is_binary(characters) do
    String.trim_leading(text, characters)
  end

  defp apply_trim(text, "trailing", nil) do
    String.trim_trailing(text)
  end

  defp apply_trim(text, "trailing", characters) when is_binary(characters) do
    String.trim_trailing(text, characters)
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
