defmodule Imgd.Steps.Executors.DataTransform do
  use Imgd.Steps.Definition,
    id: "data_transform",
    name: "Data Transform",
    category: "Transform",
    description: "Apply lightweight transformations to the input payload",
    icon: "hero-adjustments-horizontal",
    kind: :transform

  @behaviour Imgd.Steps.Executors.Behaviour

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end
end
