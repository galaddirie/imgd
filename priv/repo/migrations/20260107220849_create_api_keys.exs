defmodule Imgd.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :hashed_token, :binary, null: false
      add :partial_key, :string, null: false
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      timestamps()
    end

    create index(:api_keys, [:user_id])
    create unique_index(:api_keys, [:hashed_token])
  end
end
