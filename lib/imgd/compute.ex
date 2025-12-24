defmodule Imgd.Compute do
  @moduledoc """
  Context for Compute-Aware Execution.

  Handles dispatching work to different compute targets (Local, ComputeNode, FLAME).
  """

  alias Imgd.Compute.Dispatcher
  alias Imgd.Compute.Target

  @doc """
  Runs the given MFA on the specified target.

  Target can be a `Target` struct or a map/keyword list that can be parsed into one.
  """
  def run(target, module, function, args) do
    target = Target.parse(target)
    Dispatcher.dispatch(target, module, function, args)
  end
end
