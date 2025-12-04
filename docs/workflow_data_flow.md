# Workflow Data Flow Guide

How data is initialized, validated, passed between nodes, and persisted during workflow execution.

## End-to-End Flow

```
User Input --> DataFlow.prepare_input --> Runic.plan_eagerly
                   |                           |
                   v                           v
             Envelope (persisted)        Runic Fact (in-memory)
                   |                           |
                   v                           v
            Step executes               Output Fact
                   |                           |
                   +-------> DataFlow.snapshot (persisted)
```

## Data Shapes

### User input (what callers provide)

```elixir
Workflows.start_execution(scope, workflow, input: 42)
Workflows.start_execution(scope, workflow, input: %{user_id: 1, action: "process"})
Workflows.start_execution(scope, workflow, input: ["a", "b", "c"])
```

### Envelope (persistence layer)

```elixir
%Imgd.Engine.DataFlow.Envelope{
  value: %{user_id: 1, action: "process"},
  metadata: %{
    source: :input,
    timestamp: ~U[2024-01-01 12:00:00Z],
    trace_id: "abc123...",
    step_hash: 12345,      # when produced by a step
    step_name: "process",  # when produced by a step
    fact_hash: 67890,      # Runic fact hash
    parent_hash: 11111     # Lineage
  }
}
```

`Workflows.start_execution/3` stores the envelope in `executions.input` and copies the `trace_id` into `executions.metadata["trace_id"]` for correlation.

### Runic facts (runtime layer)

```elixir
%Runic.Workflow.Fact{
  value: %{user_id: 1, action: "process"},
  hash: 67890,
  ancestry: {parent_hash, step_hash}
}
```

### Snapshots (storage friendly)

`DataFlow.snapshot/2` produces JSON-safe maps with truncation for large or non-JSON values:

```elixir
%{"value" => 42, "type" => "integer"}
%{"_truncated" => true, "_original_size" => 50_000, "_preview" => "..."}
%{"_non_json" => true, "_inspect" => "#Function<...>"}
```

## Passing Data Into a Workflow

```elixir
alias Imgd.Engine.DataFlow
alias JSV.Schema.Helpers, as: JSONSchema

schema =
  JSONSchema.object(
    properties: %{
      user_id: JSONSchema.integer(minimum: 1),
      action: JSONSchema.string(enum: ["create", "update", "delete"]),
      payload: JSONSchema.any()
    },
    required: [:user_id, :action]
  )

case Workflows.start_execution(scope, workflow, input: params, metadata: %{}, trigger_type: :manual) do
  {:ok, execution} ->
    # execution.input is the persisted envelope map
    DataFlow.unwrap(execution.input) # raw value sent into Runic

  {:error, {:invalid_input, error}} ->
    DataFlow.ValidationError.to_map(error)
end
```

- `DataFlow.prepare_input/2` validates against the optional `workflow.settings.input_schema`.
- On success, the envelope is persisted; on failure, `start_execution/3` returns the validation error.

## Between Nodes

Steps always receive the **raw value** (DataFlow unwraps before planning) and should return raw values:

```elixir
Runic.workflow(
  steps: [
    Runic.step(fn input -> %{input | processed: true} end, name: :process),
    Runic.step(fn input -> Map.put(input, :timestamp, DateTime.utc_now()) end, name: :stamp)
  ]
)
```

Branching steps receive the same upstream value; accumulators receive `{value, acc}`; rules emit tagged tuples (`{:route, data}`) for downstream routing.

### Snapshots in execution records

- Input snapshots are built from envelopes derived from the incoming fact.
- Output snapshots use the produced fact plus step metadata.
- Both are truncated via `DataFlow.snapshot/2` to stay within storage limits.

## Validation Cheatsheet (JSV helpers)

```elixir
# Primitives
JSONSchema.string(min_length: 1, max_length: 255, format: :email)
JSONSchema.integer(minimum: 0, maximum: 100)
JSONSchema.number(minimum: 0.0)
JSONSchema.boolean()
JSONSchema.any()

# Objects
JSONSchema.object(
  required: [:id],
  properties: %{
    id: JSONSchema.integer(),
    email: JSONSchema.string(format: :email)
  },
  additional_properties: false
)

# Arrays
JSONSchema.array_of(JSONSchema.string(), min_items: 1, max_items: 10)

# Nullable / unions
JSONSchema.nullable(JSONSchema.string())
%{one_of: [JSONSchema.string(), JSONSchema.integer()]}
```

## Error Shapes

Validation errors are returned as `%Imgd.Engine.DataFlow.ValidationError{}` and can be converted to maps:

```elixir
%{
  "path" => "user.email",
  "message" => "invalid format: expected email",
  "expected" => "email",
  "actual" => "\"not-an-email\"",
  "code" => "invalid_format"
}
```

Step runtime errors are normalized as maps in `execution_steps.error` (type/message/stacktrace) and timeouts are recorded as `%{type: "timeout", message: "...ms"}`.

## API Quick Reference

- `DataFlow.prepare_input(value, schema: schema, trace_id: id)` → `{:ok, %Envelope{}} | {:error, %ValidationError{}}`
- `DataFlow.wrap(value, source: :step, step_name: "name", step_hash: 123)` → `%Envelope{}`
- `DataFlow.unwrap(envelope_or_value)` → raw value
- `DataFlow.validate(value, schema)` / `validate!/2`
- `DataFlow.snapshot(value, max_size: 10_000)` → JSON-safe map with truncation markers
- `DataFlow.serialize_for_storage(value)` / `deserialize_from_storage(map)`
