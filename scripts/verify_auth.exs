# scripts/verify_auth.exs
alias Imgd.Accounts.{User, Scope}
alias Imgd.Workflows.Workflow
alias Imgd.Collaboration.EditSession.PubSub
alias Imgd.Repo

# Find the workflow from the logs
workflow_id = "92470501-20c4-4925-b416-e50a7dfbc9b6"
user_id = "42eeb920-259f-4848-8581-65f73059d80d"

IO.inspect(workflow_id, label: "Workflow ID")
IO.inspect(user_id, label: "User ID")

workflow = Repo.get(Workflow, workflow_id)
user = Repo.get(User, user_id)

if workflow && user do
  IO.puts "Found workflow and user"
  scope = Scope.for_user(user)

  IO.inspect(workflow.user_id, label: "Workflow Owner ID")
  IO.inspect(user.id, label: "User ID from DB")

  IO.puts "Testing Scope.can_edit_workflow?..."
  res = Scope.can_edit_workflow?(scope, workflow)
  IO.inspect(res, label: "can_edit_workflow?")

  IO.puts "Testing PubSub.authorize_edit..."
  res = PubSub.authorize_edit(scope, workflow_id)
  IO.inspect(res, label: "authorize_edit result")
else
  IO.puts "Could not find workflow or user"
end
