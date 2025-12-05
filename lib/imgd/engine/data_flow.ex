defmodule Imgd.Engine.DataFlow do
  @moduledoc """
  Unified data flow management for workflow execution.

  Provides a clean, typed approach to handling data flowing through workflows:

  - **Payload** - Explicit typed wrapper with encoding metadata (like Temporal)
  - **Envelope** - Lineage tracking wrapper with trace context
  - **Schema** - JSON Schema validation via JSV

  ## Design Principles

  1. All data has explicit type metadata - no magic string keys
  2. Large data handled consistently via references
  3. Non-serializable data clearly marked with debug info
  4. Clean separation between transport (Payload) and lineage (Envelope)
  """

  alias Imgd.Engine.DataFlow.{Envelope, Payload, Schema, ValidationError}

  @type raw_value :: any()
  @type validation_result :: {:ok, any()} | {:error, ValidationError.t()}

  @type prepare_opts :: [
          schema: Schema.t() | nil,
          trace_id: String.t() | nil,
          metadata: map()
        ]

  @type wrap_opts :: [
          source: Envelope.source(),
          step_hash: integer() | nil,
          step_name: String.t() | nil,
          fact_hash: integer() | nil,
          trace_id: String.t() | nil
        ]

  # ----------------------------------------------------------------------------
  # Input Preparation
  # ----------------------------------------------------------------------------

  @doc """
  Prepares raw input for workflow execution.

  Validates against schema (if provided) and wraps in an Envelope
  for lineage tracking.

  ## Examples

      iex> prepare_input(%{name: "test"}, schema: my_schema)
      {:ok, %Envelope{value: %{name: "test"}, metadata: %{source: :input, ...}}}

      iex> prepare_input(%{bad: "data"}, schema: strict_schema)
      {:error, %ValidationError{...}}
  """
  @spec prepare_input(raw_value(), prepare_opts()) ::
          {:ok, Envelope.t()} | {:error, ValidationError.t()}
  def prepare_input(value, opts \\ []) do
    schema = opts[:schema]
    trace_id = opts[:trace_id] || generate_trace_id()
    metadata = opts[:metadata] || %{}

    with {:ok, validated} <- validate_if_schema(value, schema) do
      {:ok, Envelope.new(validated, :input, trace_id, metadata)}
    end
  end

  @doc """
  Same as `prepare_input/2` but raises on validation failure.
  """
  @spec prepare_input!(raw_value(), prepare_opts()) :: Envelope.t()
  def prepare_input!(value, opts \\ []) do
    case prepare_input(value, opts) do
      {:ok, envelope} -> envelope
      {:error, error} -> raise error
    end
  end

  # ----------------------------------------------------------------------------
  # Wrapping / Unwrapping
  # ----------------------------------------------------------------------------

  @doc """
  Wraps a raw value in an Envelope for lineage tracking.
  """
  @spec wrap(raw_value(), wrap_opts()) :: Envelope.t()
  def wrap(value, opts \\ []) do
    source = opts[:source] || :unknown
    trace_id = opts[:trace_id] || generate_trace_id()
    metadata = opts |> Keyword.take([:step_hash, :step_name, :fact_hash]) |> Map.new()

    Envelope.new(value, source, trace_id, metadata)
  end

  @doc """
  Unwraps to the raw value from an Envelope, Payload, or legacy format.
  """
  @spec unwrap(Envelope.t() | Payload.t() | map() | any()) :: raw_value()
  def unwrap(%Envelope{value: value}), do: decode_payload_if_needed(value)
  def unwrap(%Payload{} = payload), do: decode_payload(payload)

  def unwrap(%{"value" => value, "metadata" => _metadata}) do
    decode_payload_if_needed(value)
  end

  def unwrap(%{"value" => value, "encoding" => _} = payload_map) when is_map(payload_map) do
    decode_payload_map(payload_map)
  end

  def unwrap(%{"value" => value}), do: decode_payload_if_needed(value)

  def unwrap(%{value: value, encoding: _} = payload_map) do
    payload_map
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> decode_payload_map()
  end

  def unwrap(%{value: value}), do: decode_payload_if_needed(value)
  def unwrap(value), do: value

  @doc """
  Returns true if the value is wrapped in an Envelope or Payload.
  """
  @spec wrapped?(any()) :: boolean()
  def wrapped?(%Envelope{}), do: true
  def wrapped?(%Payload{}), do: true
  def wrapped?(%{"value" => _, "encoding" => _}), do: true
  def wrapped?(%{"value" => _, "metadata" => _}), do: true
  def wrapped?(_), do: false

  # ----------------------------------------------------------------------------
  # Serialization (Payload-based)
  # ----------------------------------------------------------------------------

  @doc """
  Encodes a value into a Payload for storage.

  The Payload includes explicit type and encoding metadata,
  handles large data via references, and provides debug info
  for non-serializable values.

  ## Options

  - `:max_size` - Maximum inline size (default: 100KB)
  """
  @spec encode(any(), keyword()) :: Payload.t()
  def encode(value, opts \\ []) do
    Payload.encode(value, opts)
  end

  @doc """
  Converts a value to a JSON-safe map for JSONB storage.

  Uses Payload internally for clean, typed serialization.
  """
  @spec serialize(any(), keyword()) :: map()
  def serialize(value, opts \\ []) do
    opts = normalize_preview_opts(opts, 100_000, 1_000)

    value
    |> Payload.encode(opts)
    |> serialize_payload()
  end

  @doc """
  Deserializes a stored map back to a Payload.
  """
  @spec deserialize(map()) :: Payload.t()
  def deserialize(map) do
    Payload.from_map(map)
  end

  # Legacy aliases
  @doc false
  def serialize_for_storage(value), do: serialize(value)
  @doc false
  def deserialize_from_storage(map), do: deserialize(map) |> unwrap()

  # ----------------------------------------------------------------------------
  # Snapshots (for logging/debugging)
  # ----------------------------------------------------------------------------

  @doc """
  Creates a size-limited snapshot of a value for persistence or logging.

  This is a convenience wrapper around Payload.encode with smaller defaults
  suitable for debug snapshots.

  ## Options

  - `:max_size` - Maximum size (default: 10KB)
  - `:preview_length` - Preview length for large data (default: 1KB)
  """
  @spec snapshot(any(), keyword()) :: map()
  def snapshot(value, opts \\ []) do
    opts = normalize_preview_opts(opts, 10_000, 1_000)

    value
    |> Payload.encode(opts)
    |> snapshot_payload()
  end

  # ----------------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------------

  @doc """
  Validates a value against a JSON schema.
  """
  @spec validate(any(), Schema.t() | nil) :: validation_result()
  def validate(value, nil), do: {:ok, value}

  def validate(value, schema) do
    with {:ok, root} <- build_root(schema),
         {:ok, cast_value} <- JSV.validate(value, root, cast: true, cast_formats: true) do
      {:ok, cast_value}
    else
      {:error, %JSV.ValidationError{} = error} ->
        {:error, ValidationError.from_jsv(error)}

      {:error, error} ->
        {:error, ValidationError.wrap(error)}
    end
  end

  @doc """
  Validates and returns the value, raising on validation errors.
  """
  @spec validate!(any(), Schema.t() | nil) :: any()
  def validate!(value, schema) do
    case validate(value, schema) do
      {:ok, validated} -> validated
      {:error, error} -> raise error
    end
  end

  # ----------------------------------------------------------------------------
  # Utilities
  # ----------------------------------------------------------------------------

  @doc """
  Generates a trace identifier for correlation.
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # ----------------------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------------------

  defp validate_if_schema(value, nil), do: {:ok, value}
  defp validate_if_schema(value, schema), do: validate(value, schema)

  defp build_root(%JSV.Root{} = root), do: {:ok, root}
  defp build_root(schema), do: JSV.build(schema, formats: true)

  defp decode_payload(%Payload{} = payload) do
    case Payload.decode(payload) do
      {:ok, value} -> value
      {:error, _} -> payload.data
    end
  end

  defp decode_payload_if_needed(%Payload{} = payload), do: decode_payload(payload)

  defp decode_payload_if_needed(%{"encoding" => _} = payload_map),
    do: decode_payload_map(payload_map)

  defp decode_payload_if_needed(%{encoding: _} = payload_map) do
    payload_map
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> decode_payload_map()
  end

  defp decode_payload_if_needed(value), do: value

  defp decode_payload_map(%{"encoding" => _} = payload_map) do
    payload_map
    |> Payload.from_map()
    |> decode_payload()
  rescue
    _ -> payload_map["data"] || payload_map
  end

  defp serialize_payload(%Payload{encoding: :json, data: data, type: type, size: size}) do
    %{
      "type" => type,
      "value" => stringify_keys(data),
      "_size" => size
    }
  end

  defp serialize_payload(%Payload{
         encoding: :reference,
         type: type,
         size: size,
         preview: preview,
         ref: ref
       }) do
    %{
      "type" => type,
      "_truncated" => true,
      "_original_size" => size,
      "_preview" => preview,
      "ref" => ref,
      "encoding" => "reference"
    }
  end

  defp serialize_payload(%Payload{type: "function", preview: preview}) do
    %{
      "type" => "non_serializable",
      "inspect" => preview || inspect(fn -> :ok end)
    }
  end

  defp serialize_payload(%Payload{
         encoding: encoding,
         type: type,
         preview: preview,
         data: data,
         size: size
       })
       when encoding in [:term, :binary] do
    %{
      "type" => type,
      "_non_json" => true,
      "_inspect" => preview || inspect(data),
      "encoding" => Atom.to_string(encoding),
      "data" => data,
      "_size" => size
    }
  end

  defp serialize_payload(%Payload{encoding: :error, data: data, preview: preview}) do
    inspect_val = Map.get(data, "inspect") || preview || inspect(data)

    %{
      "type" => "non_serializable",
      "inspect" => inspect_val
    }
  end

  defp serialize_payload(%Payload{} = payload) do
    %{
      "type" => payload.type,
      "value" => payload.data
    }
  end

  defp snapshot_payload(%Payload{encoding: :json, data: data, type: type, size: size}) do
    %{
      "value" => data,
      "type" => type,
      "_size" => size,
      "encoding" => "json"
    }
  end

  defp snapshot_payload(%Payload{
         encoding: :reference,
         type: type,
         size: size,
         preview: preview,
         ref: ref
       }) do
    %{
      "_truncated" => true,
      "_original_size" => size,
      "_preview" => preview,
      "_type" => type,
      "encoding" => "reference",
      "ref" => ref
    }
  end

  defp snapshot_payload(%Payload{type: "function", preview: preview}) do
    inspect_val = preview || inspect(fn -> :ok end)

    %{
      "_non_json" => true,
      "_type" => "non_serializable",
      "_inspect" => inspect_val,
      "type" => "non_serializable",
      "inspect" => inspect_val
    }
  end

  defp snapshot_payload(%Payload{
         encoding: encoding,
         type: type,
         preview: preview,
         data: data,
         size: size
       })
       when encoding in [:term, :binary] do
    %{
      "_non_json" => true,
      "_type" => type,
      "_inspect" => preview || inspect(data),
      "encoding" => Atom.to_string(encoding),
      "data" => data,
      "_size" => size
    }
  end

  defp snapshot_payload(%Payload{encoding: :error, data: data, preview: preview}) do
    inspect_val = Map.get(data, "inspect") || preview || inspect(data)

    %{
      "_non_json" => true,
      "_type" => "non_serializable",
      "_inspect" => inspect_val,
      "type" => "non_serializable",
      "inspect" => inspect_val
    }
  end

  defp snapshot_payload(%Payload{} = payload) do
    %{
      "value" => payload.data,
      "type" => payload.type
    }
  end

  defp normalize_preview_opts(opts, default_max_size, default_preview_length) do
    opts =
      Keyword.merge(
        [max_size: default_max_size, preview_length: default_preview_length],
        opts
      )

    preview_length = opts[:preview_length] || opts[:preview_size] || default_preview_length
    Keyword.put(opts, :preview_length, preview_length)
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
