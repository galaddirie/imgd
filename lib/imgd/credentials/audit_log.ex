defmodule Imgd.Credentials.AuditLog do
  @moduledoc """
  Audit log for credential operations.

  Tracks all access and modifications to credentials for security compliance.
  Logs are append-only - no UPDATE or DELETE operations are exposed.
  """
  use Imgd.Schema

  alias Imgd.Credentials.Credential
  alias Imgd.Accounts.User

  @actions [:created, :accessed, :updated, :deleted, :rotated, :oauth_refreshed]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          action: atom(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          metadata: map()
        }

  schema "credential_audit_logs" do
    field :action, Ecto.Enum, values: @actions
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}

    belongs_to :credential, Credential
    belongs_to :user, User

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating an audit log entry.
  """
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [:action, :ip_address, :user_agent, :metadata, :credential_id, :user_id])
    |> validate_required([:action, :credential_id])
    |> foreign_key_constraint(:credential_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Creates an audit log struct for a credential operation.
  """
  def build(credential, user, action, opts \\ []) do
    %__MODULE__{
      credential_id: credential.id,
      user_id: user && user.id,
      action: action,
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
