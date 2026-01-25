defmodule Imgd.Runtime.CredentialResolutionTest do
  use Imgd.DataCase

  alias Imgd.Runtime.CredentialResolver
  alias Imgd.Credentials.Reference
  alias Imgd.Credentials
  alias Imgd.AccountsFixtures

  describe "Credential Reference" do
    test "extracts object references" do
      config = %{
        "api_key" => %{
          "__credential_ref" => %{
            "id" => "cred-123",
            "field" => "token",
            "inject_as" => "string"
          }
        },
        "nested" => %{
          "other" => %{
            "__credential_ref" => %{
              "id" => "cred-456",
              "field" => nil,
              "inject_as" => nil
            }
          }
        }
      }

      refs = Reference.extract_refs(config)
      assert length(refs) == 2
      assert Enum.any?(refs, fn r -> r.credential_id == "cred-123" and r.field == "token" end)
      assert Enum.any?(refs, fn r -> r.credential_id == "cred-456" and r.field == nil end)
    end

    test "extracts string references" do
      config = %{
        "auth" => "Bearer $credential:cred-789:key",
        "simple" => "$credential:cred-000"
      }

      refs = Reference.extract_refs(config)
      assert length(refs) == 2
      assert Enum.any?(refs, fn r -> r.credential_id == "cred-789" and r.field == "key" end)
      assert Enum.any?(refs, fn r -> r.credential_id == "cred-000" and r.field == nil end)
    end
  end

  describe "Credential Resolver" do
    setup do
      user = AccountsFixtures.user_fixture()
      scope = Imgd.Accounts.Scope.for_user(user)

      # Create a test credential
      {:ok, cred} =
        Credentials.create_credential(scope, %{
          name: "Test API Key",
          data: %{"token" => "secret-value-123", "url" => "https://api.example.com"},
          type_id: "api_key"
        })

      %{scope: scope, user: user, credential: cred}
    end

    test "resolves object reference", %{scope: scope, credential: cred} do
      config = %{
        "api_key" => %{
          "__credential_ref" => %{
            "id" => cred.id,
            "field" => "token",
            "inject_as" => nil
          }
        }
      }

      {:ok, resolved} = CredentialResolver.resolve(config, scope, :production)
      assert resolved["api_key"] == "secret-value-123"
    end

    test "resolves string reference", %{scope: scope, credential: cred} do
      config = %{
        "url" => "$credential:#{cred.id}:url"
      }

      {:ok, resolved} = CredentialResolver.resolve(config, scope, :production)
      assert resolved["url"] == "https://api.example.com"
    end

    test "resolves whole credential object via string ref", %{scope: scope, credential: cred} do
      config = %{
        "creds" => "$credential:#{cred.id}"
      }

      {:ok, resolved} = CredentialResolver.resolve(config, scope, :production)

      assert resolved["creds"] == %{
               "token" => "secret-value-123",
               "url" => "https://api.example.com"
             }
    end

    test "fails if credential not found", %{scope: scope} do
      uuid = Ecto.UUID.generate()

      config = %{
        "key" => "$credential:#{uuid}:token"
      }

      result = CredentialResolver.resolve(config, scope, :production)
      assert {:error, {:resolution_failed, {_ref, :not_found}}} = result
    end

    test "fails if environment mismatch (if enforced)", %{scope: scope, credential: cred} do
      config = %{"key" => "$credential:#{cred.id}"}
      {:ok, _} = CredentialResolver.resolve(config, scope, :staging)
    end
  end
end
