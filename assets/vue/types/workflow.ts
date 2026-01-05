// =============================================================================
// Workflow Types
// =============================================================================

export interface Workflow {
    id: string
    name: string
    description?: string
    status: 'draft' | 'active' | 'archived'
    public: boolean
    current_version_tag?: string
    published_version_id?: string
    user_id: string
    draft?: WorkflowDraft
    inserted_at: string
    updated_at: string
}

export interface WorkflowDraft {
    id: string
    workflow_id: string
    steps: Step[]
    connections: Connection[]
    triggers: Trigger[]
    settings: Record<string, unknown>
}

export interface Step {
    id: string
    type_id: string
    name: string
    config: Record<string, unknown>
    position: { x: number; y: number }
    notes?: string
}

export interface Connection {
    id: string
    source_step_id: string
    source_output: string
    target_step_id: string
    target_input: string
}

export interface Trigger {
    id: string
    type: string
    config: Record<string, unknown>
    enabled: boolean
}

// =============================================================================
// Step Type Registry
// =============================================================================

export type StepKind = 'trigger' | 'action' | 'transform' | 'control_flow'

export interface StepType {
    id: string
    name: string
    description?: string
    category: string
    icon?: string
    step_kind: StepKind
    config_schema?: Record<string, unknown>
    input_schema?: Record<string, unknown>
    output_schema?: Record<string, unknown>
}

export interface NodeLibraryItem {
    type_id: string
    name: string
    description: string
    category: string
    icon: string
    step_kind: StepKind
}

// =============================================================================
// Vue Flow Node/Edge Data
// =============================================================================

export interface StepNodeData {
    id: string
    type_id: string
    name: string
    config: Record<string, unknown>
    notes?: string
    icon?: string
    category?: string
    step_kind?: StepKind
    status?: StepExecutionStatus
    stats?: {
        duration_us?: number
    }
    hasInput: boolean
    hasOutput: boolean
    disabled?: boolean
    pinned?: boolean
    locked_by?: string
    selected_by?: Array<{
        id: string
        name: string
        color: string
    }>
}

export interface EdgeData {
    animated?: boolean
}

// =============================================================================
// Execution Types
// =============================================================================

export type ExecutionStatus =
    | 'pending'
    | 'running'
    | 'completed'
    | 'failed'
    | 'cancelled'
    | 'timeout'

export type StepExecutionStatus =
    | 'pending'
    | 'queued'
    | 'running'
    | 'completed'
    | 'failed'
    | 'skipped'

export interface Execution {
    id: string
    workflow_id: string
    workflow_version_id?: string
    status: ExecutionStatus
    execution_type: 'production' | 'preview' | 'partial'
    trigger: {
        type: string
        data: Record<string, unknown>
    }
    context?: Record<string, unknown>
    output?: Record<string, unknown>
    error?: {
        type: string
        message: string
        details?: Record<string, unknown>
    }
    metadata?: Record<string, unknown>
    triggered_by_user_id?: string
    started_at?: string
    completed_at?: string
    inserted_at: string
    updated_at: string
}

export interface StepExecution {
    id: string
    execution_id: string
    step_id: string
    step_type_id: string
    status: StepExecutionStatus
    input_data?: Record<string, unknown>
    output_data?: Record<string, unknown>
    error?: string
    attempt: number
    retry_of_id?: string
    duration_us?: number
    queued_at?: string
    started_at?: string
    completed_at?: string
    metadata?: Record<string, unknown>
    inserted_at: string
}

// =============================================================================
// Collaboration Types
// =============================================================================

export interface UserPresence {
    user: {
        id: string
        name?: string | null
        email?: string | null
    }
    cursor?: {
        x: number
        y: number
    } | null
    selected_steps?: string[]
    focused_step?: string | null
    dragging_steps?: Record<string, { x: number; y: number }> | null
}

export interface EditorState {
    workflow_id: string
    pinned_outputs?: Record<string, unknown>
    disabled_steps?: string[]
    disabled_mode?: Record<string, 'skip' | 'exclude'>
    step_locks?: Record<string, string>
}

// =============================================================================
// Editor UI Types
// =============================================================================

export interface ContextMenuState {
    show: boolean
    x: number
    y: number
    targetNodeId: string | null
    targetType: 'node' | 'pane'
}

export interface MenuItem {
    id: string
    label: string
    icon?: any
    shortcut?: string
    disabled?: boolean
    danger?: boolean
    divider?: boolean
}
