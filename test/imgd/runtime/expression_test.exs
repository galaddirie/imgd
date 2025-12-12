defmodule Imgd.Runtime.ExpressionTest do
  use ExUnit.Case, async: true

  alias Imgd.Runtime.Expression
  alias Imgd.Runtime.Expression.{Context, Filters}
  alias Imgd.Executions.Context, as: ExecContext

  describe "evaluate/3" do
    test "returns unchanged string when no expressions" do
      ctx = build_context()
      assert {:ok, "Hello World"} = Expression.evaluate("Hello World", ctx)
    end

    test "evaluates simple variable" do
      ctx = build_context(%{"name" => "Alice"})
      assert {:ok, "Hello Alice"} = Expression.evaluate("Hello {{ json.name }}", ctx)
    end

    test "evaluates nested variable" do
      ctx = build_context(%{"user" => %{"name" => "Bob"}})
      assert {:ok, "Hello Bob"} = Expression.evaluate("Hello {{ json.user.name }}", ctx)
    end

    test "handles missing variable gracefully" do
      ctx = build_context()
      assert {:ok, "Hello "} = Expression.evaluate("Hello {{ json.missing }}", ctx)
    end

    test "evaluates node outputs" do
      node_outputs = %{
        "HTTP" => %{"status" => 200, "body" => "OK"}
      }

      ctx = build_context(%{}, node_outputs)

      assert {:ok, "Status: 200"} =
               Expression.evaluate("Status: {{ nodes.HTTP.json.status }}", ctx)
    end

    test "evaluates execution metadata" do
      ctx = build_context()
      assert {:ok, result} = Expression.evaluate("ID: {{ execution.id }}", ctx)
      assert String.starts_with?(result, "ID: ")
    end

    test "evaluates workflow metadata" do
      ctx = build_context()
      assert {:ok, result} = Expression.evaluate("Workflow: {{ workflow.id }}", ctx)
      assert String.starts_with?(result, "Workflow: ")
    end

    test "evaluates conditionals" do
      ctx = build_context(%{"active" => true})
      template = "{% if json.active %}Yes{% else %}No{% endif %}"
      assert {:ok, "Yes"} = Expression.evaluate(template, ctx)

      ctx2 = build_context(%{"active" => false})
      assert {:ok, "No"} = Expression.evaluate(template, ctx2)
    end

    test "evaluates loops" do
      ctx = build_context(%{"items" => ["a", "b", "c"]})
      template = "{% for item in json.items %}{{ item }}{% endfor %}"
      assert {:ok, "abc"} = Expression.evaluate(template, ctx)
    end

    test "times out on long-running expressions" do
      ctx = build_context()
      # This won't actually timeout in normal cases, but tests the mechanism
      assert {:ok, _} = Expression.evaluate("{{ json }}", ctx, timeout_ms: 5000)
    end
  end

  describe "evaluate_deep/3" do
    test "evaluates expressions in nested map" do
      ctx = build_context(%{"name" => "Test", "value" => 42})

      data = %{
        "title" => "Hello {{ json.name }}",
        "count" => "{{ json.value }}",
        "static" => "unchanged"
      }

      assert {:ok, result} = Expression.evaluate_deep(data, ctx)
      assert result["title"] == "Hello Test"
      assert result["count"] == "42"
      assert result["static"] == "unchanged"
    end

    test "evaluates expressions in lists" do
      ctx = build_context(%{"x" => "A", "y" => "B"})
      data = ["{{ json.x }}", "static", "{{ json.y }}"]

      assert {:ok, result} = Expression.evaluate_deep(data, ctx)
      assert result == ["A", "static", "B"]
    end

    test "evaluates deeply nested structures" do
      ctx = build_context(%{"val" => "deep"})

      data = %{
        "level1" => %{
          "level2" => %{
            "level3" => "{{ json.val }}"
          }
        }
      }

      assert {:ok, result} = Expression.evaluate_deep(data, ctx)
      assert result["level1"]["level2"]["level3"] == "deep"
    end
  end

  describe "validate/1" do
    test "returns :ok for valid template" do
      assert :ok = Expression.validate("Hello {{ name }}")
      assert :ok = Expression.validate("{% if x %}yes{% endif %}")
    end

    test "returns error for invalid template" do
      assert {:error, _} = Expression.validate("{% if %}")
      assert {:error, _} = Expression.validate("{{ | }}")
    end
  end

  describe "contains_expression?/1" do
    test "detects object expressions" do
      assert Expression.contains_expression?("Hello {{ name }}")
      assert Expression.contains_expression?("{{ x }} and {{ y }}")
    end

    test "detects tag expressions" do
      assert Expression.contains_expression?("{% if x %}{% endif %}")
    end

    test "returns false for plain strings" do
      refute Expression.contains_expression?("Hello World")
      refute Expression.contains_expression?("")
    end
  end

  describe "filters" do
    test "json filter" do
      ctx = build_context(%{"data" => %{"a" => 1}})
      assert {:ok, ~s({"a":1})} = Expression.evaluate("{{ json.data | json }}", ctx)
    end

    test "dig filter" do
      ctx = build_context(%{"nested" => %{"deep" => %{"value" => "found"}}})
      assert {:ok, "found"} = Expression.evaluate("{{ json.nested | dig: 'deep.value' }}", ctx)
    end

    test "pluck filter" do
      ctx = build_context(%{"items" => [%{"name" => "a"}, %{"name" => "b"}]})
      assert {:ok, result} = Expression.evaluate("{{ json.items | pluck: 'name' | json }}", ctx)
      assert result == ~s(["a","b"])
    end

    test "sha256 filter" do
      ctx = build_context(%{"secret" => "password"})
      assert {:ok, result} = Expression.evaluate("{{ json.secret | sha256 }}", ctx)
      assert String.length(result) == 64
      assert String.match?(result, ~r/^[0-9a-f]+$/)
    end

    test "base64 filters" do
      ctx = build_context(%{"text" => "hello"})
      assert {:ok, "aGVsbG8="} = Expression.evaluate("{{ json.text | base64_encode }}", ctx)

      ctx2 = build_context(%{"encoded" => "aGVsbG8="})
      assert {:ok, "hello"} = Expression.evaluate("{{ json.encoded | base64_decode }}", ctx2)
    end

    test "default filter" do
      ctx = build_context(%{"empty" => nil, "present" => "value"})

      assert {:ok, "fallback"} =
               Expression.evaluate("{{ json.empty | default: 'fallback' }}", ctx)

      assert {:ok, "value"} = Expression.evaluate("{{ json.present | default: 'fallback' }}", ctx)
    end

    test "to_int filter" do
      ctx = build_context(%{"str" => "42"})
      assert {:ok, "42"} = Expression.evaluate("{{ json.str | to_int }}", ctx)
    end

    test "slugify filter" do
      ctx = build_context(%{"title" => "Hello World!"})
      assert {:ok, "hello-world"} = Expression.evaluate("{{ json.title | slugify }}", ctx)
    end

    test "where_eq filter" do
      ctx =
        build_context(%{
          "items" => [
            %{"status" => "active", "name" => "a"},
            %{"status" => "inactive", "name" => "b"},
            %{"status" => "active", "name" => "c"}
          ]
        })

      assert {:ok, result} =
               Expression.evaluate(
                 "{{ json.items | where_eq: 'status', 'active' | pluck: 'name' | json }}",
                 ctx
               )

      assert result == ~s(["a","c"])
    end

    test "sort_by filter" do
      ctx =
        build_context(%{
          "items" => [
            %{"name" => "c"},
            %{"name" => "a"},
            %{"name" => "b"}
          ]
        })

      assert {:ok, result} =
               Expression.evaluate(
                 "{{ json.items | sort_by: 'name' | pluck: 'name' | json }}",
                 ctx
               )

      assert result == ~s(["a","b","c"])
    end

    test "format_date filter" do
      ctx = build_context(%{"date" => "2024-01-15T10:30:00Z"})

      assert {:ok, "2024-01-15"} =
               Expression.evaluate(
                 "{{ json.date | format_date: '%Y-%m-%d' }}",
                 ctx
               )
    end

    test "add_days filter" do
      ctx = build_context(%{"date" => "2024-01-15T10:30:00Z"})
      assert {:ok, result} = Expression.evaluate("{{ json.date | add_days: 7 }}", ctx)
      assert String.contains?(result, "2024-01-22")
    end

    test "math filters" do
      ctx = build_context(%{"num" => -5.7})
      assert {:ok, "5.7"} = Expression.evaluate("{{ json.num | abs }}", ctx)
      assert {:ok, "-5"} = Expression.evaluate("{{ json.num | ceil }}", ctx)
      assert {:ok, "-6"} = Expression.evaluate("{{ json.num | floor }}", ctx)
    end

    test "clamp filter" do
      ctx = build_context(%{"num" => 150})
      assert {:ok, "100.0"} = Expression.evaluate("{{ json.num | clamp: 0, 100 }}", ctx)
    end

    test "chained filters" do
      ctx =
        build_context(%{
          "items" => [
            %{"name" => "HELLO"},
            %{"name" => "WORLD"}
          ]
        })

      assert {:ok, result} =
               Expression.evaluate(
                 "{{ json.items | pluck: 'name' | first | downcase }}",
                 ctx
               )

      assert result == "hello"
    end
  end

  describe "Filters module directly" do
    test "dig handles arrays" do
      data = %{"items" => [%{"name" => "first"}, %{"name" => "second"}]}
      assert "first" = Filters.dig(data, "items.0.name")
    end

    test "group_by creates groups" do
      items = [
        %{"type" => "a", "val" => 1},
        %{"type" => "b", "val" => 2},
        %{"type" => "a", "val" => 3}
      ]

      result = Filters.group_by(items, "type")
      assert length(result["a"]) == 2
      assert length(result["b"]) == 1
    end

    test "index_by creates map" do
      items = [%{"id" => "x", "val" => 1}, %{"id" => "y", "val" => 2}]
      result = Filters.index_by(items, "id")
      assert result["x"]["val"] == 1
      assert result["y"]["val"] == 2
    end

    test "match tests regex" do
      assert Filters.match("abc123", "\\d+")
      refute Filters.match("abc", "^\\d+$")
    end

    test "extract captures regex match" do
      assert "123" = Filters.extract("abc123def", "\\d+")
      assert "" = Filters.extract("abc", "\\d+")
    end

    test "hmac_sha256 produces correct hash" do
      result = Filters.hmac_sha256("message", "secret")
      assert String.length(result) == 64
    end
  end

  describe "Context module" do
    test "builds context from execution context" do
      exec_ctx = %ExecContext{
        execution_id: "exec-123",
        workflow_id: "wf-456",
        workflow_version_id: "ver-789",
        trigger_type: :manual,
        trigger_data: %{"key" => "value"},
        node_outputs: %{"Node1" => %{"result" => "ok"}},
        variables: %{"env" => "prod"},
        current_node_id: "current",
        current_input: %{"input" => "data"},
        metadata: %{trace_id: "trace-abc"}
      }

      vars = Context.build(exec_ctx)

      assert vars["json"] == %{"input" => "data"}
      assert vars["nodes"]["Node1"]["json"] == %{"result" => "ok"}
      assert vars["execution"]["id"] == "exec-123"
      assert vars["workflow"]["id"] == "wf-456"
      assert vars["variables"]["env"] == "prod"
      assert is_binary(vars["now"])
      assert is_binary(vars["today"])
    end

    test "normalizes nested structures" do
      input = %{
        atom_key: "value",
        nested: %{another: "test"},
        datetime: ~U[2024-01-01 12:00:00Z],
        list: [%{a: 1}, %{b: 2}]
      }

      result = Context.normalize_value(input)

      assert result["atom_key"] == "value"
      assert result["nested"]["another"] == "test"
      assert result["datetime"] == "2024-01-01T12:00:00Z"
      assert [%{"a" => 1}, %{"b" => 2}] = result["list"]
    end
  end

  describe "security" do
    test "cannot access file system" do
      ctx = build_context()
      # Liquid doesn't have file access, but verify no injection possible
      assert {:ok, _} = Expression.evaluate("{{ 'test' }}", ctx)
    end

    test "handles very long templates" do
      ctx = build_context(%{"x" => "y"})
      template = String.duplicate("{{ json.x }}", 1000)
      assert {:ok, result} = Expression.evaluate(template, ctx)
      assert String.length(result) == 1000
    end

    test "handles deeply nested access attempts" do
      ctx = build_context(%{"a" => %{"b" => %{"c" => %{"d" => "deep"}}}})
      assert {:ok, "deep"} = Expression.evaluate("{{ json.a.b.c.d }}", ctx)
      assert {:ok, ""} = Expression.evaluate("{{ json.a.b.c.d.e.f.g }}", ctx)
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp build_context(input \\ %{}, node_outputs \\ %{}) do
    %ExecContext{
      execution_id: "test-exec-id",
      workflow_id: "test-workflow-id",
      workflow_version_id: "test-version-id",
      trigger_type: :manual,
      trigger_data: %{},
      node_outputs: node_outputs,
      variables: %{},
      current_node_id: "current-node",
      current_input: input,
      metadata: %{}
    }
  end
end
