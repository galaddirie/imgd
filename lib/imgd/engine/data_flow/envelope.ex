defmodule Imgd.Engine.DataFlow.Envelope do
  @moduledoc """
  Lineage-tracking wrapper for values flowing through workflows.

  While `Payload` handles serialization and type metadata, `Envelope`
  handles **lineage**: where data came from, when, and how it flows
  through the workflow graph.

  ## Relationship to Payload

  - `Payload` = "How do I serialize this?" (encoding, type, size)
  - `Envelope` = "Where did this come from?" (source, trace, ancestry)

  When persisting, an Envelope's value is encoded as a Payload:

      envelope
      |> Envelope.to_map()  # value becomes a Payload internally
      |> store_in_database()

  ## Example

      # Create from workflow input
      envelope = Envelope.new(user_data, :input, trace_id)

      # Transform through a step
      result_envelope = Envelope.transform(envelope, step_output, %{step_name: "process"})

      # The lineage is preserved
      result_envelope.metadata.parent_hash  #=> original fact hash
  """

  alias Imgd.Engine.DataFlow.Payload

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
  Builds an envelope from a Runic fact, preserving lineage.
  """
  @spec from_fact(any(), source(), String.t(), map()) :: t()
  def from_fact(fact, source, trace_id, extra_metadata \\ %{})

  def from_fact(nil, source, trace_id, extra_metadata) do
    new(nil, source, trace_id, extra_metadata)
  end

  def from_fact(%Runic.Workflow.Fact{} = fact, source, trace_id, extra_metadata) do
    parent_hash = extract_parent_hash(fact.ancestry)
    lineage = build_lineage(fact.hash, parent_hash, extra_metadata)
    new(fact.value, source, trace_id, lineage)
  end

  def from_fact(%{value: value} = fact, source, trace_id, extra_metadata) when is_map(fact) do
    parent_hash = fact |> Map.get(:ancestry) |> extract_parent_hash()
    fact_hash = Map.get(fact, :hash)
    lineage = build_lineage(fact_hash, parent_hash, extra_metadata)
    new(value, source, trace_id, lineage)
  end

  def from_fact(value, source, trace_id, extra_metadata) do
    new(value, source, trace_id, extra_metadata)
  end

  @doc """
  Transforms an envelope with a new value while preserving lineage.
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
  Converts an envelope to a JSON-friendly map for storage.

  The value is encoded as a Payload with explicit type metadata.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{value: value, metadata: metadata}) do
    %{
      "value" => Payload.encode(value) |> Payload.to_map(),
      "metadata" => serialize_metadata(metadata)
    }
  end

  @doc """
  Rebuilds an envelope from a stored map.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"value" => value_map, "metadata" => metadata}) when is_map(metadata) do
    parsed_value = parse_stored_value(value_map)
    parsed_metadata = deserialize_metadata(metadata)
    %__MODULE__{value: parsed_value, metadata: parsed_metadata}
  end

  def from_map(%{"value" => value}) do
    new(value, :unknown, generate_legacy_id())
  end

  def from_map(value) when is_map(value) and not is_struct(value) do
    new(value, :unknown, generate_legacy_id())
  end

  # ----------------------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------------------

  defp extract_parent_hash({parent, _step}), do: parent
  defp extract_parent_hash(_), do: nil

  defp build_lineage(fact_hash, parent_hash, extra_metadata) do
    %{}
    |> maybe_put(:fact_hash, fact_hash)
    |> maybe_put(:parent_hash, parent_hash)
    |> Map.merge(extra_metadata)
  end

  defp serialize_metadata(metadata) do
    Map.new(metadata, fn {k, v} ->
      {to_string(k), serialize_meta_value(v)}
    end)
  end

  defp serialize_meta_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_meta_value(value) when is_atom(value), do: to_string(value)
  defp serialize_meta_value(value), do: value

  defp deserialize_metadata(metadata) do
    Map.new(metadata, fn {k, v} ->
      key = parse_metadata_key(k)
      {key, deserialize_meta_value(key, v)}
    end)
  end

  defp deserialize_meta_value(:timestamp, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> value
    end
  end

  defp deserialize_meta_value(:source, value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> :unknown
  end

  defp deserialize_meta_value(_, value), do: value

  defp parse_metadata_key(key) when is_atom(key), do: key

  defp parse_metadata_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    _ -> String.to_atom(key)
  end

  defp parse_stored_value(%{"encoding" => _} = payload_map) do
    case Payload.from_map(payload_map) |> Payload.decode() do
      {:ok, value} -> value
      {:error, _} -> payload_map
    end
  end

  defp parse_stored_value(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generate_legacy_id do
    "legacy-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
