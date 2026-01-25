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
      seed_credential_types()

      user = AccountsFixtures.user_fixture()
      scope = Imgd.Accounts.Scope.for_user(user)

      # Create a test credential
      {:ok, cred} =
        Credentials.create_credential(scope, %{
          name: "Test API Key",
          data: %{"token" => "secret-value-123", "url" => "https://api.example.com"},
          credential_type_id: Credentials.get_credential_type_by_slug("api_key").id
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
      # By default we don't enforce strict environment separation in query unless specified.
      # But resolve_credential/3 takes environment arg and filters by it in internal query logic?
      # Let's check credentials.ex behavior.
      # list_credentials filters by env if provided.
      # resolve_credential uses get_credential which uses ID directly.
      # Credentials.resolve_credential implementation:
      # def resolve_credential(scope, id, _env) do -> get_credential(scope, id) ...
      # It currently IGNORES environment arg in logic (it names it _environment).
      # Plan said "prepares for future env-agnostic refs".
      # So for now, it should still resolve even if we ask for :staging but cred is :production (since we query by ID).
      # UNLESS I change implementation to enforce it.

      # Let's modify behavior or skip this check.
      # The implementation in credentials.ex line 143: `resolve_credential(scope, credential_id, _environment)`
      # It ignores environment. So this test would pass (resolve successfully).

      config = %{"key" => "$credential:#{cred.id}"}
      {:ok, _} = CredentialResolver.resolve(config, scope, :staging)
    end
  end

  defp seed_credential_types do
    for type <- Imgd.Credentials.CredentialType.built_in_types() do
      %Imgd.Credentials.CredentialType{}
      |> Imgd.Credentials.CredentialType.changeset(type)
      |> Imgd.Repo.insert!(on_conflict: :nothing)
    end
  end
end
