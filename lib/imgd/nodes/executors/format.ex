defmodule Imgd.Nodes.Executors.Format do
  @moduledoc """
  Executor for Format nodes.

  Formats a string using a template and values from the input.

  ## Configuration

  - `template` (required) - The template string. Use {{key}} for placeholders.
    Example: "Hello {{user.name}}, your order {{order_id}} is ready."
  """

  use Imgd.Nodes.Definition,
    id: "format",
    name: "Format String",
    category: "Data",
    description: "Format a string using a template with placeholders",
    icon: "hero-document-text",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["template"],
    "properties" => %{
      "template" => %{
        "type" => "string",
        "title" => "Template",
        "description" =>
          "Template string with {{field}} placeholders. Supports nested paths like {{user.name}}"
      }
    }
  }

  @input_schema %{
    "type" => "object",
    "description" => "Data to use for placeholder replacement"
  }

  @output_schema %{
    "type" => "string",
    "description" => "The formatted string"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(config, input, _execution) do
    template = Map.fetch!(config, "template")

    # We treat the input as the data source.
    # If input is not a map, we can only replace if there's a special placeholder or if we fail gracefully.
    # Let's assume input is a map for now.

    result = render_template(template, input)
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    if Map.get(config, "template") do
      :ok
    else
      {:error, [template: "is required"]}
    end
  end

  defp render_template(template, data) when is_map(data) do
    Regex.replace(~r/\{\{([\w\.]+)\}\}/, template, fn _, key ->
      case get_nested(data, key) do
        nil -> ""
        val -> to_string(val)
      end
    end)
  end

  defp render_template(template, _data), do: template

  defp get_nested(map, path) do
    path
    |> String.split(".")
    |> Enum.reduce(map, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end
end
