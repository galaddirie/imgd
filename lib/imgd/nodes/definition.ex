defmodule Imgd.Nodes.Definition do
  @moduledoc """
  Macro for declaring node type definitions within executor modules.

  This provides a declarative way to define node types alongside their
  executor implementation, keeping the definition and logic co-located.

  ## Usage

      defmodule Imgd.Nodes.Executors.HttpRequest do
        use Imgd.Nodes.Definition,
          id: "http_request",
          name: "HTTP Request",
          category: "Integrations",
          description: "Make HTTP requests to external APIs",
          icon: "hero-globe-alt",
          kind: :action

        # Define schemas as module attributes
        @config_schema %{
          "type" => "object",
          "required" => ["url"],
          "properties" => %{
            "url" => %{"type" => "string", "title" => "URL"}
          }
        }

        @input_schema %{"type" => "object"}
        @output_schema %{"type" => "object"}

        @behaviour Imgd.Nodes.Executors.Behaviour

        @impl true
        def execute(config, input, context) do
          # ... implementation
        end
      end

  ## Options

  - `:id` (required) - Unique identifier for the node type (snake_case)
  - `:name` (required) - Human-readable display name
  - `:category` (required) - Category for grouping in the UI
  - `:description` (required) - Description of what the node does
  - `:icon` (required) - Heroicon name (e.g., "hero-globe-alt")
  - `:kind` (required) - One of :action, :trigger, :control_flow, :transform

  ## Schema Attributes

  After `use`, you can define these module attributes:

  - `@config_schema` - JSON Schema for node configuration (what users fill in)
  - `@input_schema` - JSON Schema describing expected input
  - `@output_schema` - JSON Schema describing output

  If not defined, these default to empty objects.
  """

  @required_opts [:id, :name, :category, :description, :icon, :kind]
  @valid_kinds [:action, :trigger, :control_flow, :transform]

  defmacro __using__(opts) do
    # Validate required options at compile time
    for key <- @required_opts do
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError, "#{key} is required for Imgd.Nodes.Definition"
      end
    end

    kind = Keyword.fetch!(opts, :kind)

    unless kind in @valid_kinds do
      raise ArgumentError, "kind must be one of #{inspect(@valid_kinds)}, got: #{inspect(kind)}"
    end

    quote do
      @before_compile Imgd.Nodes.Definition

      # Store the definition metadata
      Module.register_attribute(__MODULE__, :node_id, persist: true)
      Module.register_attribute(__MODULE__, :node_name, persist: true)
      Module.register_attribute(__MODULE__, :node_category, persist: true)
      Module.register_attribute(__MODULE__, :node_description, persist: true)
      Module.register_attribute(__MODULE__, :node_icon, persist: true)
      Module.register_attribute(__MODULE__, :node_kind, persist: true)

      @node_id unquote(opts[:id])
      @node_name unquote(opts[:name])
      @node_category unquote(opts[:category])
      @node_description unquote(opts[:description])
      @node_icon unquote(opts[:icon])
      @node_kind unquote(opts[:kind])

      # Default schemas (can be overridden)
      @config_schema %{"type" => "object", "properties" => %{}}
      @input_schema %{"type" => "object"}
      @output_schema %{"type" => "object"}

      # Allow redefinition
      Module.register_attribute(__MODULE__, :config_schema, accumulate: false)
      Module.register_attribute(__MODULE__, :input_schema, accumulate: false)
      Module.register_attribute(__MODULE__, :output_schema, accumulate: false)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Returns the node type definition struct for this executor.
      """
      def __node_definition__ do
        %Imgd.Nodes.Type{
          id: @node_id,
          name: @node_name,
          category: @node_category,
          description: @node_description,
          icon: @node_icon,
          node_kind: @node_kind,
          executor: Atom.to_string(__MODULE__),
          config_schema: @config_schema,
          input_schema: @input_schema,
          output_schema: @output_schema,
          inserted_at: nil,
          updated_at: nil
        }
      end

      @doc """
      Returns the node type ID.
      """
      def __node_id__, do: @node_id
    end
  end
end
