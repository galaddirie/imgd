defmodule Imgd.Sandbox.Validator do
  @moduledoc false

  alias Imgd.Sandbox.Config

  @spec validate_code(String.t(), Config.t()) :: :ok | {:error, term()}
  def validate_code(code, %Config{max_code_size: max}) when is_binary(code) do
    size = byte_size(code)

    cond do
      size > max -> {:error, {:code_too_large, size, max}}
      true -> :ok
    end
  end

  def validate_code(_code, _config), do: {:error, {:validation_error, "code must be a string"}}

  @spec validate_args(map()) :: :ok | {:error, term()}
  def validate_args(args) when is_map(args) do
    case Jason.encode(args) do
      {:ok, _json} -> :ok
      {:error, reason} -> {:error, {:invalid_args, reason}}
    end
  end

  def validate_args(_), do: {:error, {:validation_error, "args must be a map"}}
end
