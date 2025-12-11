defmodule Imgd.Sandbox.Supervisor do
  @moduledoc false

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    flame_parent = FLAME.Parent.get()
    pool_config = Application.get_env(:imgd, Imgd.Sandbox.Pool, [])
    wasm_opts = wasm_runtime_opts()

    children =
      case wasm_opts do
        {:skip, reason} ->
          Logger.warning("Sandbox disabled", reason: reason)
          []

        opts ->
          [
            {Imgd.Sandbox.WasmRuntime, opts}
          ]
          |> maybe_add_pool(flame_parent, pool_config)
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_add_pool(children, nil, pool_config) do
    [
      {FLAME.Pool,
       name: Imgd.Sandbox.Runner,
       min: Keyword.get(pool_config, :min, 0),
       max: Keyword.get(pool_config, :max, 10),
       max_concurrency: Keyword.get(pool_config, :max_concurrency, 20),
       idle_shutdown_after: Keyword.get(pool_config, :idle_shutdown_after, 30_000)}
      | children
    ]
  end

  defp maybe_add_pool(children, _flame_parent, _pool_config), do: children

  defp wasm_runtime_opts do
    sandbox_config = Application.get_env(:imgd, Imgd.Sandbox, [])
    path = Keyword.fetch!(sandbox_config, :quickjs_wasm_path) |> Path.expand()

    if File.exists?(path) do
      [quickjs_wasm_path: path]
    else
      {:skip, %{missing_quickjs_wasm: path}}
    end
  end
end
