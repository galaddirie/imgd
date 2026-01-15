<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useLiveVue } from 'live_vue'
import type { ExecutionStatus, ResourceUsage } from '@/types/workflow'

const props = defineProps<{
  executionUsage?: ResourceUsage | null
  executionStatus?: ExecutionStatus | null
}>()

const sessionUsage = ref<ResourceUsage | null>(null)
const executionUsage = ref<ResourceUsage | null>(props.executionUsage ?? null)

watch(
  () => props.executionUsage,
  (next) => {
    executionUsage.value = next ?? null
  }
)

const live = useLiveVue()

onMounted(() => {
  live.handleEvent('resource_usage', (payload: any) => {
    if (!payload || !payload.usage) return

    if (payload.source === 'session') {
      sessionUsage.value = payload.usage as ResourceUsage
    }

    if (payload.source === 'execution') {
      executionUsage.value = payload.usage as ResourceUsage
    }
  })
})

const executionLabel = computed(() => {
  const status = props.executionStatus
  if (!status) return 'idle'
  if (['completed', 'failed', 'cancelled', 'timeout'].includes(status)) return 'final'
  return status
})

const showExecution = computed(() => {
  return Boolean(props.executionStatus || executionUsage.value)
})

const toNumber = (value: unknown): number | undefined => {
  const num = Number(value)
  return Number.isFinite(num) ? num : undefined
}

const formatBytes = (value?: unknown) => {
  const bytes = toNumber(value)
  if (bytes === undefined) return '--'
  if (bytes < 1024) return `${Math.round(bytes)} B`

  const units = ['KB', 'MB', 'GB', 'TB']
  let size = bytes / 1024
  let unitIndex = 0

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024
    unitIndex += 1
  }

  const precision = size >= 100 ? 0 : 1
  return `${size.toFixed(precision)} ${units[unitIndex]}`
}

const formatCount = (value?: unknown) => {
  const num = toNumber(value)
  if (num === undefined) return '--'
  return Math.round(num).toLocaleString()
}

const formatCpu = (usage: ResourceUsage | null, showTotal: boolean = false) => {
  if (!usage) return '--'
  
  // For completed executions, show total work (more meaningful for comparison)
  // For live sessions, show rate (more meaningful for current intensity)
  if (showTotal) {
    const delta = toNumber(usage.reductions_delta)
    if (delta !== undefined) {
      const perSecond = toNumber(usage.reductions_per_s)
      if (perSecond !== undefined && perSecond > 0) {
        // Show both total and rate for completed executions
        return `${Math.round(delta).toLocaleString()} r (${Math.round(perSecond).toLocaleString()} r/s)`
      }
      return `${Math.round(delta).toLocaleString()} r`
    }
    
    const total = toNumber(usage.reductions)
    if (total !== undefined) return `${Math.round(total).toLocaleString()} r`
  } else {
    // Live session: show rate
    const perSecond = toNumber(usage.reductions_per_s)
    if (perSecond !== undefined) return `${Math.round(perSecond).toLocaleString()} r/s`

    const delta = toNumber(usage.reductions_delta)
    if (delta !== undefined) return `${Math.round(delta).toLocaleString()} r`

    const total = toNumber(usage.reductions)
    if (total !== undefined) return `${Math.round(total).toLocaleString()} r`
  }

  return '--'
}
</script>

<template>
  <div class="absolute right-4 top-4 z-[1200] pointer-events-none">
    <div class="flex flex-col gap-2 text-xs font-semibold text-base-content/70">
      <div
        class="rounded-xl border border-base-200/70 bg-base-100/80 px-3 py-2 shadow-lg shadow-base-300/40 backdrop-blur">
        <div class="flex items-center justify-between text-[10px] uppercase tracking-wider text-base-content/50">
          <span>Session</span>
          <span class="text-emerald-500/80">live</span>
        </div>
        <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 font-mono text-[11px] text-base-content/80">
          <span>CPU {{ formatCpu(sessionUsage, false) }}</span>
          <span>Mem {{ formatBytes(sessionUsage?.memory_bytes) }}</span>
          <span>Heap {{ formatBytes(sessionUsage?.total_heap_bytes) }}</span>
          <span>MQ {{ formatCount(sessionUsage?.message_queue_len) }}</span>
        </div>
      </div>

      <div
        v-if="showExecution"
        class="rounded-xl border border-base-200/70 bg-base-100/80 px-3 py-2 shadow-lg shadow-base-300/40 backdrop-blur">
        <div class="flex items-center justify-between text-[10px] uppercase tracking-wider text-base-content/50">
          <span>Execution</span>
          <span class="text-base-content/40">{{ executionLabel }}</span>
        </div>
        <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 font-mono text-[11px] text-base-content/80">
          <span>CPU {{ formatCpu(executionUsage, true) }}</span>
          <span>Mem {{ formatBytes(executionUsage?.memory_bytes) }}</span>
          <span>Heap {{ formatBytes(executionUsage?.total_heap_bytes) }}</span>
          <span>MQ {{ formatCount(executionUsage?.message_queue_len) }}</span>
        </div>
      </div>
    </div>
  </div>
</template>
