defmodule Imgd.Engine.DataFlow do
  @moduledoc """
  Unified data flow management for workflow execution.

  Provides utilities to:
  - Wrap and unwrap values flowing through workflows
  - Validate inputs and outputs against schemas
  - Create size-safe snapshots for persistence/logging
  - Serialize values for JSONB storage
  """

  alias Imgd.Engine.DataFlow.{Envelope, Schema, ValidationError}
  alias JSV

  @type raw_value :: any()
  @type wrapped_value :: Envelope.t()
  @type validation_result :: {:ok, any()} | {:error, ValidationError.t()}

  @type prepare_opts :: [
          schema: Schema.t() | nil,
          trace_id: String.t() | nil,
          metadata: map()
        ]

  @type wrap_opts :: [
          source: :input | :step | :rule | :accumulator | :external | :unknown,
          step_hash: integer() | nil,
          step_name: String.t() | nil,
          fact_hash: integer() | nil,
          trace_id: String.t() | nil
        ]

  # ----------------------------------------------------------------------------
  # Input preparation
  # ----------------------------------------------------------------------------

  @doc """
  Wraps raw input for workflow execution, optionally validating against a schema.

  Returns `{:ok, %Envelope{}}` or `{:error, %ValidationError{}}`.
  """
  @spec prepare_input(raw_value(), prepare_opts()) ::
          {:ok, Envelope.t()} | {:error, ValidationError.t()}
  def prepare_input(value, opts \\ []) do
    schema = opts[:schema]
    trace_id = opts[:trace_id] || generate_trace_id()
    extra_metadata = opts[:metadata] || %{}

    with {:ok, validated} <- validate_if_schema(value, schema) do
      {:ok, Envelope.new(validated, :input, trace_id, extra_metadata)}
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
  # Wrapping/Unwrapping
  # ----------------------------------------------------------------------------

  @doc """
  Wraps a raw value in an envelope for persistence or transport.
  """
  @spec wrap(raw_value(), wrap_opts()) :: Envelope.t()
  def wrap(value, opts \\ []) do
    source = opts[:source] || :unknown
    trace_id = opts[:trace_id] || generate_trace_id()

    metadata =
      opts
      |> Keyword.take([:step_hash, :step_name, :fact_hash])
      |> Map.new()

    Envelope.new(value, source, trace_id, metadata)
  end

  @doc """
  Unwraps an envelope (or legacy map) to the raw value.
  """
  @spec unwrap(wrapped_value() | raw_value()) :: raw_value()
  def unwrap(%Envelope{value: value}), do: value
  def unwrap(%{"value" => value}), do: value
  def unwrap(%{value: value}), do: value
  def unwrap(value), do: value

  @doc """
  Returns true if the value looks like an envelope.
  """
  @spec wrapped?(any()) :: boolean()
  def wrapped?(%Envelope{}), do: true
  def wrapped?(%{"value" => _}), do: true
  def wrapped?(%{value: _, metadata: _}), do: true
  def wrapped?(_), do: false

  # ----------------------------------------------------------------------------
  # Serialization
  # ----------------------------------------------------------------------------

  @doc """
  Serializes an arbitrary value into a JSON-friendly map.
  """
  @spec serialize_for_storage(any()) :: map()
  def serialize_for_storage(value) do
    case serialize_value(value) do
      {:ok, serialized, type} ->
        %{"value" => serialized, "type" => type}

      {:error, :non_serializable} ->
        %{
          "type" => "non_serializable",
          "elixir_type" => inspect_type(value),
          "inspect" => inspect(value, limit: 500, printable_limit: 500)
        }
    end
  end

  @doc """
  Deserializes a value previously serialized with `serialize_for_storage/1`.
  """
  @spec deserialize_from_storage(map()) :: any()
  def deserialize_from_storage(%{"type" => "non_serializable", "inspect" => inspected}) do
    {:non_serializable, inspected}
  end

  def deserialize_from_storage(%{"value" => value}), do: value
  def deserialize_from_storage(value), do: value

  # ----------------------------------------------------------------------------
  # Snapshots
  # ----------------------------------------------------------------------------

  @doc """
  Produces a size-limited snapshot of a value for persistence/logging.

  Large values are truncated with preview metadata. Non-JSON encodable
  values are inspected and marked accordingly.
  """
  @spec snapshot(any(), keyword()) :: map()
  def snapshot(value, opts \\ []) do
    max_size = opts[:max_size] || 10_000
    preview_size = opts[:preview_size] || 1_000

    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max_size ->
        ensure_map(value)

      {:ok, encoded} ->
        %{
          "_truncated" => true,
          "_original_size" => byte_size(encoded),
          "_preview" => String.slice(encoded, 0, preview_size),
          "_type" => inspect_type(value)
        }

      {:error, _} ->
        %{
          "_non_json" => true, # todo: strange
          "_type" => inspect_type(value),
          "_inspect" => inspect(value, limit: 50, printable_limit: 200)
        }
    end
  end

  # ----------------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------------

  @doc """
  Validates a value against a schema.
  """
  @spec validate(any(), Schema.t()) :: validation_result()
  def validate(value, schema)

  def validate(value, nil), do: {:ok, value}

  def validate(value, schema) do
    with {:ok, root} <- build_root(schema),
         {:ok, cast_value} <- JSV.validate(value, root, default_validate_opts()) do
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
  @spec validate!(any(), Schema.t()) :: any()
  def validate!(value, schema) do
    case validate(value, schema) do
      {:ok, validated} -> validated
      {:error, error} -> raise error
    end
  end

  @doc """
  Generates a trace identifier suitable for correlation.
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # ----------------------------------------------------------------------------
  # Private helpers
  # ----------------------------------------------------------------------------

  defp validate_if_schema(value, nil), do: {:ok, value}

  defp validate_if_schema(value, schema), do: validate(value, schema)

  defp build_root(%JSV.Root{} = root), do: {:ok, root}
  defp build_root(schema), do: JSV.build(schema, formats: true)

  defp default_validate_opts do
    [cast: true, cast_formats: true]
  end

  defp serialize_value(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, _} -> {:ok, stringify_keys(value), "map"}
      {:error, _} -> {:error, :non_serializable}
    end
  end

  defp serialize_value(value) when is_list(value) do
    case Jason.encode(value) do
      {:ok, _} -> {:ok, value, "list"}
      {:error, _} -> {:error, :non_serializable}
    end
  end

  defp serialize_value(value) when is_binary(value), do: {:ok, value, "string"}
  defp serialize_value(value) when is_integer(value), do: {:ok, value, "integer"}
  defp serialize_value(value) when is_float(value), do: {:ok, value, "float"}
  defp serialize_value(value) when is_boolean(value), do: {:ok, value, "boolean"}
  defp serialize_value(nil), do: {:ok, nil, "null"}
  defp serialize_value(value) when is_atom(value), do: {:ok, Atom.to_string(value), "atom"}

  defp serialize_value(%{__struct__: _} = struct) do
    if function_exported?(struct.__struct__, :__schema__, 1) do
      map = Map.from_struct(struct) |> Map.drop([:__meta__])
      serialize_value(map)
    else
      case Jason.encode(struct) do
        {:ok, _} -> {:ok, Map.from_struct(struct) |> stringify_keys(), "struct"}
        {:error, _} -> {:error, :non_serializable}
      end
    end
  end

  defp serialize_value(_), do: {:error, :non_serializable}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(value), do: %{"value" => value}

  defp inspect_type(%{__struct__: mod}), do: "struct:#{inspect(mod)}"
  defp inspect_type(value) when is_map(value), do: "map"
  defp inspect_type(value) when is_list(value), do: "list"
  defp inspect_type(value) when is_binary(value), do: "string"
  defp inspect_type(value) when is_integer(value), do: "integer"
  defp inspect_type(value) when is_float(value), do: "float"
  defp inspect_type(value) when is_boolean(value), do: "boolean"
  defp inspect_type(value) when is_atom(value), do: "atom"
  defp inspect_type(value) when is_function(value), do: "function"
  defp inspect_type(value) when is_pid(value), do: "pid"
  defp inspect_type(value) when is_reference(value), do: "reference"
  defp inspect_type(value) when is_tuple(value), do: "tuple"
  defp inspect_type(_), do: "unknown"
end
