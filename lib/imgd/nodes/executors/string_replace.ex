defmodule Imgd.Nodes.Executors.StringReplace do
  @moduledoc """
  Executor for String Replace nodes.

  Replaces occurrences of a substring with another string.

  ## Configuration

  - `pattern` (required) - The substring to replace
  - `replacement` (required) - The string to replace it with
  - `global` (optional) - Whether to replace all occurrences. Defaults to true.
  - `input_field` (optional) - Field name containing the string to process (if input is a map)

  ## Input

  Accepts either:
  - A string: `"Hello World"`
  - A map with a string field: `%{text: "Hello World"}`

  ## Output

  The string with replacements applied.
  """

  use Imgd.Nodes.Definition,
    id: "string_replace",
    name: "Replace Text",
    category: "Text",
    description: "Replace substrings in text with new content",
    icon: "hero-arrow-path",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["pattern", "replacement"],
    "properties" => %{
      "pattern" => %{
        "type" => "string",
        "title" => "Pattern",
        "description" => "Substring to find and replace"
      },
      "replacement" => %{
        "type" => "string",
        "title" => "Replacement",
        "description" => "String to replace the pattern with"
      },
      "global" => %{
        "type" => "boolean",
        "title" => "Replace All",
        "description" => "Replace all occurrences (true) or just the first (false)",
        "default" => true
      },
      "input_field" => %{
        "type" => "string",
        "title" => "Input Field",
        "description" => "Field name containing the string to process"
      }
    }
  }

  @input_schema %{
    "description" => "String to process, or map containing string field"
  }

  @output_schema %{
    "type" => "string",
    "description" => "String with replacements applied"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(config, input, _context) do
    pattern = Map.fetch!(config, "pattern")
    replacement = Map.fetch!(config, "replacement")
    global = Map.get(config, "global", true)
    input_field = Map.get(config, "input_field")

    text = extract_text(input, input_field)

    result =
      if global do
        String.replace(text, pattern, replacement)
      else
        String.replace(text, pattern, replacement, global: false)
      end

    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      if Map.get(config, "pattern") do
        errors
      else
        [{:pattern, "is required"} | errors]
      end

    errors =
      if Map.get(config, "replacement") do
        errors
      else
        [{:replacement, "is required"} | errors]
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
