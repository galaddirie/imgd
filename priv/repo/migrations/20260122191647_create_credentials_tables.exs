defmodule Imgd.Repo.Migrations.CreateCredentialsTables do
  use Ecto.Migration

  def change do
    # Credential types define the schema for different credential kinds
    create table(:credential_types, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :icon, :string
      add :category, :string, null: false
      add :field_schema, :map, null: false, default: %{}
      add :built_in, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credential_types, [:slug])
    create index(:credential_types, [:category])

    # User credentials with encrypted data
    create table(:credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :environment, :string, null: false, default: "production"
      add :encrypted_data, :binary, null: false
      add :metadata, :map, default: %{}
      add :last_used_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :credential_type_id,
          references(:credential_types, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credentials, [:user_id])
    create index(:credentials, [:credential_type_id])
    create index(:credentials, [:user_id, :environment])
    create unique_index(:credentials, [:user_id, :name, :environment])

    # Audit log for credential operations
    create table(:credential_audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :string, null: false
      add :ip_address, :string
      add :user_agent, :string
      add :metadata, :map, default: %{}

      add :credential_id, references(:credentials, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:credential_audit_logs, [:credential_id])
    create index(:credential_audit_logs, [:user_id])
    create index(:credential_audit_logs, [:inserted_at])
  end
end
