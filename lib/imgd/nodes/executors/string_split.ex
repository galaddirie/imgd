defmodule Imgd.Nodes.Executors.StringSplit do
  @moduledoc """
  Executor for String Split nodes.

  Splits a string into a list of substrings based on a delimiter.

  ## Configuration

  - `delimiter` (optional) - String to split on. Defaults to whitespace.
  - `limit` (optional) - Maximum number of parts to split into. If not specified, splits all occurrences.
  - `trim_parts` (optional) - Whether to trim whitespace from each part. Defaults to false.
  - `text` (required) - The text to split. Supports expressions like `{{ json }}`.

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
    "required" => ["text"],
    "properties" => %{
      "text" => %{
        "title" => "Text",
        "description" => "Text to split (supports expressions)"
      },
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
      }
    }
  }

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "array",
    "items" => %{"type" => "string"},
    "description" => "List of split string parts"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(config, _input, _execution) do
    text = config |> Map.fetch!("text") |> to_string_safe()
    delimiter = Map.get(config, "delimiter", "")
    limit = normalize_limit(Map.get(config, "limit"))
    trim_parts = Map.get(config, "trim_parts", false)

    delimiter = to_string_safe(delimiter)

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
        nil ->
          errors

        n when is_integer(n) and n > 0 ->
          errors

        n when is_binary(n) ->
          if expression_string?(n) do
            errors
          else
            [{:limit, "must be a positive integer, got: #{inspect(n)}"} | errors]
          end

        n ->
          [{:limit, "must be a positive integer, got: #{inspect(n)}"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp normalize_limit(nil), do: nil
  defp normalize_limit(limit) when is_integer(limit), do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_limit), do: nil

  defp expression_string?(value) when is_binary(value) do
    String.contains?(value, "{{") and String.contains?(value, "}}")
  end

  defp expression_string?(_value), do: false

  defp to_string_safe(nil), do: ""
  defp to_string_safe(text) when is_binary(text), do: text
  defp to_string_safe(text) when is_number(text), do: to_string(text)
  defp to_string_safe(%{"value" => value}), do: to_string_safe(value)
  defp to_string_safe(other), do: inspect(other)
end
