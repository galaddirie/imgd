defmodule Imgd.Repo.Migrations.RenameRunicLogsToEngineLogs do
  @moduledoc """
  Renames Runic-specific log columns to engine-agnostic names.

  This supports the ExecutionEngine abstraction layer that allows
  swapping the underlying workflow execution engine.
  """
  use Ecto.Migration

  def change do
    # Rename the columns to be engine-agnostic
    rename table(:executions), :runic_build_log, to: :engine_build_log
    rename table(:executions), :runic_reaction_log, to: :engine_execution_log
  end
end
