defmodule Imgd.Nodes.TypeTest do
  use Imgd.DataCase

  alias Imgd.Nodes.Type

  describe "struct" do
    test "can create a valid Type struct" do
      type = %Type{
        id: "test_node",
        name: "Test Node",
        category: "Test",
        description: "A test node",
        icon: "hero-cube",
        executor: "Imgd.Nodes.Executors.Test",
        node_kind: :action
      }

      assert type.id == "test_node"
      assert type.name == "Test Node"
      assert type.category == "Test"
      assert type.description == "A test node"
      assert type.icon == "hero-cube"
      assert type.executor == "Imgd.Nodes.Executors.Test"
      assert type.node_kind == :action
      assert type.config_schema == %{}
      assert type.input_schema == %{}
      assert type.output_schema == %{}
      assert is_nil(type.inserted_at)
      assert is_nil(type.updated_at)
    end

    test "enforces required fields" do
      assert_raise ArgumentError, "the following keys must also be given when building struct Imgd.Nodes.Type: [:id, :name, :category, :description, :icon, :executor, :node_kind]", fn ->
        struct!(Type, %{})
      end
    end

    test "has default values for optional fields" do
      type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test.Executor",
        node_kind: :action
      }

      assert type.config_schema == %{}
      assert type.input_schema == %{}
      assert type.output_schema == %{}
    end
  end

  describe "executor_module/1" do
    test "converts executor string to module atom" do
      type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Imgd.Nodes.Executors.HttpRequest",
        node_kind: :action
      }

      assert {:ok, Imgd.Nodes.Executors.HttpRequest} = Type.executor_module(type)
    end

    test "handles Elixir prefix" do
      type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Elixir.Imgd.Nodes.Executors.HttpRequest",
        node_kind: :action
      }

      assert {:ok, Imgd.Nodes.Executors.HttpRequest} = Type.executor_module(type)
    end

    test "returns error for non-existent module" do
      type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "NonExistent.Module",
        node_kind: :action
      }

      assert {:error, :module_not_loaded} = Type.executor_module(type)
    end

    test "returns error for nil executor" do
      type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: nil,
        node_kind: :action
      }

      assert {:error, :no_executor} = Type.executor_module(type)
    end
  end

  describe "executor_module!/1" do
    test "returns module for valid executor" do
      type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Imgd.Nodes.Executors.HttpRequest",
        node_kind: :action
      }

      assert Imgd.Nodes.Executors.HttpRequest = Type.executor_module!(type)
    end

    test "raises for invalid executor" do
      type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "NonExistent.Module",
        node_kind: :action
      }

      assert_raise RuntimeError, "Failed to get executor module: :module_not_loaded", fn ->
        Type.executor_module!(type)
      end
    end
  end

  describe "kind predicates" do
    test "trigger?/1" do
      trigger_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :trigger
      }

      action_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :action
      }

      assert Type.trigger?(trigger_type)
      refute Type.trigger?(action_type)
    end

    test "control_flow?/1" do
      control_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :control_flow
      }

      action_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :action
      }

      assert Type.control_flow?(control_type)
      refute Type.control_flow?(action_type)
    end

    test "action?/1" do
      action_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :action
      }

      trigger_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :trigger
      }

      assert Type.action?(action_type)
      refute Type.action?(trigger_type)
    end

    test "transform?/1" do
      transform_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :transform
      }

      action_type = %Type{
        id: "test",
        name: "Test",
        category: "Test",
        description: "Test",
        icon: "hero-cube",
        executor: "Test",
        node_kind: :action
      }

      assert Type.transform?(transform_type)
      refute Type.transform?(action_type)
    end
  end
end
