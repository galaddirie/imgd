defmodule Imgd.Credentials.Types.OpenAI do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "openai",
      name: "OpenAI",
      description: "OpenAI API Key",
      icon: %{
        src: "/images/openai.svg",
        light_color: "black",
        dark_color: "white"
      },
      category: "AI",
      field_schema: %{
        "type" => "object",
        "required" => ["api_key"],
        "properties" => %{
          "api_key" => %{
            "type" => "string",
            "title" => "API Key",
            "format" => "password"
          },
          "organization_id" => %{"type" => "string", "title" => "Organization ID"}
        }
      }
    }
  end
end
