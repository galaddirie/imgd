<script setup lang="ts">
import { ref, computed } from 'vue'
import type {
  Execution,
  StepExecution,
  TraceEntry,
  LogEntry,
  ExecutionStatus,
  StepExecutionStatus
} from '@/types/workflow'
import {
  ChevronUpIcon,
  XMarkIcon,
  CheckCircleIcon,
  ExclamationCircleIcon,
  ClockIcon,
  PlayIcon,
  StopIcon,
} from '@heroicons/vue/24/outline'

// Props from LiveView
interface Props {
  execution?: Execution | null
  stepExecutions?: StepExecution[]
  logs?: LogEntry[]
  isExpanded?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  execution: null,
  stepExecutions: () => [],
  logs: () => [],
  isExpanded: true,
})

const emit = defineEmits<{
  (e: 'toggle'): void
  (e: 'close'): void
  (e: 'selectStep', stepId: string): void
  (e: 'runTest'): void
  (e: 'cancel'): void
}>()

const activeTab = ref<'steps' | 'logs' | 'output'>('steps')
const selectedStepId = ref<string | null>(null)

// Mock data when no props (for development)
const mockTraces: TraceEntry[] = [
  { id: '1', step_id: 'trigger_1', step_name: 'Manual Trigger', status: 'completed', duration_us: 120, timestamp: '16:15:01.234' },
  { id: '2', step_id: 'step_http', step_name: 'Fetch User Data', status: 'completed', duration_us: 245000, timestamp: '16:15:02.456' },
  { id: '3', step_id: 'step_condition', step_name: 'Check Status', status: 'completed', duration_us: 85, timestamp: '16:15:02.789' },
  { id: '4', step_id: 'step_transform', step_name: 'Format Response', status: 'running', timestamp: '16:15:03.012' },
]

const mockLogs: LogEntry[] = [
  { id: 'l1', level: 'info', message: 'Workflow execution started', timestamp: '16:15:00.100' },
  { id: 'l2', level: 'info', message: 'Executing "Manual Trigger"...', timestamp: '16:15:01.234' },
  { id: 'l3', level: 'info', message: 'HTTP GET https://api.example.com/users returned 200 OK', timestamp: '16:15:02.456' },
  { id: 'l4', level: 'warn', message: 'Variable "user_id" is undefined, using default', timestamp: '16:15:02.789' },
]

// Computed traces from props or mock
const traces = computed<TraceEntry[]>(() => {
  if (props.stepExecutions.length > 0) {
    return props.stepExecutions.map(se => ({
      id: se.id,
      step_id: se.step_id,
      step_name: se.step_id, // Would need to resolve from step registry
      status: se.status,
      duration_us: se.duration_us,
      timestamp: se.started_at
        ? new Date(se.started_at).toLocaleTimeString()
        : se.completed_at
          ? new Date(se.completed_at).toLocaleTimeString()
          : '',
      error: se.error ? JSON.stringify(se.error) : undefined,
    }))
  }

  if (props.execution) {
    return []
  }

  return mockTraces
})

const logs = computed<LogEntry[]>(() => {
  if (props.logs.length > 0) {
    return props.logs
  }

  if (props.execution) {
    return []
  }

  return mockLogs
})

// Execution status
const executionStatus = computed<ExecutionStatus>(() => {
  return props.execution?.status ?? 'pending'
})

const isRunning = computed(() =>
  executionStatus.value === 'running' || executionStatus.value === 'pending'
)

// Status counts
const statusCounts = computed(() => {
  const counts = { completed: 0, failed: 0, running: 0, pending: 0 }
  for (const trace of traces.value) {
    if (trace.status === 'completed') counts.completed++
    else if (trace.status === 'failed') counts.failed++
    else if (trace.status === 'running') counts.running++
    else counts.pending++
  }
  return counts
})

// Status badge config
const statusBadgeConfig: Record<ExecutionStatus, { class: string; label: string }> = {
  pending: { class: 'badge-ghost', label: 'Pending' },
  running: { class: 'badge-primary', label: 'Running' },
  paused: { class: 'badge-warning', label: 'Paused' },
  completed: { class: 'badge-success', label: 'Completed' },
  failed: { class: 'badge-error', label: 'Failed' },
  cancelled: { class: 'badge-ghost', label: 'Cancelled' },
  timeout: { class: 'badge-warning', label: 'Timeout' },
}

// Step status indicator
const stepStatusClass = (status: StepExecutionStatus): string => {
  const map: Record<StepExecutionStatus, string> = {
    pending: 'bg-base-content/20',
    queued: 'bg-info',
    running: 'bg-primary animate-pulse',
    completed: 'bg-success',
    failed: 'bg-error',
    skipped: 'bg-base-content/30',
  }
  return map[status] || 'bg-base-content/20'
}

// Log level styling
const logLevelClass = (level: LogEntry['level']): string => {
  const map = {
    debug: 'text-base-content/50',
    info: 'text-primary',
    warn: 'text-warning',
    error: 'text-error',
  }
  return map[level]
}

// Format duration
const formatDuration = (us?: number): string => {
  if (!us) return '...'
  if (us < 1000) return `${us}µs`
  if (us < 1_000_000) return `${(us / 1000).toFixed(1)}ms`
  return `${(us / 1_000_000).toFixed(2)}s`
}

const selectStep = (stepId: string) => {
  selectedStepId.value = stepId
  emit('selectStep', stepId)
}
</script>

<template>
  <div class="flex flex-col bg-base-100 border-t border-base-300 transition-all duration-300 overflow-hidden"
    :class="isExpanded ? 'h-80' : 'h-11'">
    <!-- Header -->
    <div
      class="h-11 px-5 bg-base-200/40 flex items-center justify-between cursor-pointer hover:bg-base-200 transition-colors shrink-0"
      @click="emit('toggle')">
      <div class="flex items-center gap-4">
        <!-- Expand/Collapse -->
        <ChevronUpIcon class="h-5 w-5 transition-transform text-base-content/60"
          :class="{ 'rotate-180': isExpanded }" />

        <div class="flex items-center gap-3">
          <span class="text-sm font-semibold text-base-content/70">
            Execution Trace
          </span>
          <span :class="['badge badge-sm font-mono', statusBadgeConfig[executionStatus].class]">
            {{ statusBadgeConfig[executionStatus].label }}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-4">
        <!-- Status summary -->
        <div class="flex gap-3 text-xs items-center font-semibold opacity-60">
          <span class="flex items-center gap-1.5">
            <span class="w-1.5 h-1.5 rounded-full bg-success"></span>
            Success: <span class="text-success">{{ statusCounts.completed }}</span>
          </span>
          <div class="w-px h-3 bg-base-300"></div>
          <span class="flex items-center gap-1.5">
            <span class="w-1.5 h-1.5 rounded-full bg-error"></span>
            Errors: <span class="text-error">{{ statusCounts.failed }}</span>
          </span>
        </div>

        <!-- Actions -->
        <div class="flex items-center gap-1" @click.stop>
          <button v-if="isRunning" class="btn btn-ghost btn-xs gap-1 text-warning" @click="emit('cancel')">
            <StopIcon class="w-4 h-4" />
            Cancel
          </button>
          <button v-else class="btn btn-ghost btn-xs gap-1" @click="emit('runTest')">
            <PlayIcon class="w-4 h-4" />
            Run Test
          </button>
        </div>

        <button class="btn btn-ghost btn-xs btn-circle hover:bg-error/10 hover:text-error" @click.stop="emit('close')">
          <XMarkIcon class="h-4 w-4" />
        </button>
      </div>
    </div>

    <!-- Body -->
    <div v-if="isExpanded" class="flex-1 flex overflow-hidden">
      <!-- Steps Timeline -->
      <div class="w-80 border-r border-base-200 overflow-y-auto bg-base-100/50 custom-scrollbar">
        <div class="p-3 space-y-1">
          <div v-for="trace in traces" :key="trace.id"
            class="flex items-center gap-3 p-2.5 rounded-xl hover:bg-primary/5 transition-all cursor-pointer group"
            :class="{
              'bg-primary/5 border border-primary/20': trace.status === 'running',
              'bg-primary/10 border border-primary/30': selectedStepId === trace.step_id,
            }" @click="selectStep(trace.step_id)">
            <!-- Status indicator -->
            <div class="w-2 h-2 rounded-full shadow-sm shrink-0" :class="stepStatusClass(trace.status)"></div>

            <!-- Content -->
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium text-base-content/80 group-hover:text-primary transition-colors truncate">
                {{ trace.step_name }}
              </div>
              <div class="text-xs text-base-content/40 font-medium tracking-tight">
                {{ trace.timestamp }}
                <span v-if="trace.step_id" class="opacity-60">• {{ trace.step_id }}</span>
              </div>
            </div>

            <!-- Duration -->
            <span class="text-xs font-mono opacity-40 shrink-0">
              {{ formatDuration(trace.duration_us) }}
            </span>

            <!-- Error indicator -->
            <ExclamationCircleIcon v-if="trace.status === 'failed'" class="w-4 h-4 text-error shrink-0" />
          </div>

          <!-- Empty state -->
          <div v-if="traces.length === 0" class="py-8 text-center text-base-content/40">
            <ClockIcon class="w-8 h-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">No execution data yet</p>
            <p class="text-xs mt-1">Run a test to see trace data</p>
          </div>
        </div>
      </div>

      <!-- Detail Panel -->
      <div class="flex-1 flex flex-col overflow-hidden bg-base-200/20">
        <!-- Tab content -->
        <div class="flex-1 overflow-y-auto p-5 custom-scrollbar">
          <!-- Logs Tab -->
          <div v-if="activeTab === 'logs'" class="space-y-2 font-mono text-sm">
            <div v-for="log in logs" :key="log.id"
              class="flex gap-4 group hover:bg-base-100/50 rounded px-2 py-1 -mx-2">
              <span class="opacity-30 shrink-0 font-medium w-24">
                {{ log.timestamp }}
              </span>
              <span :class="logLevelClass(log.level)"
                class="font-semibold shrink-0 w-12 text-xs tracking-tight uppercase">
                [{{ log.level }}]
              </span>
              <span class="text-base-content/70 group-hover:text-base-content transition-colors">
                {{ log.message }}
              </span>
            </div>

            <div v-if="logs.length === 0" class="py-8 text-center text-base-content/40">
              <p class="text-sm">No logs available</p>
            </div>
          </div>

          <!-- Steps Tab (default) -->
          <div v-else-if="activeTab === 'steps'" class="space-y-4">
            <div v-if="selectedStepId" class="bg-base-100 rounded-xl p-4 border border-base-200">
              <h4 class="font-semibold text-sm mb-3">Step Details</h4>
              <div class="text-sm text-base-content/60">
                <p>Step ID: <code class="text-primary">{{ selectedStepId }}</code></p>
                <!-- Would show input/output data here -->
              </div>
            </div>
            <div v-else class="py-8 text-center text-base-content/40">
              <p class="text-sm">Select a step to view details</p>
            </div>
          </div>

          <!-- Output Tab -->
          <div v-else-if="activeTab === 'output'" class="space-y-4">
            <div v-if="execution?.output" class="font-mono text-sm">
              <pre
                class="bg-base-100 rounded-xl p-4 border border-base-200 overflow-auto">{{ JSON.stringify(execution.output, null, 2) }}</pre>
            </div>
            <div v-else class="py-8 text-center text-base-content/40">
              <CheckCircleIcon class="w-8 h-8 mx-auto mb-2 opacity-50" />
              <p class="text-sm">No output available yet</p>
            </div>
          </div>
        </div>

        <!-- Tab Bar -->
        <div class="px-5 py-3 border-t border-base-200 bg-base-100 shrink-0">
          <div class="flex bg-base-200/50 p-1 rounded-xl w-fit">
            <button v-for="tab in (['steps', 'logs', 'output'] as const)" :key="tab"
              class="px-5 py-1.5 text-xs font-semibold rounded-lg transition-all capitalize" :class="activeTab === tab
                ? 'bg-base-100 text-primary shadow-sm'
                : 'text-base-content/50 hover:text-base-content'" @click="activeTab = tab">
              {{ tab }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 6px;
}

.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 10%, transparent);
  border-radius: 10px;
}
</style>
