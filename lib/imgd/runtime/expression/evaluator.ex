defmodule Imgd.Runtime.Expression.Evaluator do
  @moduledoc """
  High-level expression evaluation for node configurations.

  This module provides the integration point between node execution and
  expression evaluation. It handles resolving expressions in node configs
  before execution.

  ## Usage in Node Executors

      def execute(config, input, execution, state_store) do
        # Resolve all expressions in config
        {:ok, resolved_config} = Evaluator.resolve_config(config, execution, state_store)

        # Now use resolved_config with actual values
        url = resolved_config["url"]
        # ...
      end

  ## Expression Syntax in Configs

  Node configs can contain Liquid expressions anywhere:

      %{
        "url" => "https://api.example.com/users/{{ json.user_id }}",
        "headers" => %{
          "Authorization" => "Bearer {{ variables.api_token }}",
          "X-Request-ID" => "{{ execution.id }}"
        },
        "body" => %{
          "name" => "{{ json.name | upcase }}",
          "items" => "{{ nodes.Transform.json.items | json }}"
        }
      }
  """

  alias Imgd.Runtime.Expression
  alias Imgd.Runtime.ExecutionState
  alias Imgd.Executions.Execution

  require Logger

  @doc """
  Resolves all expressions in a node configuration.

  Walks through the config map/list and evaluates any string values
  containing Liquid expressions.

  Returns `{:ok, resolved_config}` or `{:error, reason}`.
  """
  @spec resolve_config(map(), Execution.t(), module()) :: {:ok, map()} | {:error, term()}
  def resolve_config(config, %Execution{} = execution, state_store \\ ExecutionState)
      when is_map(config) do
    Expression.evaluate_deep(config, execution, state_store: state_store)
  end

  @doc """
  Resolves a single expression string.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec resolve(String.t(), Execution.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def resolve(template, %Execution{} = execution, state_store \\ ExecutionState)
      when is_binary(template) do
    Expression.evaluate(template, execution, state_store: state_store)
  end

  @doc """
  Resolves an expression, returning the result or the original on error.

  Useful when you want to fail gracefully.
  """
  @spec resolve_or_original(String.t(), Execution.t(), module()) :: String.t()
  def resolve_or_original(template, %Execution{} = execution, state_store \\ ExecutionState)
      when is_binary(template) do
    case Expression.evaluate(template, execution, state_store: state_store) do
      {:ok, result} -> result
      {:error, _} -> template
    end
  end

  @doc """
  Resolves and attempts to parse the result as JSON.

  Useful for expressions that should return structured data.

  ## Examples

      # Config: "{{ nodes.API.json.data | json }}"
      {:ok, %{"key" => "value"}} = resolve_json(template, execution)
  """
  @spec resolve_json(String.t(), Execution.t(), module()) :: {:ok, term()} | {:error, term()}
  def resolve_json(template, %Execution{} = execution, state_store \\ ExecutionState)
      when is_binary(template) do
    with {:ok, result} <- Expression.evaluate(template, execution, state_store: state_store) do
      case Jason.decode(result) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> {:ok, result}
      end
    end
  end

  @doc """
  Validates that all expressions in a config are syntactically valid.

  Returns `:ok` if all valid, or `{:error, errors}` with list of invalid expressions.
  """
  @spec validate_config(map()) :: :ok | {:error, [{String.t(), term()}]}
  def validate_config(config) when is_map(config) do
    errors = collect_validation_errors(config, [])

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp collect_validation_errors(config, errors) when is_map(config) do
    Enum.reduce(config, errors, fn {_key, value}, acc ->
      collect_validation_errors(value, acc)
    end)
  end

  defp collect_validation_errors(config, errors) when is_list(config) do
    Enum.reduce(config, errors, fn value, acc ->
      collect_validation_errors(value, acc)
    end)
  end

  defp collect_validation_errors(config, errors) when is_binary(config) do
    if Expression.contains_expression?(config) do
      case Expression.validate(config) do
        :ok -> errors
        {:error, reason} -> [{config, reason} | errors]
      end
    else
      errors
    end
  end

  defp collect_validation_errors(_config, errors), do: errors

  @doc """
  Extracts all expression strings from a config for analysis or caching.
  """
  @spec extract_expressions(map()) :: [String.t()]
  def extract_expressions(config) when is_map(config) do
    collect_expressions(config, [])
    |> Enum.uniq()
  end

  defp collect_expressions(config, acc) when is_map(config) do
    Enum.reduce(config, acc, fn {_key, value}, inner_acc ->
      collect_expressions(value, inner_acc)
    end)
  end

  defp collect_expressions(config, acc) when is_list(config) do
    Enum.reduce(config, acc, fn value, inner_acc ->
      collect_expressions(value, inner_acc)
    end)
  end

  defp collect_expressions(config, acc) when is_binary(config) do
    if Expression.contains_expression?(config) do
      [config | acc]
    else
      acc
    end
  end

  defp collect_expressions(_config, acc), do: acc

  @doc """
  Pre-compiles all expressions in a config for performance.

  Call this during workflow publishing to validate and cache expressions.
  """
  @spec precompile_config(map()) :: :ok | {:error, [{String.t(), term()}]}
  def precompile_config(config) when is_map(config) do
    expressions = extract_expressions(config)

    errors =
      Enum.reduce(expressions, [], fn expr, acc ->
        case Expression.compile(expr) do
          {:ok, _compiled} -> acc
          {:error, reason} -> [{expr, reason} | acc]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end
end
