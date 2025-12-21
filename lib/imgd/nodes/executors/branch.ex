defmodule Imgd.Nodes.Executors.Branch do
  @moduledoc """
  Executor for Branch (If/Else) nodes.

  Evaluates a condition and routes execution to either the "true" or "false"
  output path. Only one path is active per execution.

  ## Configuration

  - `condition` (required) - Liquid expression that evaluates to boolean
  - `pass_data` (optional) - Whether to pass input data through (default: true)

  ## Outputs

  - `"true"` - Active when condition evaluates to truthy
  - `"false"` - Active when condition evaluates to falsy

  ## Example

      %{
        "condition" => "{{ json.status >= 400 }}"
      }

  ## Connecting Downstream Nodes

  When creating connections from a Branch node, use `source_output` to specify
  which branch the connection follows:

      # Error handler on true branch
      %Connection{
        source_node_id: "branch_1",
        source_output: "true",
        target_node_id: "error_handler"
      }

      # Success processing on false branch
      %Connection{
        source_node_id: "branch_1",
        source_output: "false",
        target_node_id: "process_response"
      }
  """

  use Imgd.Nodes.Definition,
    id: "branch",
    name: "Branch (If/Else)",
    category: "Control Flow",
    description: "Route execution based on a condition",
    icon: "hero-arrow-path-rounded-square",
    kind: :control_flow

  @config_schema %{
    "type" => "object",
    "required" => ["condition"],
    "properties" => %{
      "condition" => %{
        "type" => "string",
        "title" => "Condition",
        "description" =>
          "Expression that evaluates to true or false. Example: {{ json.count > 0 }}"
      },
      "pass_data" => %{
        "type" => "boolean",
        "title" => "Pass Data Through",
        "default" => true,
        "description" => "Whether to pass input data to the active branch"
      }
    }
  }

  @input_schema %{
    "type" => "object",
    "description" => "Any input data - used in condition evaluation"
  }

  @output_schema %{
    "type" => "object",
    "description" => "Input data passed through (if enabled) with route metadata",
    "x-outputs" => ["true", "false"]
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  alias Imgd.Runtime.Token

  @impl true
  def execute(config, input, _execution) do
    condition_expr = Map.fetch!(config, "condition")
    pass_data = Map.get(config, "pass_data", true)

    # Build context for expression evaluation
    context = %{"json" => input}

    case evaluate_condition(condition_expr, context) do
      {:ok, true} ->
        data = if pass_data, do: input, else: %{}
        {:ok, Token.new(data, route: "true")}

      {:ok, false} ->
        data = if pass_data, do: input, else: %{}
        {:ok, Token.new(data, route: "false")}

      {:error, reason} ->
        {:error, {:condition_evaluation_failed, reason}}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "condition") do
        nil -> [{:condition, "is required"} | errors]
        c when is_binary(c) -> errors
        _ -> [{:condition, "must be a string expression"} | errors]
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp evaluate_condition(expression, context) do
    template = build_condition_template(expression)

    case Imgd.Runtime.Core.Expression.evaluate_with_vars(template, context) do
      {:ok, result} -> {:ok, truthy?(String.trim(result))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp truthy?("true"), do: true
  defp truthy?("false"), do: false
  defp truthy?(""), do: false
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(0), do: false
  defp truthy?("0"), do: false
  defp truthy?(_), do: true

  defp build_condition_template(expression) do
    condition = unwrap_expression(expression)
    "{% if #{condition} %}true{% else %}false{% endif %}"
  end

  defp unwrap_expression(expression) do
    trimmed = String.trim(expression)

    case Regex.run(~r/^\{\{\s*(.*?)\s*\}\}\s*$/s, trimmed) do
      [_, inner] -> inner
      _ -> trimmed
    end
  end
end
