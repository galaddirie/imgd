defmodule Imgd.Compute.Runners.ComputeNode do
  @moduledoc """
  Executes code on a specific remote node in the cluster.
  """

  @behaviour Imgd.Compute.Runner

  require Logger

  @impl true
  def run(target, module, function, args) do
    node_name = String.to_atom(target.id)

    if node_name == Node.self() do
      apply(module, function, args)
      |> wrap_ok()
    else
      do_run(node_name, module, function, args)
    end
  end

  defp do_run(node_name, module, function, args) do
    # Use :erpc.call for better error handling and monitor support
    # (Available since OTP 23)
    try do
      result = :erpc.call(node_name, module, function, args)
      {:ok, result}
    rescue
      e in ErlangError ->
        # :erpc.call raises ErlangError on remote exception
        {:error, {:remote_execution_failed, e}}
    catch
      :exit, reason ->
        {:error, {:remote_node_down, reason}}
    end
  end

  defp wrap_ok({:ok, _} = res), do: res
  defp wrap_ok({:error, _} = res), do: res
  defp wrap_ok(res), do: {:ok, res}
end
