# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Imgd.Repo
alias Imgd.Accounts
alias Imgd.Accounts.User
alias Imgd.Workflows
alias JSV.Schema.Helpers, as: JSONSchema

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

scope = Imgd.Accounts.Scope.for_user(user)

# Build a simple Runic workflow with branching
require Runic
import Runic

# Shared input schema: numeric input
input_schema = JSONSchema.number()

# Example 1: Linear pipeline
linear_workflow =
  workflow(
    name: "linear_pipeline",
    steps: [
      step(fn x -> x * 2 end, name: :double),
      step(fn x -> x + 10 end, name: :add_ten),
      step(fn x -> "Result: #{x}" end, name: :format)
    ]
  )

# Example 2: Branching workflow
branching_workflow =
  workflow(
    name: "branching_pipeline",
    steps: [
      {step(fn x -> x * 2 end, name: :double),
       [
         step(fn x -> x + 5 end, name: :add_five),
         step(fn x -> x - 3 end, name: :subtract_three),
         step(fn x -> x * x end, name: :square)
       ]}
    ]
  )

# Example 3: Multi-step with rules
rule_workflow =
  workflow(
    name: "rule_pipeline",
    steps: [
      step(fn x -> x * 2 end, name: :double)
    ],
    rules: [
      rule(fn x when is_number(x) and x > 20 -> {:large, x} end, name: :check_large),
      rule(fn x when is_number(x) and x <= 20 -> {:small, x} end, name: :check_small)
    ]
  )

# Helper to serialize workflow definition
serialize_workflow = fn runic_wf ->
  build_log = Runic.Workflow.log(runic_wf)
  %{"encoded" => build_log |> :erlang.term_to_binary() |> Base.encode64()}
end

# Create workflows in database
workflows_to_create = [
  %{
    name: "Linear Pipeline",
    description: "A simple sequential workflow: doubles input, adds 10, then formats as string",
    runic: linear_workflow,
    input_schema: input_schema
  },
  %{
    name: "Branching Pipeline",
    description:
      "Doubles input, then branches to three parallel operations: add 5, subtract 3, and square",
    runic: branching_workflow,
    input_schema: input_schema
  },
  %{
    name: "Conditional Pipeline",
    description:
      "Doubles input, then applies rules to categorize as 'large' (>20) or 'small' (<=20)",
    runic: rule_workflow,
    input_schema: input_schema
  }
]

for wf_config <- workflows_to_create do
  # Check if workflow already exists
  existing =
    Workflows.list_workflows(scope)
    |> Enum.find(&(&1.name == wf_config.name))

  if existing do
    IO.puts("⏭️  Skipping '#{wf_config.name}' (already exists)")
  else
    IO.puts("📦 Creating '#{wf_config.name}'...")

    # Create draft workflow
    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        name: wf_config.name,
        description: wf_config.description,
        settings: %{input_schema: wf_config.input_schema}
      })

    # Publish with definition
    definition = serialize_workflow.(wf_config.runic)

    {:ok, workflow} =
      Workflows.publish_workflow(scope, workflow, %{definition: definition})

    IO.puts("✅ Created and published: #{workflow.id}")
  end
end

IO.puts("")
IO.puts("🎉 Seeding complete!")
IO.puts("")
IO.puts("You can log in with:")
IO.puts("  Email: temp@imgd.io")
IO.puts("  Password: password123456")
