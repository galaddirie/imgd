defmodule Imgd.Credentials.Types.GithubOAuth do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "github_oauth",
      name: "GitHub (OAuth)",
      description: "GitHub OAuth2 authentication",
      icon: %{
        src: "/images/github.svg",
        light_color: "black",
        dark_color: "white"
      },
      category: "Git",
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
