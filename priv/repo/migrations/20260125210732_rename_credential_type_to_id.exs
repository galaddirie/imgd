defmodule Imgd.Repo.Migrations.RenameCredentialTypeToId do
  use Ecto.Migration

  def change do
    rename table(:credentials), :type, to: :type_id
  end
end
