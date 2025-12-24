defmodule Imgd.Steps.DefinitionTest do
  use Imgd.DataCase

  alias Imgd.Steps.Type

  # Define a test module that uses the Definition macro
  defmodule TestStep do
    use Imgd.Steps.Definition,
      id: "test_step",
      name: "Test Step",
      category: "Test",
      description: "A test step for testing the Definition macro",
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

    @behaviour Imgd.Steps.Executors.Behaviour

    @impl true
    def execute(_config, _input, _execution) do
      {:ok, %{"result" => "test"}}
    end
  end

  describe "macro compilation" do
    test "__step_definition__/0 returns correct Type struct" do
      type = TestStep.__step_definition__()

      assert %Type{} = type
      assert type.id == "test_step"
      assert type.name == "Test Step"
      assert type.category == "Test"
      assert type.description == "A test step for testing the Definition macro"
      assert type.icon == "hero-beaker"
      assert type.step_kind == :action
      assert type.executor == "Elixir.Imgd.Steps.DefinitionTest.TestStep"

      # Check custom schemas
      assert type.config_schema == %{
               "type" => "object",
               "required" => ["value"],
               "properties" => %{
                 "value" => %{"type" => "string", "title" => "Test Value"}
               }
             }

      assert type.input_schema == %{
               "type" => "object",
               "properties" => %{"input" => %{"type" => "string"}}
             }

      assert type.output_schema == %{
               "type" => "object",
               "properties" => %{"output" => %{"type" => "string"}}
             }

      # Timestamps should be nil
      assert is_nil(type.inserted_at)
      assert is_nil(type.updated_at)
    end

    test "__step_id__/0 returns the correct ID" do
      assert TestStep.__step_id__() == "test_step"
    end
  end

  describe "macro validation" do
    test "raises error for missing required options" do
      assert_raise ArgumentError, ~r/id is required for Imgd\.Steps\.Definition/, fn ->
        defmodule InvalidStep1 do
          use Imgd.Steps.Definition,
            name: "Invalid",
            category: "Test",
            description: "Test",
            icon: "hero-cube",
            kind: :action
        end
      end

      assert_raise ArgumentError, ~r/name is required for Imgd\.Steps\.Definition/, fn ->
        defmodule InvalidStep2 do
          use Imgd.Steps.Definition,
            id: "invalid",
            category: "Test",
            description: "Test",
            icon: "hero-cube",
            kind: :action
        end
      end

      assert_raise ArgumentError, ~r/kind is required for Imgd\.Steps\.Definition/, fn ->
        defmodule InvalidStep3 do
          use Imgd.Steps.Definition,
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
        defmodule InvalidStep4 do
          use Imgd.Steps.Definition,
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
    defmodule MinimalStep do
      use Imgd.Steps.Definition,
        id: "minimal",
        name: "Minimal Step",
        category: "Test",
        description: "Minimal test step",
        icon: "hero-cube",
        kind: :action

      @behaviour Imgd.Steps.Executors.Behaviour

      @impl true
      def execute(_config, _input, _execution) do
        {:ok, %{}}
      end
    end

    test "uses default schemas when not overridden" do
      type = MinimalStep.__step_definition__()

      assert type.config_schema == %{"type" => "object", "properties" => %{}}
      assert type.input_schema == %{"type" => "object"}
      assert type.output_schema == %{"type" => "object"}
    end
  end

  describe "module attributes persistence" do
    test "persists step attributes correctly" do
      # Check that the module has the expected attributes
      assert TestStep.__info__(:attributes)[:step_id] == ["test_step"]
      assert TestStep.__info__(:attributes)[:step_name] == ["Test Step"]
      assert TestStep.__info__(:attributes)[:step_category] == ["Test"]

      assert TestStep.__info__(:attributes)[:step_description] == [
               "A test step for testing the Definition macro"
             ]

      assert TestStep.__info__(:attributes)[:step_icon] == ["hero-beaker"]
      assert TestStep.__info__(:attributes)[:step_kind] == [:action]
    end
  end

  describe "behaviour implementation" do
    test "implements the expected behaviour" do
      # The module should have the execute function
      assert function_exported?(TestStep, :execute, 3)

      # Test the execute function
      config = %{"value" => "test"}
      input = %{}
      execution = %{}

      assert {:ok, %{"result" => "test"}} = TestStep.execute(config, input, execution)
    end
  end
end
