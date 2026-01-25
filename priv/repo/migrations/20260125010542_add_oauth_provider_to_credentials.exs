defmodule Imgd.Repo.Migrations.AddOauthProviderToCredentials do
  use Ecto.Migration

  def change do
    alter table(:credentials) do
      add :oauth_provider_id,
          references(:oauth_providers, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, default: "connected"
      add :account_identifier, :string
    end

    create index(:credentials, [:oauth_provider_id])
  end
end
