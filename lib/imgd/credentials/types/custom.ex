defmodule Imgd.Credentials.Types.Custom do
  @behaviour Imgd.Credentials.Type

  @impl true
  def definition do
    %Imgd.Credentials.Type{
      id: "custom",
      name: "Custom",
      description: "Custom credential with any fields",
      icon: "hero-wrench-screwdriver",
      category: "Custom",
      field_schema: %{
        "type" => "object",
        "additionalProperties" => true
      }
    }
  end
end
