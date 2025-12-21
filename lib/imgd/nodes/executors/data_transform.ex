defmodule Imgd.Nodes.Executors.DataTransform do
  use Imgd.Nodes.Definition,
    id: "data_transform",
    name: "Data Transform",
    category: "Transform",
    description: "Apply lightweight transformations to the input payload",
    icon: "hero-adjustments-horizontal",
    kind: :transform

  @behaviour Imgd.Nodes.Executors.Behaviour

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end
end
