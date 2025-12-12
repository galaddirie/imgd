defmodule Imgd.Sandbox.WasmRuntime do
  @moduledoc """
  Manages QuickJS WebAssembly instances.

  Handles compilation, instantiation, and provides pre-compiled modules for fast startup.
  """

  use GenServer

  alias Imgd.Sandbox.Config

  alias Wasmex.{Engine, EngineConfig, Pipe, Store, StoreLimits, StoreOrCaller}
  alias Wasmex.Module, as: WasmModule
  alias Wasmex.Wasi.WasiOptions

  @engine_key {__MODULE__, :engine}
  @module_key {__MODULE__, :compiled_module}

  defstruct [:engine, :compiled_module]

  @type t :: %__MODULE__{
          engine: Engine.t(),
          compiled_module: WasmModule.t()
        }

  @type instance_handles :: %{
          pid: pid(),
          store: StoreOrCaller.t(),
          stdout: Pipe.t() | nil,
          stderr: Pipe.t() | nil
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new Wasm instance configured with the given limits.
  """
  @spec new_instance(Config.t(), WasiOptions.t()) ::
          {:ok, instance_handles()} | {:error, term()}
  def new_instance(%Config{} = config, %WasiOptions{} = wasi_options) do
    case runtime_resources() do
      {:ok, engine, compiled_module} ->
        create_instance(engine, compiled_module, config, wasi_options)

      :error ->
        GenServer.call(__MODULE__, {:new_instance, config, wasi_options})
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    wasm_path =
      opts
      |> Keyword.fetch!(:quickjs_wasm_path)
      |> Path.expand()

    unless File.exists?(wasm_path) do
      raise ArgumentError,
            "QuickJS wasm not found at #{wasm_path}. Place qjs-wasi.wasm there or set QJS_WASM_PATH."
    end

    engine_config = %EngineConfig{
      consume_fuel: true,
      cranelift_opt_level: :speed
    }

    with {:ok, engine} <- Engine.new(engine_config),
         {:ok, store} <- Store.new(nil, engine),
         {:ok, bytes} <- File.read(wasm_path),
         {:ok, compiled_module} <- WasmModule.compile(store, bytes) do
      :persistent_term.put(@engine_key, engine)
      :persistent_term.put(@module_key, compiled_module)
      {:ok, %__MODULE__{engine: engine, compiled_module: compiled_module}}
    else
      {:error, reason} -> {:stop, {:wasm_init_failed, reason}}
      {:error, _store, reason} -> {:stop, {:wasm_init_failed, reason}}
      {:error, _a, _b, reason} -> {:stop, {:wasm_init_failed, reason}}
    end
  end

  @impl true
  def handle_call(
        {:new_instance, %Config{} = config, %WasiOptions{} = wasi_options},
        _from,
        %__MODULE__{} = state
      ) do
    case create_instance(state.engine, state.compiled_module, config, wasi_options) do
      {:ok, handles} -> {:reply, {:ok, handles}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp runtime_resources do
    try do
      engine = :persistent_term.get(@engine_key)
      compiled_module = :persistent_term.get(@module_key)
      {:ok, engine, compiled_module}
    catch
      :error, _ -> :error
    end
  end

  defp create_instance(engine, compiled_module, %Config{} = config, %WasiOptions{} = wasi_options) do
    limits = %StoreLimits{
      memory_size: config.memory_mb * 1024 * 1024,
      instances: 1,
      tables: 100,
      memories: 1
    }

    with {:ok, store} <- Store.new_wasi(wasi_options, limits, engine),
         :ok <- StoreOrCaller.set_fuel(store, config.fuel),
         {:ok, pid} <- Wasmex.start_link(%{store: store, module: compiled_module}) do
      handles = %{
        pid: pid,
        store: store,
        stdout: Map.get(wasi_options, :stdout),
        stderr: Map.get(wasi_options, :stderr)
      }

      {:ok, handles}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
