# priv/scripts/verify_persistence.exs
alias Imgd.Repo
alias Imgd.Executions.{Execution, StepExecution}
import Ecto.Query

# 1. Find a workflow and create an execution
workflow = Repo.one(from w in Imgd.Workflows.Workflow, limit: 1)
unless workflow do
  IO.puts "No workflow found. Please create one first."
  System.halt(1)
end

# Ensure workflow has a draft
workflow = Repo.preload(workflow, :draft)
unless workflow.draft do
  {:ok, draft} = Imgd.Workflows.create_workflow_version(workflow, %{
    definition: %{
      "steps" => [
        %{"id" => "start", "type_id" => "trigger", "config" => %{}},
        %{"id" => "math", "type_id" => "math", "config" => %{"operation" => "add", "a" => 5, "b" => 10}}
      ],
      "connections" => [
        %{"from_step_id" => "start", "to_step_id" => "math"}
      ]
    }
  })
  workflow = %{workflow | draft_id: draft.id}
end

# Bypass scope checks for verification
execution = %Execution{}
|> Execution.changeset(%{
  workflow_id: workflow.id,
  trigger: %{type: "manual", data: %{}},
  execution_type: :preview,
  status: :pending
})
|> Repo.insert!()

IO.puts "Created execution: #{execution.id}"
execution = Repo.preload(execution, workflow: [:draft, :published_version])

# 2. Start the execution server
{:ok, pid} = Imgd.Runtime.Execution.Server.start_link(execution_id: execution.id)

# Wait for completion (it's short)
Process.sleep(1000)

# 3. Check DB for step executions
steps = Repo.all(from se in StepExecution, where: se.execution_id == ^execution.id)
IO.puts "Found #{length(steps)} step executions in DB."

if length(steps) > 0 do
  IO.puts "Verification SUCCESS: Step executions persisted."
  Enum.each(steps, fn s ->
    IO.puts " - Step: #{s.step_id}, Status: #{s.status}, Type: #{s.step_type_id}"
  end)
else
  IO.puts "Verification FAILURE: No step executions found."
  # Check if execution itself completed
  exec = Repo.get(Execution, execution.id)
  IO.puts "Execution status: #{exec.status}"
end
