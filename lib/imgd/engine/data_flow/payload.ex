defmodule Imgd.Engine.DataFlow.Payload do
  @moduledoc """
  Typed payload wrapper for data flowing through workflows.

  Inspired by Temporal's Payload system - all data is explicitly typed
  with encoding metadata, enabling clean serialization and debugging.

  ## Encodings

  - `:json` - Native JSON-serializable data (maps, lists, strings, numbers, booleans, null)
  - `:binary` - Raw binary data, stored as base64
  - `:term` - Erlang term, stored as base64-encoded ETF
  - `:reference` - Large data stored externally, payload contains reference key
  - `:error` - Represents a serialization failure with debug info

  ## Examples

      # JSON-encodable data
      Payload.encode(%{name: "test", count: 42})
      #=> %Payload{data: %{name: "test", count: 42}, encoding: :json, ...}

      # Non-JSON struct
      Payload.encode(%MyStruct{field: :value})
      #=> %Payload{data: "base64...", encoding: :term, type: "MyStruct", ...}

      # Large data (over threshold)
      Payload.encode(large_binary, max_size: 10_000)
      #=> %Payload{encoding: :reference, ref: "sha256:...", size: 1_000_000, ...}
  """

  @type encoding :: :json | :binary | :term | :reference | :error

  @type t :: %__MODULE__{
          data: any(),
          encoding: encoding(),
          type: String.t(),
          size: non_neg_integer(),
          preview: String.t() | nil,
          ref: String.t() | nil
        }

  @derive {Jason.Encoder, only: [:data, :encoding, :type, :size, :preview, :ref]}
  defstruct [:data, :encoding, :type, :size, :preview, :ref]

  @default_max_size 100_000
  @preview_length 500

  @doc """
  Encodes a value into a payload with appropriate encoding.

  ## Options

  - `:max_size` - Maximum inline size before switching to reference (default: 100KB)
  - `:preview_length` - Length of preview for large/non-JSON data (default: 500)
  """
  @spec encode(any(), keyword()) :: t()
  def encode(value, opts \\ []) do
    max_size = opts[:max_size] || @default_max_size
    preview_length = opts[:preview_length] || @preview_length

    case try_json_encode(value) do
      {:ok, encoded, size} when size <= max_size ->
        %__MODULE__{
          data: value,
          encoding: :json,
          type: type_name(value),
          size: size
        }

      {:ok, encoded, size} ->
        # JSON-encodable but too large - store as reference
        %__MODULE__{
          data: nil,
          encoding: :reference,
          type: type_name(value),
          size: size,
          preview: String.slice(encoded, 0, preview_length),
          ref: content_hash(encoded)
        }

      :error ->
        encode_non_json(value, max_size, preview_length)
    end
  end

  @doc """
  Decodes a payload back to its original value.

  Note: `:term` and `:reference` encodings may not perfectly reconstruct
  the original value (atoms become strings, structs become maps, etc.)
  """
  @spec decode(t()) :: {:ok, any()} | {:error, :reference_not_loaded | :decode_failed}
  def decode(%__MODULE__{encoding: :json, data: data}), do: {:ok, data}
  def decode(%__MODULE__{encoding: :error, data: data}), do: {:ok, data}

  def decode(%__MODULE__{encoding: :binary, data: data}) do
    case Base.decode64(data) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :decode_failed}
    end
  end

  def decode(%__MODULE__{encoding: :term, data: data}) do
    with {:ok, binary} <- Base.decode64(data) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    _ -> {:error, :decode_failed}
  end

  def decode(%__MODULE__{encoding: :reference}) do
    {:error, :reference_not_loaded}
  end

  @doc """
  Converts payload to a map suitable for JSONB storage.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "data" => payload.data,
      "encoding" => Atom.to_string(payload.encoding),
      "type" => payload.type,
      "size" => payload.size
    }
    |> maybe_put("preview", payload.preview)
    |> maybe_put("ref", payload.ref)
  end

  @doc """
  Reconstructs a payload from a stored map.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"encoding" => encoding} = map) do
    %__MODULE__{
      data: map["data"],
      encoding: parse_encoding(encoding),
      type: map["type"],
      size: map["size"],
      preview: map["preview"],
      ref: map["ref"]
    }
  end

  # Legacy format support
  def from_map(%{"value" => value}) do
    encode(value)
  end

  def from_map(value) when is_map(value) do
    encode(value)
  end

  # Private

  defp try_json_encode(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded, byte_size(encoded)}
      {:error, _} -> :error
    end
  end

  defp encode_non_json(value, max_size, preview_length) when is_binary(value) do
    size = byte_size(value)

    if size <= max_size do
      %__MODULE__{
        data: Base.encode64(value),
        encoding: :binary,
        type: "binary",
        size: size,
        preview: binary_preview(value, preview_length)
      }
    else
      %__MODULE__{
        data: nil,
        encoding: :reference,
        type: "binary",
        size: size,
        preview: binary_preview(value, preview_length),
        ref: content_hash(value)
      }
    end
  end

  defp encode_non_json(value, max_size, preview_length) do
    term_binary = :erlang.term_to_binary(value)
    size = byte_size(term_binary)

    if size <= max_size do
      %__MODULE__{
        data: Base.encode64(term_binary),
        encoding: :term,
        type: type_name(value),
        size: size,
        preview: inspect(value, limit: 20, printable_limit: preview_length)
      }
    else
      %__MODULE__{
        data: nil,
        encoding: :reference,
        type: type_name(value),
        size: size,
        preview: inspect(value, limit: 10, printable_limit: preview_length),
        ref: content_hash(term_binary)
      }
    end
  rescue
    # Some terms can't be serialized (functions, pids, etc.)
    _ ->
      %__MODULE__{
        data: %{
          "inspect" => inspect(value, limit: 20, printable_limit: preview_length),
          "reason" => "non_serializable"
        },
        encoding: :error,
        type: type_name(value),
        size: 0,
        preview: inspect(value, limit: 10, printable_limit: min(preview_length, 200))
      }
  end

  defp type_name(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_atom(value), do: "atom"
  defp type_name(value) when is_function(value), do: "function"
  defp type_name(value) when is_pid(value), do: "pid"
  defp type_name(value) when is_reference(value), do: "reference"
  defp type_name(value) when is_tuple(value), do: "tuple"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "unknown"

  defp binary_preview(binary, max_length) do
    if String.printable?(binary) do
      String.slice(binary, 0, max_length)
    else
      "<<#{byte_size(binary)} bytes>>"
    end
  end

  defp content_hash(data) when is_binary(data) do
    hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    "sha256:#{hash}"
  end

  defp parse_encoding("json"), do: :json
  defp parse_encoding("binary"), do: :binary
  defp parse_encoding("term"), do: :term
  defp parse_encoding("reference"), do: :reference
  defp parse_encoding("error"), do: :error
  defp parse_encoding(_), do: :json

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
