defmodule Imgd.Credentials.CredentialType do
  @moduledoc """
  Schema for credential type definitions.

  Credential types define the structure (field schema) for different kinds of
  credentials - e.g., "openai" requires an api_key, "oauth2" needs tokens, etc.

  Built-in types are seeded at startup and cannot be deleted.
  Users can create custom credential types.
  """
  use Imgd.Schema

  @derive {Jason.Encoder, only: [:id, :slug, :name, :icon, :category, :field_schema, :built_in]}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          slug: String.t(),
          name: String.t(),
          icon: String.t() | nil,
          category: String.t(),
          field_schema: map(),
          built_in: boolean()
        }

  schema "credential_types" do
    field :slug, :string
    field :name, :string
    field :icon, :string
    field :category, :string
    field :field_schema, :map, default: %{}
    field :built_in, :boolean, default: false

    has_many :credentials, Imgd.Credentials.Credential

    timestamps()
  end

  @doc """
  Changeset for creating/updating a credential type.
  """
  def changeset(credential_type, attrs) do
    credential_type
    |> cast(attrs, [:slug, :name, :icon, :category, :field_schema, :built_in])
    |> validate_required([:slug, :name, :category])
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_]*$/,
      message: "must be lowercase alphanumeric with underscores"
    )
    |> unique_constraint(:slug)
  end

  @doc """
  Built-in credential type definitions.
  These are seeded at startup.
  """
  def built_in_types do
    [
      %{
        slug: "api_key",
        name: "API Key",
        icon: "hero-key",
        category: "Authentication",
        field_schema: %{
          "type" => "object",
          "required" => ["api_key"],
          "properties" => %{
            "api_key" => %{"type" => "string", "title" => "API Key", "format" => "password"}
          }
        },
        built_in: true
      },
      %{
        slug: "bearer_token",
        name: "Bearer Token",
        icon: "hero-shield-check",
        category: "Authentication",
        field_schema: %{
          "type" => "object",
          "required" => ["token"],
          "properties" => %{
            "token" => %{"type" => "string", "title" => "Bearer Token", "format" => "password"}
          }
        },
        built_in: true
      },
      %{
        slug: "basic_auth",
        name: "Basic Auth",
        icon: "hero-user",
        category: "Authentication",
        field_schema: %{
          "type" => "object",
          "required" => ["username", "password"],
          "properties" => %{
            "username" => %{"type" => "string", "title" => "Username"},
            "password" => %{"type" => "string", "title" => "Password", "format" => "password"}
          }
        },
        built_in: true
      },
      %{
        slug: "oauth2",
        name: "OAuth2",
        icon: "hero-arrow-path",
        category: "Authentication",
        field_schema: %{
          "type" => "object",
          "required" => ["access_token"],
          "properties" => %{
            "access_token" => %{"type" => "string", "title" => "Access Token"},
            "refresh_token" => %{"type" => "string", "title" => "Refresh Token"},
            "token_type" => %{"type" => "string", "title" => "Token Type"},
            "scope" => %{"type" => "string", "title" => "Scope"}
          }
        },
        built_in: true
      },
      %{
        slug: "openai",
        name: "OpenAI",
        icon: "hero-sparkles",
        category: "AI",
        field_schema: %{
          "type" => "object",
          "required" => ["api_key"],
          "properties" => %{
            "api_key" => %{"type" => "string", "title" => "API Key", "format" => "password"},
            "organization_id" => %{"type" => "string", "title" => "Organization ID"}
          }
        },
        built_in: true
      },
      %{
        slug: "anthropic",
        name: "Anthropic",
        icon: "hero-cpu-chip",
        category: "AI",
        field_schema: %{
          "type" => "object",
          "required" => ["api_key"],
          "properties" => %{
            "api_key" => %{"type" => "string", "title" => "API Key", "format" => "password"}
          }
        },
        built_in: true
      },
      %{
        slug: "custom",
        name: "Custom",
        icon: "hero-wrench-screwdriver",
        category: "Custom",
        field_schema: %{
          "type" => "object",
          "additionalProperties" => true
        },
        built_in: true
      }
    ]
  end
end
