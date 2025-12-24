defmodule Imgd.Steps.RegistryTest do
  use Imgd.DataCase, async: false

  alias Imgd.Steps.Registry
  alias Imgd.Steps.Type

  setup do
    # The registry should already be started by the application supervisor
    # If not, we could start it here, but for now assume it's running
    :ok
  end

  describe "start_link/1" do
    test "starts the registry process" do
      # The registry should already be running from the application startup
      assert Process.whereis(Registry) != nil
    end
  end

  describe "all/0" do
    test "returns all registered step types" do
      types = Registry.all()

      assert is_list(types)
      assert length(types) > 0

      # All types should be Type structs
      for type <- types do
        assert %Type{} = type
        assert is_binary(type.id)
        assert is_binary(type.name)
        assert is_binary(type.category)
        assert is_binary(type.description)
        assert is_binary(type.icon)
        assert type.step_kind in [:action, :trigger, :control_flow, :transform]
      end
    end

    test "returns types sorted by name" do
      types = Registry.all()
      names = Enum.map(types, & &1.name)

      assert names == Enum.sort(names)
    end
  end

  describe "get/1" do
    test "returns {:ok, type} for existing type" do
      {:ok, type} = Registry.get("http_request")

      assert %Type{} = type
      assert type.id == "http_request"
      assert type.name == "HTTP Request"
      assert type.category == "Integrations"
    end

    test "returns {:error, :not_found} for non-existent type" do
      assert {:error, :not_found} = Registry.get("nonexistent_type")
    end

    test "handles empty string" do
      assert {:error, :not_found} = Registry.get("")
    end
  end

  describe "get!/1" do
    test "returns type for existing type" do
      type = Registry.get!("http_request")

      assert %Type{} = type
      assert type.id == "http_request"
    end

    test "raises for non-existent type" do
      assert_raise RuntimeError, "Step type not found: nonexistent_type", fn ->
        Registry.get!("nonexistent_type")
      end
    end
  end

  describe "exists?/1" do
    test "returns true for existing type" do
      assert Registry.exists?("http_request")
    end

    test "returns false for non-existent type" do
      refute Registry.exists?("nonexistent_type")
    end

    test "handles empty string" do
      refute Registry.exists?("")
    end
  end

  describe "list_by_category/1" do
    test "returns types for existing category" do
      types = Registry.list_by_category("Integrations")

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.category == "Integrations"
      end
    end

    test "returns empty list for non-existent category" do
      types = Registry.list_by_category("NonExistentCategory")

      assert types == []
    end
  end

  describe "list_by_kind/1" do
    test "returns types for :action kind" do
      types = Registry.list_by_kind(:action)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :action
      end
    end

    test "returns types for :trigger kind" do
      types = Registry.list_by_kind(:trigger)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :trigger
      end
    end

    test "returns types for :control_flow kind" do
      types = Registry.list_by_kind(:control_flow)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :control_flow
      end
    end

    test "returns types for :transform kind" do
      types = Registry.list_by_kind(:transform)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :transform
      end
    end

    test "raises for invalid kind" do
      assert_raise FunctionClauseError, fn ->
        Registry.list_by_kind(:invalid_kind)
      end
    end
  end

  describe "categories/0" do
    test "returns all unique categories" do
      categories = Registry.categories()

      assert is_list(categories)
      assert length(categories) > 0

      # All should be strings
      for category <- categories do
        assert is_binary(category)
      end

      # Should be sorted
      assert categories == Enum.sort(categories)

      # Should be unique
      assert categories == Enum.uniq(categories)
    end
  end

  describe "grouped_by_category/0" do
    test "groups types by category" do
      grouped = Registry.grouped_by_category()

      assert is_map(grouped)

      # Should have some known categories
      categories = Map.keys(grouped)
      assert "Integrations" in categories

      # Each category should contain a list of types
      for {category, types} <- grouped do
        assert is_binary(category)
        assert is_list(types)

        for type <- types do
          assert %Type{} = type
          assert type.category == category
        end
      end
    end
  end

  describe "count/0" do
    test "returns the number of registered types" do
      count = Registry.count()

      assert is_integer(count)
      assert count >= 0

      # Should match the length of all()
      assert count == length(Registry.all())
    end
  end

  describe "reload functionality" do
    test "can reload the registry" do
      # Get initial count
      initial_count = Registry.count()

      # Call reload (this would normally reload from modules)
      # In a real scenario, this might be used after hot code reloading
      # For this test, we're just ensuring the call works
      assert :ok = GenServer.call(Registry, :reload)

      # Count should be the same (since we're not actually changing modules)
      assert Registry.count() == initial_count
    end
  end

  describe "ETS table" do
    test "uses the correct ETS table name" do
      # The ETS table should exist
      assert :ets.info(:imgd_step_types) != :undefined

      # Should have read concurrency enabled
      info = :ets.info(:imgd_step_types)
      assert info[:read_concurrency] == true
      assert info[:type] == :set
      assert info[:protection] == :protected
    end

    test "ETS table contains expected data" do
      # Get some data directly from ETS
      case :ets.lookup(:imgd_step_types, "http_request") do
        [{_id, type}] ->
          assert %Type{} = type
          assert type.id == "http_request"

        [] ->
          flunk("Expected http_request type to be in ETS table")
      end
    end
  end
end
