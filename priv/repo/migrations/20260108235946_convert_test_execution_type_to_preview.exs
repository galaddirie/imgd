defmodule Imgd.Repo.Migrations.ConvertTestExecutionTypeToPreview do
  use Ecto.Migration

  def up do
    execute("UPDATE executions SET execution_type = 'preview' WHERE execution_type = 'test'")
  end

  def down do
    execute("UPDATE executions SET execution_type = 'test' WHERE execution_type = 'preview'")
  end
end
