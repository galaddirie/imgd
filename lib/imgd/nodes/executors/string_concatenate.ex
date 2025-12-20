defmodule Imgd.Nodes.Executors.StringConcatenate do
  @moduledoc """
  Executor for String Concatenate nodes.

  Concatenates multiple strings together with an optional separator.

  ## Configuration

  - `separator` (optional) - String to join the parts with. Defaults to empty string.
  - `parts` (required) - List of parts to concatenate. Supports expressions like `{{ json.name_parts }}`.

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
    "required" => ["parts"],
    "properties" => %{
      "parts" => %{
        "title" => "Parts",
        "description" => "List of parts to concatenate (supports expressions)"
      },
      "separator" => %{
        "type" => "string",
        "title" => "Separator",
        "description" => "String to insert between concatenated parts",
        "default" => ""
      }
    }
  }

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "string",
    "description" => "The concatenated string"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(config, _input, _execution) do
    separator = Map.get(config, "separator", "")
    parts = Map.get(config, "parts")
    strings = extract_strings(parts)

    result = Enum.join(strings, to_string_safe(separator))
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    if Map.get(config, "parts") do
      :ok
    else
      {:error, [parts: "is required"]}
    end
  end

  defp extract_strings(parts) when is_list(parts) do
    Enum.map(parts, &to_string_safe/1)
  end

  defp extract_strings(parts) when is_map(parts) do
    parts
    |> Map.values()
    |> Enum.map(&to_string_safe/1)
  end

  defp extract_strings(nil), do: []
  defp extract_strings(parts), do: [to_string_safe(parts)]

  defp to_string_safe(nil), do: ""
  defp to_string_safe(text) when is_binary(text), do: text
  defp to_string_safe(text) when is_number(text), do: to_string(text)
  defp to_string_safe(%{"value" => value}), do: to_string_safe(value)
  defp to_string_safe(other), do: inspect(other)
end
