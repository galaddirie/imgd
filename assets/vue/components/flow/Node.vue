<script setup lang="ts">
import { computed } from 'vue'
import { Position } from '@vue-flow/core'
import type { NodeProps } from '@vue-flow/core'
import Handle from './Handle.vue'
import { colorMap, type NodeStatus, oklchToHex, darkenColor, lightenColor } from '../../lib/color'
import { useThemeStore } from '../../stores/theme'
import type { StepNodeData, StepKind } from '@/types/workflow'
import {
    GlobeAltIcon,
    ServerIcon,
    CodeBracketIcon,
    EnvelopeIcon,
    ArrowPathIcon,
    CodeBracketSquareIcon,
    EllipsisVerticalIcon,
    BugAntIcon,
    CalculatorIcon,
    FunnelIcon,
    AdjustmentsHorizontalIcon,
    ArrowDownTrayIcon,
    CursorArrowRaysIcon,
    DocumentTextIcon,
    ArrowsRightLeftIcon,
    ListBulletIcon,
    ArrowsPointingOutIcon,
    ArrowsPointingInIcon,
    CheckIcon,
    ExclamationCircleIcon,
    ClockIcon,
    ForwardIcon,
    PauseIcon,
    BookmarkIcon,
    LockClosedIcon,
    EyeSlashIcon,
    BoltIcon,
    CircleStackIcon,
    VariableIcon,
} from '@heroicons/vue/24/outline'

const props = defineProps<NodeProps<StepNodeData>>()
const themeStore = useThemeStore()

// Compute effective status (pinned takes precedence for display)
const effectiveStatus = computed<NodeStatus>(() => {
    if (props.data.pinned) return 'pinned'
    if (props.data.disabled) return 'skipped'
    return props.data.status ?? 'pending'
})

// Icon mapping for step types
const iconComponents = {
    'hero-globe-alt': GlobeAltIcon,
    'hero-server': ServerIcon,
    'hero-code-bracket': CodeBracketIcon,
    'hero-envelope': EnvelopeIcon,
    'hero-arrow-path': ArrowPathIcon,
    'hero-code-bracket-square': CodeBracketSquareIcon,
    'hero-bug-ant': BugAntIcon,
    'hero-calculator': CalculatorIcon,
    'hero-funnel': FunnelIcon,
    'hero-adjustments-horizontal': AdjustmentsHorizontalIcon,
    'hero-arrow-down-tray': ArrowDownTrayIcon,
    'hero-cursor-arrow-rays': CursorArrowRaysIcon,
    'hero-document-text': DocumentTextIcon,
    'hero-arrows-right-left': ArrowsRightLeftIcon,
    'hero-list-bullet': ListBulletIcon,
    'hero-arrows-pointing-out': ArrowsPointingOutIcon,
    'hero-arrows-pointing-in': ArrowsPointingInIcon,
    'hero-bolt': BoltIcon,
    'hero-circle-stack': CircleStackIcon,
    'hero-variable': VariableIcon,
} as const

type IconName = keyof typeof iconComponents

const IconComponent = computed(() => {
    const iconKey = props.data.icon as IconName
    return iconComponents[iconKey] || CodeBracketIcon
})

// Status indicator icons
const statusIconMap = {
    pending: null,
    queued: PauseIcon,
    running: ClockIcon,
    completed: CheckIcon,
    failed: ExclamationCircleIcon,
    skipped: ForwardIcon,
    pinned: BookmarkIcon,
} as const

const StatusIcon = computed(() => statusIconMap[effectiveStatus.value])

// Color configuration per status
const statusConfig = computed(() => {
    const isDark = themeStore.theme === 'dark'
    const adjust = (color: string, amount: number) =>
        isDark ? oklchToHex(darkenColor(color, amount)) : oklchToHex(lightenColor(color, amount))

    return {
        pending: {
            bg: adjust(colorMap.pending, isDark ? 15 : 5),
            border: adjust(colorMap.pending, isDark ? 15 : 5) + 'C0',
            text: isDark ? oklchToHex(lightenColor(colorMap.pending, 20)) : oklchToHex(darkenColor(colorMap.pending, 40)),
        },
        queued: {
            bg: adjust(colorMap.queued, isDark ? 15 : 5),
            border: adjust(colorMap.queued, isDark ? 15 : 5) + 'C0',
            text: isDark ? oklchToHex(lightenColor(colorMap.queued, 20)) : oklchToHex(darkenColor(colorMap.queued, 40)),
        },
        running: {
            bg: adjust(colorMap.running, isDark ? 15 : 5),
            border: adjust(colorMap.running, isDark ? 15 : 5) + 'C0',
            text: isDark ? oklchToHex(lightenColor(colorMap.running, 25)) : oklchToHex(darkenColor(colorMap.running, 45)),
        },
        completed: {
            bg: adjust(colorMap.completed, isDark ? 15 : 5),
            border: adjust(colorMap.completed, isDark ? 15 : 5) + 'C0',
            text: isDark ? oklchToHex(lightenColor(colorMap.completed, 25)) : oklchToHex(darkenColor(colorMap.completed, 40)),
        },
        failed: {
            bg: adjust(colorMap.failed, isDark ? 10 : 5),
            border: adjust(colorMap.failed, isDark ? 10 : 5) + 'C0',
            text: isDark ? oklchToHex(lightenColor(colorMap.failed, 30)) : oklchToHex(darkenColor(colorMap.failed, 30)),
        },
        skipped: {
            bg: adjust(colorMap.skipped, isDark ? 15 : 5),
            border: adjust(colorMap.skipped, isDark ? 15 : 5) + 'C0',
            text: isDark ? oklchToHex(lightenColor(colorMap.skipped, 20)) : oklchToHex(darkenColor(colorMap.skipped, 35)),
        },
        pinned: {
            bg: adjust(colorMap.pinned, isDark ? 20 : 5),
            border: adjust(colorMap.pinned, isDark ? 20 : 5) + 'C0',
            text: isDark ? oklchToHex(lightenColor(colorMap.pinned, 30)) : oklchToHex(darkenColor(colorMap.pinned, 45)),
        },
    }
})

const currentStatusStyle = computed(() => statusConfig.value[effectiveStatus.value])

// Step kind badge styling
const stepKindConfig: Record<StepKind, { label: string; class: string }> = {
    trigger: { label: 'Trigger', class: 'badge-primary' },
    action: { label: 'Action', class: 'badge-info' },
    transform: { label: 'Transform', class: 'badge-secondary' },
    control_flow: { label: 'Logic', class: 'badge-warning' },
}

const stepKindBadge = computed(() => {
    const kind = props.data.step_kind ?? 'action'
    return stepKindConfig[kind]
})

// Node classes
const nodeClasses = computed(() => [
    'group relative flex items-start gap-3 rounded-2xl border bg-base-100 p-4 shadow-md transition-shadow',
    // Different styling for trigger nodes
    props.data.step_kind === 'trigger' ? 'rounded-[50px_0.5rem_0.5rem_10px]' : '',
    props.dragging ? 'cursor-grabbing shadow-xl' : 'cursor-grab hover:shadow-lg',
    props.data.disabled ? 'opacity-60' : '',
    props.data.locked_by ? 'ring-2 ring-warning/50' : '',
])

// Node style with selection ring
const nodeStyle = computed(() => {
    const isDark = themeStore.theme === 'dark'
    let shadow = isDark
        ? 'inset 0px 2px 3px 0px rgba(255,255,255,0.25), 0 6px 12px 4px rgba(255, 255, 255, 0.01)'
        : 'inset 0px 2px 3px 0px rgba(255,255,255,0.95), 0 6px 12px 4px rgba(0, 0, 0, 0.08)'

    if (props.selected) {
        const ringColor = isDark ? 'rgba(255, 255, 255, 0.55)' : 'rgba(0, 0, 0, 0.95)'
        shadow += `, 0 0 0 2px ${ringColor}`
    }

    return {
        borderColor: props.selected ? oklchToHex(colorMap[props.data.status ?? 'pending']) : currentStatusStyle.value.border,
        boxShadow: shadow,
    }
})

// Format duration for display
const formatDuration = (us?: number): string => {
    if (us === undefined || us === null) return '—'
    if (us < 1000) return `${us}µs`
    if (us < 1_000_000) return `${(us / 1000).toFixed(1)}ms`
    return `${(us / 1_000_000).toFixed(2)}s`
}

// Format bytes for display
const formatBytes = (bytes?: number): string => {
    if (bytes === undefined || bytes === null || bytes === 0) return ''
    const k = 1024
    const sizes = ['B', 'KB', 'MB', 'GB']
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return `${(bytes / Math.pow(k, i)).toFixed(1)}${sizes[i]}`
}

// Whether to show timing stats
const showStats = computed(() => {
    const status = props.data.status
    return status && status !== 'pending' && props.data.stats?.duration_us !== undefined
})

// Determine if handles should be shown
const showInputHandle = computed(() =>
    props.data.hasInput !== false && props.data.step_kind !== 'trigger'
)
const showOutputHandle = computed(() => props.data.hasOutput !== false)
</script>

<template>
    <div class="relative inline-flex">
        <!-- Input Handle -->
        <div v-if="showInputHandle" class="absolute left-0 top-1/2 z-10 -translate-x-1/2 -translate-y-1/2">
            <Handle id="main" type="target" :position="Position.Left" />
        </div>

        <!-- Node Card -->
        <div :class="nodeClasses" :style="nodeStyle">
            <!-- Icon Container -->
            <div class="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-base-200 shadow-inner">
                <component :is="IconComponent" class="size-6 text-base-content/80" />
            </div>

            <!-- Content -->
            <div class="min-w-0 flex-1">
                <!-- Title Row -->
                <div class="mb-1 flex items-start justify-between gap-2">
                    <h3 class="truncate text-sm font-semibold leading-tight text-base-content">
                        {{ data.name || 'Untitled Step' }}
                    </h3>

                    <div class="flex items-center gap-1">
                        <!-- Lock indicator -->
                        <div v-if="data.locked_by" class="tooltip tooltip-left"
                            :data-tip="`Locked by ${data.locked_by}`">
                            <LockClosedIcon class="size-4 text-warning" />
                        </div>

                        <!-- Disabled indicator -->
                        <div v-if="data.disabled" class="tooltip tooltip-left" data-tip="Step disabled">
                            <EyeSlashIcon class="size-4 text-base-content/40" />
                        </div>

                        <!-- Actions menu -->
                        <button class="btn btn-ghost btn-xs opacity-0 group-hover:opacity-100 transition-opacity"
                            aria-label="Step actions">
                            <EllipsisVerticalIcon class="size-5 text-base-content/60" />
                        </button>
                    </div>
                </div>

                <!-- Meta Row -->
                <div class="flex items-center justify-between gap-2">
                    <div class="flex items-center gap-2 min-w-0">
                        <span class="truncate font-mono text-[11px] text-base-content/60">
                            {{ data.type_id }}
                        </span>
                    </div>
                </div>

                <!-- Stats -->
                <div v-if="showStats"
                    class="mt-1.5 flex shrink-0 items-center gap-1 text-[11px] text-base-content/60 font-mono">
                    <ClockIcon class="size-3.5" />
                    <span>{{ formatDuration(data.stats?.duration_us) }}</span>
                    <template v-if="formatBytes(data.stats?.bytes)">
                        <span class="mx-0.5 text-base-content/40">•</span>
                        <span>{{ formatBytes(data.stats?.bytes) }}</span>
                    </template>
                </div>
            </div>

            <!-- Status Bubble -->
            <div class="pointer-events-none absolute -top-4 -right-4">
                <div class="relative">
                    <!-- Ping animation for running -->
                    <span v-if="effectiveStatus === 'running'"
                        class="absolute inset-0 rounded-full opacity-30 animate-ping"
                        :style="{ backgroundColor: currentStatusStyle.bg }" />

                    <div class="relative flex size-11 items-center justify-center rounded-full border-2 bg-base-100 shadow-lg"
                        :style="{ borderColor: currentStatusStyle.border }">
                        <div class="flex size-9 items-center justify-center rounded-full"
                            :style="{ backgroundColor: currentStatusStyle.bg }">
                            <!-- Spinner for running -->
                            <span v-if="effectiveStatus === 'running'"
                                class="inline-block size-4 rounded-full border-2 border-t-transparent animate-spin"
                                :style="{
                                    borderColor: currentStatusStyle.text + 'E6',
                                    borderTopColor: 'transparent'
                                }" />
                            <!-- Status icon -->
                            <component v-else-if="StatusIcon" :is="StatusIcon" class="size-6 drop-shadow-sm"
                                :style="{ color: currentStatusStyle.text }" />
                            <!-- Default dot for pending -->
                            <span v-else class="size-2 rounded-full"
                                :style="{ backgroundColor: currentStatusStyle.text + 'CC' }" />
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Output Handle -->
        <div v-if="showOutputHandle" class="absolute right-0 top-1/2 z-10 -translate-y-1/2 translate-x-1/2">
            <Handle id="main" type="source" :position="Position.Right" />
        </div>
    </div>
</template>
