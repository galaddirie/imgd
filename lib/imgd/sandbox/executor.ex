defmodule Imgd.Sandbox.Executor do
  @moduledoc """
  Executes JavaScript code using QuickJS compiled to WebAssembly.

  This module runs inside the FLAME execution context.
  """

  alias Imgd.Sandbox.{Config, WasmRuntime}

  alias Wasmex.{Pipe, StoreOrCaller}
  alias Wasmex.Wasi.WasiOptions

  @result_prefix "__IMGD_RESULT__"

  @bootstrap_script """
  import * as std from 'std';

  const RESULT_PREFIX = "#{@result_prefix}";

  const encodeResult = (result) => {
    try {
      std.out.puts(RESULT_PREFIX + JSON.stringify(result) + "\\n");
    } catch (err) {
      const fallback = {
        ok: false,
        error: "Failed to encode result: " + String(err && err.message ? err.message : err)
      };
      std.out.puts(RESULT_PREFIX + JSON.stringify(fallback) + "\\n");
    }
  };

  const safeValue = (value) => {
    const seen = new WeakSet();

    const replacer = (_key, val) => {
      if (typeof val === "bigint") return `bigint:${val.toString()}`;
      if (typeof val === "function") return `[Function ${val.name || "anonymous"}]`;
      if (typeof val === "symbol") return val.toString();
      if (val === undefined) return null;
      if (val && typeof val === "object") {
        if (seen.has(val)) return "[Circular]";
        seen.add(val);
      }
      return val;
    };

    try {
      return JSON.parse(JSON.stringify(value, replacer));
    } catch (err) {
      return `[Unserializable: ${err && err.message ? err.message : String(err)}]`;
    }
  };

  const redirectConsole = () => {
    const sink = (...messages) => {
      try {
        std.err.puts(messages.map((value) => String(value)).join(" ") + "\\n");
      } catch (_err) {}
    };

    globalThis.console = {
      log: sink,
      info: sink,
      warn: sink,
      error: sink,
      debug: sink
    };
    globalThis.print = (...messages) => sink(...messages);
  };

  const formatError = (err) => {
    if (!err) return "Unknown error";
    if (typeof err === "object" && err.stack) return String(err.stack);
    return String(err.message || err);
  };

  const main = async () => {
    redirectConsole();

    const payloadEnv = std.getenv("IMGD_PAYLOAD");
    if (!payloadEnv) {
      encodeResult({ ok: false, error: "Missing payload" });
      return;
    }

    let payload;
    try {
      payload = JSON.parse(payloadEnv);
    } catch (err) {
      encodeResult({ ok: false, error: "Invalid payload: " + String(err && err.message ? err.message : err) });
      return;
    }

    if (typeof payload.code !== "string") {
      encodeResult({ ok: false, error: "Payload missing code" });
      return;
    }

    const args = payload.args || {};
    globalThis.args = args;

    try {
      const fn = new Function("args", payload.code);
      let value = fn(args);
      if (value && typeof value.then === "function") {
        value = await value;
      }

      encodeResult({ ok: true, value: safeValue(value) });
    } catch (err) {
      encodeResult({ ok: false, error: formatError(err) });
    }
  };

  main().finally(() => std.exit(0));
  """

  @spec run(String.t(), Config.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def run(code, %Config{} = config) do
    payload = Jason.encode!(%{code: code, args: config.args})

    with {:ok, wasi_options} <- build_wasi_options(payload),
         {:ok, instance} <- WasmRuntime.new_instance(config, wasi_options) do
      try do
        with {:ok, raw} <- execute(instance, config) do
          fuel_used = fuel_consumed(instance.store, config.fuel)
          {:ok, raw, %{fuel_consumed: fuel_used}}
        end
      after
        GenServer.stop(instance.pid)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:execution_error, Exception.message(e)}}
  end

  defp build_wasi_options(payload) do
    with {:ok, stdout} <- Pipe.new(),
         {:ok, stderr} <- Pipe.new() do
      opts = %WasiOptions{
        args: runtime_args(),
        env: %{"IMGD_PAYLOAD" => payload},
        stdout: stdout,
        stderr: stderr
      }

      {:ok, opts}
    else
      {:error, reason} -> {:error, {:wasm_error, reason}}
    end
  end

  defp execute(%{pid: pid, store: _store, stdout: stdout, stderr: stderr}, %Config{
         max_output_size: max_output_size
       }) do
    call_result = Wasmex.call_function(pid, "_start", [])
    stdout_data = read_pipe(stdout)
    stderr_data = read_pipe(stderr)

    result =
      case call_result do
        {:ok, _} ->
          with :ok <- enforce_output_limit_bytes(stdout_data, max_output_size),
               {:ok, output} <- extract_result(stdout_data) do
            {:ok, output}
          end

        {:trap, reason} ->
          {:error, classify_trap(reason)}

        {:error, msg} when is_binary(msg) ->
          {:error, classify_message(msg)}

        {:error, reason} ->
          {:error, {:wasm_error, reason}}
      end

    maybe_attach_logs(result, stdout_data, stderr_data)
  end

  defp runtime_args do
    ["qjs", "-m", "-e", bootstrap_script()]
  end

  defp bootstrap_script do
    @bootstrap_script |> String.trim()
  end

  defp read_pipe(nil), do: ""

  defp read_pipe(pipe) do
    _ = Pipe.seek(pipe, 0)
    Pipe.read(pipe)
  end

  defp enforce_output_limit_bytes(data, max_output_size) when byte_size(data) > max_output_size do
    {:error, {:runtime_error, "Output exceeds max size of #{max_output_size} bytes"}}
  end

  defp enforce_output_limit_bytes(_data, _max_output_size), do: :ok

  defp extract_result(stdout) do
    case :binary.matches(stdout, @result_prefix) do
      [] ->
        {:error, {:runtime_error, "Sandbox output missing result marker"}}

      matches ->
        {idx, _} = List.last(matches)
        start = idx + byte_size(@result_prefix)
        remaining = binary_part(stdout, start, byte_size(stdout) - start)

        json =
          remaining
          |> String.split("\n", parts: 2)
          |> List.first()

        json =
          case json do
            nil -> ""
            value -> String.trim(value)
          end

        if json == "" do
          {:error, {:runtime_error, "Sandbox returned empty result"}}
        else
          {:ok, json}
        end
    end
  end

  defp maybe_attach_logs({:error, {:runtime_error, msg}}, stdout, stderr) do
    details =
      [stdout: stdout, stderr: stderr]
      |> Enum.map(fn {label, data} -> {label, truncate_logs(data)} end)
      |> Enum.filter(fn {_label, data} -> data != "" end)

    if details == [] do
      {:error, {:runtime_error, msg}}
    else
      log_text =
        details
        |> Enum.map(fn {label, data} -> "#{label}: #{data}" end)
        |> Enum.join(" | ")

      {:error, {:runtime_error, "#{msg} (#{log_text})"}}
    end
  end

  defp maybe_attach_logs(other, _stdout, _stderr), do: other

  defp truncate_logs(data) when is_binary(data) do
    trimmed = String.trim(data)

    if byte_size(trimmed) > 500 do
      binary_part(trimmed, 0, 500) <> "..."
    else
      trimmed
    end
  end

  defp truncate_logs(_data), do: ""

  defp fuel_consumed(store, original) do
    case StoreOrCaller.get_fuel(store) do
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
