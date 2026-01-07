defmodule Imgd.Accounts.ApiKeyTest do
  use Imgd.DataCase

  alias Imgd.Accounts
  alias Imgd.Accounts.ApiKey

  import Imgd.AccountsFixtures

  describe "api_keys" do
    test "list_api_keys/1 returns all api_keys for a user" do
      user = user_fixture()
      {:ok, {api_key, _raw}} = Accounts.create_api_key(user, %{name: "Test Key"})
      assert Enum.map(Accounts.list_api_keys(user), & &1.id) == [api_key.id]
    end

    test "create_api_key/2 with valid data creates an api_key" do
      user = user_fixture()

      assert {:ok, {%ApiKey{} = api_key, raw_token}} =
               Accounts.create_api_key(user, %{name: "Test Key"})

      assert String.starts_with?(raw_token, "imgd_")
      assert String.starts_with?(api_key.partial_key, "imgd_")
      assert api_key.name == "Test Key"
      assert api_key.user_id == user.id
      assert api_key.partial_key != nil
      assert byte_size(api_key.hashed_token) == 32

      # Verify hashing
      assert :crypto.hash(:sha256, raw_token) == api_key.hashed_token
    end

    test "get_api_key_by_token/1 returns the api_key and preloads user" do
      user = user_fixture()
      {:ok, {api_key, raw_token}} = Accounts.create_api_key(user, %{name: "Test Key"})

      found_key = Accounts.get_api_key_by_token(raw_token)
      assert found_key.id == api_key.id
      assert found_key.user.id == user.id
    end

    test "delete_api_key/2 deletes the api_key" do
      user = user_fixture()
      {:ok, {api_key, _raw}} = Accounts.create_api_key(user, %{name: "Test Key"})
      assert {:ok, %ApiKey{}} = Accounts.delete_api_key(user, api_key.id)
      assert Accounts.list_api_keys(user) == []
    end

    test "create_api_key/2 with expiry" do
      user = user_fixture()
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      assert {:ok, {api_key, _raw}} =
               Accounts.create_api_key(user, %{name: "Test Key", expires_at: expires_at})

      # Ecto might return with different precision or offset, but since we use utc_datetime it should match
      assert DateTime.diff(api_key.expires_at, expires_at) == 0
    end
  end
end
