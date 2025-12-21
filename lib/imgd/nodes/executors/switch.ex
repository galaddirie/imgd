defmodule Imgd.Nodes.Executors.Switch do
  @moduledoc """
  Executor for Switch (multi-way branch) nodes.

  Routes execution to one of multiple outputs based on matching a value.
  Similar to a switch/case statement in programming.

  ## Configuration

  - `value` (required) - Expression to evaluate and match against cases
  - `cases` (required) - List of match conditions and their output routes
  - `default_output` (optional) - Output route if no cases match (default: "default")
  - `mode` (optional) - Matching mode: "equals", "contains", "regex" (default: "equals")

  ## Example

      %{
        "value" => "{{ json.type }}",
        "cases" => [
          %{"match" => "error", "output" => "error"},
          %{"match" => "warning", "output" => "warning"},
          %{"match" => "info", "output" => "info"}
        ],
        "default_output" => "other"
      }

  ## Outputs

  Dynamic based on configuration - each case's "output" value becomes an output port,
  plus the default_output.
  """

  use Imgd.Nodes.Definition,
    id: "switch",
    name: "Switch",
    category: "Control Flow",
    description: "Route to multiple paths based on value matching",
    icon: "hero-queue-list",
    kind: :control_flow

  @config_schema %{
    "type" => "object",
    "required" => ["value", "cases"],
    "properties" => %{
      "value" => %{
        "type" => "string",
        "title" => "Value to Match",
        "description" => "Expression to evaluate. Example: {{ json.status }}"
      },
      "cases" => %{
        "type" => "array",
        "title" => "Cases",
        "items" => %{
          "type" => "object",
          "required" => ["match", "output"],
          "properties" => %{
            "match" => %{
              "type" => "string",
              "title" => "Match Value",
              "description" => "Value to match against"
            },
            "output" => %{
              "type" => "string",
              "title" => "Output Route",
              "description" => "Name of output port if matched"
            }
          }
        }
      },
      "default_output" => %{
        "type" => "string",
        "title" => "Default Output",
        "default" => "default",
        "description" => "Output route if no cases match"
      },
      "mode" => %{
        "type" => "string",
        "title" => "Match Mode",
        "enum" => ["equals", "contains", "regex", "expression"],
        "default" => "equals"
      }
    }
  }

  @input_schema %{
    "type" => "object"
  }

  @output_schema %{
    "type" => "object",
    "description" => "Input data with route set to matching case output",
    "x-outputs" => "dynamic"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  alias Imgd.Runtime.Token

  @impl true
  def execute(config, input, _execution) do
    value_expr = Map.fetch!(config, "value")
    cases = Map.fetch!(config, "cases")
    default_output = Map.get(config, "default_output", "default")
    mode = Map.get(config, "mode", "equals")

    context = %{"json" => input}

    with {:ok, value} <- evaluate_value(value_expr, context) do
      output_route = find_matching_case(value, cases, mode, context) || default_output
      {:ok, Token.new(input, route: output_route)}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "value") do
        nil -> [{:value, "is required"} | errors]
        v when is_binary(v) -> errors
        _ -> [{:value, "must be a string expression"} | errors]
      end

    errors =
      case Map.get(config, "cases") do
        nil ->
          [{:cases, "is required"} | errors]

        cases when is_list(cases) ->
          if Enum.all?(cases, &valid_case?/1) do
            errors
          else
            [{:cases, "each case must have 'match' and 'output' fields"} | errors]
          end

        _ ->
          [{:cases, "must be a list"} | errors]
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp valid_case?(case_item) when is_map(case_item) do
    Map.has_key?(case_item, "match") and Map.has_key?(case_item, "output")
  end

  defp valid_case?(_), do: false

  defp evaluate_value(expression, context) do
    template =
      if String.contains?(expression, "{{") do
        expression
      else
        "{{ #{expression} }}"
      end

    case Imgd.Runtime.Core.Expression.evaluate_with_vars(template, context) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, reason} -> {:error, {:value_evaluation_failed, reason}}
    end
  end

  defp find_matching_case(value, cases, mode, context) do
    Enum.find_value(cases, fn case_item ->
      match_value = Map.get(case_item, "match")
      output = Map.get(case_item, "output")

      if matches?(value, match_value, mode, context) do
        output
      end
    end)
  end

  defp matches?(value, match, "equals", _context) do
    to_string(value) == to_string(match)
  end

  defp matches?(value, match, "contains", _context) do
    String.contains?(to_string(value), to_string(match))
  end

  defp matches?(value, pattern, "regex", _context) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, to_string(value))
      _ -> false
    end
  end

  defp matches?(value, expression, "expression", context) do
    # Expression mode: match is a Liquid expression that should evaluate to true/false
    ctx = Map.put(context, "value", value)
    template = "{{ #{expression} }}"

    case Imgd.Runtime.Core.Expression.evaluate_with_vars(template, ctx) do
      {:ok, result} -> truthy?(result)
      _ -> false
    end
  end

  defp truthy?("true"), do: true
  defp truthy?("false"), do: false
  defp truthy?(""), do: false
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true
end
