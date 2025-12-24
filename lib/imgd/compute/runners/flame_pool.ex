defmodule Imgd.Compute.Runners.FlamePool do
  @moduledoc """
  Executes code via FLAME (Elastic Compute).
  """

  @behaviour Imgd.Compute.Runner

  require Logger

  @impl true
  def run(target, module, function, args) do
    pool_name = String.to_atom(target.id)

    # Wrap the MFA call in a lambda for FLAME
    # FLAME.call/3 expects (pool, func, opts)

    try do
      result =
        FLAME.call(pool_name, fn ->
          apply(module, function, args)
        end)

      {:ok, result}
    rescue
      e ->
        {:error, {:flame_error, e}}
    catch
      kind, reason ->
        {:error, {:flame_exit, {kind, reason}}}
    end
  end
end
