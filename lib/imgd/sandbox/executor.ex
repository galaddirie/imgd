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
  const RESULT_PREFIX = "#{@result_prefix}";

  const writer = globalThis.print || (() => {});
  const log = (...messages) => writer(messages.map((value) => String(value)).join(" "));

  const encodeResult = (result) => {
    try {
      writer(RESULT_PREFIX + JSON.stringify(result));
    } catch (err) {
      const fallback = {
        ok: false,
        error: "Failed to encode result: " + String(err && err.message ? err.message : err)
      };
      writer(RESULT_PREFIX + JSON.stringify(fallback));
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

  const setupConsole = () => {
    const sink = (...messages) => log(...messages);

    globalThis.console = {
      log: sink,
      info: sink,
      warn: sink,
      error: sink,
      debug: sink
    };
  };

  const formatError = (err) => {
    if (!err) return "Unknown error";

    if (typeof err === "object") {
      const message = String(err.message || err);
      if (err.stack) return message + "\\n" + String(err.stack);
      return message;
    }

    return String(err);
  };

  const readPayload = () => {
    const argv = globalThis.scriptArgs || [];
    if (!Array.isArray(argv) || argv.length === 0) return null;
    return argv[argv.length - 1];
  };

  const main = async () => {
    setupConsole();

    const payloadRaw = readPayload();
    if (typeof payloadRaw !== "string") {
      encodeResult({ ok: false, error: "Missing payload" });
      return;
    }

    let payload;
    try {
      payload = JSON.parse(payloadRaw);
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

  main().catch((err) => {
    encodeResult({ ok: false, error: formatError(err) });
  });
  """

  @spec run(String.t(), Config.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def run(code, %Config{} = config) do
    payload = Jason.encode!(%{code: code, args: config.args})

    with {:ok, wasi_options} <- build_wasi_options(payload),
         {:ok, instance} <- WasmRuntime.new_instance(config, wasi_options) do
      try do
      with {:ok, raw, logs} <- execute(instance, config) do
        fuel_used = fuel_consumed(instance.store, config.fuel)
        {:ok, raw, Map.merge(logs, %{fuel_consumed: fuel_used})}
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
        args: runtime_args(payload),
        env: %{},
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
          handle_output(stdout_data, max_output_size)

        {:error, msg} when is_binary(msg) ->
          if proc_exit?(msg) do
            handle_output(stdout_data, max_output_size)
          else
            {:error, classify_message(msg)}
          end

        {:trap, reason} when is_binary(reason) ->
          if proc_exit?(reason) do
            handle_output(stdout_data, max_output_size)
          else
            {:error, classify_trap(reason)}
          end

        {:error, reason} ->
          {:error, {:wasm_error, reason}}
      end

    case result do
      {:ok, output} ->
        {:ok, output, %{stdout: stdout_data, stderr: stderr_data}}

      {:error, reason} ->
        maybe_attach_logs({:error, reason}, stdout_data, stderr_data)
    end
  end

  defp handle_output(stdout_data, max_output_size) do
    with :ok <- enforce_output_limit_bytes(stdout_data, max_output_size),
         {:ok, output} <- extract_result(stdout_data) do
      {:ok, output}
    end
  end

  defp runtime_args(payload) do
    ["qjs", "-m", "-e", bootstrap_script(), "--", payload]
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

  defp proc_exit?(message) when is_binary(message) do
    String.contains?(message, "__wasi_proc_exit")
  end

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
