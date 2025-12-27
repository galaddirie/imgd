// =============================================================================
// Core Workflow Types (matching Elixir schemas)
// =============================================================================

/** Matches Imgd.Workflows.Embeds.Step */
export interface Step {
    id: string
    type_id: string
    name: string
    config: Record<string, unknown>
    position: Position
    notes?: string
}

/** Matches Imgd.Workflows.Embeds.Connection */
export interface Connection {
    id: string
    source_step_id: string
    source_output: string // default: "main"
    target_step_id: string
    target_input: string // default: "main"
}

/** Matches Imgd.Workflows.Embeds.Trigger */
export interface Trigger {
    type: TriggerType
    config: Record<string, unknown>
}

export type TriggerType = 'manual' | 'webhook' | 'schedule' | 'event'

/** Position on canvas */
export interface Position {
    x: number
    y: number
}

// =============================================================================
// Step Type Registry (matching Imgd.Steps.Type)
// =============================================================================

/** Matches Imgd.Steps.Type - blueprint for steps users can add */
export interface StepType {
    id: string
    name: string
    category: string
    description: string
    icon: string
    step_kind: StepKind
    executor: string
    config_schema: JsonSchema
    input_schema: JsonSchema
    output_schema: JsonSchema
}

export type StepKind = 'action' | 'trigger' | 'control_flow' | 'transform'

/** JSON Schema subset for config forms */
export interface JsonSchema {
    type?: string
    required?: string[]
    properties?: Record<string, JsonSchemaProperty>
    description?: string
}

export interface JsonSchemaProperty {
    type?: string
    title?: string
    description?: string
    default?: unknown
    enum?: string[]
    items?: JsonSchemaProperty
}

// =============================================================================
// Execution Types (matching Imgd.Executions)
// =============================================================================

/** Matches Imgd.Executions.Execution */
export interface Execution {
    id: string
    workflow_id: string
    status: ExecutionStatus
    execution_type: ExecutionType
    trigger: ExecutionTrigger
    context: Record<string, unknown>
    output?: Record<string, unknown>
    error?: ExecutionError
    started_at?: string
    completed_at?: string
    metadata?: ExecutionMetadata
}

export type ExecutionStatus =
    | 'pending'
    | 'running'
    | 'paused'
    | 'completed'
    | 'failed'
    | 'cancelled'
    | 'timeout'

export type ExecutionType = 'production' | 'preview' | 'partial'

export interface ExecutionTrigger {
    type: TriggerType
    data: Record<string, unknown>
}

export interface ExecutionError {
    type: string
    message?: string
    step_id?: string
    reason?: string
}

export interface ExecutionMetadata {
    trace_id?: string
    correlation_id?: string
    triggered_by?: string
    tags?: Record<string, string>
    extras?: Record<string, unknown>
}

/** Matches Imgd.Executions.StepExecution */
export interface StepExecution {
    id: string
    execution_id: string
    step_id: string
    step_type_id: string
    status: StepExecutionStatus
    input_data?: Record<string, unknown>
    output_data?: Record<string, unknown>
    error?: Record<string, unknown>
    queued_at?: string
    started_at?: string
    completed_at?: string
    duration_us?: number
    attempt: number
}

export type StepExecutionStatus =
    | 'pending'
    | 'queued'
    | 'running'
    | 'completed'
    | 'failed'
    | 'skipped'

// =============================================================================
// Editor State (matching Imgd.Collaboration.EditorState)
// =============================================================================

/** Matches Imgd.Collaboration.EditorState - session-only state */
export interface EditorState {
    workflow_id: string
    pinned_outputs: Record<string, unknown> // step_id => output_data
    disabled_steps: string[] // step_ids
    disabled_mode: Record<string, 'skip' | 'exclude'>
    step_locks: Record<string, string> // step_id => user_id
}

/** User presence in collaborative session */
export interface UserPresence {
    user: {
        id: string
        email: string
        name: string
    }
    cursor?: Position
    selected_steps: string[]
    focused_step?: string
    joined_at: string
}

// =============================================================================
// Vue Flow Node/Edge Data Types
// =============================================================================

/** Data payload for workflow step nodes in Vue Flow */
export interface StepNodeData {
    // From Step embed
    id: string
    type_id: string
    name: string
    config?: Record<string, unknown>
    notes?: string

    // From StepType (resolved via type_id)
    icon?: string
    category?: string
    step_kind?: StepKind

    // From StepExecution (runtime)
    status?: StepExecutionStatus
    stats?: StepStats

    // Graph connectivity (computed)
    hasInput?: boolean
    hasOutput?: boolean

    // From EditorState
    disabled?: boolean
    pinned?: boolean
    locked_by?: string
}

/** Runtime statistics for a step */
export interface StepStats {
    in?: number
    out?: number
    duration_us?: number
    bytes?: number
}

/** Data payload for edges in Vue Flow */
export interface EdgeData {
    animated?: boolean
    label?: string
}

// =============================================================================
// Workflow Types (matching Elixir structs)
// =============================================================================

/** Matches Imgd.Workflows.Workflow */
export interface Workflow {
    id: string
    name: string
    description?: string
    status: 'draft' | 'active' | 'archived'
    public: boolean
    current_version_tag?: string
    published_version_id?: string
    user_id: string
    inserted_at: string
    updated_at: string

    // Associations
    draft?: WorkflowDraft
    shares?: unknown[]
}

/** Matches Imgd.Workflows.WorkflowDraft */
export interface WorkflowDraft {
    workflow_id: string
    steps: Step[]
    connections: Connection[]
    triggers: Trigger[]
    settings: WorkflowSettings
    inserted_at?: string
    updated_at?: string
}

export interface WorkflowSettings {
    timeout_ms?: number
    max_retries?: number
    [key: string]: unknown
}

// =============================================================================
// UI Component Props Types
// =============================================================================

/** Props for NodeLibrary items */
export interface NodeLibraryItem {
    type_id: string
    name: string
    icon: string
    description: string
    step_kind: StepKind
    category: string
}

/** Props for ExecutionTracePanel entries */
export interface TraceEntry {
    id: string
    step_id: string
    step_name: string
    status: StepExecutionStatus
    duration_us?: number
    timestamp: string
    input_preview?: string
    output_preview?: string
    error?: string
}

/** Log entry for execution panel */
export interface LogEntry {
    id: string
    level: 'debug' | 'info' | 'warn' | 'error'
    message: string
    timestamp: string
    step_id?: string
}