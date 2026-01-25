defmodule Imgd.Credentials.Types.OAuth2 do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "oauth2",
      name: "OAuth2",
      description: "Generic OAuth2 authentication",
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
      }
    }
  end
end
