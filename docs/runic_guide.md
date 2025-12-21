# Runic: Complete Guide to Workflow-as-Data in Elixir

Runic is an Elixir library for modeling workflows as composable, runtime-modifiable directed acyclic graphs (DAGs). It's designed for expert systems, user-defined DSLs, and dynamic dataflow pipelines where logic must be composed or modified at runtime.

---

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Simple Workflows](#simple-workflows)
3. [Branching Pipelines](#branching-pipelines)
4. [Rules and Conditional Logic](#rules-and-conditional-logic)
5. [Processing Collections (Map/Reduce)](#processing-collections)
6. [State Machines](#state-machines)
7. [Advanced: Game Server Workflow](#game-server-workflow)
8. [Hooks and Debugging](#hooks-and-debugging)
9. [Serialization and Replay](#serialization-and-replay)

---

## Core Concepts

### Facts
Inputs fed through a workflow are called **Facts**. Every value passing through the system becomes a `%Fact{}` with:
- `value`: The actual data
- `hash`: Unique identifier
- `ancestry`: Tuple of `{parent_step_hash, parent_fact_hash}` tracking lineage

### Steps
The fundamental building block—a simple input → output function:

```elixir
require Runic

# Anonymous function step
step = Runic.step(fn x -> x + 1 end)

# Named step
named_step = Runic.step(fn x -> x * 2 end, name: :doubler)

# Captured function step
step = Runic.step(&String.upcase/1)
```

### Workflows
A workflow is a DAG of connected components:

```elixir
workflow = Runic.workflow(
  name: "my_workflow",
  steps: [...],
  rules: [...]
)
```

### Evaluation
- `Workflow.react/2` - Execute one cycle of runnables
- `Workflow.react_until_satisfied/2` - Run until all leaf nodes reached
- `Workflow.plan/2` - Match phase only (prepare runnables)
- `Workflow.plan_eagerly/2` - Full eager match phase

---

## Simple Workflows

### Linear Pipeline

```elixir
require Runic
alias Runic.Workflow

# A simple three-step pipeline
pipeline = Runic.workflow(
  name: "number_pipeline",
  steps: [
    Runic.step(fn x -> x + 1 end),   # Step A
    Runic.step(fn x -> x * 2 end),   # Step B  
    Runic.step(fn x -> x - 1 end)    # Step C
  ]
)

# Input: 5 → A(6) → B(12) → C(11)
result = pipeline
|> Workflow.react_until_satisfied(5)
|> Workflow.raw_productions()
# => [6, 12, 11]
```

### Nested Pipeline Syntax

Use tuples to express parent-child relationships:

```elixir
workflow = Runic.workflow(
  name: "nested_pipeline",
  steps: [
    {Runic.step(fn x -> x * 2 end, name: :double), [
      {Runic.step(fn x -> x + 10 end, name: :add_ten), [
        Runic.step(fn x -> "Result: #{x}" end, name: :format)
      ]}
    ]}
  ]
)

# Input: 5 → double(10) → add_ten(20) → format("Result: 20")
workflow
|> Workflow.react_until_satisfied(5)
|> Workflow.raw_productions()
# => [10, 20, "Result: 20"]
```

---

## Branching Pipelines

### Fan-Out Pattern

One step feeding multiple dependent steps:

```elixir
defmodule TextProcessing do
  def tokenize(text) do
    text |> String.downcase() |> String.split(~r/[^[:alnum:]\-]/u, trim: true)
  end
  
  def count_words(words), do: Enum.frequencies(words)
  def count_uniques(word_count), do: map_size(word_count)
  def first_word(words), do: List.first(words)
  def last_word(words), do: List.last(words)
end

text_workflow = Runic.workflow(
  name: "text_analysis",
  steps: [
    {Runic.step(&TextProcessing.tokenize/1, name: :tokenize), [
      # Three branches from tokenize
      {Runic.step(&TextProcessing.count_words/1, name: :count), [
        Runic.step(&TextProcessing.count_uniques/1, name: :uniques)
      ]},
      Runic.step(&TextProcessing.first_word/1, name: :first),
      Runic.step(&TextProcessing.last_word/1, name: :last)
    ]}
  ]
)

# Graph structure:
#       tokenize
#      /   |    \
#   count first  last
#     |
#  uniques

text_workflow
|> Workflow.react_until_satisfied("Hello World Example")
|> Workflow.raw_productions()
# => [["hello", "world", "example"], 
#     %{"hello" => 1, "world" => 1, "example" => 1},
#     3, "hello", "example"]
```

### Join Pattern

Combine outputs from multiple parent steps:

```elixir
workflow = Runic.workflow(
  name: "parallel_join",
  steps: [
    # Two parallel parent steps that feed into a child
    {[
      Runic.step(fn x -> x * 2 end, name: :double),
      Runic.step(fn x -> x + 100 end, name: :add_hundred)
    ], [
      # This step receives [double_result, add_hundred_result] as a list
      Runic.step(fn [a, b] -> a + b end, name: :combine)
    ]}
  ]
)

# Input: 10 → double(20), add_hundred(110) → combine(130)
workflow
|> Workflow.react_until_satisfied(10)
|> Workflow.raw_productions()
# => [20, 110, 130]
```

---

## Rules and Conditional Logic

Rules have a left-hand side (condition) and right-hand side (reaction):

### Basic Rules

```elixir
# Using anonymous function with guard
greeting_rule = Runic.rule(fn input when is_binary(input) -> 
  "Hello, #{input}!" 
end)

# Check without executing
Runic.Workflow.Rule.check(greeting_rule, "World")  # => true
Runic.Workflow.Rule.check(greeting_rule, 123)       # => false

# Execute the rule
Runic.Workflow.Rule.run(greeting_rule, "World")    # => "Hello, World!"
```

### Explicit Condition/Reaction

```elixir
age_rule = Runic.rule(
  name: :age_classifier,
  condition: fn age -> is_integer(age) and age >= 0 end,
  reaction: fn age ->
    cond do
      age < 13 -> :child
      age < 20 -> :teenager
      age < 65 -> :adult
      true -> :senior
    end
  end
)
```

### Rules in Workflows

```elixir
classifier_workflow = Runic.workflow(
  name: "value_classifier",
  rules: [
    Runic.rule(
      name: :positive,
      if: fn x -> is_number(x) and x > 0 end,
      do: fn x -> {:positive, x} end
    ),
    Runic.rule(
      name: :negative, 
      if: fn x -> is_number(x) and x < 0 end,
      do: fn x -> {:negative, x} end
    ),
    Runic.rule(
      name: :zero,
      if: fn x -> x == 0 end,
      do: fn _ -> {:zero, 0} end
    ),
    Runic.rule(
      name: :not_a_number,
      if: fn x -> not is_number(x) end,
      do: fn x -> {:error, "#{inspect(x)} is not a number"} end
    )
  ]
)

# Only matching rules fire
classifier_workflow
|> Workflow.react_until_satisfied(-5)
|> Workflow.raw_productions()
# => [{:negative, -5}]

classifier_workflow
|> Workflow.react_until_satisfied("hello")
|> Workflow.raw_productions()
# => [{:error, "\"hello\" is not a number"}]
```

---

## Processing Collections

### Map Operations

```elixir
# Simple map
map_workflow = Runic.workflow(
  name: "double_all",
  steps: [
    {Runic.step(fn -> 1..5 end), [
      Runic.map(fn x -> x * 2 end)
    ]}
  ]
)

map_workflow
|> Workflow.react_until_satisfied(nil)
|> Workflow.raw_productions()
# => [1..5, 2, 4, 6, 8, 10]
```

### Map with Pipeline

```elixir
# Map with nested processing
complex_map = Runic.workflow(
  name: "process_items",
  steps: [
    {Runic.step(fn items -> items end, name: :input), [
      Runic.map({
        Runic.step(fn x -> x * 2 end, name: :double),
        [
          Runic.step(fn x -> x + 1 end, name: :increment),
          Runic.step(fn x -> x - 1 end, name: :decrement)
        ]
      }, name: :process_each)
    ]}
  ]
)

# Each item: double → [increment, decrement]
complex_map
|> Workflow.react_until_satisfied([1, 2, 3])
|> Workflow.raw_productions()
```

### Map + Reduce

```elixir
sum_workflow = Runic.workflow(
  name: "sum_doubled",
  steps: [
    {Runic.step(fn items -> items end), [
      {Runic.map(fn x -> x * 2 end, name: :double_each), [
        Runic.reduce(0, fn x, acc -> acc + x end, map: :double_each)
      ]}
    ]}
  ]
)

# [1,2,3] → map(*2) → [2,4,6] → reduce(+) → 12
sum_workflow
|> Workflow.react_until_satisfied([1, 2, 3])
|> Workflow.raw_productions()
# Final reduction: 12
```

### Simple Reduce (without Map)

```elixir
reduce_workflow = Runic.workflow(
  name: "simple_sum",
  steps: [
    {Runic.step(fn -> 1..10 end), [
      Runic.reduce(0, fn x, acc -> acc + x end)
    ]}
  ]
)

reduce_workflow
|> Workflow.react_until_satisfied(nil)
|> Workflow.raw_productions()
# => [1..10, 55]
```

---

## State Machines

State machines maintain state across multiple inputs with reducers and reactors:

```elixir
# A combination lock state machine
combo_lock = Runic.state_machine(
  name: :combo_lock,
  init: %{
    code: [1, 2, 3],
    attempts: [],
    state: :locked,
    max_attempts: 3
  },
  reducer: fn
    # Reset command
    :reset, state ->
      %{state | attempts: [], state: :locked}
    
    # Already unlocked - ignore input
    digit, %{state: :unlocked} = state when is_integer(digit) ->
      state
    
    # Too many attempts - lockout
    _digit, %{attempts: attempts, max_attempts: max} = state 
    when length(attempts) >= max ->
      %{state | state: :lockout}
    
    # Enter a digit
    digit, %{code: code, attempts: attempts} = state when is_integer(digit) ->
      new_attempts = attempts ++ [digit]
      cond do
        new_attempts == code ->
          %{state | attempts: new_attempts, state: :unlocked}
        length(new_attempts) >= length(code) ->
          %{state | attempts: [], state: :locked}  # Wrong code, reset
        true ->
          %{state | attempts: new_attempts}
      end
  end,
  reactors: [
    fn %{state: :unlocked} -> {:access, :granted} end,
    fn %{state: :lockout} -> {:access, :denied_lockout} end,
    fn %{state: :locked, attempts: []} -> {:status, :ready} end,
    fn %{state: :locked, attempts: a} -> {:status, {:entering, length(a)}} end
  ]
)

# Build workflow and test
lock_workflow = Runic.transmute(combo_lock)

# Enter correct code: 1, 2, 3
lock_workflow
|> Workflow.react_until_satisfied(1)
|> Workflow.react_until_satisfied(2)
|> Workflow.react_until_satisfied(3)
|> Workflow.raw_productions()
# => [..., {:access, :granted}]
```

### Counter State Machine

```elixir
counter = Runic.state_machine(
  name: :counter,
  init: 0,
  reducer: fn
    :increment, count -> count + 1
    :decrement, count -> count - 1
    {:add, n}, count -> count + n
    :reset, _count -> 0
    _other, count -> count
  end,
  reactors: [
    fn count when count > 10 -> {:alert, :high_count, count} end,
    fn count when count < 0 -> {:alert, :negative, count} end,
    fn count -> {:count, count} end
  ]
)
```

---

## Game Server Workflow

Here's a complete example of a turn-based game server:

```elixir
defmodule GameServer do
  @moduledoc """
  A turn-based RPG combat system using Runic workflows.
  """
  
  require Runic
  alias Runic.Workflow
  
  # Game state structure
  defmodule State do
    defstruct [
      :phase,        # :waiting, :player_turn, :enemy_turn, :combat_resolution, :game_over
      :player,       # %{hp: int, max_hp: int, attack: int, defense: int, items: [...]}
      :enemy,        # %{hp: int, max_hp: int, attack: int, defense: int, name: str}
      :turn_count,
      :combat_log,
      :last_action
    ]
  end
  
  def initial_state do
    %State{
      phase: :player_turn,
      player: %{hp: 100, max_hp: 100, attack: 15, defense: 5, items: [:potion, :potion]},
      enemy: %{hp: 80, max_hp: 80, attack: 12, defense: 3, name: "Goblin"},
      turn_count: 1,
      combat_log: [],
      last_action: nil
    }
  end
  
  # The main game state machine
  def game_state_machine do
    Runic.state_machine(
      name: :game_combat,
      init: initial_state(),
      reducer: &reduce_game_action/2,
      reactors: [
        # Victory condition
        fn %State{enemy: %{hp: hp}} = state when hp <= 0 ->
          {:game_over, :victory, state}
        end,
        
        # Defeat condition
        fn %State{player: %{hp: hp}} = state when hp <= 0 ->
          {:game_over, :defeat, state}
        end,
        
        # Turn announcement
        fn %State{phase: :player_turn, turn_count: t} ->
          {:prompt, "Turn #{t}: Choose action - :attack, :defend, {:use_item, :potion}"}
        end,
        
        # Combat log output
        fn %State{last_action: action, combat_log: [latest | _]} when not is_nil(action) ->
          {:log, latest}
        end
      ]
    )
  end
  
  # Game reducer - processes all game actions
  defp reduce_game_action(action, %State{} = state) do
    case {state.phase, action} do
      # Player attacks
      {:player_turn, :attack} ->
        damage = max(0, state.player.attack - state.enemy.defense)
        new_enemy = %{state.enemy | hp: state.enemy.hp - damage}
        log_entry = "Player attacks #{state.enemy.name} for #{damage} damage!"
        
        %State{state |
          enemy: new_enemy,
          phase: :enemy_turn,
          combat_log: [log_entry | state.combat_log],
          last_action: :attack
        }
      
      # Player defends (reduces incoming damage next turn)
      {:player_turn, :defend} ->
        log_entry = "Player takes defensive stance!"
        %State{state |
          phase: :enemy_turn,
          combat_log: [log_entry | state.combat_log],
          last_action: :defend,
          player: Map.put(state.player, :defending, true)
        }
      
      # Player uses item
      {:player_turn, {:use_item, :potion}} when :potion in state.player.items ->
        heal_amount = 30
        new_hp = min(state.player.max_hp, state.player.hp + heal_amount)
        new_items = List.delete(state.player.items, :potion)
        log_entry = "Player drinks potion, restoring #{heal_amount} HP!"
        
        %State{state |
          player: %{state.player | hp: new_hp, items: new_items},
          phase: :enemy_turn,
          combat_log: [log_entry | state.combat_log],
          last_action: {:use_item, :potion}
        }
      
      # No potions left
      {:player_turn, {:use_item, :potion}} ->
        %State{state |
          combat_log: ["No potions remaining!" | state.combat_log],
          last_action: :no_item
        }
      
      # Enemy turn - auto attack
      {:enemy_turn, :enemy_action} ->
        defense_bonus = if Map.get(state.player, :defending, false), do: 10, else: 0
        damage = max(0, state.enemy.attack - state.player.defense - defense_bonus)
        new_player = state.player
          |> Map.put(:hp, state.player.hp - damage)
          |> Map.delete(:defending)
        
        log_entry = "#{state.enemy.name} attacks for #{damage} damage!"
        
        %State{state |
          player: new_player,
          phase: :player_turn,
          turn_count: state.turn_count + 1,
          combat_log: [log_entry | state.combat_log],
          last_action: :enemy_attack
        }
      
      # Invalid action - no state change
      _ ->
        %State{state | last_action: :invalid}
    end
  end
  
  # Build complete game workflow with AI and validation
  def build_game_workflow do
    game_machine = game_state_machine()
    
    Runic.workflow(
      name: :game_server,
      steps: [
        # Input validation step
        {Runic.step(&validate_input/1, name: :validate), [
          # Pass valid actions to state machine
          game_machine
        ]}
      ],
      rules: [
        # Auto-trigger enemy turn after player acts
        Runic.rule(
          name: :enemy_ai,
          if: fn
            {:log, msg} when is_binary(msg) -> 
              String.contains?(msg, "Player")
            _ -> false
          end,
          do: fn _ -> :enemy_action end
        )
      ]
    )
  end
  
  defp validate_input(action) do
    valid_actions = [:attack, :defend, {:use_item, :potion}, :enemy_action]
    if action in valid_actions, do: action, else: {:error, :invalid_action}
  end
  
  # Convenience function to play turns
  def play_turn(workflow, action) do
    workflow
    |> Workflow.react_until_satisfied(action)
  end
  
  def get_state(workflow) do
    workflow
    |> Workflow.productions()
    |> Enum.find(&match?(%Runic.Workflow.Fact{value: %State{}}, &1))
    |> case do
      nil -> nil
      fact -> fact.value
    end
  end
end

# Usage Example:
game = GameServer.build_game_workflow()

game = game
|> GameServer.play_turn(:attack)
|> GameServer.play_turn(:attack)
|> GameServer.play_turn({:use_item, :potion})
|> GameServer.play_turn(:defend)
|> GameServer.play_turn(:attack)

# Check game state
GameServer.get_state(game)
```

---

## Hooks and Debugging

### Before/After Hooks

```elixir
require Logger

debugged_workflow = Runic.workflow(
  name: :with_hooks,
  steps: [
    Runic.step(fn x -> x * 2 end, name: :doubler),
    Runic.step(fn x -> x + 1 end, name: :incrementer)
  ],
  before_hooks: [
    doubler: fn step, workflow, fact ->
      Logger.debug("About to run #{step.name} with input: #{inspect(fact.value)}")
      workflow
    end
  ],
  after_hooks: [
    doubler: fn step, workflow, result_fact ->
      Logger.debug("#{step.name} produced: #{inspect(result_fact.value)}")
      workflow
    end,
    incrementer: fn step, workflow, result_fact ->
      Logger.info("Final result: #{result_fact.value}")
      workflow
    end
  ]
)
```

### Dynamic Hook Attachment

```elixir
workflow = Runic.workflow(steps: [
  Runic.step(fn x -> x end, name: :passthrough)
])

workflow_with_hook = workflow
|> Workflow.attach_before_hook(:passthrough, fn step, wrk, fact ->
  IO.puts("Processing: #{inspect(fact.value)}")
  wrk
end)
```

---

## Serialization and Replay

Workflows can be serialized and reconstructed:

### Build Log

```elixir
# Create and use workflow
workflow = Runic.workflow(
  name: :serializable,
  steps: [
    Runic.step(fn x -> x + 1 end, name: :step1),
    Runic.step(fn x -> x * 2 end, name: :step2)
  ]
)

# Get build log (serializable events)
log = Workflow.build_log(workflow)
# => [%ComponentAdded{source: ..., to: ..., bindings: ...}, ...]

# Reconstruct workflow from log
reconstructed = Workflow.from_log(log)
```

### Full Event Log (with reactions)

```elixir
# Run workflow
executed = workflow |> Workflow.react_until_satisfied(5)

# Get complete log including reactions
full_log = Workflow.log(executed)
# Includes %ComponentAdded{} and %ReactionOccurred{} events

# Rebuild entire workflow state
rebuilt = Workflow.from_log(full_log)
```
---
## Common Mistakes and API Clarifications

### Building Workflows Programmatically

When building workflows step-by-step (rather than using the declarative workflow syntax), it's important to understand the correct API:

#### ❌ Common Mistakes

```elixir
# WRONG: Adding steps twice
step1 = Runic.step(fn x -> x end, name: "step1")
wrk = Workflow.add_step(wrk, step1)
wrk = Component.connect(step1, :root, wrk)  # Don't do this!

# WRONG: Calling Component.connect directly
step2 = Runic.step(fn x -> x end, name: "step2")
wrk = Component.connect(step2, "step1", wrk)  # Internal protocol method!

# WRONG: Referencing :root by name
wrk = Workflow.add(wrk, step, to: :root)  # :root is not a component name
```

**Why these are wrong:**
- `Component.connect/3` is an internal protocol method called by `Workflow.add/3` - not meant for direct use
- Adding a step with `add_step` or `add` already connects it to the graph
- The `:root` symbol isn't a registered component name - it's a `%Root{}` struct

#### ✅ Correct Approach

```elixir
require Runic
alias Runic.Workflow

# Create workflow
wrk = Workflow.new(name: "my_workflow")

# Option 1: Using add (high-level, recommended)
step1 = Runic.step(fn x -> x + 1 end, name: "step1")
wrk = Workflow.add(wrk, step1)  # Adds to root automatically

step2 = Runic.step(fn x -> x * 2 end, name: "step2")
wrk = Workflow.add(wrk, step2, to: "step1")  # Adds as child of step1

# Option 2: Using add_step (lower-level)
wrk = Workflow.new(name: "my_workflow")
step1 = Runic.step(fn x -> x + 1 end)
wrk = Workflow.add_step(wrk, step1)  # Adds to root

step2 = Runic.step(fn x -> x * 2 end)
wrk = Workflow.add_step(wrk, step1, step2)  # Connect by struct reference
# or: wrk = Workflow.add_step(wrk, "step1", step2)  # Connect by name

# Test it
wrk
|> Workflow.react_until_satisfied(5)
|> Workflow.raw_productions()
# => [6, 12]
```

---

## Best Practices

1. **Name your components** - Makes debugging and hook attachment easier
2. **Use rules for conditional branching** - Cleaner than embedding conditionals in steps
3. **Leverage state machines for stateful logic** - Keeps state management explicit
4. **Use map/reduce for collection processing** - Enables lazy evaluation and parallelization
5. **Keep steps pure when possible** - Side effects should be isolated to specific steps
6. **Use hooks for cross-cutting concerns** - Logging, metrics, debugging

## When NOT to Use Runic

- Simple, linear code that doesn't need runtime modification
- Performance-critical hot paths (compiled Elixir is faster)
- When workflow structure is known at compile time

Runic shines when:
- Building expert systems
- User-defined workflows (low-code tools)
- Dynamic rule engines
- Complex data pipelines that change at runtime