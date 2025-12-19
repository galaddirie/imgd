defmodule Imgd.Runtime.Expression.Context do
  @moduledoc """
  Builds the variable context for expression evaluation.

  Transforms an `Imgd.Executions.Execution` struct combined with runtime
  state from `ExecutionState` into a flat map suitable for Liquid template rendering.

  This module builds the context **on-demand** from the single source of truth:
  - Static data from `Execution` (trigger, metadata, workflow info)
  - Dynamic data from `ExecutionState` (node outputs, current input)

  ## Variable Structure

  ```
  %{
    "json" => current_input,
    "nodes" => %{
      "NodeName" => %{"json" => output_data, ...},
      ...
    },
    "execution" => %{
      "id" => "uuid",
      "started_at" => datetime,
      ...
    },
    "workflow" => %{
      "id" => "uuid",
      "version_id" => "uuid"
    },
    "variables" => %{...workflow variables...},
    "metadata" => %{...execution metadata...},
    "env" => %{...allowed env vars...}
  }
  ```
  """

  alias Imgd.Executions.Execution

  # Environment variables that are safe to expose
  # Configure via application env: config :imgd, :allowed_env_vars, [...]
  @default_allowed_env_vars ~w(
    MIX_ENV
    NODE_ENV
    APP_ENV
  )

  @doc """
  Builds a variable map from an execution and runtime state.

  The resulting map uses string keys for compatibility with Liquid.

  ## Parameters

  - `execution` - The Execution struct (should have workflow_version preloaded for variables)
  - `node_outputs` - Map of node_id -> output data
  - `current_input` - The input data for the current node (optional)
  """
  @spec build(Execution.t(), term(), term()) :: map()
  def build(%Execution{} = execution, node_outputs \\ %{}, current_input \\ nil) do
    # Merge persisted context with runtime data
    execution_context = execution.context || %{}
    node_outputs_map = if is_map(node_outputs), do: node_outputs, else: %{}
    all_outputs = Map.merge(execution_context, node_outputs_map)
    current_input = current_input || Execution.trigger_data(execution)

    %{
      "json" => normalize_value(current_input),
      "input" => normalize_value(current_input),
      "nodes" => build_nodes_map(all_outputs),
      "execution" => build_execution_map(execution),
      "workflow" => build_workflow_map(execution),
      "variables" => extract_variables(execution),
      "metadata" => build_metadata_map(execution),
      "env" => build_env_map(),
      "now" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "today" => Date.utc_today() |> Date.to_iso8601()
    }
  end

  @doc """
  Builds a minimal context for testing or simple evaluations.
  """
  @spec build_minimal(map()) :: map()
  def build_minimal(input \\ %{}) do
    %{
      "json" => normalize_value(input),
      "input" => normalize_value(input),
      "nodes" => %{},
      "execution" => %{},
      "workflow" => %{},
      "variables" => %{},
      "metadata" => %{},
      "env" => build_env_map(),
      "now" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "today" => Date.utc_today() |> Date.to_iso8601()
    }
  end

  # ============================================================================
  # Private Builders
  # ============================================================================

  defp build_nodes_map(node_outputs) when is_map(node_outputs) do
    Map.new(node_outputs, fn {node_id, output} ->
      node_data = %{
        "json" => normalize_value(output),
        "data" => normalize_value(output)
      }

      # Also extract common fields for convenience
      node_data =
        if is_map(output) do
          node_data
          |> maybe_put("status", output["status"] || output[:status])
          |> maybe_put("body", output["body"] || output[:body])
          |> maybe_put("headers", output["headers"] || output[:headers])
          |> maybe_put("error", output["error"] || output[:error])
        else
          node_data
        end

      {node_id, node_data}
    end)
  end

  defp build_nodes_map(_), do: %{}

  defp build_execution_map(%Execution{} = execution) do
    trigger_type = Execution.trigger_type(execution)
    trigger_data = Execution.trigger_data(execution)
    metadata = execution.metadata || %{}

    %{
      "id" => execution.id,
      "trigger_type" => to_string(trigger_type || "unknown"),
      "trigger_data" => normalize_value(trigger_data)
    }
    |> maybe_put("started_at", execution.started_at)
    |> maybe_put("trace_id", get_metadata_field(metadata, :trace_id))
    |> maybe_put("correlation_id", get_metadata_field(metadata, :correlation_id))
  end

  defp build_workflow_map(%Execution{} = execution) do
    %{
      "id" => execution.workflow_id,
      "version_id" => execution.workflow_version_id
    }
  end

  defp build_metadata_map(%Execution{metadata: metadata}) when is_struct(metadata) do
    metadata
    |> Map.from_struct()
    |> normalize_map()
  end

  defp build_metadata_map(%Execution{metadata: metadata}) when is_map(metadata) do
    normalize_map(metadata)
  end

  defp build_metadata_map(_), do: %{}

  defp build_env_map do
    allowed_vars()
    |> Enum.reduce(%{}, fn var, acc ->
      case System.get_env(var) do
        nil -> acc
        value -> Map.put(acc, var, value)
      end
    end)
  end

  defp allowed_vars do
    Application.get_env(:imgd, :allowed_env_vars, @default_allowed_env_vars)
  end

  defp extract_variables(%Execution{} = execution) do
    case execution.workflow_version do
      %{settings: settings} when is_map(settings) ->
        Map.get(settings, "variables") || Map.get(settings, :variables) || %{}

      _ ->
        %{}
    end
  end

  defp get_metadata_field(%{} = metadata, key) when is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp get_metadata_field(_, _), do: nil

  # ============================================================================
  # Value Normalization
  # ============================================================================

  @doc """
  Normalizes a value for use in Liquid templates.

  - Converts structs to maps
  - Ensures string keys
  - Handles DateTime/Date conversion
  - Preserves primitives
  """
  @spec normalize_value(term()) :: term()
  def normalize_value(value) when is_struct(value, DateTime) do
    DateTime.to_iso8601(value)
  end

  def normalize_value(value) when is_struct(value, NaiveDateTime) do
    NaiveDateTime.to_iso8601(value)
  end

  def normalize_value(value) when is_struct(value, Date) do
    Date.to_iso8601(value)
  end

  def normalize_value(value) when is_struct(value, Time) do
    Time.to_iso8601(value)
  end

  def normalize_value(%{__struct__: _} = value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> normalize_map()
  end

  def normalize_value(value) when is_map(value) do
    normalize_map(value)
  end

  def normalize_value(value) when is_list(value) do
    Enum.map(value, &normalize_value/1)
  end

  def normalize_value(value)
      when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  def normalize_value(value), do: value

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      {key, normalize_value(v)}
    end)
  end

  defp normalize_map(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, normalize_value(value))
end
