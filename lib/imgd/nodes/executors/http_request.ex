defmodule Imgd.Nodes.Executors.HttpRequest do
  @moduledoc """
  Executor for HTTP Request nodes.

  Makes HTTP requests using the Req library and returns the response.

  ## Configuration

  - `url` (required) - The URL to request
  - `method` - HTTP method (GET, POST, PUT, PATCH, DELETE). Default: GET
  - `headers` - Map of headers to include
  - `body` - Request body (for POST/PUT/PATCH)
  - `timeout_ms` - Request timeout in milliseconds. Default: 30000
  - `follow_redirects` - Whether to follow redirects. Default: true

  ## Input

  Configuration values support expressions like `{{ json }}` and `{{ nodes.NodeId.json }}`.
  Use these expressions to interpolate upstream data into the URL, headers, or body.

  ## Output

  Returns a map with:
  - `status` - HTTP status code
  - `headers` - Response headers as a map
  - `body` - Response body (parsed as JSON if applicable)
  """

  use Imgd.Nodes.Definition,
    id: "http_request",
    name: "HTTP Request",
    category: "Integrations",
    description: "Make HTTP requests to external APIs and services",
    icon: "hero-globe-alt",
    kind: :action

  @config_schema %{
    "type" => "object",
    "required" => ["url"],
    "properties" => %{
      "url" => %{
        "type" => "string",
        "title" => "URL",
        "description" => "The URL to request"
      },
      "method" => %{
        "type" => "string",
        "title" => "Method",
        "enum" => ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
        "default" => "GET",
        "description" => "HTTP method to use"
      },
      "headers" => %{
        "type" => "object",
        "title" => "Headers",
        "additionalProperties" => %{"type" => "string"},
        "description" => "HTTP headers to include in the request (supports expressions)"
      },
      "body" => %{
        "title" => "Request Body",
        "description" => "JSON body for POST/PUT/PATCH requests (supports expressions)"
      },
      "timeout_ms" => %{
        "type" => "integer",
        "title" => "Timeout (ms)",
        "default" => 30_000,
        "minimum" => 1000,
        "description" => "Request timeout in milliseconds"
      },
      "follow_redirects" => %{
        "type" => "boolean",
        "title" => "Follow Redirects",
        "default" => true,
        "description" => "Whether to follow HTTP redirects"
      }
    }
  }

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "status" => %{"type" => "integer", "description" => "HTTP status code"},
      "headers" => %{"type" => "object", "description" => "Response headers"},
      "body" => %{"description" => "Response body (JSON parsed if applicable)"},
      "ok" => %{"type" => "boolean", "description" => "True if status is 2xx"}
    }
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  require Logger

  @default_timeout_ms 30_000
  @default_method "GET"

  @impl true
  def execute(config, _input, _execution) do
    url = Map.fetch!(config, "url")
    method = Map.get(config, "method", @default_method) |> normalize_method()
    headers = Map.get(config, "headers", %{}) |> normalize_headers()
    body = Map.get(config, "body")
    timeout_ms = Map.get(config, "timeout_ms", @default_timeout_ms)
    follow_redirects = Map.get(config, "follow_redirects", true)

    # Build request options
    req_opts = [
      method: method,
      url: url,
      headers: headers,
      receive_timeout: timeout_ms,
      redirect: follow_redirects
    ]

    # Add body for methods that support it
    req_opts =
      if method in [:post, :put, :patch] and body != nil do
        Keyword.put(req_opts, :json, body)
      else
        req_opts
      end

    Logger.debug("Executing HTTP request",
      url: url,
      method: method
    )

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        output = %{
          "status" => status,
          "headers" => Map.new(resp_headers),
          "body" => resp_body,
          "ok" => status in 200..299
        }

        if status in 200..299 do
          {:ok, output}
        else
          {:error, output}
        end

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, %{"type" => "transport_error", "reason" => inspect(reason)}}

      {:error, reason} ->
        {:error, %{"type" => "request_error", "reason" => inspect(reason)}}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "url") do
        nil ->
          [{:url, "is required"} | errors]

        url when is_binary(url) ->
          if expression_string?(url) do
            errors
          else
            validate_url(url, errors)
          end

        _ ->
          [{:url, "must be a string"} | errors]
      end

    errors =
      case Map.get(config, "method") do
        nil ->
          errors

        method when is_binary(method) ->
          cond do
            expression_string?(method) ->
              errors

            method in ~w(GET POST PUT PATCH DELETE HEAD OPTIONS) ->
              errors

            true ->
              [{:method, "must be one of: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS"} | errors]
          end

        _ ->
          [{:method, "must be a string"} | errors]
      end

    errors =
      case Map.get(config, "headers") do
        nil ->
          errors

        headers when is_map(headers) ->
          errors

        headers when is_binary(headers) ->
          if expression_string?(headers) do
            errors
          else
            [{:headers, "must be a map"} | errors]
          end

        _ ->
          [{:headers, "must be a map"} | errors]
      end

    errors =
      case Map.get(config, "timeout_ms") do
        nil ->
          errors

        timeout when is_integer(timeout) and timeout > 0 ->
          errors

        timeout when is_binary(timeout) ->
          if expression_string?(timeout) do
            errors
          else
            [{:timeout_ms, "must be a positive integer"} | errors]
          end

        _ ->
          [{:timeout_ms, "must be a positive integer"} | errors]
      end

    errors =
      case Map.get(config, "follow_redirects") do
        nil ->
          errors

        flag when is_boolean(flag) ->
          errors

        flag when is_binary(flag) ->
          if expression_string?(flag) do
            errors
          else
            [{:follow_redirects, "must be a boolean"} | errors]
          end

        _ ->
          [{:follow_redirects, "must be a boolean"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_method(method) when is_binary(method) do
    method
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :get
  end

  defp normalize_method(method) when is_atom(method), do: method

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(_), do: []

  defp validate_url(url, errors) do
    case URI.parse(url) do
      %URI{scheme: nil} ->
        [{:url, "must include scheme (http:// or https://)"} | errors]

      %URI{host: nil} ->
        [{:url, "must include host"} | errors]

      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        [{:url, "scheme must be http or https"} | errors]

      _ ->
        errors
    end
  end

  defp expression_string?(value) when is_binary(value) do
    String.contains?(value, "{{") and String.contains?(value, "}}")
  end

  defp expression_string?(_value), do: false
end
