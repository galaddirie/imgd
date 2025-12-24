defmodule Imgd.Compute.Dispatcher do
  @moduledoc """
  Dispatches execution to the appropriate runner based on the target.
  """

  alias Imgd.Compute.Target
  alias Imgd.Compute.Runners

  @doc """
  Dispatches the given MFA to the target.
  """
  @spec dispatch(Target.t(), module(), atom(), list()) :: {:ok, term()} | {:error, term()}
  def dispatch(target, module, function, args) do
    runner = resolve_runner(target.type)
    runner.run(target, module, function, args)
  end

  defp resolve_runner(:local), do: Runners.Local
  defp resolve_runner(:compute_node), do: Runners.ComputeNode
  defp resolve_runner(:flame), do: Runners.FlamePool
  defp resolve_runner(_), do: Runners.Local
end
