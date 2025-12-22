defmodule Imgd.Nodes.DefinitionTest do
  use Imgd.DataCase

  alias Imgd.Nodes.Type

  # Define a test module that uses the Definition macro
  defmodule TestNode do
    use Imgd.Nodes.Definition,
      id: "test_node",
      name: "Test Node",
      category: "Test",
      description: "A test node for testing the Definition macro",
      icon: "hero-beaker",
      kind: :action

    # Custom config schema
    @config_schema %{
      "type" => "object",
      "required" => ["value"],
      "properties" => %{
        "value" => %{"type" => "string", "title" => "Test Value"}
      }
    }

    # Custom input schema
    @input_schema %{"type" => "object", "properties" => %{"input" => %{"type" => "string"}}}

    # Custom output schema
    @output_schema %{"type" => "object", "properties" => %{"output" => %{"type" => "string"}}}

    @behaviour Imgd.Nodes.Executors.Behaviour

    @impl true
    def execute(_config, _input, _execution) do
      {:ok, %{"result" => "test"}}
    end
  end

  describe "macro compilation" do
    test "__node_definition__/0 returns correct Type struct" do
      type = TestNode.__node_definition__()

      assert %Type{} = type
      assert type.id == "test_node"
      assert type.name == "Test Node"
      assert type.category == "Test"
      assert type.description == "A test node for testing the Definition macro"
      assert type.icon == "hero-beaker"
      assert type.node_kind == :action
      assert type.executor == "Elixir.Imgd.Nodes.DefinitionTest.TestNode"

      # Check custom schemas
      assert type.config_schema == %{
        "type" => "object",
        "required" => ["value"],
        "properties" => %{
          "value" => %{"type" => "string", "title" => "Test Value"}
        }
      }

      assert type.input_schema == %{"type" => "object", "properties" => %{"input" => %{"type" => "string"}}}
      assert type.output_schema == %{"type" => "object", "properties" => %{"output" => %{"type" => "string"}}}

      # Timestamps should be nil
      assert is_nil(type.inserted_at)
      assert is_nil(type.updated_at)
    end

    test "__node_id__/0 returns the correct ID" do
      assert TestNode.__node_id__() == "test_node"
    end
  end

  describe "macro validation" do
    test "raises error for missing required options" do
      assert_raise ArgumentError, ~r/id is required for Imgd\.Nodes\.Definition/, fn ->
        defmodule InvalidNode1 do
          use Imgd.Nodes.Definition,
            name: "Invalid",
            category: "Test",
            description: "Test",
            icon: "hero-cube",
            kind: :action
        end
      end

      assert_raise ArgumentError, ~r/name is required for Imgd\.Nodes\.Definition/, fn ->
        defmodule InvalidNode2 do
          use Imgd.Nodes.Definition,
            id: "invalid",
            category: "Test",
            description: "Test",
            icon: "hero-cube",
            kind: :action
        end
      end

      assert_raise ArgumentError, ~r/kind is required for Imgd\.Nodes\.Definition/, fn ->
        defmodule InvalidNode3 do
          use Imgd.Nodes.Definition,
            id: "invalid",
            name: "Invalid",
            category: "Test",
            description: "Test",
            icon: "hero-cube"
        end
      end
    end

    test "raises error for invalid kind" do
      assert_raise ArgumentError, ~r/kind must be one of/, fn ->
        defmodule InvalidNode4 do
          use Imgd.Nodes.Definition,
            id: "invalid",
            name: "Invalid",
            category: "Test",
            description: "Test",
            icon: "hero-cube",
            kind: :invalid_kind
        end
      end
    end
  end

  describe "default schemas" do
    defmodule MinimalNode do
      use Imgd.Nodes.Definition,
        id: "minimal",
        name: "Minimal Node",
        category: "Test",
        description: "Minimal test node",
        icon: "hero-cube",
        kind: :action

      @behaviour Imgd.Nodes.Executors.Behaviour

      @impl true
      def execute(_config, _input, _execution) do
        {:ok, %{}}
      end
    end

    test "uses default schemas when not overridden" do
      type = MinimalNode.__node_definition__()

      assert type.config_schema == %{"type" => "object", "properties" => %{}}
      assert type.input_schema == %{"type" => "object"}
      assert type.output_schema == %{"type" => "object"}
    end
  end

  describe "module attributes persistence" do
    test "persists node attributes correctly" do
      # Check that the module has the expected attributes
      assert TestNode.__info__(:attributes)[:node_id] == ["test_node"]
      assert TestNode.__info__(:attributes)[:node_name] == ["Test Node"]
      assert TestNode.__info__(:attributes)[:node_category] == ["Test"]
      assert TestNode.__info__(:attributes)[:node_description] == ["A test node for testing the Definition macro"]
      assert TestNode.__info__(:attributes)[:node_icon] == ["hero-beaker"]
      assert TestNode.__info__(:attributes)[:node_kind] == [:action]
    end
  end

  describe "behaviour implementation" do
    test "implements the expected behaviour" do
      # The module should have the execute function
      assert function_exported?(TestNode, :execute, 3)

      # Test the execute function
      config = %{"value" => "test"}
      input = %{}
      execution = %{}

      assert {:ok, %{"result" => "test"}} = TestNode.execute(config, input, execution)
    end
  end
end
