defmodule Imgd.Repo.Migrations.CreateOauthProviders do
  use Ecto.Migration

  def change do
    create table(:oauth_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_slug, :string, null: false
      add :name, :string, null: false
      add :client_id, :string, null: false
      add :encrypted_client_secret, :binary, null: false
      add :authorization_url, :string
      add :token_url, :string
      add :scopes, {:array, :string}, default: []
      add :metadata, :map, default: %{}
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:oauth_providers, [:user_id])
    create unique_index(:oauth_providers, [:user_id, :name])
  end
end
