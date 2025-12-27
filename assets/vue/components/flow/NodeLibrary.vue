<script setup lang="ts">
import { ref, computed } from 'vue'
import { useThemeStore } from '@/stores/theme'
import type { StepType, StepKind, NodeLibraryItem } from '@/types/workflow'
import {
  MagnifyingGlassIcon,
  CursorArrowRaysIcon,
  BoltIcon,
  ClockIcon,
  GlobeAltIcon,
  EnvelopeIcon,
  CircleStackIcon,
  CodeBracketIcon,
  ArrowPathIcon,
  VariableIcon,
  FunnelIcon,
  AdjustmentsHorizontalIcon,
  ArrowsPointingOutIcon,
  ArrowsPointingInIcon,
  ArrowsRightLeftIcon,
  ListBulletIcon,
  BugAntIcon,
  CalculatorIcon,
  DocumentTextIcon,
  ArrowDownTrayIcon,
  ChevronRightIcon,
} from '@heroicons/vue/24/outline'

// Props - will receive step types from LiveView
interface Props {
  stepTypes?: StepType[]
  isCollapsed?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  stepTypes: () => [],
  isCollapsed: false,
})

const emit = defineEmits<{
  (e: 'collapse'): void
  (e: 'expand'): void
  (e: 'dragStart', type: string, event: DragEvent): void
}>()

const searchQuery = ref('')
const expandedCategories = ref<Set<string>>(new Set(['Triggers', 'Actions']))

// Icon mapping for step types
const iconMap: Record<string, typeof CursorArrowRaysIcon> = {
  'hero-cursor-arrow-rays': CursorArrowRaysIcon,
  'hero-bolt': BoltIcon,
  'hero-clock': ClockIcon,
  'hero-globe-alt': GlobeAltIcon,
  'hero-envelope': EnvelopeIcon,
  'hero-circle-stack': CircleStackIcon,
  'hero-code-bracket': CodeBracketIcon,
  'hero-arrow-path': ArrowPathIcon,
  'hero-variable': VariableIcon,
  'hero-funnel': FunnelIcon,
  'hero-adjustments-horizontal': AdjustmentsHorizontalIcon,
  'hero-arrows-pointing-out': ArrowsPointingOutIcon,
  'hero-arrows-pointing-in': ArrowsPointingInIcon,
  'hero-arrows-right-left': ArrowsRightLeftIcon,
  'hero-list-bullet': ListBulletIcon,
  'hero-bug-ant': BugAntIcon,
  'hero-calculator': CalculatorIcon,
  'hero-document-text': DocumentTextIcon,
  'hero-arrow-down-tray': ArrowDownTrayIcon,
}

// Default/mock step types (will be replaced by props.stepTypes from LiveView)
const defaultStepTypes: NodeLibraryItem[] = [
  // Triggers
  { type_id: 'manual_input', name: 'Manual Trigger', icon: 'hero-cursor-arrow-rays', description: 'Start workflow manually', step_kind: 'trigger', category: 'Triggers' },
  { type_id: 'webhook', name: 'Webhook', icon: 'hero-bolt', description: 'Trigger via HTTP webhook', step_kind: 'trigger', category: 'Triggers' },
  { type_id: 'schedule', name: 'Schedule', icon: 'hero-clock', description: 'Run on a schedule', step_kind: 'trigger', category: 'Triggers' },

  // Integrations
  { type_id: 'http_request', name: 'HTTP Request', icon: 'hero-globe-alt', description: 'Make HTTP API calls', step_kind: 'action', category: 'Integrations' },
  { type_id: 'send_email', name: 'Send Email', icon: 'hero-envelope', description: 'Send email notifications', step_kind: 'action', category: 'Integrations' },
  { type_id: 'db_query', name: 'Database Query', icon: 'hero-circle-stack', description: 'Query a database', step_kind: 'action', category: 'Integrations' },

  // Control Flow
  { type_id: 'condition', name: 'If/Else', icon: 'hero-arrows-right-left', description: 'Conditional branching', step_kind: 'control_flow', category: 'Control Flow' },
  { type_id: 'switch', name: 'Switch', icon: 'hero-list-bullet', description: 'Multi-way branching', step_kind: 'control_flow', category: 'Control Flow' },
  { type_id: 'loop', name: 'Loop', icon: 'hero-arrow-path', description: 'Iterate over items', step_kind: 'control_flow', category: 'Control Flow' },

  // Transform
  { type_id: 'data_transform', name: 'Transform', icon: 'hero-adjustments-horizontal', description: 'Transform data shape', step_kind: 'transform', category: 'Transform' },
  { type_id: 'data_filter', name: 'Filter', icon: 'hero-funnel', description: 'Filter data fields', step_kind: 'transform', category: 'Transform' },
  { type_id: 'format', name: 'Format String', icon: 'hero-document-text', description: 'Format text with templates', step_kind: 'transform', category: 'Transform' },
  { type_id: 'math', name: 'Math', icon: 'hero-calculator', description: 'Arithmetic operations', step_kind: 'transform', category: 'Transform' },
  { type_id: 'splitter', name: 'Split Items', icon: 'hero-arrows-pointing-out', description: 'Split list for parallel processing', step_kind: 'transform', category: 'Transform' },
  { type_id: 'aggregator', name: 'Aggregate', icon: 'hero-arrows-pointing-in', description: 'Combine items back together', step_kind: 'transform', category: 'Transform' },

  // Utilities
  { type_id: 'debug', name: 'Debug', icon: 'hero-bug-ant', description: 'Log data for debugging', step_kind: 'action', category: 'Utilities' },
  { type_id: 'data_output', name: 'Output', icon: 'hero-arrow-down-tray', description: 'Final workflow output', step_kind: 'action', category: 'Utilities' },
]

// Merge props with defaults
const allStepTypes = computed(() => {
  if (props.stepTypes && props.stepTypes.length > 0) {
    return props.stepTypes.map(st => ({
      type_id: st.id,
      name: st.name,
      icon: st.icon,
      description: st.description,
      step_kind: st.step_kind,
      category: st.category,
    }))
  }
  return defaultStepTypes
})

// Group by category
const categorizedTypes = computed(() => {
  const filtered = allStepTypes.value.filter(item => {
    if (!searchQuery.value) return true
    const q = searchQuery.value.toLowerCase()
    return (
      item.name.toLowerCase().includes(q) ||
      item.description.toLowerCase().includes(q) ||
      item.type_id.toLowerCase().includes(q)
    )
  })

  const grouped: Record<string, NodeLibraryItem[]> = {}
  for (const item of filtered) {
    if (!grouped[item.category]) {
      grouped[item.category] = []
    }
    grouped[item.category].push(item)
  }

  // Sort categories with Triggers first
  const sortOrder = ['Triggers', 'Integrations', 'Control Flow', 'Transform', 'Utilities']
  return Object.entries(grouped).sort(([a], [b]) => {
    const aIdx = sortOrder.indexOf(a)
    const bIdx = sortOrder.indexOf(b)
    if (aIdx === -1 && bIdx === -1) return a.localeCompare(b)
    if (aIdx === -1) return 1
    if (bIdx === -1) return -1
    return aIdx - bIdx
  })
})

// Theme store
const themeStore = useThemeStore()

// Step kind styling - reactive based on theme
const kindStyles = computed(() => ({
  trigger: 'text-primary',
  action: 'text-info',
  transform: themeStore.theme === 'dark' ? 'text-secondary' : 'text-info',
  control_flow: 'text-warning',
}))

const toggleCategory = (category: string) => {
  if (expandedCategories.value.has(category)) {
    expandedCategories.value.delete(category)
  } else {
    expandedCategories.value.add(category)
  }
}

const onDragStart = (event: DragEvent, typeId: string) => {
  if (event.dataTransfer) {
    event.dataTransfer.setData('application/vueflow', typeId)
    event.dataTransfer.effectAllowed = 'move'
  }
  emit('dragStart', typeId, event)
}

const getIcon = (iconName: string) => iconMap[iconName] || CodeBracketIcon
</script>

<template>
  <aside class="flex flex-col h-full bg-base-100 border-r border-base-200 overflow-hidden transition-all duration-300"
    :class="isCollapsed ? 'w-0' : 'w-72'">
    <!-- Header -->
    <div class="px-5 py-5 border-b border-base-200 shrink-0">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-sm font-semibold text-base-content/90 tracking-tight">
          Step Library
        </h2>
        <span class="badge badge-ghost badge-sm font-mono">
          {{ allStepTypes.length }}
        </span>
      </div>

      <!-- Search -->
      <div class="relative group">
        <MagnifyingGlassIcon
          class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/30 group-focus-within:text-primary transition-colors" />
        <input v-model="searchQuery" type="text" placeholder="Search steps..."
          class="w-full pl-9 pr-4 py-2.5 bg-base-200/30 border border-transparent focus:border-primary/20 focus:bg-base-100 focus:ring-4 focus:ring-primary/5 text-sm font-medium rounded-xl transition-all duration-200 outline-none placeholder:text-base-content/30" />
      </div>
    </div>

    <!-- Step List -->
    <div class="flex-1 overflow-y-auto p-3 space-y-1 custom-scrollbar">
      <div v-for="[category, items] in categorizedTypes" :key="category" class="mb-2">
        <!-- Category Header -->
        <button
          class="w-full flex items-center justify-between px-2 py-2 rounded-lg text-xs font-bold uppercase tracking-wider text-base-content/50 hover:text-base-content/70 hover:bg-base-200/50 transition-colors"
          @click="toggleCategory(category)">
          <span>{{ category }}</span>
          <div class="flex items-center gap-2">
            <span class="badge badge-ghost badge-xs">{{ items.length }}</span>
            <ChevronRightIcon class="w-3.5 h-3.5 transition-transform duration-200"
              :class="{ 'rotate-90': expandedCategories.has(category) }" />
          </div>
        </button>

        <!-- Category Items -->
        <div v-show="expandedCategories.has(category)" class="mt-1 space-y-1">
          <div v-for="item in items" :key="item.type_id"
            class="group flex items-start gap-3 p-3 bg-base-100 hover:bg-base-200/50 rounded-xl cursor-grab active:cursor-grabbing border border-transparent hover:border-base-300/50 transition-all duration-200"
            draggable="true" @dragstart="onDragStart($event, item.type_id)">
            <!-- Icon -->
            <div
              class="w-9 h-9 shrink-0 flex items-center justify-center rounded-lg bg-base-200/50 group-hover:bg-primary/10 transition-all duration-200 border border-base-200/50 group-hover:border-primary/20"
              :class="kindStyles[item.step_kind]">
              <component :is="getIcon(item.icon)" class="h-4.5 w-4.5" />
            </div>

            <!-- Content -->
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium text-base-content/90 group-hover:text-base-content truncate">
                  {{ item.name }}
                </span>
              </div>
              <p class="text-xs text-base-content/50 leading-relaxed mt-0.5 line-clamp-2">
                {{ item.description }}
              </p>
            </div>
          </div>
        </div>
      </div>

      <!-- Empty State -->
      <div v-if="categorizedTypes.length === 0" class="flex flex-col items-center justify-center py-8 text-center">
        <MagnifyingGlassIcon class="w-8 h-8 text-base-content/20 mb-2" />
        <p class="text-sm text-base-content/50">No steps match your search</p>
        <button class="btn btn-ghost btn-xs mt-2" @click="searchQuery = ''">
          Clear search
        </button>
      </div>
    </div>

    <!-- Footer -->
    <div class="px-5 py-3 border-t border-base-200 bg-base-200/10 shrink-0">
      <div class="flex items-center justify-center gap-2 text-xs font-medium text-base-content/40 tracking-wide">
        <CursorArrowRaysIcon class="w-3.5 h-3.5" />
        <span>Drag to canvas to add</span>
      </div>
    </div>
  </aside>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 4px;
}

.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 5%, transparent);
  border-radius: 10px;
}

.custom-scrollbar:hover::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 10%, transparent);
}

.line-clamp-2 {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
</style>