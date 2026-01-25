defmodule Imgd.CredentialsTest do
  use Imgd.DataCase

  alias Imgd.Credentials
  alias Imgd.Credentials.{CredentialType, Encryption, AuditLog}
  alias Imgd.Accounts.Scope

  import Imgd.AccountsFixtures

  setup do
    # Ensure built-in types exist
    seed_credential_types()

    # Create a user and scope
    user = user_fixture()
    scope = Scope.for_user(user)

    %{user: user, scope: scope}
  end

  defp seed_credential_types do
    types =
      CredentialType.built_in_types() ++
        [
          %{
            slug: "z_searchable_api",
            name: "Z Searchable API",
            icon: "hero-star",
            category: "Integration",
            field_schema: %{},
            built_in: false
          }
        ]

    for type <- types do
      %CredentialType{}
      |> CredentialType.changeset(type)
      |> Imgd.Repo.insert!(on_conflict: :nothing)
    end
  end

  describe "credential types" do
    test "list_credential_types/1 filters by search" do
      # Should find "OpenAI"
      results = Credentials.list_credential_types(search: "open")
      assert Enum.any?(results, &(&1.name == "OpenAI"))

      # Should not find random string
      results = Credentials.list_credential_types(search: "xyzabc")
      assert results == []

      # Should find by category
      results = Credentials.list_credential_types(search: "Integration")
      assert Enum.any?(results, &(&1.name == "Z Searchable API"))
    end

    test "list_credential_types/1 limits results" do
      # We have enough built-in types to test limit
      results = Credentials.list_credential_types(limit: 2)
      assert length(results) == 2
    end

    test "list_credential_types/1 filters by category" do
      results = Credentials.list_credential_types(category: "AI")
      assert length(results) > 0
      assert Enum.all?(results, &(&1.category == "AI"))
    end
  end

  describe "encryption" do
    test "encrypts and decrypts maps correctly" do
      data = %{"api_key" => "sk-12345", "meta" => "valid"}

      assert {:ok, encrypted} = Encryption.encrypt(data)
      assert is_binary(encrypted)
      assert byte_size(encrypted) > 0

      # Should not overlap with plaintext (basic sanity check)
      refute String.contains?(encrypted, "sk-12345")

      assert {:ok, decrypted} = Encryption.decrypt(encrypted)
      assert decrypted == data
    end
  end

  describe "credentials crud" do
    test "list_credentials/2 returns empty list initially", %{scope: scope} do
      assert Credentials.list_credentials(scope) == []
    end

    test "create_credential/2 creates a valid credential", %{scope: scope} do
      type_id = get_type_id("openai")

      attrs = %{
        name: "My OpenAI Key",
        data: %{"api_key" => "sk-test-123"},
        credential_type_id: type_id
      }

      assert {:ok, credential} = Credentials.create_credential(scope, attrs)
      assert credential.name == "My OpenAI Key"
      assert credential.user_id == scope.user.id
      assert credential.encrypted_data

      # Database check
      from_db = Repo.get!(Imgd.Credentials.Credential, credential.id)
      assert from_db.encrypted_data == credential.encrypted_data

      # Verify audit log
      log = Repo.one(AuditLog)
      assert log.credential_id == credential.id
      assert log.action == :created
    end

    test "list_credentials/2 filters by user", %{scope: scope} do
      type_id = get_type_id("api_key")

      {:ok, _c1} =
        Credentials.create_credential(scope, %{
          name: "My Key",
          data: %{"k" => "v"},
          credential_type_id: type_id
        })

      # Another user
      other_user = user_fixture()
      other_scope = Scope.for_user(other_user)

      {:ok, _c2} =
        Credentials.create_credential(other_scope, %{
          name: "Other Key",
          data: %{"k" => "v"},
          credential_type_id: type_id
        })

      my_creds = Credentials.list_credentials(scope)
      assert length(my_creds) == 1
      assert hd(my_creds).name == "My Key"
    end
  end

  describe "resolution" do
    test "resolve_credential/3 decrypts data", %{scope: scope} do
      type_id = get_type_id("openai")
      secret_data = %{"api_key" => "sk-secret-value"}

      {:ok, cred} =
        Credentials.create_credential(scope, %{
          name: "Secret Key",
          data: secret_data,
          credential_type_id: type_id
        })

      assert {:ok, resolved} = Credentials.resolve_credential(scope, cred.id, :production)
      assert resolved.data == secret_data

      # Verify audit log for access
      logs =
        Repo.all(
          from l in AuditLog, where: l.credential_id == ^cred.id, order_by: [asc: l.inserted_at]
        )

      # created + accessed
      assert length(logs) == 2
      assert List.last(logs).action == :accessed
    end

    test "resolve_credential/3 denies access to other users", %{scope: scope} do
      other_user = user_fixture()
      other_scope = Scope.for_user(other_user)
      type_id = get_type_id("openai")

      {:ok, cred} =
        Credentials.create_credential(other_scope, %{
          name: "Other's Key",
          data: %{"k" => "v"},
          credential_type_id: type_id
        })

      assert {:error, :not_found} = Credentials.resolve_credential(scope, cred.id, :production)
    end
  end

  defp get_type_id(slug) do
    Repo.get_by!(CredentialType, slug: slug).id
  end
end
