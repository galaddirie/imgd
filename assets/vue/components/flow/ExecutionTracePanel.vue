<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import type {
  Execution,
  StepExecution,
  TraceEntry,
  ExecutionStatus,
  StepExecutionStatus,
} from '@/types/workflow';
import {
  ChevronUpIcon,
  ExclamationCircleIcon,
  ClockIcon,
  StopIcon,
} from '@heroicons/vue/24/outline';

// Props from LiveView
interface Props {
  execution?: Execution | null;
  stepExecutions?: StepExecution[];
  isExpanded?: boolean;
  stepNameById?: Record<string, string>;
  selectedStepId?: string | null;
}

const props = withDefaults(defineProps<Props>(), {
  execution: null,
  stepExecutions: () => [],
  isExpanded: true,
  stepNameById: () => ({}),
  selectedStepId: null,
});

const emit = defineEmits<{
  (e: 'toggle'): void;
  (e: 'close'): void;
  (e: 'selectStep', stepId: string): void;
  (e: 'runTest'): void;
  (e: 'cancel'): void;
}>();

const activeTab = ref<'input' | 'output'>('input');
const localSelectedStepId = ref<string | null>(null);

// Mock data when no props (for development)
const mockTraces: TraceEntry[] = [
  {
    id: '1',
    step_id: 'trigger_1',
    step_name: 'Manual Trigger',
    status: 'completed',
    duration_us: 120,
    timestamp: '16:15:01.234',
  },
  {
    id: '2',
    step_id: 'step_http',
    step_name: 'Fetch User Data',
    status: 'completed',
    duration_us: 245000,
    timestamp: '16:15:02.456',
  },
  {
    id: '3',
    step_id: 'step_condition',
    step_name: 'Check Status',
    status: 'completed',
    duration_us: 85,
    timestamp: '16:15:02.789',
  },
  {
    id: '4',
    step_id: 'step_transform',
    step_name: 'Format Response',
    status: 'running',
    timestamp: '16:15:03.012',
  },
];

const selectedStepExecution = computed(() => {
  if (!localSelectedStepId.value) return null;
  return props.stepExecutions.find(se => se.step_id === localSelectedStepId.value) || null;
});

// Watch for external selection changes and sync to local state
watch(
  () => props.selectedStepId,
  newSelectedStepId => {
    localSelectedStepId.value = newSelectedStepId ?? null;
  },
  { immediate: true }
);

const formatTraceTimestamp = (execution: StepExecution): string => {
  if (execution.started_at) return new Date(execution.started_at).toLocaleTimeString();
  if (execution.completed_at) return new Date(execution.completed_at).toLocaleTimeString();
  return '';
};

// Computed traces from props or mock
const traces = computed<TraceEntry[]>(() => {
  if (props.stepExecutions.length > 0) {
    return props.stepExecutions.map(se => {
      const baseName = props.stepNameById?.[se.step_id] || se.step_id;
      // Append item number for multi-item steps
      const stepName = se.items_total && se.items_total > 1 && se.item_index !== null && se.item_index !== undefined
        ? `${baseName} #${se.item_index + 1}`
        : baseName;
      
      return {
        id: se.id,
        step_id: se.step_id,
        step_name: stepName,
        status: se.status,
        duration_us: se.duration_us,
        timestamp: formatTraceTimestamp(se),
        error: se.error ? JSON.stringify(se.error) : undefined,
        item_index: se.item_index,
        items_total: se.items_total,
      };
    });
  }

  if (props.execution) {
    return [];
  }

  if (import.meta.env.DEV) {
    return mockTraces;
  }

  return [];
});

// Execution status
const executionStatus = computed<ExecutionStatus>(() => {
  return props.execution?.status ?? 'pending';
});

const isRunning = computed(
  () => executionStatus.value === 'running' || executionStatus.value === 'pending'
);

// Status counts
const statusCounts = computed(() => {
  const counts = { completed: 0, failed: 0, running: 0, pending: 0 };
  for (const trace of traces.value) {
    if (trace.status === 'completed') counts.completed++;
    else if (trace.status === 'failed') counts.failed++;
    else if (trace.status === 'running') counts.running++;
    else counts.pending++;
  }
  return counts;
});

// Status badge config
const statusBadgeConfig: Record<ExecutionStatus, { class: string; label: string }> = {
  pending: { class: 'badge-ghost', label: 'Pending' },
  running: { class: 'badge-primary', label: 'Running' },
  paused: { class: 'badge-warning', label: 'Paused' },
  completed: { class: 'badge-success', label: 'Completed' },
  failed: { class: 'badge-error', label: 'Failed' },
  cancelled: { class: 'badge-ghost', label: 'Cancelled' },
  timeout: { class: 'badge-warning', label: 'Timeout' },
};

// Step status indicator
const stepStatusClass = (status: StepExecutionStatus): string => {
  const map: Record<StepExecutionStatus, string> = {
    pending: 'bg-base-content/20',
    queued: 'bg-info',
    running: 'bg-primary animate-pulse',
    completed: 'bg-success',
    failed: 'bg-error',
    skipped: 'bg-base-content/30',
    cancelled: 'bg-base-content/40',
  };
  return map[status] || 'bg-base-content/20';
};

// Format duration
const formatDuration = (us?: number): string => {
  if (!us) return '';
  if (us < 1000) return `${us}µs`;
  if (us < 1_000_000) return `${(us / 1000).toFixed(1)}ms`;
  return `${(us / 1_000_000).toFixed(2)}s`;
};

const selectStep = (stepId: string) => {
  if (localSelectedStepId.value === stepId) return;
  localSelectedStepId.value = stepId;
  emit('selectStep', stepId);
};
</script>

<template>
  <div
    class="bg-base-100 border-base-300 flex flex-col overflow-hidden border-t transition-all duration-300"
    :class="isExpanded ? 'h-80' : 'h-11'"
  >
    <!-- Header -->
    <div
      class="bg-base-200/40 hover:bg-base-200 flex h-11 shrink-0 cursor-pointer items-center justify-between px-5 transition-colors"
      @click="emit('toggle')"
    >
      <div class="flex items-center gap-4">
        <!-- Expand/Collapse -->
        <ChevronUpIcon
          class="text-base-content/60 h-5 w-5 transition-transform"
          :class="{ 'rotate-180': isExpanded }"
        />

        <div class="flex items-center gap-3">
          <span class="text-base-content/70 text-sm font-semibold"> Execution Trace </span>
          <span :class="['badge badge-sm font-mono', statusBadgeConfig[executionStatus].class]">
            {{ statusBadgeConfig[executionStatus].label }}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-4">
        <!-- Status summary -->
        <div class="flex items-center gap-3 text-xs font-semibold opacity-60">
          <span class="flex items-center gap-1.5">
            <span class="bg-success h-1.5 w-1.5 rounded-full"></span>
            Success: <span class="text-success">{{ statusCounts.completed }}</span>
          </span>
          <div class="bg-base-300 h-3 w-px"></div>
          <span class="flex items-center gap-1.5">
            <span class="bg-error h-1.5 w-1.5 rounded-full"></span>
            Errors: <span class="text-error">{{ statusCounts.failed }}</span>
          </span>
        </div>

        <!-- Actions -->
        <div class="flex items-center gap-1" @click.stop>
          <button
            v-if="isRunning"
            class="btn btn-ghost btn-xs text-warning gap-1"
            @click="emit('cancel')"
          >
            <StopIcon class="h-4 w-4" />
            Cancel
          </button>
        </div>
      </div>
    </div>

    <!-- Body -->
    <div v-if="isExpanded" class="flex flex-1 overflow-hidden">
      <!-- Steps Timeline -->
      <div class="border-base-200 bg-base-100/50 custom-scrollbar w-80 overflow-y-auto border-r">
        <div class="space-y-1 p-3">
          <div
            v-for="trace in traces"
            :key="trace.id"
            class="hover:bg-primary/5 group flex cursor-pointer items-center gap-3 rounded-xl p-2.5 transition-all"
            :class="{
              'bg-primary/5 border-primary/20 border': trace.status === 'running',
              'bg-primary/10 border-primary/30 border': localSelectedStepId === trace.step_id,
            }"
            @click="selectStep(trace.step_id)"
          >
            <!-- Status indicator -->
            <div
              class="h-2 w-2 shrink-0 rounded-full shadow-sm"
              :class="stepStatusClass(trace.status)"
            ></div>

            <!-- Content -->
            <div class="min-w-0 flex-1">
              <div
                class="text-base-content/80 group-hover:text-primary truncate text-sm font-medium transition-colors"
              >
                {{ trace.step_name }}
              </div>
              <div class="text-base-content/40 text-xs font-medium tracking-tight">
                {{ trace.timestamp }}
                <span v-if="trace.step_id === trace.step_name" class="opacity-60"
                  >• {{ trace.step_id }}</span
                >
              </div>
            </div>

            <!-- Duration -->
            <span class="shrink-0 font-mono text-xs opacity-40">
              {{ formatDuration(trace.duration_us) }}
            </span>

            <!-- Error indicator -->
            <ExclamationCircleIcon
              v-if="trace.status === 'failed'"
              class="text-error h-4 w-4 shrink-0"
            />
          </div>

          <!-- Empty state -->
          <div v-if="traces.length === 0" class="text-base-content/40 py-8 text-center">
            <ClockIcon class="mx-auto mb-2 h-8 w-8 opacity-50" />
            <p class="text-sm">No execution data yet</p>
            <p class="mt-1 text-xs">Run a test to see trace data</p>
          </div>
        </div>
      </div>

      <!-- Detail Panel -->
      <div class="bg-base-200/20 flex flex-1 flex-col overflow-hidden">
        <!-- Tab content -->
        <div class="custom-scrollbar flex-1 overflow-y-auto p-5">
          <!-- Input Tab -->
          <div v-if="activeTab === 'input'" class="space-y-4">
            <div v-if="selectedStepExecution?.input_data" class="font-mono text-sm">
              <h4 class="mb-3 text-sm font-semibold">Input Data</h4>
              <pre class="bg-base-100 border-base-200 overflow-auto rounded-xl border p-4">{{
                JSON.stringify(selectedStepExecution.input_data, null, 2)
              }}</pre>
            </div>
            <div v-else-if="localSelectedStepId" class="text-base-content/40 py-8 text-center">
              <p class="text-sm">No input data available</p>
              <p class="mt-1 text-xs">The step may not have started yet or has no input</p>
            </div>
            <div v-else class="text-base-content/40 py-8 text-center">
              <p class="text-sm">Select a step to view input data</p>
            </div>
          </div>

          <!-- Output Tab -->
          <div v-else-if="activeTab === 'output'" class="space-y-4">
            <div v-if="selectedStepExecution?.output_data" class="font-mono text-sm">
              <h4 class="mb-3 text-sm font-semibold">Output Data</h4>
              <pre class="bg-base-100 border-base-200 overflow-auto rounded-xl border p-4">{{
                JSON.stringify(selectedStepExecution.output_data, null, 2)
              }}</pre>
            </div>
            <div v-else-if="localSelectedStepId" class="text-base-content/40 py-8 text-center">
              <p class="text-sm">No output data available</p>
              <p class="mt-1 text-xs">The step may not have completed yet or has no output</p>
            </div>
            <div v-else class="text-base-content/40 py-8 text-center">
              <p class="text-sm">Select a step to view output data</p>
            </div>
          </div>
        </div>

        <!-- Tab Bar -->
        <div class="border-base-200 bg-base-100 shrink-0 border-t px-5 py-3">
          <div class="bg-base-200/50 flex w-fit rounded-xl p-1">
            <button
              v-for="tab in ['input', 'output'] as const"
              :key="tab"
              class="rounded-lg px-5 py-1.5 text-xs font-semibold capitalize transition-all"
              :class="
                activeTab === tab
                  ? 'bg-base-100 text-primary shadow-sm'
                  : 'text-base-content/50 hover:text-base-content'
              "
              @click="activeTab = tab"
            >
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
