defmodule Imgd.Repo.Migrations.AddDomainRestrictionToCredentials do
  use Ecto.Migration

  def change do
    alter table(:credentials) do
      # Domain restriction type: "all" (default), "specific", or "none"
      add :domain_restriction, :string, null: false, default: "all"

      # Regex pattern for allowed domains (only used when domain_restriction is "specific")
      add :allowed_domains_pattern, :string
    end
  end
end
