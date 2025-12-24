defmodule Imgd.Compute.Runner do
  @moduledoc """
  Behaviour for execution strategies.

  A Runner is responsible for executing a given MFA (Module, Function, Args)
  on a specific target type.
  """

  alias Imgd.Compute.Target

  @callback run(Target.t(), module(), atom(), list()) :: {:ok, term()} | {:error, term()}
end
