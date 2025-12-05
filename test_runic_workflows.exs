# Test script to verify Runic workflow behavior

# Run with: mix run test_runic_workflows.exs

require Runic

import Runic

alias Runic.Workflow

IO.puts("=" |> String.duplicate(60))
IO.puts("RUNIC WORKFLOW BEHAVIOR TESTS")
IO.puts("=" |> String.duplicate(60))

# =============================================================================
# TEST 1: Flat list of steps (current seeds approach)
# =============================================================================

IO.puts(("\n" <> "-") |> String.duplicate(60))
IO.puts("TEST 1: Flat list of steps")
IO.puts("-" |> String.duplicate(60))

flat_workflow =
  workflow(
    name: "flat_list",
    steps: [
      step(fn x -> x * 2 end, name: :double),
      step(fn x -> x + 10 end, name: :add_ten),
      step(fn x -> "Result: #{x}" end, name: :format)
    ]
  )

input = 5
result = flat_workflow |> Workflow.react_until_satisfied(input) |> Workflow.raw_productions()

IO.puts("Input: #{input}")
IO.puts("Productions: #{inspect(result)}")
IO.puts("")

IO.puts("Expected if PARALLEL: [10, 15, \"Result: 5\"]")
IO.puts("  - double: 5 * 2 = 10")
IO.puts("  - add_ten: 5 + 10 = 15")
IO.puts("  - format: \"Result: 5\"")
IO.puts("")

IO.puts("Expected if SEQUENTIAL: [\"Result: 20\"]")
IO.puts("  - double: 5 * 2 = 10")
IO.puts("  - add_ten: 10 + 10 = 20")
IO.puts("  - format: \"Result: 20\"")
IO.puts("")

parallel? = length(result) == 3

IO.puts("RESULT: #{if parallel?, do: "PARALLEL ✗", else: "SEQUENTIAL ✓"}")

# =============================================================================
# TEST 2: Nested tuple syntax (proper linear chain)
# =============================================================================

IO.puts(("\n" <> "-") |> String.duplicate(60))
IO.puts("TEST 2: Nested tuple syntax (a -> b -> c)")
IO.puts("-" |> String.duplicate(60))

linear_workflow =
  workflow(
    name: "linear_chain",
    steps: [
      {step(fn x -> x * 2 end, name: :double),
       [
         {step(fn x -> x + 10 end, name: :add_ten),
          [step(fn x -> "Result: #{x}" end, name: :format)]}
       ]}
    ]
  )

result2 = linear_workflow |> Workflow.react_until_satisfied(input) |> Workflow.raw_productions()

IO.puts("Input: #{input}")
IO.puts("Productions: #{inspect(result2)}")
IO.puts("")

IO.puts("Expected: [10, 20, \"Result: 20\"]")
IO.puts("  - double: 5 * 2 = 10")
IO.puts("  - add_ten: 10 + 10 = 20")
IO.puts("  - format: \"Result: 20\"")
IO.puts("")

sequential? = "Result: 20" in result2

IO.puts("RESULT: #{if sequential?, do: "SEQUENTIAL ✓", else: "UNEXPECTED ✗"}")

# =============================================================================
# TEST 3: Branching (one parent, multiple children)
# =============================================================================

IO.puts(("\n" <> "-") |> String.duplicate(60))
IO.puts("TEST 3: Branching (double -> [add_five, subtract_three, square])")
IO.puts("-" |> String.duplicate(60))

branching_workflow =
  workflow(
    name: "branching",
    steps: [
      {step(fn x -> x * 2 end, name: :double),
       [
         step(fn x -> x + 5 end, name: :add_five),
         step(fn x -> x - 3 end, name: :subtract_three),
         step(fn x -> x * x end, name: :square)
       ]}
    ]
  )

result3 =
  branching_workflow |> Workflow.react_until_satisfied(input) |> Workflow.raw_productions()

IO.puts("Input: #{input}")
IO.puts("Productions: #{inspect(result3)}")
IO.puts("")

IO.puts("Expected: [10, 15, 7, 100]")
IO.puts("  - double: 5 * 2 = 10")
IO.puts("  - add_five: 10 + 5 = 15")
IO.puts("  - subtract_three: 10 - 3 = 7")
IO.puts("  - square: 10 * 10 = 100")
IO.puts("")

branches_from_doubled? = 15 in result3 and 7 in result3 and 100 in result3

IO.puts("RESULT: #{if branches_from_doubled?, do: "BRANCHING CORRECT ✓", else: "UNEXPECTED ✗"}")

# =============================================================================
# TEST 4: Alternative linear syntax using list with single child
# =============================================================================

IO.puts(("\n" <> "-") |> String.duplicate(60))
IO.puts("TEST 4: Alternative syntax {parent, [single_child]}")
IO.puts("-" |> String.duplicate(60))

alt_linear_workflow =
  workflow(
    name: "alt_linear",
    steps: [
      {step(fn x -> x * 2 end, name: :double),
       [
         {step(fn x -> x + 10 end, name: :add_ten),
          [step(fn x -> "Result: #{x}" end, name: :format)]}
       ]}
    ]
  )

result4 =
  alt_linear_workflow |> Workflow.react_until_satisfied(input) |> Workflow.raw_productions()

IO.puts("Input: #{input}")
IO.puts("Productions: #{inspect(result4)}")
IO.puts("")

IO.puts("Expected: [10, 20, \"Result: 20\"]")

alt_sequential? = "Result: 20" in result4

IO.puts("RESULT: #{if alt_sequential?, do: "SEQUENTIAL ✓", else: "UNEXPECTED ✗"}")

# =============================================================================
# TEST 5: Check generation counts
# =============================================================================

IO.puts(("\n" <> "-") |> String.duplicate(60))
IO.puts("TEST 5: Generation comparison")
IO.puts("-" |> String.duplicate(60))

flat_wf_executed = flat_workflow |> Workflow.react_until_satisfied(input)
linear_wf_executed = linear_workflow |> Workflow.react_until_satisfied(input)

IO.puts("Flat workflow generations: #{flat_wf_executed.generations}")
IO.puts("Linear workflow generations: #{linear_wf_executed.generations}")
IO.puts("")

IO.puts("Flat should have 1 generation (all parallel)")
IO.puts("Linear should have 3 generations (sequential)")

# =============================================================================
# SUMMARY
# =============================================================================

IO.puts(("\n" <> "=") |> String.duplicate(60))
IO.puts("SUMMARY")
IO.puts("=" |> String.duplicate(60))
IO.puts("")

IO.puts("Flat list syntax:   steps: [a, b, c]")
IO.puts("  -> Creates PARALLEL steps, all connected to root")
IO.puts("")

IO.puts("Nested tuple syntax: steps: [{a, {b, c}}]")
IO.puts("  -> Creates SEQUENTIAL chain: a -> b -> c")
IO.puts("")

IO.puts("Branching syntax:   steps: [{parent, [child1, child2]}]")
IO.puts("  -> Creates: parent -> child1")
IO.puts("              parent -> child2")
IO.puts("")
