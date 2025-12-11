defmodule Imgd.Sandbox.Executor do
  @moduledoc """
  Executes JavaScript code using QuickJS compiled to WebAssembly.

  This module runs inside the FLAME execution context.
  """

  alias Imgd.Sandbox.{Config, WasmRuntime}

  @input_fallback_offset 1_024

  @spec run(String.t(), Config.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def run(code, %Config{} = config) do
    case WasmRuntime.new_instance(config.fuel, config.memory_mb) do
      {:ok, pid, store} ->
        try do
          do_run(pid, store, code, config)
        after
          GenServer.stop(pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:execution_error, Exception.message(e)}}
  end

  defp do_run(pid, store, code, %Config{} = config) do
    with {:ok, memory} <- Wasmex.memory(pid),
         {:ok, input_ptr, input_len} <- write_input(pid, store, memory, code, config.args),
         {:ok, raw} <- execute(pid, store, memory, input_ptr, input_len, config) do
      fuel_used = fuel_consumed(store, config.fuel)
      {:ok, raw, %{fuel_consumed: fuel_used}}
    end
  end

  defp write_input(pid, store, memory, code, args) do
    input = Jason.encode!(%{code: code, args: args})
    input_bytes = input <> <<0>>
    input_len = byte_size(input)

    with {:ok, ptr} <- allocate(pid, input_len + 1),
         :ok <- Wasmex.Memory.write_binary(store, memory, ptr, input_bytes) do
      {:ok, ptr, input_len}
    else
      {:error, reason} -> {:error, {:wasm_error, reason}}
    end
  end

  defp allocate(pid, size) do
    case Wasmex.call_function(pid, "alloc", [size]) do
      {:ok, [ptr]} when is_integer(ptr) and ptr > 0 ->
        {:ok, ptr}

      _ ->
        {:ok, @input_fallback_offset}
    end
  end

  defp execute(pid, store, memory, input_ptr, input_len, %Config{max_output_size: max_output_size}) do
    case Wasmex.call_function(pid, "eval_js", [input_ptr, input_len]) do
      {:ok, [0]} ->
        read_error(pid, store, memory)

      {:ok, [result_ptr]} ->
        with {:ok, [result_len]} <- Wasmex.call_function(pid, "get_output_len", []),
             :ok <- enforce_output_limit(result_len, max_output_size),
             {:ok, output} <- read_output(store, memory, result_ptr, result_len) do
          {:ok, output}
        else
          {:error, reason} -> {:error, reason}
        end

      {:trap, reason} ->
        {:error, classify_trap(reason)}

      {:error, msg} when is_binary(msg) ->
        {:error, classify_message(msg)}

      {:error, reason} ->
        {:error, {:wasm_error, reason}}
    end
  end

  defp read_error(pid, store, memory) do
    with {:ok, [err_ptr]} <- Wasmex.call_function(pid, "get_error_ptr", []),
         {:ok, [err_len]} <- Wasmex.call_function(pid, "get_error_len", []) do
      message = Wasmex.Memory.read_string(store, memory, err_ptr, err_len)
      {:error, {:runtime_error, message}}
    else
      _ -> {:error, {:runtime_error, "Unknown runtime error"}}
    end
  end

  defp read_output(store, memory, ptr, len) do
    {:ok, Wasmex.Memory.read_string(store, memory, ptr, len)}
  rescue
    e -> {:error, {:wasm_error, Exception.message(e)}}
  end

  defp enforce_output_limit(len, max_output_size) when len > max_output_size do
    {:error, {:runtime_error, "Output exceeds max size of #{max_output_size} bytes"}}
  end

  defp enforce_output_limit(_len, _max_output_size), do: :ok

  defp fuel_consumed(store, original) do
    case Wasmex.StoreOrCaller.get_fuel(store) do
      {:ok, remaining} when is_integer(remaining) -> max(original - remaining, 0)
      _ -> nil
    end
  end

  defp classify_message(msg) do
    cond do
      String.contains?(msg, "all fuel consumed") -> :fuel_exhausted
      String.contains?(msg, "fuel") -> :fuel_exhausted
      String.contains?(msg, "memory") -> :memory_exceeded
      true -> {:wasm_error, msg}
    end
  end

  defp classify_trap(trap) when is_binary(trap), do: classify_message(trap)
  defp classify_trap(trap), do: {:wasm_error, trap}
end
