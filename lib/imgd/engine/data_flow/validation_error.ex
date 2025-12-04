defmodule Imgd.Engine.DataFlow.ValidationError do
  @moduledoc """
  Validation error for data flow schema violations.
  """

  alias JSV

  @type error_code ::
          :type_mismatch
          | :required_missing
          | :constraint_violated
          | :invalid_format
          | :unknown_field

  @type t :: %__MODULE__{
          path: [atom() | String.t() | integer()],
          message: String.t(),
          expected: String.t() | nil,
          actual: String.t() | nil,
          code: error_code()
        }

  defexception [:path, :message, :expected, :actual, :code]

  @impl true
  def message(%__MODULE__{path: path, message: msg}) do
    path_str = format_path(path)

    if path_str == "" do
      msg
    else
      "#{path_str}: #{msg}"
    end
  end

  @spec type_mismatch([any()], atom() | String.t(), any()) :: t()
  def type_mismatch(path, expected, actual) do
    actual_type = type_name(actual)

    %__MODULE__{
      path: path,
      message: "expected #{expected}, got #{actual_type}",
      expected: to_string(expected),
      actual: actual_type,
      code: :type_mismatch
    }
  end

  @spec required_missing([any()], atom() | String.t()) :: t()
  def required_missing(path, field) do
    %__MODULE__{
      path: path,
      message: "missing required field: #{field}",
      expected: "field #{field}",
      actual: "missing",
      code: :required_missing
    }
  end

  @spec constraint_violated([any()], String.t(), any(), any()) :: t()
  def constraint_violated(path, constraint, expected, actual) do
    %__MODULE__{
      path: path,
      message: "value #{inspect(actual)} violates #{constraint} constraint: #{inspect(expected)}",
      expected: inspect(expected),
      actual: inspect(actual),
      code: :constraint_violated
    }
  end

  @spec invalid_format([any()], String.t(), any()) :: t()
  def invalid_format(path, format, actual) do
    %__MODULE__{
      path: path,
      message: "invalid format: expected #{format}",
      expected: format,
      actual: inspect(actual),
      code: :invalid_format
    }
  end

  @spec unknown_field([any()], atom() | String.t()) :: t()
  def unknown_field(path, field) do
    %__MODULE__{
      path: path ++ [field],
      message: "unknown field: #{field}",
      expected: "no field #{field}",
      actual: "field present",
      code: :unknown_field
    }
  end

  @doc """
  Builds a validation error from a JSV validation error.
  """
  @spec from_jsv(JSV.ValidationError.t()) :: t()
  def from_jsv(%JSV.ValidationError{} = error) do
    normalized = JSV.normalize_error(error, key_type: :atom)

    detail =
      normalized[:details] ||
        normalized["details"] ||
        []
        |> List.first()

    jsv_error =
      (detail && (detail[:errors] || detail["errors"])) ||
        []
        |> List.first() || %{}

    path =
      detail
      |> instance_location_to_path()

    %__MODULE__{
      path: path,
      message: jsv_error[:message] || jsv_error["message"] || "invalid data",
      expected: jsv_error[:kind] |> to_string_safe(),
      actual: nil,
      code: jsv_kind_to_code(jsv_error[:kind])
    }
  end

  @doc """
  Wraps arbitrary validation errors into the DataFlow error shape.
  """
  @spec wrap(term()) :: t()
  def wrap(error) do
    %__MODULE__{
      path: [],
      message: inspect(error),
      expected: nil,
      actual: nil,
      code: :constraint_violated
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "path" => format_path(error.path),
      "message" => error.message,
      "expected" => error.expected,
      "actual" => error.actual,
      "code" => Atom.to_string(error.code)
    }
  end

  defp format_path([]), do: ""

  defp format_path(path) do
    path
    |> Enum.map(fn
      i when is_integer(i) -> "[#{i}]"
      key -> ".#{key}"
    end)
    |> Enum.join()
    |> String.trim_leading(".")
  end

  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(nil), do: "null"
  defp type_name(value) when is_atom(value), do: "atom"
  defp type_name(_), do: "unknown"

  defp instance_location_to_path(nil), do: []

  defp instance_location_to_path(location) when is_binary(location) do
    location
    |> String.trim_leading("#/")
    |> String.split("/", trim: true)
    |> Enum.map(&String.replace(&1, "~1", "/"))
  end

  defp instance_location_to_path(_), do: []

  defp jsv_kind_to_code(:required), do: :required_missing
  defp jsv_kind_to_code(:type), do: :type_mismatch
  defp jsv_kind_to_code(:format), do: :invalid_format
  defp jsv_kind_to_code(_), do: :constraint_violated

  defp to_string_safe(nil), do: nil
  defp to_string_safe(value), do: to_string(value)
end
