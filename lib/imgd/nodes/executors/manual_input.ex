defmodule Imgd.Nodes.Executors.ManualInput do
  use Imgd.Nodes.Definition,
    id: "manual_input",
    name: "Manual Input",
    category: "Triggers",
    description: "Starts a workflow with provided input data",
    icon: "hero-cursor-arrow-rays",
    kind: :trigger

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end
end
