defmodule Imgd.Runtime.Expression.Context do
  @moduledoc """
  Builds the variable context for expression evaluation.

  Transforms an `Imgd.Executions.Context` into a flat map suitable
  for Liquid template rendering.

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

  alias Imgd.Executions.Context, as: ExecContext

  # Environment variables that are safe to expose
  # Configure via application env: config :imgd, :allowed_env_vars, [...]
  @default_allowed_env_vars ~w(
    MIX_ENV
    NODE_ENV
    APP_ENV
  )

  @doc """
  Builds a variable map from an execution context.

  The resulting map uses string keys for compatibility with Liquid.
  """
  @spec build(ExecContext.t()) :: map()
  def build(%ExecContext{} = ctx) do
    %{
      "json" => normalize_value(ctx.current_input),
      "input" => normalize_value(ctx.current_input),
      "nodes" => build_nodes_map(ctx.node_outputs),
      "execution" => build_execution_map(ctx),
      "workflow" => build_workflow_map(ctx),
      "variables" => normalize_map(ctx.variables),
      "metadata" => build_metadata_map(ctx.metadata),
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

  defp build_execution_map(%ExecContext{} = ctx) do
    %{
      "id" => ctx.execution_id,
      "trigger_type" => to_string(ctx.trigger_type || "unknown"),
      "trigger_data" => normalize_value(ctx.trigger_data)
    }
    |> maybe_put("started_at", get_in(ctx.metadata, [:started_at]))
    |> maybe_put("trace_id", get_in(ctx.metadata, [:trace_id]))
    |> maybe_put("correlation_id", get_in(ctx.metadata, [:correlation_id]))
  end

  defp build_workflow_map(%ExecContext{} = ctx) do
    %{
      "id" => ctx.workflow_id,
      "version_id" => ctx.workflow_version_id
    }
  end

  defp build_metadata_map(metadata) when is_map(metadata) do
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
