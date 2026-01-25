defmodule Imgd.Credentials.Types.ApiKey do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "api_key",
      name: "API Key",
      description: "Simple API Key authentication",
      icon: "hero-key",
      category: "Authentication",
      field_schema: %{
        "type" => "object",
        "required" => ["api_key"],
        "properties" => %{
          "api_key" => %{
            "type" => "string",
            "title" => "API Key",
            "format" => "password"
          }
        }
      }
    }
  end
end
