defmodule Imgd.Repo.Migrations.MergeOauthIntoCredentials do
  @moduledoc """
  Merges OAuth provider configuration directly into credentials, removing the
  separate oauth_providers table. This simplifies the UX by letting users create
  OAuth credentials in a single unified flow (like n8n).

  Each OAuth credential now stores its own client_id/client_secret in the
  encrypted_data blob alongside tokens.
  """
  use Ecto.Migration

  def change do
    # Step 1: Add new OAuth fields to credentials table
    alter table(:credentials) do
      # OAuth provider type (google, github, slack, custom)
      add :oauth_provider_slug, :string

      # Custom OAuth endpoints (for custom providers)
      add :authorization_url, :string
      add :token_url, :string

      # OAuth scopes as array
      add :oauth_scopes, {:array, :string}, default: []
    end

    # Step 2: Remove the environment column and update unique constraint
    # First drop the old unique constraint
    drop_if_exists unique_index(:credentials, [:user_id, :name, :environment])
    drop_if_exists index(:credentials, [:user_id, :environment])

    # Add new unique constraint without environment
    create unique_index(:credentials, [:user_id, :name])

    # Step 3: Remove environment column
    alter table(:credentials) do
      remove :environment, :string, default: "production"
    end

    # Step 4: Remove oauth_provider_id FK
    drop_if_exists index(:credentials, [:oauth_provider_id])

    alter table(:credentials) do
      remove :oauth_provider_id, references(:oauth_providers, type: :binary_id)
    end

    # Step 5: Drop the oauth_providers table
    drop_if_exists table(:oauth_providers)

    # Add index for oauth provider slug
    create index(:credentials, [:oauth_provider_slug])
  end
end
