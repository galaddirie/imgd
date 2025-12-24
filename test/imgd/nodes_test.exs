defmodule Imgd.StepsTest do
  use Imgd.DataCase

  alias Imgd.Steps
  alias Imgd.Steps.Type

  describe "list_types/0" do
    test "returns all registered step types" do
      types = Steps.list_types()

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
      types = Steps.list_types()
      names = Enum.map(types, & &1.name)

      assert names == Enum.sort(names)
    end
  end

  describe "get_type/1" do
    test "returns {:ok, type} for existing type" do
      {:ok, type} = Steps.get_type("http_request")

      assert %Type{} = type
      assert type.id == "http_request"
      assert type.name == "HTTP Request"
      assert type.category == "Integrations"
    end

    test "returns {:error, :not_found} for non-existent type" do
      assert {:error, :not_found} = Steps.get_type("nonexistent_type")
    end

    test "handles empty string" do
      assert {:error, :not_found} = Steps.get_type("")
    end
  end

  describe "get_type!/1" do
    test "returns type for existing type" do
      type = Steps.get_type!("http_request")

      assert %Type{} = type
      assert type.id == "http_request"
    end

    test "raises for non-existent type" do
      assert_raise RuntimeError, "Step type not found: nonexistent_type", fn ->
        Steps.get_type!("nonexistent_type")
      end
    end
  end

  describe "type_exists?/1" do
    test "returns true for existing type" do
      assert Steps.type_exists?("http_request")
    end

    test "returns false for non-existent type" do
      refute Steps.type_exists?("nonexistent_type")
    end

    test "handles empty string" do
      refute Steps.type_exists?("")
    end
  end

  describe "types_by_category/0" do
    test "groups types by category" do
      grouped = Steps.types_by_category()

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

  describe "categories/0" do
    test "returns all unique categories" do
      categories = Steps.categories()

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

  describe "list_types_by_category/1" do
    test "returns types for existing category" do
      types = Steps.list_types_by_category("Integrations")

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.category == "Integrations"
      end
    end

    test "returns empty list for non-existent category" do
      types = Steps.list_types_by_category("NonExistentCategory")

      assert types == []
    end
  end

  describe "list_types_by_kind/1" do
    test "returns types for :action kind" do
      types = Steps.list_types_by_kind(:action)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :action
      end
    end

    test "returns types for :trigger kind" do
      types = Steps.list_types_by_kind(:trigger)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :trigger
      end
    end

    test "returns types for :control_flow kind" do
      types = Steps.list_types_by_kind(:control_flow)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :control_flow
      end
    end

    test "returns types for :transform kind" do
      types = Steps.list_types_by_kind(:transform)

      assert is_list(types)

      for type <- types do
        assert %Type{} = type
        assert type.step_kind == :transform
      end
    end
  end

  describe "type_count/0" do
    test "returns the number of registered types" do
      count = Steps.type_count()

      assert is_integer(count)
      assert count >= 0

      # Should match the length of list_types
      assert count == length(Steps.list_types())
    end
  end

  describe "validate_type_ids/1" do
    test "returns :ok when all type IDs exist" do
      # Get some existing type IDs
      existing_types = Steps.list_types() |> Enum.take(2) |> Enum.map(& &1.id)

      assert :ok = Steps.validate_type_ids(existing_types)
    end

    test "returns {:error, missing_ids} when some type IDs don't exist" do
      existing_id = Steps.list_types() |> List.first() |> Map.get(:id)
      missing_ids = [existing_id, "nonexistent_1", "nonexistent_2"]

      assert {:error, ["nonexistent_1", "nonexistent_2"]} = Steps.validate_type_ids(missing_ids)
    end

    test "returns :ok for empty list" do
      assert :ok = Steps.validate_type_ids([])
    end

    test "removes duplicates from missing list" do
      missing_ids = ["nonexistent_1", "nonexistent_1", "nonexistent_2"]

      assert {:error, missing} = Steps.validate_type_ids(missing_ids)
      assert Enum.sort(missing) == ["nonexistent_1", "nonexistent_2"]
    end
  end
end
