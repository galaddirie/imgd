defmodule Imgd.Credentials.Types.GithubToken do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "github_token",
      name: "GitHub (Personal Access Token)",
      description: "GitHub Personal Access Token",
      icon: %{
        src: "/images/github.svg",
        light_color: "black",
        dark_color: "white"
      },
      category: "Git",
      field_schema: %{
        "type" => "object",
        "required" => ["token"],
        "properties" => %{
          "token" => %{
            "type" => "string",
            "title" => "Personal Access Token",
            "format" => "password"
          }
        }
      }
    }
  end
end
