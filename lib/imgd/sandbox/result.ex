defmodule Imgd.Sandbox.Result do
  @moduledoc false

  @spec parse(String.t()) :: {:ok, term()} | {:error, term()}
  def parse(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"ok" => true, "value" => value}} ->
        {:ok, value}

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, {:runtime_error, error}}

      {:ok, other} ->
        {:error, {:unexpected_result, other}}

      {:error, _} ->
        {:error, {:invalid_json, output}}
    end
  end

  def parse(other), do: {:error, {:invalid_json, inspect(other)}}
end
