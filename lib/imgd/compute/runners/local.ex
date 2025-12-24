defmodule Imgd.Compute.Runners.Local do
  @moduledoc """
  Executes code locally on the current node.
  """

  @behaviour Imgd.Compute.Runner

  @impl true
  def run(_target, module, function, args) do
    try do
      result = apply(module, function, args)
      {:ok, result}
    rescue
      e ->
        {:error, e}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end
end
