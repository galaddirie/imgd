defmodule Imgd.Repo.Migrations.RemoveCredentialSystem do
  use Ecto.Migration

  def up do
    drop_if_exists table(:credential_audit_logs)
    drop_if_exists table(:credentials)
    drop_if_exists table(:credential_types)
    drop_if_exists table(:oauth_providers)
  end

  def down do
    raise "Irreversible migration: credential system tables were removed"
  end
end
