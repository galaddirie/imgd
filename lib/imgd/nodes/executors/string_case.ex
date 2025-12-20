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
  - `text` (required) - The text to convert. Supports expressions like `{{ json }}`.

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
    "required" => ["operation", "text"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "title" => "Case Operation",
        "enum" => ["upper", "lower", "title", "camel", "snake", "kebab"],
        "description" => "Type of case conversion to apply"
      },
      "text" => %{
        "title" => "Text",
        "description" => "Text to convert (supports expressions)"
      }
    }
  }

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "string",
    "description" => "String with case conversion applied"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @supported_operations ~w(upper lower title camel snake kebab)

  @impl true
  def execute(config, _input, _execution) do
    operation = Map.fetch!(config, "operation")
    text = config |> Map.fetch!("text") |> to_string_safe()

    result = apply_case_operation(text, operation)
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "operation") do
        nil ->
          [{:operation, "is required"} | errors]

        op when op in @supported_operations ->
          errors

        op when is_binary(op) ->
          [{:operation, "must be one of: #{Enum.join(@supported_operations, ", ")}"} | errors]

        _ ->
          [{:operation, "must be a string"} | errors]
      end

    errors =
      if Map.get(config, "text") do
        errors
      else
        [{:text, "is required"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
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

  defp to_string_safe(nil), do: ""
  defp to_string_safe(text) when is_binary(text), do: text
  defp to_string_safe(text) when is_number(text), do: to_string(text)
  defp to_string_safe(%{"value" => value}), do: to_string_safe(value)
  defp to_string_safe(other), do: inspect(other)
end
