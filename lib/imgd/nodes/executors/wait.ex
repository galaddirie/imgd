defmodule Imgd.Nodes.Executors.Wait do
  @moduledoc """
  Executor for Wait nodes.

  Artificially waits for a specified number of seconds before passing data through unchanged.

  ## Configuration

  - `seconds` (optional) - Number of seconds to wait. Default: 5
  """

  use Imgd.Nodes.Definition,
    id: "wait",
    name: "Wait",
    category: "Utilities",
    description: "Wait for a specified number of seconds before continuing",
    icon: "hero-clock",
    kind: :action

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "seconds" => %{
        "type" => "number",
        "title" => "Seconds",
        "default" => 5,
        "minimum" => 0,
        "maximum" => 300,
        "description" => "Number of seconds to wait"
      }
    }
  }

  @input_schema %{
    "description" => "Any data to pass through after waiting"
  }

  @output_schema %{
    "description" => "The input data, unchanged"
  }

  @behaviour Imgd.Runtime.NodeExecutor
  require Logger

  @impl true
  def execute(config, input, _context) do
    seconds = Map.get(config, "seconds", 5)
    milliseconds = trunc(seconds * 1000)

    Logger.info("Wait node: sleeping for #{seconds} seconds...")

    :timer.sleep(milliseconds)

    Logger.info("Wait node: finished sleeping")

    {:ok, input}
  end

  @impl true
  def validate_config(config) do
    seconds = Map.get(config, "seconds", 5)

    cond do
      not is_number(seconds) ->
        {:error, [seconds: "must be a number"]}

      seconds < 0 ->
        {:error, [seconds: "must be non-negative"]}

      seconds > 300 ->
        {:error, [seconds: "must not exceed 300 seconds (5 minutes)"]}

      true ->
        :ok
    end
  end
end
