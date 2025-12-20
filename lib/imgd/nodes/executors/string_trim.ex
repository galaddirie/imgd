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
  - `text` (required) - The text to trim. Supports expressions like `{{ json }}`.

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
    "required" => ["text"],
    "properties" => %{
      "text" => %{
        "title" => "Text",
        "description" => "Text to trim (supports expressions)"
      },
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
      }
    }
  }

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "string",
    "description" => "Trimmed string"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @supported_sides ~w(both leading trailing)

  @impl true
  def execute(config, _input, _execution) do
    text = config |> Map.fetch!("text") |> to_string_safe()
    characters = Map.get(config, "characters")
    side = Map.get(config, "side", "both")

    characters =
      if is_nil(characters) do
        nil
      else
        to_string_safe(characters)
      end

    result = apply_trim(text, side, characters)
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
      case Map.get(config, "side") do
        nil ->
          errors

        side when side in @supported_sides ->
          errors

        side when is_binary(side) ->
          [{:side, "must be one of: #{Enum.join(@supported_sides, ", ")}"} | errors]

        _ ->
          [{:side, "must be a string"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
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

  defp to_string_safe(nil), do: ""
  defp to_string_safe(text) when is_binary(text), do: text
  defp to_string_safe(text) when is_number(text), do: to_string(text)
  defp to_string_safe(%{"value" => value}), do: to_string_safe(value)
  defp to_string_safe(other), do: inspect(other)
end
