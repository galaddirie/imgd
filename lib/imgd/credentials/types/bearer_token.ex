defmodule Imgd.Credentials.Types.BearerToken do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "bearer_token",
      name: "Bearer Token",
      description: "Bearer Token authentication",
      icon: "hero-shield-check",
      category: "Authentication",
      field_schema: %{
        "type" => "object",
        "required" => ["token"],
        "properties" => %{
          "token" => %{
            "type" => "string",
            "title" => "Bearer Token",
            "format" => "password"
          }
        }
      }
    }
  end
end
