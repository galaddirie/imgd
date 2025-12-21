# Runic: Architectural Uniqueness

## The Core Insight: Workflow = Execution State

Unlike traditional workflow engines that separate **definition** from **execution**, Runic unifies them:

```
Traditional Engine:
┌─────────────────┐     ┌─────────────────┐
│ Workflow        │     │ Workflow        │
│ Definition      │ ──▶ │ Instance/Run    │
│ (static)        │     │ (mutable state) │
└─────────────────┘     └─────────────────┘

Runic:
┌─────────────────────────────────────────┐
│ %Workflow{}                             │
│ ┌─────────────────────────────────────┐ │
│ │ Graph containing:                   │ │
│ │ • Component vertices (Steps, Rules)│ │
│ │ • Fact vertices (runtime data)     │ │
│ │ • Edges (flow + execution state)   │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

**The workflow struct itself accumulates execution history.** There's no separate "instance" - you transform the workflow and get back a new workflow containing everything.

---

## The Graph is Everything

Runic's `%Workflow{}` contains a single `Graph` that serves multiple purposes:

### Vertices (Nodes)
| Type | Purpose |
|------|---------|
| `%Root{}` | Entry point for all inputs |
| `%Step{}`, `%Condition{}`, `%Rule{}` | Component definitions |
| `%Fact{}` | Runtime values flowing through |
| `Integer` (generation) | Causal ordering markers |

### Edges (Labeled Connections)
| Label | Meaning |
|-------|---------|
| `:flow` | Static dataflow connection (definition) |
| `:runnable` | "This step can execute with this fact" |
| `:matchable` | "This condition can be checked with this fact" |
| `:ran` | "This step executed with this fact" |
| `:produced` | "This step produced this fact" |
| `:satisfied` | "This condition passed for this fact" |
| `:generation` | Links facts to their causal generation |

```elixir
# After running: workflow |> Workflow.react(5)
# The graph contains edges like:

%Root{} ──[:flow]──▶ %Step{fn x -> x + 1}
                           │
                      [:produced]
                           │
                           ▼
                     %Fact{value: 6, ancestry: {step_hash, input_hash}}
                           │
                      [:runnable]
                           │
                           ▼
                     %Step{fn x -> x * 2}  # Next step ready to run
```

---

## Immutable Transformations

Every operation returns a **new workflow**:

```elixir
workflow1 = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end)])
workflow2 = Workflow.react(workflow1, 5)
workflow3 = Workflow.react(workflow2, 10)

# workflow1 is unchanged - still just the definition
# workflow2 contains the execution of input 5
# workflow3 contains executions of both 5 and 10
```

This enables:
- **Time travel**: Keep references to any point in execution
- **Branching**: Fork a workflow and run different inputs
- **Persistence**: Serialize any workflow state

---

## Two-Phase Execution Model

Runic separates **matching** (left-hand side) from **execution** (right-hand side):

```
┌─────────────┐     ┌─────────────┐
│ MATCH PHASE │ ──▶ │ EXEC PHASE  │
│ (planning)  │     │ (reacting)  │
└─────────────┘     └─────────────┘
     │                    │
     ▼                    ▼
 Conditions           Steps
 evaluated          executed
     │                    │
     ▼                    ▼
 :matchable ──▶ :satisfied ──▶ :runnable ──▶ :ran ──▶ :produced
```

### API Implications

| Function | Match Phase | Execute Phase |
|----------|-------------|---------------|
| `plan/2` | ✓ One level | ✗ |
| `plan_eagerly/2` | ✓ All conditions | ✗ |
| `react/2` | ✓ One level | ✓ One cycle |
| `react_until_satisfied/2` | ✓ All | ✓ All |

This lets you:
- Inspect what *would* run before running it
- Distribute matching vs execution across different processes
- Implement custom scheduling strategies

---

## Causal Generations

Facts are grouped into **generations** for ordering:

```elixir
Generation 0: (workflow definition only)
Generation 1: [input_fact] ──▶ [produced_facts...]
Generation 2: [produced_facts from gen 1] ──▶ [their produced_facts...]
```

```elixir
# In the graph:
1 ──[:generation]──▶ %Fact{value: "input"}
1 ──[:generation]──▶ %Fact{value: "output1"}
2 ──[:generation]──▶ %Fact{value: "derived from output1"}
```

This enables:
- Tracking causality chains
- Querying "what happened in turn N"
- Proper ordering for state machines

---

## Protocol-Driven Extensibility

Three protocols define how components work:

### `Invokable` - How to Execute
```elixir
defprotocol Runic.Workflow.Invokable do
  def invoke(node, workflow, fact)      # Execute and return new workflow
  def match_or_execute(node)            # :match or :execute phase?
end
```

### `Component` - How to Compose
```elixir
defprotocol Runic.Component do
  def connect(component, to, workflow)  # Add to workflow
  def get_component(component, name)    # Access sub-components
  def connectable?(component, other)    # Can these connect?
end
```

### `Transmutable` - How to Become a Workflow
```elixir
defprotocol Runic.Transmutable do
  def transmute(component)              # Convert to %Workflow{}
end
```

**Custom components** implement these protocols to integrate seamlessly.

---

## Event Sourcing Built-In

Workflows are reconstructable from their event log:

```elixir
# Build log captures construction
log = Workflow.build_log(workflow)
# => [%ComponentAdded{source: quoted_ast, to: :root, bindings: %{}}]

# Full log includes runtime events
full_log = Workflow.log(executed_workflow)
# => [%ComponentAdded{...}, %ReactionOccurred{from: step, to: fact, ...}]

# Reconstruct from log
rebuilt = Workflow.from_log(full_log)
```

The `source` field stores the **original AST**, enabling:
- Serialization of workflow definitions
- Reconstruction with different bindings
- Debugging/inspection of what built each component

---

## Pinned Variables in Closures

Runic captures external variables used in step functions:

```elixir
multiplier = 10

step = Runic.step(fn x -> x * ^multiplier end)
# The `^multiplier` is captured in step.bindings

step.bindings
# => %{multiplier: 10, __caller_context__: %Macro.Env{...}}
```

This enables serialization/reconstruction of steps that reference external state.

---

## Key Design Decisions Summary

| Decision | Implication |
|----------|-------------|
| Graph = definition + state | No separate "instance" concept |
| Immutable transformations | Safe concurrency, time travel |
| Labeled edges for execution state | Query "what can run" via graph traversal |
| Two-phase execution | Separate planning from doing |
| Generation tracking | Causal ordering without timestamps |
| Protocol-based extension | Add new component types easily |
| AST preservation | Full serializability |

---

## When This Matters

This architecture excels when you need:

1. **Runtime workflow modification** - Add/remove steps while running
2. **Inspection** - See exactly what will execute and why
3. **Persistence** - Save and restore any execution state
4. **Distributed execution** - Plan on one node, execute on another
5. **Debugging** - Full execution history in one data structure

It trades off:
- **Memory** - Entire history lives in the graph
- **Performance** - Graph operations vs compiled function calls
- **Complexity** - More concepts to learn than simple pipelines