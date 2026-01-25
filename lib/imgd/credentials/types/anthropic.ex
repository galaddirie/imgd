defmodule Imgd.Credentials.Types.Anthropic do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "anthropic",
      name: "Anthropic",
      description: "Anthropic API Key",
      icon: "/images/anthropic.svg",
      category: "AI",
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
