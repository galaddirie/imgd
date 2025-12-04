defmodule Imgd.Engine.DataFlow.Schema do
  @moduledoc """
  Convenience JSON Schema-style builders compatible with the JSV validator.

  The validation helpers remain for backwards compatibility, but new code
  should rely on `JSV.build/2` + `JSV.validate/3` via `Imgd.Engine.DataFlow`.
  """

  alias Imgd.Engine.DataFlow.ValidationError

  @type schema_type :: :object | :array | :string | :integer | :number | :boolean | :null | :any
  @type string_format :: :email | :uri | :uuid | :datetime | :date | :time

  @type t :: %{
          optional(:type) => schema_type(),
          optional(:required) => [atom() | String.t()],
          optional(:properties) => %{(atom() | String.t()) => t()},
          optional(:additional_properties) => boolean(),
          optional(:items) => t(),
          optional(:min_items) => non_neg_integer(),
          optional(:max_items) => non_neg_integer(),
          optional(:min_length) => non_neg_integer(),
          optional(:max_length) => non_neg_integer(),
          optional(:pattern) => Regex.t(),
          optional(:format) => string_format(),
          optional(:minimum) => number(),
          optional(:maximum) => number(),
          optional(:exclusive_minimum) => boolean(),
          optional(:exclusive_maximum) => boolean(),
          optional(:enum) => [any()],
          optional(:nullable) => boolean(),
          optional(:one_of) => [t()]
        }

  @doc """
  Validates a value against a schema. Returns `:ok` or `{:error, %ValidationError{}}`.
  """
  @spec validate(any(), t(), [atom() | String.t() | integer()]) ::
          :ok | {:error, ValidationError.t()}
  def validate(value, schema, path \\ [])

  # Nullable
  def validate(nil, %{nullable: true}, _path), do: :ok

  # Enum
  def validate(value, %{enum: allowed} = schema, path) when is_list(allowed) do
    if value in allowed do
      schema_without_enum = Map.delete(schema, :enum)

      if map_size(schema_without_enum) > 0 do
        validate(value, schema_without_enum, path)
      else
        :ok
      end
    else
      {:error, ValidationError.constraint_violated(path, "enum", allowed, value)}
    end
  end

  # Union
  def validate(value, %{one_of: schemas}, path) when is_list(schemas) do
    results = Enum.map(schemas, &validate(value, &1, path))

    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      errors =
        results
        |> Enum.filter(&match?({:error, _}, &1))
        |> Enum.map(fn {:error, e} -> e end)
        |> Enum.sort_by(&length(&1.path))

      {:error, hd(errors)}
    end
  end

  # Any
  def validate(_value, %{type: :any}, _path), do: :ok

  # Null
  def validate(nil, %{type: :null}, _path), do: :ok

  def validate(value, %{type: :null}, path),
    do: {:error, ValidationError.type_mismatch(path, :null, value)}

  # Boolean
  def validate(value, %{type: :boolean}, _path) when is_boolean(value), do: :ok

  def validate(value, %{type: :boolean}, path),
    do: {:error, ValidationError.type_mismatch(path, :boolean, value)}

  # Integer
  def validate(value, %{type: :integer} = schema, path) when is_integer(value) do
    validate_number_constraints(value, schema, path)
  end

  def validate(value, %{type: :integer}, path) do
    {:error, ValidationError.type_mismatch(path, :integer, value)}
  end

  # Number
  def validate(value, %{type: :number} = schema, path) when is_number(value) do
    validate_number_constraints(value, schema, path)
  end

  def validate(value, %{type: :number}, path) do
    {:error, ValidationError.type_mismatch(path, :number, value)}
  end

  # String
  def validate(value, %{type: :string} = schema, path) when is_binary(value) do
    with :ok <- validate_string_length(value, schema, path),
         :ok <- validate_string_pattern(value, schema, path),
         :ok <- validate_string_format(value, schema, path) do
      :ok
    end
  end

  def validate(value, %{type: :string}, path) do
    {:error, ValidationError.type_mismatch(path, :string, value)}
  end

  # Array
  def validate(value, %{type: :array} = schema, path) when is_list(value) do
    with :ok <- validate_array_length(value, schema, path),
         :ok <- validate_array_items(value, schema, path) do
      :ok
    end
  end

  def validate(value, %{type: :array}, path) do
    {:error, ValidationError.type_mismatch(path, :array, value)}
  end

  # Object
  def validate(value, %{type: :object} = schema, path) when is_map(value) do
    with :ok <- validate_required_fields(value, schema, path),
         :ok <- validate_properties(value, schema, path),
         :ok <- validate_additional_properties(value, schema, path) do
      :ok
    end
  end

  def validate(value, %{type: :object}, path) do
    {:error, ValidationError.type_mismatch(path, :object, value)}
  end

  # Schema without explicit type
  def validate(value, schema, path) when is_map(schema) and not is_map_key(schema, :type) do
    cond do
      is_map(value) and Map.has_key?(schema, :properties) ->
        validate(value, Map.put(schema, :type, :object), path)

      is_list(value) and Map.has_key?(schema, :items) ->
        validate(value, Map.put(schema, :type, :array), path)

      true ->
        :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Number constraints
  # ----------------------------------------------------------------------------

  defp validate_number_constraints(value, schema, path) do
    with :ok <- validate_minimum(value, schema, path),
         :ok <- validate_maximum(value, schema, path) do
      :ok
    end
  end

  defp validate_minimum(value, %{minimum: min, exclusive_minimum: true}, path)
       when value <= min do
    {:error, ValidationError.constraint_violated(path, "exclusive minimum", min, value)}
  end

  defp validate_minimum(value, %{minimum: min}, path) when value < min do
    {:error, ValidationError.constraint_violated(path, "minimum", min, value)}
  end

  defp validate_minimum(_, _, _), do: :ok

  defp validate_maximum(value, %{maximum: max, exclusive_maximum: true}, path)
       when value >= max do
    {:error, ValidationError.constraint_violated(path, "exclusive maximum", max, value)}
  end

  defp validate_maximum(value, %{maximum: max}, path) when value > max do
    {:error, ValidationError.constraint_violated(path, "maximum", max, value)}
  end

  defp validate_maximum(_, _, _), do: :ok

  # ----------------------------------------------------------------------------
  # String constraints
  # ----------------------------------------------------------------------------

  defp validate_string_length(value, %{min_length: min}, path)
       when byte_size(value) < min do
    {:error, ValidationError.constraint_violated(path, "min_length", min, byte_size(value))}
  end

  defp validate_string_length(value, %{max_length: max}, path)
       when byte_size(value) > max do
    {:error, ValidationError.constraint_violated(path, "max_length", max, byte_size(value))}
  end

  defp validate_string_length(_, _, _), do: :ok

  defp validate_string_pattern(value, %{pattern: pattern}, path) do
    if Regex.match?(pattern, value) do
      :ok
    else
      {:error, ValidationError.constraint_violated(path, "pattern", Regex.source(pattern), value)}
    end
  end

  defp validate_string_pattern(_, _, _), do: :ok

  defp validate_string_format(value, %{format: format}, path) do
    if valid_format?(value, format) do
      :ok
    else
      {:error, ValidationError.invalid_format(path, Atom.to_string(format), value)}
    end
  end

  defp validate_string_format(_, _, _), do: :ok

  defp valid_format?(value, :email) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value)
  end

  defp valid_format?(value, :uri) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) -> true
      _ -> false
    end
  end

  defp valid_format?(value, :uuid) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp valid_format?(value, :datetime) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  defp valid_format?(value, :date) do
    case Date.from_iso8601(value) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_format?(value, :time) do
    case Time.from_iso8601(value) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_format?(_, _), do: true

  # ----------------------------------------------------------------------------
  # Array constraints
  # ----------------------------------------------------------------------------

  defp validate_array_length(value, %{min_items: min}, path) when length(value) < min do
    {:error, ValidationError.constraint_violated(path, "min_items", min, length(value))}
  end

  defp validate_array_length(value, %{max_items: max}, path) when length(value) > max do
    {:error, ValidationError.constraint_violated(path, "max_items", max, length(value))}
  end

  defp validate_array_length(_, _, _), do: :ok

  defp validate_array_items(value, %{items: item_schema}, path) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case validate(item, item_schema, path ++ [index]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_array_items(_, _, _), do: :ok

  # ----------------------------------------------------------------------------
  # Object constraints
  # ----------------------------------------------------------------------------

  defp validate_required_fields(value, %{required: required}, path) when is_list(required) do
    Enum.reduce_while(required, :ok, fn field, :ok ->
      field_key = normalize_key(field)

      if has_key?(value, field_key) do
        {:cont, :ok}
      else
        {:halt, {:error, ValidationError.required_missing(path, field)}}
      end
    end)
  end

  defp validate_required_fields(_, _, _), do: :ok

  defp validate_properties(value, %{properties: properties}, path) when is_map(properties) do
    Enum.reduce_while(properties, :ok, fn {field, field_schema}, :ok ->
      field_key = normalize_key(field)

      case get_field(value, field_key) do
        {:ok, field_value} ->
          case validate(field_value, field_schema, path ++ [field]) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        :not_found ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_properties(_, _, _), do: :ok

  defp validate_additional_properties(
         value,
         %{additional_properties: false, properties: props},
         path
       )
       when is_map(props) do
    defined_keys = Map.keys(props) |> Enum.map(&normalize_key/1) |> MapSet.new()

    value
    |> Map.keys()
    |> Enum.map(&normalize_key/1)
    |> Enum.find(fn key -> not MapSet.member?(defined_keys, key) end)
    |> case do
      nil -> :ok
      extra_key -> {:error, ValidationError.unknown_field(path, extra_key)}
    end
  end

  defp validate_additional_properties(_, _, _), do: :ok

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key

  defp has_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))
  rescue
    _ -> Map.has_key?(map, key)
  end

  defp get_field(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:ok, Map.get(map, String.to_atom(key))}
      true -> :not_found
    end
  rescue
    _ ->
      if Map.has_key?(map, key), do: {:ok, Map.get(map, key)}, else: :not_found
  end

  # ----------------------------------------------------------------------------
  # Builder helpers
  # ----------------------------------------------------------------------------

  @doc "Builds an object schema with common defaults."
  @spec object(keyword()) :: t()
  def object(opts \\ []) do
    %{type: :object}
    |> maybe_put(:required, opts[:required])
    |> maybe_put(:properties, opts[:properties])
    |> maybe_put(:additional_properties, opts[:additional_properties])
  end

  @doc "Builds a string schema."
  @spec string(keyword()) :: t()
  def string(opts \\ []) do
    %{type: :string}
    |> maybe_put(:min_length, opts[:min_length])
    |> maybe_put(:max_length, opts[:max_length])
    |> maybe_put(:pattern, opts[:pattern])
    |> maybe_put(:format, opts[:format])
    |> maybe_put(:enum, opts[:enum])
  end

  @doc "Builds an integer schema."
  @spec integer(keyword()) :: t()
  def integer(opts \\ []) do
    %{type: :integer}
    |> maybe_put(:minimum, opts[:minimum])
    |> maybe_put(:maximum, opts[:maximum])
    |> maybe_put(:exclusive_minimum, opts[:exclusive_minimum])
    |> maybe_put(:exclusive_maximum, opts[:exclusive_maximum])
    |> maybe_put(:enum, opts[:enum])
  end

  @doc "Builds a number schema."
  @spec number(keyword()) :: t()
  def number(opts \\ []) do
    %{type: :number}
    |> maybe_put(:minimum, opts[:minimum])
    |> maybe_put(:maximum, opts[:maximum])
  end

  @doc "Builds an array schema."
  @spec array(t(), keyword()) :: t()
  def array(items_schema, opts \\ []) do
    %{type: :array, items: items_schema}
    |> maybe_put(:min_items, opts[:min_items])
    |> maybe_put(:max_items, opts[:max_items])
  end

  @doc "Builds a boolean schema."
  @spec boolean() :: t()
  def boolean, do: %{type: :boolean}

  @doc "Builds an any schema (accepts all values)."
  @spec any() :: t()
  def any, do: %{type: :any}

  @doc "Makes a schema nullable."
  @spec nullable(t()) :: t()
  def nullable(schema), do: Map.put(schema, :nullable, true)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
