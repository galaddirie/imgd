defmodule Imgd.Accounts.ApiKey do
  use Imgd.Schema

  schema "api_keys" do
    field :name, :string
    field :hashed_token, :binary
    field :partial_key, :string
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :user, Imgd.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :expires_at, :last_used_at])
    |> validate_required([:name])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:hashed_token)
  end
end
