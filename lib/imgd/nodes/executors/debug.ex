defmodule Imgd.Nodes.Executors.Debug do
  @moduledoc """
  Executor for Debug nodes.

  Logs the input data and passes it through unchanged. Useful for inspecting
  data flow in a workflow.

  ## Configuration

  - `label` (optional) - A label to prefix the log message with
  - `level` (optional) - The log level (debug, info, warn, error). Default: info
  """

  use Imgd.Nodes.Definition,
    id: "debug",
    name: "Debug",
    category: "Utilities",
    description: "Log input data and pass it through unchanged for debugging",
    icon: "hero-bug-ant",
    kind: :action

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "label" => %{
        "type" => "string",
        "title" => "Label",
        "default" => "Debug Node",
        "description" => "Label to prefix the log message"
      },
      "level" => %{
        "type" => "string",
        "title" => "Log Level",
        "enum" => ["debug", "info", "warn", "error"],
        "default" => "info",
        "description" => "The log level to use"
      }
    }
  }

  @input_schema %{
    "description" => "Any data to inspect and pass through"
  }

  @output_schema %{
    "description" => "The input data, unchanged"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour
  require Logger

  @impl true
  def execute(config, input, _execution) do
    label = Map.get(config, "label", "Debug Node")
    level = Map.get(config, "level", "info") |> String.to_atom()

    message = "#{label}: #{inspect(input, pretty: true)}"

    case level do
      :debug -> Logger.debug(message)
      :info -> Logger.info(message)
      :warn -> Logger.warning(message)
      :error -> Logger.error(message)
      _ -> Logger.info(message)
    end

    {:ok, input}
  end

  @impl true
  def validate_config(config) do
    level = Map.get(config, "level", "info")

    if level in ~w(debug info warn error) do
      :ok
    else
      {:error, [level: "must be one of: debug, info, warn, error"]}
    end
  end
end
