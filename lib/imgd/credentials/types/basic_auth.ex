defmodule Imgd.Credentials.Types.BasicAuth do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "basic_auth",
      name: "Basic Auth",
      description: "Basic Username/Password authentication",
      icon: "hero-user",
      category: "Authentication",
      field_schema: %{
        "type" => "object",
        "required" => ["username", "password"],
        "properties" => %{
          "username" => %{"type" => "string", "title" => "Username"},
          "password" => %{
            "type" => "string",
            "title" => "Password",
            "format" => "password"
          }
        }
      }
    }
  end
end
