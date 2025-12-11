defmodule Imgd.Sandbox.WasmRuntime do
  @moduledoc """
  Manages QuickJS WebAssembly instances.

  Handles compilation, instantiation, and provides pre-compiled modules for fast startup.
  """

  use GenServer

  alias Wasmex.{Engine, EngineConfig, Store, StoreLimits, StoreOrCaller}
  alias Wasmex.Module, as: WasmModule

  defstruct [:engine, :compiled_module]

  @type t :: %__MODULE__{
          engine: Engine.t(),
          compiled_module: WasmModule.t()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new Wasm instance configured with the given limits.
  """
  @spec new_instance(pos_integer(), pos_integer()) ::
          {:ok, pid(), StoreOrCaller.t()} | {:error, term()}
  def new_instance(fuel, memory_mb) when is_integer(fuel) and is_integer(memory_mb) do
    GenServer.call(__MODULE__, {:new_instance, fuel, memory_mb})
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
            "QuickJS wasm not found at #{wasm_path}. Download or place quickjs.wasm there."
    end

    engine_config = %EngineConfig{
      consume_fuel: true,
      cranelift_opt_level: :speed
    }

    with {:ok, engine} <- Engine.new(engine_config),
         {:ok, store} <- Store.new(nil, engine),
         {:ok, bytes} <- File.read(wasm_path),
         {:ok, compiled_module} <- WasmModule.compile(store, bytes) do
      {:ok, %__MODULE__{engine: engine, compiled_module: compiled_module}}
    else
      {:error, reason} -> {:stop, {:wasm_init_failed, reason}}
      {:error, _store, reason} -> {:stop, {:wasm_init_failed, reason}}
      {:error, _a, _b, reason} -> {:stop, {:wasm_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:new_instance, fuel, memory_mb}, _from, %__MODULE__{} = state) do
    limits = %StoreLimits{
      memory_size: memory_mb * 1024 * 1024,
      instances: 1,
      tables: 100,
      memories: 1
    }

    with {:ok, store} <- Store.new(limits, state.engine),
         :ok <- StoreOrCaller.set_fuel(store, fuel),
         {:ok, pid} <- Wasmex.start_link(%{store: store, module: state.compiled_module}) do
      {:reply, {:ok, pid, store}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end
end
