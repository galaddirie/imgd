defmodule Imgd.Nodes.Executors.StringReplace do
  @moduledoc """
  Executor for String Replace nodes.

  Replaces occurrences of a substring with another string.

  ## Configuration

  - `pattern` (required) - The substring to replace
  - `replacement` (required) - The string to replace it with
  - `global` (optional) - Whether to replace all occurrences. Defaults to true.
  - `text` (required) - The text to process. Supports expressions like `{{ json }}`.

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
    "required" => ["text", "pattern", "replacement"],
    "properties" => %{
      "text" => %{
        "title" => "Text",
        "description" => "Text to process (supports expressions)"
      },
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
      }
    }
  }

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "string",
    "description" => "String with replacements applied"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(config, _input, _execution) do
    text = config |> Map.fetch!("text") |> to_string_safe()
    pattern = config |> Map.fetch!("pattern") |> to_string_safe()
    replacement = config |> Map.fetch!("replacement") |> to_string_safe()
    global = Map.get(config, "global", true)

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
      if Map.get(config, "text") do
        errors
      else
        [{:text, "is required"} | errors]
      end

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

  defp to_string_safe(nil), do: ""
  defp to_string_safe(text) when is_binary(text), do: text
  defp to_string_safe(text) when is_number(text), do: to_string(text)
  defp to_string_safe(%{"value" => value}), do: to_string_safe(value)
  defp to_string_safe(other), do: inspect(other)
end
