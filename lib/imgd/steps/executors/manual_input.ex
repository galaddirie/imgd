defmodule Imgd.Steps.Executors.ManualInput do
  use Imgd.Steps.Definition,
    id: "manual_input",
    name: "Manual Input",
    category: "Triggers",
    description: "Starts a workflow with provided input data",
    icon: "hero-cursor-arrow-rays",
    kind: :trigger

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "trigger_data" => %{
        "type" => "string",
        "title" => "Trigger Data (JSON)",
        "format" => "json",
        "default" => "{}"
      }
    }
  }

  @behaviour Imgd.Steps.Executors.Behaviour

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end
end
