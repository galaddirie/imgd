# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Imgd.Repo
alias Imgd.Accounts
alias Imgd.Accounts.User
alias Imgd.Accounts.Scope
alias Imgd.Workflows
alias Imgd.Workflows.Workflow

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

# Helper to create or update workflows with versioning
defmodule WorkflowSeeder do
  def seed_workflow(scope, workflow_attrs) do
    name = Map.fetch!(workflow_attrs, :name)

    case Workflows.get_workflow_by_name(scope, name) do
      nil ->
        # Workflow doesn't exist, create and publish it
        IO.puts("  → Creating new workflow: #{name}")

        {:ok, workflow} = Workflows.create_workflow(scope, workflow_attrs)

        {:ok, _} =
          Workflows.publish_workflow(scope, workflow, %{
            version_tag: "1.0.0",
            changelog: "Initial seeded workflow"
          })

        workflow

      existing_workflow ->
        # Workflow exists, check if content changed
        temp_workflow = %Workflow{
          nodes: workflow_attrs[:nodes] || workflow_attrs["nodes"],
          connections: workflow_attrs[:connections] || workflow_attrs["connections"],
          triggers: workflow_attrs[:triggers] || workflow_attrs["triggers"],
          settings: workflow_attrs[:settings] || workflow_attrs["settings"] || %{}
        }

        # Compute hash of new content and compare with published version
        new_hash = Workflows.compute_source_hash(temp_workflow)
        published_hash = Workflows.get_published_source_hash(existing_workflow)

        if new_hash != published_hash do
          IO.puts("  → Updating existing workflow: #{name}")

          # Update the workflow content
          update_attrs =
            Map.take(workflow_attrs, [:description, :nodes, :connections, :triggers, :settings])

          {:ok, updated_workflow} =
            Workflows.update_workflow(scope, existing_workflow, update_attrs)

          # Publish new version
          {:ok, _} =
            Workflows.publish_workflow(scope, updated_workflow, %{
              version_tag: next_version_tag(existing_workflow.current_version_tag),
              changelog: "Updated seeded workflow"
            })

          updated_workflow
        else
          IO.puts("  → Workflow unchanged: #{name}")
          existing_workflow
        end
    end
  end

  defp next_version_tag(nil), do: "1.0.0"

  defp next_version_tag(current_tag) do
    case Version.parse(current_tag) do
      {:ok, version} ->
        # Increment patch version for updates
        next_version = %{version | patch: version.patch + 1}
        Version.to_string(next_version)

      :error ->
        "1.0.0"
    end
  end
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

_wf_linear =
  WorkflowSeeder.seed_workflow(scope, %{
    name: "1. Linear Math",
    description: "Simple sequence: (x + 10) * 2",
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

_wf_branch =
  WorkflowSeeder.seed_workflow(scope, %{
    name: "2. Branching Math",
    description: "Splits execution into two parallel math operations",
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

_wf_complex =
  WorkflowSeeder.seed_workflow(scope, %{
    name: "3. Complex Math",
    description: "Diamond pattern: (x+1)^2 AND abs(x+1) -> Both feed into Modulo",
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

# =============================================================================
# 4. Wait Workflow
# =============================================================================
IO.puts("  → Wait Workflow (active)")

wait_start = SeedHelpers.node_id("wait_start")
wait_add = SeedHelpers.node_id("wait_add")
wait_pause = SeedHelpers.node_id("wait_pause")
wait_result = SeedHelpers.node_id("wait_result")

_wf_wait =
  WorkflowSeeder.seed_workflow(scope, %{
    name: "4. Wait Workflow",
    description: "Start -> Add 10 -> Wait 5 seconds -> Debug result",
    nodes: [
      %{
        id: wait_start,
        type_id: "debug",
        name: "Start",
        config: %{"label" => "Input", "level" => "info"},
        position: %{"x" => 100, "y" => 100}
      },
      %{
        id: wait_add,
        type_id: "math",
        name: "Add 10",
        config: %{"operation" => "add", "operand" => 10, "field" => "value"},
        position: %{"x" => 100, "y" => 250}
      },
      %{
        id: wait_pause,
        type_id: "wait",
        name: "Wait 5s",
        config: %{"seconds" => 5},
        position: %{"x" => 100, "y" => 400}
      },
      %{
        id: wait_result,
        type_id: "debug",
        name: "Result",
        config: %{"label" => "Final Result", "level" => "info"},
        position: %{"x" => 100, "y" => 550}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: wait_start, target_node_id: wait_add},
      %{id: SeedHelpers.conn_id(), source_node_id: wait_add, target_node_id: wait_pause},
      %{id: SeedHelpers.conn_id(), source_node_id: wait_pause, target_node_id: wait_result}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{label: "Value 5", description: "5 + 10 = 15 (after 5s wait)", data: %{"value" => 5}},
        %{label: "Value 0", description: "0 + 10 = 10 (after 5s wait)", data: %{"value" => 0}}
      ]
    }
  })

# =============================================================================
# 5. Basic Format Workflow
# =============================================================================
IO.puts("  → Basic Format (active)")

format_start = SeedHelpers.node_id("format_start")
format_msg = SeedHelpers.node_id("format_msg")
format_output = SeedHelpers.node_id("format_output")

_wf_format =
  WorkflowSeeder.seed_workflow(scope, %{
    name: "5. Basic Format",
    description: "Simple string formatting with placeholders",
    nodes: [
      %{
        id: format_start,
        type_id: "debug",
        name: "User Input",
        config: %{"label" => "Input Data", "level" => "info"},
        position: %{"x" => 100, "y" => 100}
      },
      %{
        id: format_msg,
        type_id: "format",
        name: "Format Message",
        config: %{
          "template" => "Hello {{user.name}}! Welcome to {{app.name}}. Your ID is {{user.id}}."
        },
        position: %{"x" => 100, "y" => 250}
      },
      %{
        id: format_output,
        type_id: "debug",
        name: "Formatted Message",
        config: %{"label" => "Result", "level" => "info"},
        position: %{"x" => 100, "y" => 400}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: format_start, target_node_id: format_msg},
      %{id: SeedHelpers.conn_id(), source_node_id: format_msg, target_node_id: format_output}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{
          label: "John Doe",
          description: "Basic user greeting",
          data: %{
            "user" => %{"name" => "John Doe", "id" => "12345"},
            "app" => %{"name" => "MyApp"}
          }
        },
        %{
          label: "Jane Smith",
          description: "Different user data",
          data: %{
            "user" => %{"name" => "Jane Smith", "id" => "67890"},
            "app" => %{"name" => "Dashboard"}
          }
        }
      ]
    }
  })

# =============================================================================
# 6. String Manipulation Workflow
# =============================================================================
IO.puts("  → String Manipulation (active)")

string_input = SeedHelpers.node_id("string_input")
string_concat = SeedHelpers.node_id("string_concat")
string_case = SeedHelpers.node_id("string_case")
string_trim = SeedHelpers.node_id("string_trim")
string_replace = SeedHelpers.node_id("string_replace")
string_final = SeedHelpers.node_id("string_final")

_wf_string =
  WorkflowSeeder.seed_workflow(scope, %{
    name: "6. String Manipulation",
    description: "Complete string processing pipeline: concat, case conversion, trim, replace",
    nodes: [
      %{
        id: string_input,
        type_id: "debug",
        name: "Input Text",
        config: %{"label" => "Raw Input", "level" => "info"},
        position: %{"x" => 100, "y" => 50}
      },
      %{
        id: string_concat,
        type_id: "string_concatenate",
        name: "Build Full Name",
        config: %{"separator" => " ", "input_field" => "name_parts"},
        position: %{"x" => 100, "y" => 200}
      },
      %{
        id: string_case,
        type_id: "string_case",
        name: "Title Case",
        config: %{"operation" => "title"},
        position: %{"x" => 100, "y" => 350}
      },
      %{
        id: string_trim,
        type_id: "string_trim",
        name: "Clean Spaces",
        config: %{"side" => "both"},
        position: %{"x" => 100, "y" => 500}
      },
      %{
        id: string_replace,
        type_id: "string_replace",
        name: "Fix Typos",
        config: %{"pattern" => "jonh", "replacement" => "john", "global" => true},
        position: %{"x" => 100, "y" => 650}
      },
      %{
        id: string_final,
        type_id: "debug",
        name: "Final Result",
        config: %{"label" => "Processed Text", "level" => "info"},
        position: %{"x" => 100, "y" => 800}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: string_input, target_node_id: string_concat},
      %{id: SeedHelpers.conn_id(), source_node_id: string_concat, target_node_id: string_case},
      %{id: SeedHelpers.conn_id(), source_node_id: string_case, target_node_id: string_trim},
      %{id: SeedHelpers.conn_id(), source_node_id: string_trim, target_node_id: string_replace},
      %{id: SeedHelpers.conn_id(), source_node_id: string_replace, target_node_id: string_final}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{
          label: "Name with Typo",
          description: "Process name parts with typo correction",
          data: %{
            "name_parts" => ["  jonh", "doe  "],
            "extra_spaces" => "   messy   "
          }
        },
        %{
          label: "Full Name",
          description: "Build and clean full name from parts",
          data: %{
            "name_parts" => ["mary", "jane", "smith"],
            "title" => "dr."
          }
        }
      ]
    }
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
