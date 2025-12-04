defmodule Imgd.Engine.DataFlow.Envelope do
  @moduledoc """
  Lightweight wrapper around values flowing through the workflow engine.

  Captures metadata for lineage, traceability, and persistence without
  mutating the underlying values.
  """

  @type source :: :input | :step | :rule | :accumulator | :external | :unknown

  @type metadata :: %{
          required(:source) => source(),
          required(:timestamp) => DateTime.t(),
          required(:trace_id) => String.t(),
          optional(:step_hash) => integer(),
          optional(:step_name) => String.t(),
          optional(:fact_hash) => integer(),
          optional(:parent_hash) => integer()
        }

  @type t :: %__MODULE__{
          value: any(),
          metadata: metadata()
        }

  @derive {Jason.Encoder, only: [:value, :metadata]}
  defstruct [:value, :metadata]

  @doc """
  Creates a new envelope wrapping the given value.
  """
  @spec new(any(), source(), String.t(), map()) :: t()
  def new(value, source, trace_id, extra_metadata \\ %{}) do
    metadata =
      %{
        source: source,
        timestamp: DateTime.utc_now(),
        trace_id: trace_id
      }
      |> Map.merge(extra_metadata)

    %__MODULE__{value: value, metadata: metadata}
  end

  @doc """
  Builds an envelope from a Runic fact (or fact-shaped map), preserving lineage.
  """
  @spec from_fact(any(), source(), String.t(), map()) :: t()
  def from_fact(fact, source, trace_id, extra_metadata \\ %{})

  def from_fact(nil, source, trace_id, extra_metadata),
    do: new(nil, source, trace_id, extra_metadata)

  def from_fact(%Runic.Workflow.Fact{} = fact, source, trace_id, extra_metadata) do
    parent_hash =
      case fact.ancestry do
        {parent, _step} -> parent
        _ -> nil
      end

    new(fact.value, source, trace_id, lineage_metadata(fact.hash, parent_hash, extra_metadata))
  end

  def from_fact(%{value: value} = fact, source, trace_id, extra_metadata) when is_map(fact) do
    parent_hash =
      case Map.get(fact, :ancestry) do
        {parent, _step} -> parent
        _ -> nil
      end

    fact_hash = Map.get(fact, :hash)

    new(value, source, trace_id, lineage_metadata(fact_hash, parent_hash, extra_metadata))
  end

  def from_fact(value, source, trace_id, extra_metadata),
    do: new(value, source, trace_id, extra_metadata)

  @doc """
  Updates the value while preserving lineage.
  """
  @spec transform(t(), any(), map()) :: t()
  def transform(%__MODULE__{metadata: prev_meta}, new_value, new_metadata \\ %{}) do
    updated_metadata =
      prev_meta
      |> Map.put(:timestamp, DateTime.utc_now())
      |> Map.put(:parent_hash, prev_meta[:fact_hash])
      |> Map.merge(new_metadata)

    %__MODULE__{value: new_value, metadata: updated_metadata}
  end

  @doc """
  Converts an envelope into a JSON-friendly map (string metadata keys).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{value: value, metadata: metadata}) do
    %{
      "value" => value,
      "metadata" =>
        metadata
        |> Map.new(fn {k, v} -> {Atom.to_string(k), serialize_meta_value(v)} end)
    }
  end

  @doc """
  Rebuilds an envelope from a serialized map.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"value" => value, "metadata" => metadata}) do
    parsed_metadata =
      metadata
      |> Map.new(fn {k, v} ->
        key = parse_metadata_key(k)
        {key, deserialize_meta_value(key, v)}
      end)

    %__MODULE__{value: value, metadata: parsed_metadata}
  end

  def from_map(%{"value" => value}) do
    # Legacy format without metadata
    new(value, :unknown, "legacy-" <> generate_id())
  end

  def from_map(value) when is_map(value) and not is_struct(value) do
    # Raw map value (not an envelope)
    new(value, :unknown, "raw-" <> generate_id())
  end

  # ----------------------------------------------------------------------------
  # Private helpers
  # ----------------------------------------------------------------------------

  defp lineage_metadata(fact_hash, parent_hash, extra_metadata) do
    %{}
    |> maybe_put(:fact_hash, fact_hash)
    |> maybe_put(:parent_hash, parent_hash)
    |> Map.merge(extra_metadata)
  end

  defp serialize_meta_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_meta_value(value), do: value

  defp deserialize_meta_value("timestamp", value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> value
    end
  end

  defp deserialize_meta_value("source", value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> :unknown
  end

  defp deserialize_meta_value(_, value), do: value

  defp parse_metadata_key(key) when is_atom(key), do: key

  defp parse_metadata_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    _ -> key
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
