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
      "path" => %{
        "type" => "string",
        "title" => "Webhook Path",
        "description" => "Custom slug for the webhook endpoint"
      },
      "http_method" => %{
        "type" => "string",
        "title" => "HTTP Method",
        "enum" => ["GET", "POST", "PUT", "PATCH", "DELETE"],
        "default" => "POST"
      },
      "response_mode" => %{
        "type" => "string",
        "title" => "Response Mode",
        "enum" => ["immediate", "on_completion", "on_respond_node"],
        "default" => "immediate"
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
