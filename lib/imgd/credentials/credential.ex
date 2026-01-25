defmodule Imgd.Credentials.Credential do
  @moduledoc """
  Schema for user credentials with encrypted storage.

  Sensitive credential data (API keys, tokens, etc.) is stored encrypted.
  The `data` virtual field is populated only when explicitly decrypted
  for runtime resolution - it is never persisted or returned in API responses.

  ## OAuth Credentials

  OAuth credentials store their own client configuration (client_id, client_secret)
  in the encrypted_data blob alongside tokens. This enables a unified credential
  creation flow similar to n8n.

  ## Example

      %Credential{
        name: "My Google Account",
        oauth_provider_slug: :google,
        oauth_scopes: ["email", "profile"],
        credential_type: %CredentialType{slug: "google"},
        # encrypted_data holds client_id, client_secret, tokens
        # data is virtual, populated only during resolution
      }
  """
  use Imgd.Schema

  alias Imgd.Credentials.{CredentialType, Encryption, AuditLog}
  alias Imgd.Accounts.User

  @oauth_provider_slugs [:google, :github, :slack, :custom]
  @statuses [:connected, :needs_reconnect, :expired, :error]
  @domain_restrictions [:all, :specific, :none]

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :status,
             :account_identifier,
             :domain_restriction,
             :allowed_domains_pattern,
             :oauth_provider_slug,
             :oauth_scopes,
             :metadata,
             :last_used_at,
             :expires_at,
             :credential_type_id,
             :inserted_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          status: atom(),
          account_identifier: String.t() | nil,
          domain_restriction: atom(),
          allowed_domains_pattern: String.t() | nil,
          oauth_provider_slug: atom() | nil,
          authorization_url: String.t() | nil,
          token_url: String.t() | nil,
          oauth_scopes: [String.t()],
          encrypted_data: binary(),
          metadata: map(),
          last_used_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          data: map() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          credential_type: CredentialType.t() | Ecto.Association.NotLoaded.t()
        }

  schema "credentials" do
    field :name, :string
    field :status, Ecto.Enum, values: @statuses, default: :connected
    field :account_identifier, :string
    field :domain_restriction, Ecto.Enum, values: @domain_restrictions, default: :all
    field :allowed_domains_pattern, :string
    field :encrypted_data, :binary
    field :metadata, :map, default: %{}
    field :last_used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    # OAuth-specific fields (nil for non-OAuth credentials)
    field :oauth_provider_slug, Ecto.Enum, values: @oauth_provider_slugs
    field :authorization_url, :string
    field :token_url, :string
    field :oauth_scopes, {:array, :string}, default: []

    # Virtual field - never persisted, populated only during resolution
    field :data, :map, virtual: true

    belongs_to :user, User
    belongs_to :credential_type, CredentialType
    has_many :audit_logs, AuditLog

    timestamps()
  end

  @doc """
  Returns the list of supported OAuth provider slugs.
  """
  def oauth_provider_slugs, do: @oauth_provider_slugs

  @doc """
  Returns true if this credential is an OAuth credential.
  """
  @spec oauth_credential?(t()) :: boolean()
  def oauth_credential?(%__MODULE__{oauth_provider_slug: slug}) when not is_nil(slug), do: true
  def oauth_credential?(_), do: false

  @doc """
  Changeset for creating a credential.
  Encrypts the `data` field into `encrypted_data`.
  """
  def create_changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :name,
      :status,
      :account_identifier,
      :domain_restriction,
      :allowed_domains_pattern,
      :oauth_provider_slug,
      :authorization_url,
      :token_url,
      :oauth_scopes,
      :metadata,
      :expires_at,
      :user_id,
      :credential_type_id
    ])
    |> validate_required([:name, :user_id, :credential_type_id])
    |> unique_constraint([:user_id, :name])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:credential_type_id)
    |> validate_future_expiration()
    |> validate_domain_restriction()
    |> validate_custom_oauth_provider()
    |> validate_against_schema(attrs)
    |> encrypt_data(attrs)
  end

  @doc """
  Changeset for updating a credential.
  If `data` is provided, re-encrypts it.
  """
  def update_changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :name,
      :status,
      :account_identifier,
      :domain_restriction,
      :allowed_domains_pattern,
      :oauth_provider_slug,
      :authorization_url,
      :token_url,
      :oauth_scopes,
      :metadata,
      :expires_at
    ])
    |> unique_constraint([:user_id, :name])
    |> validate_future_expiration()
    |> validate_domain_restriction()
    |> validate_custom_oauth_provider()
    |> maybe_validate_against_schema(credential, attrs)
    |> maybe_encrypt_data(attrs)
  end

  @doc """
  Changeset for updating last_used_at timestamp.
  """
  def touch_changeset(credential) do
    credential
    |> change(last_used_at: DateTime.utc_now())
  end

  # Encrypts the data field from attrs
  defp encrypt_data(changeset, attrs) do
    data = Map.get(attrs, :data) || Map.get(attrs, "data")

    if is_map(data) do
      case Encryption.encrypt(data) do
        {:ok, encrypted} ->
          put_change(changeset, :encrypted_data, encrypted)

        {:error, reason} ->
          add_error(changeset, :data, "encryption failed: #{inspect(reason)}")
      end
    else
      add_error(changeset, :data, "is required")
    end
  end

  # Only encrypt if data is provided
  defp maybe_encrypt_data(changeset, attrs) do
    data = Map.get(attrs, :data) || Map.get(attrs, "data")

    if is_map(data) do
      case Encryption.encrypt(data) do
        {:ok, encrypted} ->
          put_change(changeset, :encrypted_data, encrypted)

        {:error, reason} ->
          add_error(changeset, :data, "encryption failed: #{inspect(reason)}")
      end
    else
      changeset
    end
  end

  @doc """
  Decrypts the credential's encrypted_data and populates the virtual `data` field.
  Returns `{:ok, credential_with_data}` or `{:error, reason}`.
  """
  @spec decrypt(t()) :: {:ok, t()} | {:error, term()}
  def decrypt(%__MODULE__{encrypted_data: encrypted} = credential) when is_binary(encrypted) do
    case Encryption.decrypt(encrypted) do
      {:ok, data} ->
        {:ok, %{credential | data: data}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decrypt(%__MODULE__{encrypted_data: nil}) do
    {:error, :no_encrypted_data}
  end

  @doc """
  Checks if the given domain is allowed by this credential's domain restriction.
  Returns `true` if the domain is allowed, `false` otherwise.
  """
  @spec domain_allowed?(t(), String.t()) :: boolean()
  def domain_allowed?(%__MODULE__{domain_restriction: :all}, _domain), do: true
  def domain_allowed?(%__MODULE__{domain_restriction: :none}, _domain), do: false

  def domain_allowed?(
        %__MODULE__{domain_restriction: :specific, allowed_domains_pattern: nil},
        _domain
      ),
      do: false

  def domain_allowed?(
        %__MODULE__{domain_restriction: :specific, allowed_domains_pattern: pattern},
        domain
      ) do
    case Regex.compile(pattern, [:caseless]) do
      {:ok, regex} -> Regex.match?(regex, domain)
      {:error, _} -> false
    end
  end

  @doc """
  Returns the list of valid domain restriction options.
  """
  def domain_restrictions, do: @domain_restrictions

  # Validation helpers

  defp validate_custom_oauth_provider(changeset) do
    provider_slug = get_field(changeset, :oauth_provider_slug)

    if provider_slug == :custom do
      changeset
      |> validate_required([:authorization_url, :token_url],
        message: "is required for custom OAuth providers"
      )
      |> validate_url(:authorization_url)
      |> validate_url(:token_url)
    else
      changeset
    end
  end

  defp validate_url(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      url ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            changeset

          _ ->
            add_error(changeset, field, "must be a valid HTTP(S) URL")
        end
    end
  end

  defp validate_domain_restriction(changeset) do
    domain_restriction = get_field(changeset, :domain_restriction)
    allowed_domains_pattern = get_change(changeset, :allowed_domains_pattern)

    changeset
    |> validate_pattern_required_for_specific(domain_restriction)
    |> validate_regex_pattern(allowed_domains_pattern)
  end

  defp validate_pattern_required_for_specific(changeset, :specific) do
    pattern = get_field(changeset, :allowed_domains_pattern)

    if is_nil(pattern) || pattern == "" do
      add_error(
        changeset,
        :allowed_domains_pattern,
        "is required when domain restriction is 'specific'"
      )
    else
      changeset
    end
  end

  defp validate_pattern_required_for_specific(changeset, _), do: changeset

  defp validate_regex_pattern(changeset, nil), do: changeset
  defp validate_regex_pattern(changeset, ""), do: changeset

  defp validate_regex_pattern(changeset, pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, _} ->
        changeset

      {:error, {reason, _}} ->
        add_error(changeset, :allowed_domains_pattern, "is not a valid regex: #{reason}")
    end
  end

  defp validate_future_expiration(changeset) do
    case get_change(changeset, :expires_at) do
      nil ->
        changeset

      expires_at ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          add_error(changeset, :expires_at, "must be in the future")
        else
          changeset
        end
    end
  end

  defp validate_against_schema(changeset, attrs) do
    credential_type_id = get_field(changeset, :credential_type_id)
    data = Map.get(attrs, :data) || Map.get(attrs, "data")

    if credential_type_id && is_map(data) do
      case Imgd.Repo.get(CredentialType, credential_type_id) do
        nil ->
          changeset

        credential_type ->
          do_validate_schema(changeset, credential_type.field_schema, data)
      end
    else
      changeset
    end
  end

  defp maybe_validate_against_schema(changeset, credential, attrs) do
    data = Map.get(attrs, :data) || Map.get(attrs, "data")

    if is_map(data) do
      # Load credential type if not already loaded
      credential = Imgd.Repo.preload(credential, :credential_type)

      if credential.credential_type do
        do_validate_schema(changeset, credential.credential_type.field_schema, data)
      else
        changeset
      end
    else
      changeset
    end
  end

  defp do_validate_schema(changeset, field_schema, data) do
    # Only validate if schema has properties defined AND validation is enabled
    # Schema validation is opt-in to maintain backward compatibility
    validate_schemas = Application.get_env(:imgd, :validate_credential_schemas, false)

    if validate_schemas && (field_schema["properties"] || field_schema["required"]) do
      # JSV requires a compiled schema (Root struct) using build!
      try do
        compiled_schema = JSV.build!(field_schema)

        case JSV.validate(data, compiled_schema) do
          {:ok, _} ->
            changeset

          {:error, errors} ->
            error_msg = format_schema_errors(errors)
            add_error(changeset, :data, "does not match schema: #{error_msg}")
        end
      rescue
        e ->
          # Schema compilation failed - log but don't fail the changeset
          require Logger
          Logger.warning("Failed to compile credential field schema: #{inspect(e)}")
          changeset
      end
    else
      changeset
    end
  end

  defp format_schema_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{message: msg} -> msg
      %{"message" => msg} -> msg
      error -> inspect(error)
    end)
    |> Enum.join(", ")
  end

  defp format_schema_errors(error), do: inspect(error)
end
