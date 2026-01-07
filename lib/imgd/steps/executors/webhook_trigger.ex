defmodule Imgd.Steps.Executors.WebhookTrigger do
  @moduledoc """
  Trigger node that outputs incoming webhook data.

  ## Configuration

  - `path_label` (optional) - A descriptive name for this webhook endpoint.
  - `auth_token` (optional) - Required token to authorize requests.

  ## Output

  The full webhook payload including body, params, and headers.
  """
  use Imgd.Steps.Definition,
    id: "webhook_trigger",
    name: "Webhook Trigger",
    category: "Triggers",
    description: "Accepts incoming HTTP requests to start the workflow",
    icon: "hero-bolt",
    kind: :trigger

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "path_label" => %{
        "type" => "string",
        "title" => "Path Label",
        "description" => "Descriptive name for the endpoint"
      },
      "auth_token" => %{
        "type" => "string",
        "title" => "Auth Token",
        "description" => "Optional token to protect this webhook"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "body" => %{"type" => "object"},
      "headers" => %{"type" => "object"},
      "params" => %{"type" => "object"},
      "method" => %{"type" => "string"}
    }
  }

  @behaviour Imgd.Steps.Executors.Behaviour

  @impl true
  def execute(_config, input, _context) do
    # For triggers, 'input' is the trigger payload provided by the runtime
    {:ok, input}
  end
end
