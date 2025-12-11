defmodule Imgd.Sandbox do
  @moduledoc """
  A secure JavaScript sandbox powered by QuickJS and WebAssembly.

  Executes JS inside a Wasm sandbox with fuel and memory limits, orchestrated via FLAME.
  """

  alias Imgd.Sandbox.{Config, Validator, Executor, Result, Error, Telemetry}

  @type eval_opts :: [
          args: map(),
          timeout: pos_integer(),
          fuel: pos_integer(),
          memory_mb: pos_integer()
        ]

  @spec eval(String.t(), eval_opts()) :: {:ok, term()} | {:error, Error.t()}
  def eval(code, opts \\ []) when is_binary(code) do
    config = Config.build(opts)
    metadata = %{code_size: byte_size(code)}

    Telemetry.span([:sandbox, :eval], metadata, fn ->
      result = do_eval(code, config)

      {final_result, status_meta} =
        case result do
          {:ok, value, metrics} ->
            {{:ok, value}, %{status: :ok, fuel_consumed: metrics[:fuel_consumed]}}

          {:error, error} ->
            {{:error, error}, %{status: :error}}
        end

      {final_result, status_meta}
    end)
  end

  defp do_eval(code, config) do
    with :ok <- ensure_runtime_available(config),
         :ok <- ensure_pool_running(),
         :ok <- Validator.validate_code(code, config),
         :ok <- Validator.validate_args(config.args),
         {:ok, raw, metrics} <- execute_in_flame(code, config),
         {:ok, result} <- Result.parse(raw) do
      {:ok, result, metrics}
    else
      {:error, reason} -> {:error, Error.wrap(reason)}
    end
  end

  defp execute_in_flame(code, config) do
    FLAME.call(
      Imgd.Sandbox.Runner,
      fn ->
        Executor.run(code, config)
      end,
      timeout: config.timeout
    )
  catch
    :exit, {:timeout, _} -> {:error, {:timeout, config.timeout}}
    :exit, reason -> {:error, {:flame_error, reason}}
  end

  defp ensure_runtime_available(%Config{quickjs_wasm_path: path}) do
    if File.exists?(path) do
      :ok
    else
      {:error, {:validation_error, "qjs-wasi.wasm not found at #{path}"}}
    end
  end

  defp ensure_pool_running do
    if Process.whereis(Imgd.Sandbox.Runner) do
      :ok
    else
      {:error, {:validation_error, "Sandbox pool is not running"}}
    end
  end

  @spec eval!(String.t(), eval_opts()) :: term()
  def eval!(code, opts \\ []) do
    case eval(code, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
