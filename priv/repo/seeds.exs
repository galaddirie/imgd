# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Imgd.Repo
alias Imgd.Accounts
alias Imgd.Accounts.User
alias Imgd.Accounts.Scope
alias Imgd.Workflows
alias Imgd.Workflows.WorkflowShare

IO.puts("🌱 Seeding database...")

# Create test users if they don't exist
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

temp2_user =
  case Repo.get_by(User, email: "temp2@imgd.io") do
    nil ->
      IO.puts("Creating user temp2@imgd.io...")

      {:ok, temp2_user} =
        Accounts.register_user(%{
          email: "temp2@imgd.io",
          password: "password123456"
        })

      temp2_user

    temp2_user ->
      IO.puts("Using existing user temp2@imgd.io...")
      temp2_user
  end

scope = %Scope{user: user}

IO.puts("\n🔐 Login Credentials:")
IO.puts("  Email: temp@imgd.io")
IO.puts("  Password: password123456")
IO.puts("  Email: temp2@imgd.io")
IO.puts("  Password: password123456")
IO.puts("")

IO.puts("📋 Creating example workflows...")

# Helper function to create workflow with draft
create_workflow_with_draft = fn attrs, steps, connections ->
  {:ok, workflow} = Workflows.create_workflow(scope, attrs)

  draft_attrs = %{
    steps: steps,
    connections: connections,
    settings: %{timeout_ms: 300_000, max_retries: 3}
  }

  {:ok, _draft} = Workflows.update_workflow_draft(scope, workflow, draft_attrs)
  workflow
end

# ============================================================================
# Example 1: Linear Workflow - Simple sequential data processing
# ============================================================================
IO.puts("Creating Linear Workflow...")

linear_steps = [
  %{
    id: "start",
    type_id: "manual_input",
    name: "Start",
    config: %{
      "trigger_data" => "{\"name\": \"John Doe\", \"timestamp\": \"2026-01-04 20:00:00\"}"
    },
    position: %{"x" => 100, "y" => 100}
  },
  %{
    id: "format_greeting",
    type_id: "format",
    name: "Format Greeting",
    config: %{"template" => "Hello {{json.name}}! Welcome to the workflow."},
    position: %{"x" => 300, "y" => 100}
  },
  %{
    id: "add_timestamp",
    type_id: "format",
    name: "Add Timestamp",
    config: %{"template" => "{{json.greeting}} Processed at {{json.timestamp}}"},
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "end",
    type_id: "debug",
    name: "End",
    config: %{"message" => "Linear workflow completed"},
    position: %{"x" => 700, "y" => 100}
  }
]

linear_connections = [
  %{
    id: "start_to_format",
    source_step_id: "start",
    source_output: "main",
    target_step_id: "format_greeting",
    target_input: "main"
  },
  %{
    id: "format_to_add_timestamp",
    source_step_id: "format_greeting",
    source_output: "main",
    target_step_id: "add_timestamp",
    target_input: "main"
  },
  %{
    id: "add_timestamp_to_end",
    source_step_id: "add_timestamp",
    source_output: "main",
    target_step_id: "end",
    target_input: "main"
  }
]

# Triggers are now defined as steps (webhook_trigger, schedule_trigger)
# Manual triggers are represented by manual_input steps in the UI.

linear_workflow =
  create_workflow_with_draft.(
    %{
      name: "Linear Data Processing",
      description: "A simple linear workflow that processes data sequentially",
      public: true
    },
    linear_steps,
    linear_connections
  )

IO.puts("✅ Created Linear Workflow: #{linear_workflow.name}")

# ============================================================================
# Example 2: Branching Workflow - Conditional processing with if/else
# ============================================================================
IO.puts("Creating Branching Workflow...")

branching_steps = [
  %{
    id: "input",
    type_id: "manual_input",
    name: "Input",
    config: %{"trigger_data" => "{\"name\": \"Alice\", \"status\": \"active\"}"},
    position: %{"x" => 100, "y" => 150}
  },
  %{
    id: "check_status",
    type_id: "condition",
    name: "Check Status",
    config: %{"condition" => "{{json.status}} == 'active'"},
    position: %{"x" => 300, "y" => 150}
  },
  %{
    id: "active_path",
    type_id: "format",
    name: "Active User",
    config: %{"template" => "✅ User {{json.name}} is active"},
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "inactive_path",
    type_id: "format",
    name: "Inactive User",
    config: %{"template" => "❌ User {{json.name}} is inactive"},
    position: %{"x" => 500, "y" => 200}
  },
  %{
    id: "output",
    type_id: "debug",
    name: "Output",
    config: %{"message" => "Branching workflow completed"},
    position: %{"x" => 700, "y" => 150}
  }
]

branching_connections = [
  %{
    id: "input_to_check",
    source_step_id: "input",
    source_output: "main",
    target_step_id: "check_status",
    target_input: "main"
  },
  %{
    id: "check_to_active",
    source_step_id: "check_status",
    source_output: "true",
    target_step_id: "active_path",
    target_input: "main"
  },
  %{
    id: "check_to_inactive",
    source_step_id: "check_status",
    source_output: "false",
    target_step_id: "inactive_path",
    target_input: "main"
  },
  %{
    id: "active_to_output",
    source_step_id: "active_path",
    source_output: "main",
    target_step_id: "output",
    target_input: "main"
  },
  %{
    id: "inactive_to_output",
    source_step_id: "inactive_path",
    source_output: "main",
    target_step_id: "output",
    target_input: "main"
  }
]

branching_workflow =
  create_workflow_with_draft.(
    %{
      name: "Branching User Status",
      description: "Conditional workflow that routes based on user status",
      public: true
    },
    branching_steps,
    branching_connections
  )

IO.puts("✅ Created Branching Workflow: #{branching_workflow.name}")

# ============================================================================
# Example 3: Diamond Workflow - Switch-based multi-branch routing
# ============================================================================
IO.puts("Creating Diamond Workflow...")

diamond_steps = [
  %{
    id: "start",
    type_id: "manual_input",
    name: "Start",
    config: %{"trigger_data" => "{\"type\": \"user\", \"name\": \"Bob\"}"},
    position: %{"x" => 100, "y" => 200}
  },
  %{
    id: "route_by_type",
    type_id: "switch",
    name: "Route by Type",
    config: %{
      "value" => "{{json.type}}",
      "cases" => [
        %{"match" => "user", "output" => "user_branch"},
        %{"match" => "admin", "output" => "admin_branch"},
        %{"match" => "guest", "output" => "guest_branch"}
      ],
      "default_output" => "other_branch"
    },
    position: %{"x" => 300, "y" => 200}
  },
  %{
    id: "user_processing",
    type_id: "format",
    name: "Process User",
    config: %{"template" => "👤 Processing user: {{json.name}}"},
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "admin_processing",
    type_id: "format",
    name: "Process Admin",
    config: %{"template" => "👑 Processing admin: {{json.name}} (Level: {{json.level}})"},
    position: %{"x" => 500, "y" => 200}
  },
  %{
    id: "guest_processing",
    type_id: "format",
    name: "Process Guest",
    config: %{"template" => "👋 Processing guest: {{json.name}}"},
    position: %{"x" => 500, "y" => 300}
  },
  %{
    id: "other_processing",
    type_id: "format",
    name: "Process Other",
    config: %{"template" => "❓ Processing unknown type: {{json.type}}"},
    position: %{"x" => 500, "y" => 400}
  },
  %{
    id: "merge",
    type_id: "debug",
    name: "Merge Point",
    config: %{"message" => "All branches merged"},
    position: %{"x" => 700, "y" => 200}
  }
]

diamond_connections = [
  %{
    id: "start_to_route",
    source_step_id: "start",
    source_output: "main",
    target_step_id: "route_by_type",
    target_input: "main"
  },
  %{
    id: "route_to_user",
    source_step_id: "route_by_type",
    source_output: "user_branch",
    target_step_id: "user_processing",
    target_input: "main"
  },
  %{
    id: "route_to_admin",
    source_step_id: "route_by_type",
    source_output: "admin_branch",
    target_step_id: "admin_processing",
    target_input: "main"
  },
  %{
    id: "route_to_guest",
    source_step_id: "route_by_type",
    source_output: "guest_branch",
    target_step_id: "guest_processing",
    target_input: "main"
  },
  %{
    id: "route_to_other",
    source_step_id: "route_by_type",
    source_output: "other_branch",
    target_step_id: "other_processing",
    target_input: "main"
  },
  %{
    id: "user_to_merge",
    source_step_id: "user_processing",
    source_output: "main",
    target_step_id: "merge",
    target_input: "main"
  },
  %{
    id: "admin_to_merge",
    source_step_id: "admin_processing",
    source_output: "main",
    target_step_id: "merge",
    target_input: "main"
  },
  %{
    id: "guest_to_merge",
    source_step_id: "guest_processing",
    source_output: "main",
    target_step_id: "merge",
    target_input: "main"
  },
  %{
    id: "other_to_merge",
    source_step_id: "other_processing",
    source_output: "main",
    target_step_id: "merge",
    target_input: "main"
  }
]

diamond_workflow =
  create_workflow_with_draft.(
    %{
      name: "Diamond User Routing",
      description: "Multi-branch routing based on user type with diamond pattern",
      public: true
    },
    diamond_steps,
    diamond_connections
  )

IO.puts("✅ Created Diamond Workflow: #{diamond_workflow.name}")

# ============================================================================
# Example 4: Simple Workflow - Basic format and math operations
# ============================================================================
IO.puts("Creating Simple Workflow...")

simple_steps = [
  %{
    id: "input_data",
    type_id: "manual_input",
    name: "Input Data",
    config: %{"trigger_data" => "{\"a\": 10, \"b\": 20, \"operation\": \"add\"}"},
    position: %{"x" => 100, "y" => 100}
  },
  %{
    id: "format_message",
    type_id: "format",
    name: "Format Message",
    config: %{"template" => "Calculating {{json.operation}} for {{json.a}} and {{json.b}}"},
    position: %{"x" => 300, "y" => 100}
  },
  %{
    id: "perform_calc",
    type_id: "math",
    name: "Calculate",
    config: %{
      "operation" => "add",
      "value" => "{{json.a}}",
      "operand" => "{{json.b}}"
    },
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "format_result",
    type_id: "format",
    name: "Format Result",
    config: %{"template" => "Result: {{json.result}}"},
    position: %{"x" => 700, "y" => 100}
  }
]

simple_connections = [
  %{
    id: "input_to_format",
    source_step_id: "input_data",
    source_output: "main",
    target_step_id: "format_message",
    target_input: "main"
  },
  %{
    id: "format_to_calc",
    source_step_id: "format_message",
    source_output: "main",
    target_step_id: "perform_calc",
    target_input: "main"
  },
  %{
    id: "calc_to_result",
    source_step_id: "perform_calc",
    source_output: "main",
    target_step_id: "format_result",
    target_input: "main"
  }
]

simple_workflow =
  create_workflow_with_draft.(
    %{
      name: "Simple Calculator",
      description: "Basic arithmetic operations with formatting",
      public: true
    },
    simple_steps,
    simple_connections
  )

IO.puts("✅ Created Simple Workflow: #{simple_workflow.name}")

# ============================================================================
# Example 5: Complex Workflow - Multi-step data transformation pipeline
# ============================================================================
IO.puts("Creating Complex Workflow...")

complex_steps = [
  %{
    id: "receive_order",
    type_id: "manual_input",
    name: "Receive Order",
    config: %{
      "trigger_data" => "{\"customer\": \"Acme Corp\", \"subtotal\": 150, \"total\": 150}"
    },
    position: %{"x" => 100, "y" => 150}
  },
  %{
    id: "validate_order",
    type_id: "condition",
    name: "Validate Order",
    config: %{"condition" => "{{json.total}} > 0"},
    position: %{"x" => 300, "y" => 150}
  },
  %{
    id: "invalid_order",
    type_id: "format",
    name: "Invalid Order",
    config: %{"template" => "❌ Invalid order: total must be > 0"},
    position: %{"x" => 300, "y" => 250}
  },
  %{
    id: "calculate_tax",
    type_id: "math",
    name: "Calculate Tax",
    config: %{
      "operation" => "multiply",
      "value" => "{{json.subtotal}}",
      "operand" => "0.08"
    },
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "calculate_total",
    type_id: "math",
    name: "Calculate Total",
    config: %{
      "operation" => "add",
      "value" => "{{json.subtotal}}",
      "operand" => "{{json.tax}}"
    },
    position: %{"x" => 700, "y" => 100}
  },
  %{
    id: "apply_discount",
    type_id: "condition",
    name: "Apply Discount",
    config: %{"condition" => "{{json.subtotal}} > 100"},
    position: %{"x" => 500, "y" => 200}
  },
  %{
    id: "calculate_discount",
    type_id: "math",
    name: "Calculate Discount",
    config: %{
      "operation" => "multiply",
      "value" => "{{json.total}}",
      "operand" => "0.1"
    },
    position: %{"x" => 700, "y" => 200}
  },
  %{
    id: "apply_discount_total",
    type_id: "math",
    name: "Apply Discount",
    config: %{
      "operation" => "subtract",
      "value" => "{{json.total}}",
      "operand" => "{{json.discount}}"
    },
    position: %{"x" => 900, "y" => 200}
  },
  %{
    id: "format_invoice",
    type_id: "format",
    name: "Format Invoice",
    config: %{
      "template" =>
        "Invoice for {{json.customer}}\nSubtotal: ${{json.subtotal}}\nTax: ${{json.tax}}\nDiscount: ${{json.discount || 0}}\nTotal: ${{json.final_total}}"
    },
    position: %{"x" => 1100, "y" => 150}
  },
  %{
    id: "complete_order",
    type_id: "debug",
    name: "Order Complete",
    config: %{"message" => "Order processing completed"},
    position: %{"x" => 1300, "y" => 150}
  }
]

complex_connections = [
  %{
    id: "receive_to_validate",
    source_step_id: "receive_order",
    source_output: "main",
    target_step_id: "validate_order",
    target_input: "main"
  },
  %{
    id: "validate_to_invalid",
    source_step_id: "validate_order",
    source_output: "false",
    target_step_id: "invalid_order",
    target_input: "main"
  },
  %{
    id: "validate_to_tax",
    source_step_id: "validate_order",
    source_output: "true",
    target_step_id: "calculate_tax",
    target_input: "main"
  },
  %{
    id: "tax_to_total",
    source_step_id: "calculate_tax",
    source_output: "main",
    target_step_id: "calculate_total",
    target_input: "main"
  },
  %{
    id: "total_to_discount_check",
    source_step_id: "calculate_total",
    source_output: "main",
    target_step_id: "apply_discount",
    target_input: "main"
  },
  %{
    id: "discount_check_to_calc_discount",
    source_step_id: "apply_discount",
    source_output: "true",
    target_step_id: "calculate_discount",
    target_input: "main"
  },
  %{
    id: "calc_discount_to_apply",
    source_step_id: "calculate_discount",
    source_output: "main",
    target_step_id: "apply_discount_total",
    target_input: "main"
  },
  %{
    id: "apply_discount_to_format",
    source_step_id: "apply_discount_total",
    source_output: "main",
    target_step_id: "format_invoice",
    target_input: "main"
  },
  %{
    id: "total_to_format",
    source_step_id: "calculate_total",
    source_output: "main",
    target_step_id: "format_invoice",
    target_input: "main"
  },
  %{
    id: "format_to_complete",
    source_step_id: "format_invoice",
    source_output: "main",
    target_step_id: "complete_order",
    target_input: "main"
  }
]

complex_workflow =
  create_workflow_with_draft.(
    %{
      name: "Complex Order Processing",
      description: "Multi-step order processing with validation, calculations, and discounts",
      public: true
    },
    complex_steps,
    complex_connections
  )

IO.puts("✅ Created Complex Workflow: #{complex_workflow.name}")

# ============================================================================
# Example 6: Map/Aggregate Workflow - Split and aggregate pattern
# ============================================================================
IO.puts("Creating Map/Aggregate Workflow...")

map_aggregate_steps = [
  %{
    id: "input_list",
    type_id: "manual_input",
    name: "Input List",
    config: %{"trigger_data" => "{\"numbers\": [1, 2, 3, 4, 5]}"},
    position: %{"x" => 100, "y" => 150}
  },
  %{
    id: "split_items",
    type_id: "splitter",
    name: "Split Items",
    config: %{"field" => "numbers"},
    position: %{"x" => 300, "y" => 150}
  },
  %{
    id: "double_value",
    type_id: "math",
    name: "Double Value",
    config: %{
      "operation" => "multiply",
      "value" => "{{json}}",
      "operand" => "2"
    },
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "square_value",
    type_id: "math",
    name: "Square Value",
    config: %{
      "operation" => "power",
      "value" => "{{json}}",
      "operand" => "2"
    },
    position: %{"x" => 500, "y" => 200}
  },
  %{
    id: "aggregate_doubled",
    type_id: "aggregator",
    name: "Aggregate Doubled",
    config: %{"operation" => "sum"},
    position: %{"x" => 700, "y" => 100}
  },
  %{
    id: "aggregate_squared",
    type_id: "aggregator",
    name: "Aggregate Squared",
    config: %{"operation" => "sum"},
    position: %{"x" => 700, "y" => 200}
  },
  %{
    id: "format_results",
    type_id: "format",
    name: "Format Results",
    config: %{
      "template" =>
        "Original: {{json.original_numbers}}\nDoubled Sum: {{json.doubled_sum}}\nSquared Sum: {{json.squared_sum}}"
    },
    position: %{"x" => 900, "y" => 150}
  },
  %{
    id: "output",
    type_id: "debug",
    name: "Output",
    config: %{"message" => "Map/aggregate processing completed"},
    position: %{"x" => 1100, "y" => 150}
  }
]

map_aggregate_connections = [
  %{
    id: "input_to_split",
    source_step_id: "input_list",
    source_output: "main",
    target_step_id: "split_items",
    target_input: "main"
  },
  %{
    id: "split_to_double",
    source_step_id: "split_items",
    source_output: "main",
    target_step_id: "double_value",
    target_input: "main"
  },
  %{
    id: "split_to_square",
    source_step_id: "split_items",
    source_output: "main",
    target_step_id: "square_value",
    target_input: "main"
  },
  %{
    id: "double_to_aggregate",
    source_step_id: "double_value",
    source_output: "main",
    target_step_id: "aggregate_doubled",
    target_input: "main"
  },
  %{
    id: "square_to_aggregate",
    source_step_id: "square_value",
    source_output: "main",
    target_step_id: "aggregate_squared",
    target_input: "main"
  },
  %{
    id: "aggregate_doubled_to_format",
    source_step_id: "aggregate_doubled",
    source_output: "main",
    target_step_id: "format_results",
    target_input: "doubled_sum"
  },
  %{
    id: "aggregate_squared_to_format",
    source_step_id: "aggregate_squared",
    source_output: "main",
    target_step_id: "format_results",
    target_input: "squared_sum"
  },
  %{
    id: "input_to_format",
    source_step_id: "input_list",
    source_output: "main",
    target_step_id: "format_results",
    target_input: "original_numbers"
  },
  %{
    id: "format_to_output",
    source_step_id: "format_results",
    source_output: "main",
    target_step_id: "output",
    target_input: "main"
  }
]

map_aggregate_workflow =
  create_workflow_with_draft.(
    %{
      name: "Map/Aggregate Numbers",
      description: "Split numbers, process in parallel (double & square), then aggregate results",
      public: true
    },
    map_aggregate_steps,
    map_aggregate_connections
  )

IO.puts("✅ Created Map/Aggregate Workflow: #{map_aggregate_workflow.name}")

# ============================================================================
# Example 7: Conditional Workflow - Multiple condition checks
# ============================================================================
IO.puts("Creating Conditional Workflow...")

conditional_steps = [
  %{
    id: "user_input",
    type_id: "debug",
    name: "User Input",
    config: %{"message" => "Received user data"},
    position: %{"x" => 100, "y" => 150}
  },
  %{
    id: "check_age",
    type_id: "condition",
    name: "Check Age",
    config: %{"condition" => "{{json.age}} >= 18"},
    position: %{"x" => 300, "y" => 100}
  },
  %{
    id: "underage",
    type_id: "format",
    name: "Underage",
    config: %{"template" => "❌ User {{json.name}} is underage ({{json.age}})"},
    position: %{"x" => 300, "y" => 200}
  },
  %{
    id: "check_membership",
    type_id: "condition",
    name: "Check Membership",
    config: %{"condition" => "{{json.membership}} == 'premium'"},
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "premium_user",
    type_id: "format",
    name: "Premium User",
    config: %{"template" => "⭐ Premium user {{json.name}} - VIP access granted"},
    position: %{"x" => 700, "y" => 50}
  },
  %{
    id: "check_activity",
    type_id: "condition",
    name: "Check Activity",
    config: %{"condition" => "{{json.last_login_days}} < 30"},
    position: %{"x" => 500, "y" => 150}
  },
  %{
    id: "active_regular",
    type_id: "format",
    name: "Active Regular",
    config: %{"template" => "✅ Regular user {{json.name}} - active member"},
    position: %{"x" => 700, "y" => 100}
  },
  %{
    id: "inactive_regular",
    type_id: "format",
    name: "Inactive Regular",
    config: %{
      "template" => "⚠️ Regular user {{json.name}} - inactive ({{json.last_login_days}} days)"
    },
    position: %{"x" => 700, "y" => 200}
  },
  %{
    id: "inactive_premium",
    type_id: "format",
    name: "Inactive Premium",
    config: %{
      "template" => "⭐ Premium user {{json.name}} - inactive ({{json.last_login_days}} days)"
    },
    position: %{"x" => 900, "y" => 50}
  },
  %{
    id: "final_output",
    type_id: "debug",
    name: "Final Output",
    config: %{"message" => "User classification completed"},
    position: %{"x" => 1100, "y" => 150}
  }
]

conditional_connections = [
  %{
    id: "input_to_age_check",
    source_step_id: "user_input",
    source_output: "main",
    target_step_id: "check_age",
    target_input: "main"
  },
  %{
    id: "age_to_underage",
    source_step_id: "check_age",
    source_output: "false",
    target_step_id: "underage",
    target_input: "main"
  },
  %{
    id: "age_to_membership",
    source_step_id: "check_age",
    source_output: "true",
    target_step_id: "check_membership",
    target_input: "main"
  },
  %{
    id: "membership_to_premium",
    source_step_id: "check_membership",
    source_output: "true",
    target_step_id: "premium_user",
    target_input: "main"
  },
  %{
    id: "membership_to_activity",
    source_step_id: "check_membership",
    source_output: "false",
    target_step_id: "check_activity",
    target_input: "main"
  },
  %{
    id: "activity_to_active_regular",
    source_step_id: "check_activity",
    source_output: "true",
    target_step_id: "active_regular",
    target_input: "main"
  },
  %{
    id: "activity_to_inactive_regular",
    source_step_id: "check_activity",
    source_output: "false",
    target_step_id: "inactive_regular",
    target_input: "main"
  },
  %{
    id: "premium_to_inactive_check",
    source_step_id: "premium_user",
    source_output: "main",
    target_step_id: "check_activity",
    target_input: "main"
  },
  %{
    id: "inactive_premium_to_output",
    source_step_id: "inactive_premium",
    source_output: "main",
    target_step_id: "final_output",
    target_input: "main"
  },
  %{
    id: "active_regular_to_output",
    source_step_id: "active_regular",
    source_output: "main",
    target_step_id: "final_output",
    target_input: "main"
  },
  %{
    id: "inactive_regular_to_output",
    source_step_id: "inactive_regular",
    source_output: "main",
    target_step_id: "final_output",
    target_input: "main"
  },
  %{
    id: "underage_to_output",
    source_step_id: "underage",
    source_output: "main",
    target_step_id: "final_output",
    target_input: "main"
  }
]

conditional_workflow =
  create_workflow_with_draft.(
    %{
      name: "Multi-Conditional User Classification",
      description: "Complex conditional logic with multiple branching paths",
      public: true
    },
    conditional_steps,
    conditional_connections
  )

IO.puts("✅ Created Conditional Workflow: #{conditional_workflow.name}")

# ============================================================================
# Example 8: Webhook Workflow - Triggered by an external HTTP request
# ============================================================================
IO.puts("Creating Webhook Workflow...")

webhook_steps = [
  %{
    id: "webhook_start",
    type_id: "webhook_trigger",
    name: "Incoming Webhook",
    config: %{
      "path" => "my-webhook",
      "http_method" => "POST",
      "response_mode" => "immediate"
    },
    position: %{"x" => 100, "y" => 100}
  },
  %{
    id: "log_payload",
    type_id: "debug",
    name: "Log Payload",
    config: %{"message" => "Received webhook with data: {{json.body}}"},
    position: %{"x" => 350, "y" => 100}
  }
]

webhook_connections = [
  %{
    id: "webhook_to_log",
    source_step_id: "webhook_start",
    source_output: "default",
    target_step_id: "log_payload",
    target_input: "default"
  }
]

webhook_workflow =
  create_workflow_with_draft.(
    %{
      name: "External Webhook Handler",
      description: "Demonstrates how to trigger a workflow via HTTP POST",
      public: true
    },
    webhook_steps,
    webhook_connections
  )

IO.puts("✅ Created Webhook Workflow: #{webhook_workflow.name}")

# ============================================================================
# Example 9: Scheduled Workflow - Runs periodically on a schedule
# ============================================================================
IO.puts("Creating Scheduled Workflow...")

scheduled_steps = [
  %{
    id: "schedule_start",
    type_id: "schedule_trigger",
    name: "Daily Cleanup",
    config: %{
      "cron" => "0 0 * * *",
      "timezone" => "UTC"
    },
    position: %{"x" => 100, "y" => 100}
  },
  %{
    id: "cleanup_task",
    type_id: "debug",
    name: "Cleanup Task",
    config: %{"message" => "Running scheduled cleanup job"},
    position: %{"x" => 350, "y" => 100}
  }
]

scheduled_connections = [
  %{
    id: "schedule_to_task",
    source_step_id: "schedule_start",
    source_output: "default",
    target_step_id: "cleanup_task",
    target_input: "default"
  }
]

scheduled_workflow =
  create_workflow_with_draft.(
    %{
      name: "Daily Maintenance Schedule",
      description: "A workflow that runs automatically every day at midnight",
      public: true
    },
    scheduled_steps,
    scheduled_connections
  )

IO.puts("✅ Created Scheduled Workflow: #{scheduled_workflow.name}")

# ============================================================================
# Share workflows with temp2@imgd.io as editor
# ============================================================================
IO.puts("\n🔗 Sharing workflows with temp2@imgd.io as editor...")

workflows_to_share = [
  linear_workflow,
  branching_workflow,
  diamond_workflow,
  simple_workflow,
  complex_workflow,
  map_aggregate_workflow,
  conditional_workflow,
  webhook_workflow,
  scheduled_workflow
]

Enum.each(workflows_to_share, fn workflow ->
  case Repo.get_by(WorkflowShare, user_id: temp2_user.id, workflow_id: workflow.id) do
    nil ->
      {:ok, _share} =
        %WorkflowShare{}
        |> WorkflowShare.changeset(%{
          user_id: temp2_user.id,
          workflow_id: workflow.id,
          role: :editor
        })
        |> Repo.insert()

      IO.puts("✅ Shared '#{workflow.name}' with temp2@imgd.io as editor")

    _share ->
      IO.puts("ℹ️ '#{workflow.name}' already shared with temp2@imgd.io")
  end
end)

IO.puts("\n🎉 All example workflows created and shared successfully!")
IO.puts("You can now log in and explore these workflow patterns:")
IO.puts("  - Linear Data Processing")
IO.puts("  - Branching User Status")
IO.puts("  - Diamond User Routing")
IO.puts("  - Simple Calculator")
IO.puts("  - Complex Order Processing")
IO.puts("  - Map/Aggregate Numbers")
IO.puts("  - Multi-Conditional User Classification")
IO.puts("  - External Webhook Handler")
IO.puts("  - Daily Maintenance Schedule")
IO.puts("\nAll workflows have been shared with temp2@imgd.io with editor permissions.")
