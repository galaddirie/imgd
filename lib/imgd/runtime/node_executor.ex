defmodule Imgd.Runtime.NodeExecutor do
  @moduledoc """
  Behaviour for node executors.

  Each node type in the workflow system has an associated executor module that
  implements this behaviour. The executor is responsible for performing the
  actual work of the node given its configuration and input data.

  ## Example Implementation

      defmodule Imgd.Nodes.Executors.HTTP do
        @behaviour Imgd.Runtime.NodeExecutor

        @impl true
        def execute(config, input, context) do
          url = config["url"]
          method = config["method"] || "GET"

          case Req.request(method: method, url: url, json: input) do
            {:ok, %{status: status, body: body}} when status in 200..299 ->
              {:ok, %{"status" => status, "body" => body}}

            {:ok, %{status: status, body: body}} ->
              {:error, %{status: status, body: body}}

            {:error, reason} ->
              {:error, reason}
          end
        end

        @impl true
        def validate_config(config) do
          cond do
            not is_binary(config["url"]) ->
              {:error, [url: "is required and must be a string"]}

            true ->
              :ok
          end
        end
      end

  ## Return Values

  - `{:ok, output}` - The node executed successfully with the given output
  - `{:error, reason}` - The node failed with the given reason
  - `{:skip, reason}` - The node was skipped (e.g., condition not met)
  """

  alias Imgd.Executions.Context

  @doc """
  Executes the node with the given configuration, input, and context.

  ## Parameters

  - `config` - The node's configuration map (from `node.config`)
  - `input` - The input data flowing into this node (from parent nodes)
  - `context` - The execution context containing workflow state, variables, etc.

  ## Returns

  - `{:ok, output}` - Success with output data
  - `{:error, reason}` - Failure with error details
  - `{:skip, reason}` - Node was skipped
  """
  @callback execute(config :: map(), input :: term(), context :: Context.t()) ::
              {:ok, output :: term()}
              | {:error, reason :: term()}
              | {:skip, reason :: term()}

  @doc """
  Validates the node's configuration.

  Called during workflow publishing to ensure node configurations are valid
  before the workflow can be executed.

  ## Parameters

  - `config` - The node's configuration map to validate

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, errors}` - Configuration is invalid with list of error tuples
  """
  @callback validate_config(config :: map()) :: :ok | {:error, errors :: list()}

  @optional_callbacks validate_config: 1

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Resolves the executor module for a given node type ID.

  First checks the Registry for the type, falling back to convention-based
  resolution if not found (for backwards compatibility).

  Returns `{:ok, module}` if found and loaded, `{:error, reason}` otherwise.
  """
  def resolve(type_id) when is_binary(type_id) do
    # Try registry first
    case Imgd.Nodes.Registry.get(type_id) do
      {:ok, type} ->
        Imgd.Nodes.Type.executor_module(type)

      {:error, :not_found} ->
        # Fallback to convention-based resolution
        resolve_by_convention(type_id)
    end
  end

  defp resolve_by_convention(type_id) do
    # Convention: type_id "http_request" -> Imgd.Nodes.Executors.HttpRequest
    module_name = type_id_to_module_name(type_id)

    try do
      module = Module.safe_concat([Imgd.Nodes.Executors, module_name])

      if function_exported?(module, :execute, 3) do
        {:ok, module}
      else
        {:error, {:not_executor, module}}
      end
    rescue
      ArgumentError ->
        {:error, {:not_found, type_id}}
    end
  end

  @doc """
  Resolves the executor module or raises.
  """
  def resolve!(type_id) do
    case resolve(type_id) do
      {:ok, module} -> module
      {:error, reason} -> raise "Failed to resolve executor for #{type_id}: #{inspect(reason)}"
    end
  end

  @doc """
  Executes a node using its type ID to resolve the executor.

  This is a convenience function that combines resolution and execution.
  """
  def execute(type_id, config, input, context) do
    case resolve(type_id) do
      {:ok, module} ->
        module.execute(config, input, context)

      {:error, reason} ->
        {:error, {:executor_not_found, reason}}
    end
  end

  @doc """
  Validates config using the executor's validate_config callback if defined.
  """
  def validate_config(type_id, config) do
    case resolve(type_id) do
      {:ok, module} ->
        if function_exported?(module, :validate_config, 1) do
          module.validate_config(config)
        else
          :ok
        end

      {:error, _reason} ->
        # Can't validate if executor doesn't exist
        :ok
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp type_id_to_module_name(type_id) do
    type_id
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
    |> String.to_atom()
  end
end
