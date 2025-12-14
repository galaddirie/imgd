# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Imgd.Repo
alias Imgd.Accounts
alias Imgd.Accounts.User
alias Imgd.Accounts.Scope
alias Imgd.Workflows

IO.puts("🌱 Seeding database...")

# Create a test user if one doesn't exist
user =
  case Repo.get_by(User, email: "temp@imgd.io") do
    nil ->
      IO.puts("Creating user temp@imgd.io...")

      {:ok, user} =
        Accounts.register_user(%{
          email: "temp@imgd.io",
          password: "password123456"
        })

      user

    user ->
      IO.puts("Using existing user temp@imgd.io...")
      user
  end

scope = %Scope{user: user}

# Helper to generate UUIDs for nodes/connections
defmodule SeedHelpers do
  def node_id(prefix),
    do: "#{prefix}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

  def conn_id, do: "conn_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
end

IO.puts("\n📋 Creating workflows...")

# =============================================================================
# 1. Simple Linear Math Workflow
# =============================================================================
IO.puts("  → Simple Linear Math (active)")

linear_input = SeedHelpers.node_id("debug_in")
linear_add = SeedHelpers.node_id("math_add")
linear_mult = SeedHelpers.node_id("math_mult")
linear_debug = SeedHelpers.node_id("debug_out")

{:ok, wf_linear} =
  Workflows.create_workflow(scope, %{
    name: "1. Linear Math",
    description: "Simple sequence: (x + 10) * 2",
    status: :draft,
    nodes: [
      %{
        id: linear_input,
        type_id: "debug",
        name: "Start",
        config: %{"label" => "Input", "level" => "info"},
        position: %{"x" => 100, "y" => 100}
      },
      %{
        id: linear_add,
        type_id: "math",
        name: "Add 10",
        config: %{"operation" => "add", "operand" => 10, "field" => "value"},
        position: %{"x" => 100, "y" => 250}
      },
      %{
        id: linear_mult,
        type_id: "math",
        name: "Multiply by 2",
        config: %{"operation" => "multiply", "operand" => 2},
        position: %{"x" => 100, "y" => 400}
      },
      %{
        id: linear_debug,
        type_id: "debug",
        name: "Result",
        config: %{"label" => "Final Value", "level" => "info"},
        position: %{"x" => 100, "y" => 550}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: linear_input, target_node_id: linear_add},
      %{id: SeedHelpers.conn_id(), source_node_id: linear_add, target_node_id: linear_mult},
      %{id: SeedHelpers.conn_id(), source_node_id: linear_mult, target_node_id: linear_debug}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{label: "Value 5", description: "(5 + 10) * 2 = 30", data: %{"value" => 5}},
        %{label: "Value 20", description: "(20 + 10) * 2 = 60", data: %{"value" => 20}}
      ]
    }
  })

{:ok, _} =
  Workflows.publish_workflow(scope, wf_linear, %{
    version_tag: "1.0.0",
    changelog: "Initial linear workflow"
  })

# =============================================================================
# 2. Branching Math Workflow
# =============================================================================
IO.puts("  → Branching Math (active)")

branch_start = SeedHelpers.node_id("start")
branch_split = SeedHelpers.node_id("split_math")
branch_path_a = SeedHelpers.node_id("path_a")
branch_path_b = SeedHelpers.node_id("path_b")
branch_debug_a = SeedHelpers.node_id("debug_a")
branch_debug_b = SeedHelpers.node_id("debug_b")

{:ok, wf_branch} =
  Workflows.create_workflow(scope, %{
    name: "2. Branching Math",
    description: "Splits execution into two parallel math operations",
    status: :draft,
    nodes: [
      %{
        id: branch_start,
        type_id: "debug",
        name: "Input",
        config: %{"label" => "Start", "level" => "info"},
        position: %{"x" => 300, "y" => 50}
      },
      %{
        id: branch_split,
        type_id: "math",
        name: "Divide by 2",
        config: %{"operation" => "divide", "operand" => 2, "field" => "number"},
        position: %{"x" => 300, "y" => 200}
      },
      %{
        id: branch_path_a,
        type_id: "math",
        name: "Round Up (Ceil)",
        config: %{"operation" => "ceil"},
        position: %{"x" => 150, "y" => 350}
      },
      %{
        id: branch_path_b,
        type_id: "math",
        name: "Round Down (Floor)",
        config: %{"operation" => "floor"},
        position: %{"x" => 450, "y" => 350}
      },
      %{
        id: branch_debug_a,
        type_id: "debug",
        name: "Ceil Result",
        config: %{"label" => "Ceiled", "level" => "info"},
        position: %{"x" => 150, "y" => 500}
      },
      %{
        id: branch_debug_b,
        type_id: "debug",
        name: "Floor Result",
        config: %{"label" => "Floored", "level" => "info"},
        position: %{"x" => 450, "y" => 500}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: branch_start, target_node_id: branch_split},
      %{id: SeedHelpers.conn_id(), source_node_id: branch_split, target_node_id: branch_path_a},
      %{id: SeedHelpers.conn_id(), source_node_id: branch_split, target_node_id: branch_path_b},
      %{id: SeedHelpers.conn_id(), source_node_id: branch_path_a, target_node_id: branch_debug_a},
      %{id: SeedHelpers.conn_id(), source_node_id: branch_path_b, target_node_id: branch_debug_b}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{
          label: "Number 5.5",
          description: "5.5 / 2 = 2.75 -> Ceil: 3, Floor: 2",
          data: %{"number" => 5.5}
        },
        %{
          label: "Number 9",
          description: "9 / 2 = 4.5 -> Ceil: 5, Floor: 4",
          data: %{"number" => 9}
        }
      ]
    }
  })

{:ok, _} =
  Workflows.publish_workflow(scope, wf_branch, %{
    version_tag: "1.0.0",
    changelog: "Initial branching workflow"
  })

# =============================================================================
# 3. Complex Math Workflow
# =============================================================================
IO.puts("  → Complex Math (active)")

comp_start = SeedHelpers.node_id("start")
comp_add = SeedHelpers.node_id("add")
comp_sq = SeedHelpers.node_id("sq")
comp_abs = SeedHelpers.node_id("abs")
comp_merge = SeedHelpers.node_id("merge_point")
comp_final = SeedHelpers.node_id("final")

{:ok, wf_complex} =
  Workflows.create_workflow(scope, %{
    name: "3. Complex Math",
    description: "Diamond pattern: (x+1)^2 AND abs(x+1) -> Both feed into Modulo",
    status: :draft,
    nodes: [
      %{
        id: comp_start,
        type_id: "debug",
        name: "Input",
        config: %{"label" => "Start", "level" => "info"},
        position: %{"x" => 300, "y" => 50}
      },
      %{
        id: comp_add,
        type_id: "math",
        name: "Add 1",
        config: %{"operation" => "add", "operand" => 1, "field" => "x"},
        position: %{"x" => 300, "y" => 200}
      },
      %{
        id: comp_sq,
        type_id: "math",
        name: "Square (Power 2)",
        config: %{"operation" => "power", "operand" => 2},
        position: %{"x" => 150, "y" => 350}
      },
      %{
        id: comp_abs,
        type_id: "math",
        name: "Absolute Value",
        config: %{"operation" => "abs"},
        position: %{"x" => 450, "y" => 350}
      },
      %{
        id: comp_merge,
        type_id: "math",
        name: "Modulo 5",
        config: %{"operation" => "modulo", "operand" => 5},
        position: %{"x" => 300, "y" => 500},
        notes: "Receives input from both branches independently"
      },
      %{
        id: comp_final,
        type_id: "debug",
        name: "Result",
        config: %{"label" => "Final", "level" => "info"},
        position: %{"x" => 300, "y" => 650}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: comp_start, target_node_id: comp_add},
      %{id: SeedHelpers.conn_id(), source_node_id: comp_add, target_node_id: comp_sq},
      %{id: SeedHelpers.conn_id(), source_node_id: comp_add, target_node_id: comp_abs},
      %{id: SeedHelpers.conn_id(), source_node_id: comp_sq, target_node_id: comp_merge},
      %{id: SeedHelpers.conn_id(), source_node_id: comp_abs, target_node_id: comp_merge},
      %{id: SeedHelpers.conn_id(), source_node_id: comp_merge, target_node_id: comp_final}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{
          label: "x = 3",
          description:
            "Add 1 = 4. Branch 1: 4^2=16. Branch 2: abs(4)=4. Merge(Mod 5): 16%5=1, 4%5=4.",
          data: %{"x" => 3}
        },
        %{
          label: "x = -6",
          description:
            "Add 1 = -5. Branch 1: (-5)^2=25. Branch 2: abs(-5)=5. Merge(Mod 5): 25%5=0, 5%5=0.",
          data: %{"x" => -6}
        }
      ]
    }
  })

{:ok, _} =
  Workflows.publish_workflow(scope, wf_complex, %{
    version_tag: "1.0.0",
    changelog: "Initial complex workflow"
  })

# =============================================================================
# Summary
# =============================================================================
IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("🎉 Seeding complete!")
IO.puts(String.duplicate("=", 60))

workflows = Workflows.list_workflows(scope)
by_status = Enum.group_by(workflows, & &1.status)

IO.puts("\n📊 Workflow Summary:")
IO.puts("  Total: #{length(workflows)}")
IO.puts("  Draft: #{length(Map.get(by_status, :draft, []))}")
IO.puts("  Active: #{length(Map.get(by_status, :active, []))}")
IO.puts("  Archived: #{length(Map.get(by_status, :archived, []))}")

IO.puts("\n📝 Created Workflows:")

for wf <- workflows do
  status_emoji =
    case wf.status do
      :draft -> "📝"
      :active -> "✅"
      :archived -> "📦"
    end

  node_count = length(wf.nodes || [])
  IO.puts("  #{status_emoji} #{wf.name} (#{node_count} nodes)")
end

IO.puts("\n🔐 Login Credentials:")
IO.puts("  Email: temp@imgd.io")
IO.puts("  Password: password123456")
IO.puts("")
