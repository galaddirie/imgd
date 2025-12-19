defmodule Imgd.Nodes.Executors.StringConcatenate do
  @moduledoc """
  Executor for String Concatenate nodes.

  Concatenates multiple strings together with an optional separator.

  ## Configuration

  - `separator` (optional) - String to join the parts with. Defaults to empty string.
  - `input_field` (optional) - If input is a map, the field containing the list/array of strings to concatenate. If not specified, concatenates all string values from the input map.

  ## Input

  Accepts either:
  - A list of strings: `["Hello", " ", "World"]`
  - A map with string values: `%{first: "Hello", second: "World", separator: " "}`

  ## Output

  A single concatenated string.
  """

  use Imgd.Nodes.Definition,
    id: "string_concatenate",
    name: "Concatenate Strings",
    category: "Text",
    description: "Join multiple strings together with an optional separator",
    icon: "hero-link",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "separator" => %{
        "type" => "string",
        "title" => "Separator",
        "description" => "String to insert between concatenated parts",
        "default" => ""
      },
      "input_field" => %{
        "type" => "string",
        "title" => "Input Field",
        "description" =>
          "Field name containing the list of strings (leave empty to concatenate all string values from input map)"
      }
    }
  }

  @input_schema %{
    "description" => "List of strings to concatenate, or map containing string values"
  }

  @output_schema %{
    "type" => "string",
    "description" => "The concatenated string"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(config, input, _execution) do
    separator = Map.get(config, "separator", "")
    input_field = Map.get(config, "input_field")

    strings = extract_strings(input, input_field)

    result = Enum.join(strings, separator)
    {:ok, result}
  end

  @impl true
  def validate_config(_config) do
    # Config is always valid since all fields are optional
    :ok
  end

  # Extract strings from input based on configuration
  defp extract_strings(input, nil) when is_list(input) do
    # Input is a list, use all string elements
    Enum.map(input, &to_string/1)
  end

  defp extract_strings(input, nil) when is_map(input) do
    # Input is a map, concatenate all string values
    input
    |> Map.values()
    |> Enum.filter(&is_binary/1)
  end

  defp extract_strings(input, field) when is_map(input) and is_binary(field) do
    # Input is a map, get the specific field
    case Map.get(input, field) do
      list when is_list(list) ->
        Enum.map(list, &to_string/1)

      value when is_binary(value) ->
        [value]

      nil ->
        []

      value ->
        [to_string(value)]
    end
  end

  defp extract_strings(input, _field) do
    # Fallback: try to convert input to string
    [to_string(input)]
  end
end
