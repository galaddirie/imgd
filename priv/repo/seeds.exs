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
# 1. Simple API Fetch Workflow (Draft)
# =============================================================================
IO.puts("  → Simple API Fetch (draft)")

api_fetch_trigger = SeedHelpers.node_id("trigger")
api_fetch_http = SeedHelpers.node_id("http")
api_fetch_debug = SeedHelpers.node_id("debug")

{:ok, _wf_api_fetch} =
  Workflows.create_workflow(scope, %{
    name: "Simple API Fetch",
    description: "Fetches data from a public API and logs the response",
    status: :draft,
    nodes: [
      %{
        id: api_fetch_http,
        type_id: "http_request",
        name: "Fetch JSONPlaceholder",
        config: %{
          "url" => "https://jsonplaceholder.typicode.com/posts/1",
          "method" => "GET",
          "timeout_ms" => 10_000
        },
        position: %{"x" => 250, "y" => 100}
      },
      %{
        id: api_fetch_debug,
        type_id: "debug",
        name: "Log Response",
        config: %{
          "label" => "API Response",
          "level" => "info"
        },
        position: %{"x" => 250, "y" => 250}
      }
    ],
    connections: [
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: api_fetch_http,
        source_output: "main",
        target_node_id: api_fetch_debug,
        target_input: "main"
      }
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      timeout_ms: 60_000,
      max_retries: 3,
      demo_inputs: [
        %{
          label: "Default request",
          description: "Hit JSONPlaceholder with no payload",
          data: %{}
        },
        %{
          label: "Custom post id",
          description: "Attach a post id to the run for downstream nodes",
          data: %{"post_id" => 42}
        }
      ]
    }
  })

# =============================================================================
# 2. Data Transformation Pipeline (Active, Published)
# =============================================================================
IO.puts("  → Data Transformation Pipeline (active)")

transform_http = SeedHelpers.node_id("http")
transform_pick = SeedHelpers.node_id("transform_pick")
transform_format = SeedHelpers.node_id("format")
transform_debug = SeedHelpers.node_id("debug")

{:ok, wf_transform} =
  Workflows.create_workflow(scope, %{
    name: "Data Transformation Pipeline",
    description: "Fetches user data, transforms it, and formats a greeting message",
    status: :draft,
    nodes: [
      %{
        id: transform_http,
        type_id: "http_request",
        name: "Fetch User",
        config: %{
          "url" => "https://jsonplaceholder.typicode.com/users/1",
          "method" => "GET"
        },
        position: %{"x" => 100, "y" => 100}
      },
      %{
        id: transform_pick,
        type_id: "transform",
        name: "Extract Fields",
        config: %{
          "operation" => "pick",
          "options" => %{"fields" => ["name", "email", "company"]}
        },
        position: %{"x" => 100, "y" => 250}
      },
      %{
        id: transform_format,
        type_id: "format",
        name: "Create Greeting",
        config: %{
          "template" =>
            "Hello {{name}}! Your email is {{email}} and you work at {{company.name}}."
        },
        position: %{"x" => 100, "y" => 400}
      },
      %{
        id: transform_debug,
        type_id: "debug",
        name: "Output",
        config: %{"label" => "Final Message", "level" => "info"},
        position: %{"x" => 100, "y" => 550}
      }
    ],
    connections: [
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: transform_http,
        target_node_id: transform_pick
      },
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: transform_pick,
        target_node_id: transform_format
      },
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: transform_format,
        target_node_id: transform_debug
      }
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      timeout_ms: 120_000,
      max_retries: 2,
      demo_inputs: [
        %{
          label: "User 1",
          description: "Default user data fetched from jsonplaceholder",
          data: %{"user_id" => 1}
        },
        %{
          label: "User 5",
          description: "Fetch and greet a different user id",
          data: %{"user_id" => 5}
        }
      ]
    }
  })

# Publish this workflow
{:ok, _} =
  Workflows.publish_workflow(scope, wf_transform, %{
    version_tag: "1.0.0",
    changelog: "Initial release of data transformation pipeline"
  })

# =============================================================================
# 3. Math Calculator Workflow (Active, Published)
# =============================================================================
IO.puts("  → Math Calculator (active)")

math_debug_in = SeedHelpers.node_id("debug_in")
math_add = SeedHelpers.node_id("math_add")
math_multiply = SeedHelpers.node_id("math_mult")
math_debug_out = SeedHelpers.node_id("debug_out")

{:ok, wf_math} =
  Workflows.create_workflow(scope, %{
    name: "Math Calculator",
    description: "Demonstrates chained math operations: (input + 10) * 2",
    status: :draft,
    nodes: [
      %{
        id: math_debug_in,
        type_id: "debug",
        name: "Log Input",
        config: %{"label" => "Input Value", "level" => "debug"},
        position: %{"x" => 200, "y" => 50}
      },
      %{
        id: math_add,
        type_id: "math",
        name: "Add 10",
        config: %{"operation" => "add", "operand" => 10},
        position: %{"x" => 200, "y" => 200}
      },
      %{
        id: math_multiply,
        type_id: "math",
        name: "Multiply by 2",
        config: %{"operation" => "multiply", "operand" => 2},
        position: %{"x" => 200, "y" => 350}
      },
      %{
        id: math_debug_out,
        type_id: "debug",
        name: "Log Result",
        config: %{"label" => "Calculation Result", "level" => "info"},
        position: %{"x" => 200, "y" => 500}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: math_debug_in, target_node_id: math_add},
      %{id: SeedHelpers.conn_id(), source_node_id: math_add, target_node_id: math_multiply},
      %{id: SeedHelpers.conn_id(), source_node_id: math_multiply, target_node_id: math_debug_out}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{label: "Start at 12", description: "Expect (12 + 10) * 2 = 44", data: 12},
        %{label: "Start at 100", description: "Expect (100 + 10) * 2 = 220", data: 100}
      ]
    }
  })

{:ok, _} =
  Workflows.publish_workflow(scope, wf_math, %{
    version_tag: "1.0.0",
    changelog: "Initial math calculator"
  })

# =============================================================================
# 4. Multi-API Aggregator (Draft - complex workflow)
# =============================================================================
IO.puts("  → Multi-API Aggregator (draft)")

agg_http_posts = SeedHelpers.node_id("http_posts")
agg_http_users = SeedHelpers.node_id("http_users")
agg_transform_posts = SeedHelpers.node_id("transform_posts")
agg_transform_users = SeedHelpers.node_id("transform_users")
agg_merge = SeedHelpers.node_id("merge")
agg_debug = SeedHelpers.node_id("debug")

{:ok, _wf_aggregator} =
  Workflows.create_workflow(scope, %{
    name: "Multi-API Aggregator",
    description: "Fetches from multiple APIs and merges the results (parallel branches)",
    status: :draft,
    nodes: [
      %{
        id: agg_http_posts,
        type_id: "http_request",
        name: "Fetch Posts",
        config: %{
          "url" => "https://jsonplaceholder.typicode.com/posts?_limit=5",
          "method" => "GET"
        },
        position: %{"x" => 100, "y" => 100}
      },
      %{
        id: agg_http_users,
        type_id: "http_request",
        name: "Fetch Users",
        config: %{
          "url" => "https://jsonplaceholder.typicode.com/users?_limit=5",
          "method" => "GET"
        },
        position: %{"x" => 400, "y" => 100}
      },
      %{
        id: agg_transform_posts,
        type_id: "transform",
        name: "Extract Post Titles",
        config: %{"operation" => "map", "options" => %{"field" => "title"}},
        position: %{"x" => 100, "y" => 250}
      },
      %{
        id: agg_transform_users,
        type_id: "transform",
        name: "Extract User Names",
        config: %{"operation" => "map", "options" => %{"field" => "name"}},
        position: %{"x" => 400, "y" => 250}
      },
      %{
        id: agg_merge,
        type_id: "transform",
        name: "Merge Data",
        config: %{
          "operation" => "merge",
          "options" => %{"data" => %{"source" => "aggregated"}}
        },
        position: %{"x" => 250, "y" => 400}
      },
      %{
        id: agg_debug,
        type_id: "debug",
        name: "Final Output",
        config: %{"label" => "Aggregated Data", "level" => "info"},
        position: %{"x" => 250, "y" => 550}
      }
    ],
    connections: [
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: agg_http_posts,
        target_node_id: agg_transform_posts
      },
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: agg_http_users,
        target_node_id: agg_transform_users
      },
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: agg_transform_posts,
        target_node_id: agg_merge
      },
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: agg_transform_users,
        target_node_id: agg_merge
      },
      %{id: SeedHelpers.conn_id(), source_node_id: agg_merge, target_node_id: agg_debug}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      timeout_ms: 180_000,
      max_retries: 1,
      demo_inputs: [
        %{
          label: "Default fetch",
          description: "Run with no payload and gather sample posts/users",
          data: %{}
        },
        %{
          label: "Limit to 3",
          description: "Use a smaller limit hint for downstream processing",
          data: %{"limit" => 3}
        }
      ]
    }
  })

# =============================================================================
# 5. Webhook Handler (Active with webhook trigger)
# =============================================================================
IO.puts("  → Webhook Handler (active)")

webhook_debug_in = SeedHelpers.node_id("debug_in")
webhook_transform = SeedHelpers.node_id("transform")
webhook_format = SeedHelpers.node_id("format")
webhook_http = SeedHelpers.node_id("http")

{:ok, wf_webhook} =
  Workflows.create_workflow(scope, %{
    name: "Webhook Handler",
    description: "Receives webhook data, transforms it, and forwards to another service",
    status: :draft,
    nodes: [
      %{
        id: webhook_debug_in,
        type_id: "debug",
        name: "Log Incoming Webhook",
        config: %{"label" => "Webhook Payload", "level" => "info"},
        position: %{"x" => 200, "y" => 50}
      },
      %{
        id: webhook_transform,
        type_id: "transform",
        name: "Extract Event Data",
        config: %{
          "operation" => "pick",
          "options" => %{"fields" => ["event", "data", "timestamp"]}
        },
        position: %{"x" => 200, "y" => 200}
      },
      %{
        id: webhook_format,
        type_id: "format",
        name: "Format Notification",
        config: %{
          "template" => "Event: {{event}} received at {{timestamp}}"
        },
        position: %{"x" => 200, "y" => 350}
      },
      %{
        id: webhook_http,
        type_id: "http_request",
        name: "Send Notification",
        config: %{
          "url" => "https://httpbin.org/post",
          "method" => "POST",
          "headers" => %{"Content-Type" => "application/json"},
          "body" => %{"message" => "{{ nodes.format.json }}"}
        },
        position: %{"x" => 200, "y" => 500}
      }
    ],
    connections: [
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: webhook_debug_in,
        target_node_id: webhook_transform
      },
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: webhook_transform,
        target_node_id: webhook_format
      },
      %{id: SeedHelpers.conn_id(), source_node_id: webhook_format, target_node_id: webhook_http}
    ],
    triggers: [
      %{type: :webhook, config: %{"path" => "/hooks/incoming", "method" => "POST"}}
    ],
    settings: %{
      demo_inputs: [
        %{
          label: "User created",
          description: "Webhook-style payload for testing without an external caller",
          data: %{
            "event" => "user.created",
            "timestamp" => "2024-01-01T12:00:00Z",
            "data" => %{"id" => "usr_123", "email" => "demo@example.com"}
          }
        }
      ]
    }
  })

{:ok, _} =
  Workflows.publish_workflow(scope, wf_webhook, %{
    version_tag: "1.0.0",
    changelog: "Initial webhook handler"
  })

# =============================================================================
# 6. Archived Legacy Workflow
# =============================================================================
IO.puts("  → Legacy Workflow (archived)")

legacy_http = SeedHelpers.node_id("http")
legacy_debug = SeedHelpers.node_id("debug")

{:ok, wf_legacy} =
  Workflows.create_workflow(scope, %{
    name: "Legacy API Integration",
    description: "Old workflow - no longer in use (kept for reference)",
    status: :draft,
    nodes: [
      %{
        id: legacy_http,
        type_id: "http_request",
        name: "Old API Call",
        config: %{
          "url" => "https://api.example.com/v1/deprecated",
          "method" => "GET"
        },
        position: %{"x" => 200, "y" => 100}
      },
      %{
        id: legacy_debug,
        type_id: "debug",
        name: "Log",
        config: %{"label" => "Response"},
        position: %{"x" => 200, "y" => 250}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: legacy_http, target_node_id: legacy_debug}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{
          label: "Legacy ping",
          description: "Run without payload for quick regression checks",
          data: %{}
        }
      ]
    }
  })

# Publish then archive
{:ok, %{workflow: wf_legacy}} =
  Workflows.publish_workflow(scope, wf_legacy, %{
    version_tag: "1.0.0",
    changelog: "Final version before deprecation"
  })

{:ok, _} = Workflows.archive_workflow(scope, wf_legacy)

# =============================================================================
# 7. Scheduled Report Generator (Active)
# =============================================================================
IO.puts("  → Scheduled Report (active)")

report_http = SeedHelpers.node_id("http")
report_transform = SeedHelpers.node_id("transform")
report_format = SeedHelpers.node_id("format")
report_debug = SeedHelpers.node_id("debug")

{:ok, wf_report} =
  Workflows.create_workflow(scope, %{
    name: "Daily Stats Report",
    description: "Runs on schedule to generate daily statistics report",
    status: :draft,
    nodes: [
      %{
        id: report_http,
        type_id: "http_request",
        name: "Fetch Stats",
        config: %{
          "url" => "https://jsonplaceholder.typicode.com/posts",
          "method" => "GET"
        },
        position: %{"x" => 200, "y" => 100}
      },
      %{
        id: report_transform,
        type_id: "transform",
        name: "Filter Today",
        config: %{
          "operation" => "filter",
          "options" => %{"field" => "userId", "operator" => "eq", "value" => 1}
        },
        position: %{"x" => 200, "y" => 250}
      },
      %{
        id: report_format,
        type_id: "format",
        name: "Generate Report",
        config: %{
          "template" => "Daily Report: Found {{size}} posts for user 1"
        },
        position: %{"x" => 200, "y" => 400}
      },
      %{
        id: report_debug,
        type_id: "debug",
        name: "Output Report",
        config: %{"label" => "Daily Report", "level" => "info"},
        position: %{"x" => 200, "y" => 550}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: report_http, target_node_id: report_transform},
      %{
        id: SeedHelpers.conn_id(),
        source_node_id: report_transform,
        target_node_id: report_format
      },
      %{id: SeedHelpers.conn_id(), source_node_id: report_format, target_node_id: report_debug}
    ],
    triggers: [
      %{type: :schedule, config: %{"cron" => "0 9 * * *", "timezone" => "UTC"}}
    ],
    settings: %{
      demo_inputs: [
        %{
          label: "Daily run context",
          description: "Simulate a scheduled run date",
          data: %{"date" => "2024-01-01"}
        }
      ]
    }
  })

{:ok, _} =
  Workflows.publish_workflow(scope, wf_report, %{
    version_tag: "1.0.0",
    changelog: "Initial scheduled report"
  })

# =============================================================================
# 8. Empty Workflow (Draft - for testing UI)
# =============================================================================
IO.puts("  → Empty Workflow (draft)")

{:ok, _wf_empty} =
  Workflows.create_workflow(scope, %{
    name: "New Project - Untitled",
    description: nil,
    status: :draft,
    nodes: [],
    connections: [],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{label: "Empty payload", description: "Useful for wiring up new nodes", data: %{}}
      ]
    }
  })

# =============================================================================
# 9. All Transform Operations Demo (Draft)
# =============================================================================
IO.puts("  → Transform Operations Demo (draft)")

demo_http = SeedHelpers.node_id("http")
demo_pick = SeedHelpers.node_id("pick")
demo_omit = SeedHelpers.node_id("omit")
demo_set = SeedHelpers.node_id("set")
demo_rename = SeedHelpers.node_id("rename")
demo_debug = SeedHelpers.node_id("debug")

{:ok, _wf_demo} =
  Workflows.create_workflow(scope, %{
    name: "Transform Operations Demo",
    description: "Demonstrates various transform operations: pick, omit, set, rename",
    status: :draft,
    nodes: [
      %{
        id: demo_http,
        type_id: "http_request",
        name: "Fetch Sample Data",
        config: %{
          "url" => "https://jsonplaceholder.typicode.com/users/1",
          "method" => "GET"
        },
        position: %{"x" => 200, "y" => 50}
      },
      %{
        id: demo_pick,
        type_id: "transform",
        name: "Pick Fields",
        config: %{"operation" => "pick", "options" => %{"fields" => ["id", "name", "email"]}},
        position: %{"x" => 200, "y" => 150},
        notes: "Select only id, name, and email fields"
      },
      %{
        id: demo_set,
        type_id: "transform",
        name: "Add Timestamp",
        config: %{
          "operation" => "set",
          "options" => %{"field" => "processed_at", "value" => "2024-01-01"}
        },
        position: %{"x" => 200, "y" => 250},
        notes: "Add a processed_at field"
      },
      %{
        id: demo_rename,
        type_id: "transform",
        name: "Rename Fields",
        config: %{
          "operation" => "rename",
          "options" => %{"mapping" => %{"name" => "fullName", "email" => "emailAddress"}}
        },
        position: %{"x" => 200, "y" => 350},
        notes: "Rename name->fullName and email->emailAddress"
      },
      %{
        id: demo_debug,
        type_id: "debug",
        name: "Final Output",
        config: %{"label" => "Transformed Data", "level" => "info"},
        position: %{"x" => 200, "y" => 450}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: demo_http, target_node_id: demo_pick},
      %{id: SeedHelpers.conn_id(), source_node_id: demo_pick, target_node_id: demo_set},
      %{id: SeedHelpers.conn_id(), source_node_id: demo_set, target_node_id: demo_rename},
      %{id: SeedHelpers.conn_id(), source_node_id: demo_rename, target_node_id: demo_debug}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{
          label: "Sample user profile",
          description: "Matches the transform steps for pick/set/rename demo",
          data: %{
            "id" => 99,
            "name" => "Grace Hopper",
            "email" => "grace@example.com",
            "company" => %{"name" => "Navy"},
            "role" => "Engineer"
          }
        }
      ]
    }
  })

# =============================================================================
# 10. Error Handling Test (Draft - will fail on execution)
# =============================================================================
IO.puts("  → Error Handling Test (draft)")

err_http = SeedHelpers.node_id("http")
err_debug = SeedHelpers.node_id("debug")

{:ok, _wf_error} =
  Workflows.create_workflow(scope, %{
    name: "Error Handling Test",
    description: "Tests error handling - calls a non-existent endpoint",
    status: :draft,
    nodes: [
      %{
        id: err_http,
        type_id: "http_request",
        name: "Call Bad Endpoint",
        config: %{
          "url" => "https://httpstat.us/500",
          "method" => "GET",
          "timeout_ms" => 5000
        },
        position: %{"x" => 200, "y" => 100},
        notes: "This will return a 500 error"
      },
      %{
        id: err_debug,
        type_id: "debug",
        name: "Should Not Reach",
        config: %{"label" => "Success", "level" => "info"},
        position: %{"x" => 200, "y" => 250}
      }
    ],
    connections: [
      %{id: SeedHelpers.conn_id(), source_node_id: err_http, target_node_id: err_debug}
    ],
    triggers: [%{type: :manual, config: %{}}],
    settings: %{
      demo_inputs: [
        %{
          label: "Timeout check",
          description: "Attach a request id to track the failing call",
          data: %{"request_id" => "demo-500"}
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
