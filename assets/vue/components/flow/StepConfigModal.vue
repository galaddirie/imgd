<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { watchDebounced } from '@vueuse/core'
import ExpressionPreviewError from './ExpressionPreviewError.vue'
import type { EditorState } from '../../types/workflow'
import {
  ArrowRightOnRectangleIcon,
  BoltIcon,
  CpuChipIcon,
  VariableIcon,
  GlobeAltIcon,
  PencilIcon,
} from '@heroicons/vue/24/outline'
import { unwrapData, formatDataForDisplay } from '../../lib/dataUtils'

interface NodeData {
  id: string
  type_id: string
  name: string
  config?: Record<string, unknown>
  [key: string]: any
}

interface Node {
  id: string
  data: Record<string, any>
  [key: string]: any
}

interface Props {
  node: any | null
  isOpen: boolean
  stepType?: any
  execution?: any
  stepExecutions?: any[]
  expressionPreviews?: Record<string, any>
  editorState?: EditorState
  stepNameById?: Record<string, string>
}

const props = defineProps<Props>()
const emit = defineEmits(['close', 'save', 'preview_expression', 'toggle_webhook_test'])

const activeTab = ref<'config' | 'output' | 'pinned'>('config')
const fieldModes = ref<Record<string, 'literal' | 'expression'>>({})
const fieldValues = ref<Record<string, any>>({})
const searchQuery = ref('')
const isEditingName = ref(false)
const editName = ref('')

// Initialize field state when node changes
watch([() => props.node, () => props.isOpen], ([newNode, open]) => {
  if (open && newNode) {
    const config = newNode.data.config || {}
    const modes: Record<string, 'literal' | 'expression'> = {}
    const values: Record<string, any> = {}

    Object.entries(config).forEach(([key, value]) => {
      const isExpr = typeof value === 'string' && (value.includes('{{') || value.includes('{%'))
      modes[key] = isExpr ? 'expression' : 'literal'
      values[key] = value
    })

    fieldModes.value = modes
    fieldValues.value = values
    editName.value = newNode.data.name || ''
    isEditingName.value = false
  }
}, { immediate: true })

// Watch for changes and emit preview events
watchDebounced(fieldValues, (newValues) => {
  if (!props.isOpen || !props.node) return

  Object.entries(newValues).forEach(([key, value]) => {
    if (fieldModes.value[key] === 'expression' && typeof value === 'string') {
      emit('preview_expression', {
        step_id: props.node.id,
        field_key: key,
        expression: value
      })
    }
  })
}, { debounce: 300, deep: true })

const closeModal = () => emit('close')

const saveConfig = () => {
  emit('save', {
    id: props.node?.id,
    name: editName.value,
    config: { ...fieldValues.value }
  })
  closeModal()
}

const toggleMode = (field: string) => {
  fieldModes.value[field] = fieldModes.value[field] === 'literal' ? 'expression' : 'literal'
}

// Map schema types to input types
const fields = computed(() => {
  if (!props.node) return []

  const schema = props.stepType?.config_schema?.properties || {}
  const config = props.node.data.config || {}

  // Combine schema-defined fields and existing config fields
  const allKeys = new Set([...Object.keys(schema), ...Object.keys(config)])

  return Array.from(allKeys).map(key => {
    const schemaField = schema[key] || {}
    let type = inferType(config[key] ?? schemaField.default)

    if (schemaField.format === 'json') {
      type = 'json'
    } else if (schemaField.type === 'string' && schemaField.format === 'textarea') {
      type = 'textarea'
    }

    return {
      key,
      label: schemaField.title || key.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase()),
      type,
    }
  })
})

const inferType = (val: any) => {
  if (typeof val === 'boolean') return 'boolean'
  if (typeof val === 'number') return 'number'
  if (typeof val === 'string' && val.length > 50) return 'textarea'
  return 'text'
}

const expandedSections = ref<Record<string, boolean>>({ json: true, trigger: true, steps: true, variables: true })

const toggleSection = (id: string) => {
  expandedSections.value[id] = !expandedSections.value[id]
}

const activeStepExecution = computed(() => {
  if (!props.node || !props.stepExecutions) return null
  return props.stepExecutions.find(se => se.step_id === props.node?.id) || null
})

const evaluatedConfig = computed(() => {
  return activeStepExecution.value?.metadata?.evaluated_config || {}
})

const contextData = computed(() => {
  if (!props.execution) return {}
  const currentStepId = props.node?.id
  return {
    json: unwrapData(activeStepExecution.value?.input_data) || {},
    trigger: props.execution?.trigger?.data || {},
    variables: props.execution?.metadata?.variables || {},
    request: props.execution?.metadata?.extras?.request || {},
    steps: props.stepExecutions?.reduce((acc: any, se: any) => {
      const isCurrentStep = se.step_id === currentStepId
      const stepName = isCurrentStep ? editName.value : props.stepNameById?.[se.step_id]
      const key = stepName && stepName.length > 0 ? stepName : se.step_id

      acc[key] = { json: unwrapData(se.output_data) }
      return acc
    }, {}) || {}
  }
})

const explorerData = computed(() => {
  const data = contextData.value
  
  const wrapPrimitive = (val: any, key: string) => {
    if (val === null || val === undefined) return val
    if (typeof val === 'object' && !Array.isArray(val)) return val
    return { [key]: val }
  }

  return [
    { id: 'json', label: 'Current Input', icon: ArrowRightOnRectangleIcon, data: wrapPrimitive(data.json, 'json') },
    { id: 'trigger', label: 'Trigger Data', icon: BoltIcon, data: wrapPrimitive(data.trigger, 'trigger') },
    { id: 'steps', label: 'Upstream Steps', icon: CpuChipIcon, data: data.steps },
    { id: 'variables', label: 'Workflow Variables', icon: VariableIcon, data: wrapPrimitive(data.variables, 'variables') },
    { id: 'request', label: 'Request Metadata', icon: GlobeAltIcon, data: wrapPrimitive(data.request, 'request') },
  ]
})

const previewKeyFor = (fieldKey: string) => (props.node ? `${props.node.id}:${fieldKey}` : '')

const hasPreviewFor = (fieldKey: string) => {
  const key = previewKeyFor(fieldKey)
  if (!key) return false
  return Object.prototype.hasOwnProperty.call(props.expressionPreviews || {}, key)
}

const previewValueFor = (fieldKey: string) => {
  const key = previewKeyFor(fieldKey)
  if (!key) return undefined
  return props.expressionPreviews?.[key]
}

// Webhook Logic
const webhookMode = ref<'test' | 'production'>('test')
const isWebhookTrigger = computed(() => {
  const typeId = props.node?.data?.type_id
  return typeId === 'webhook_trigger' || typeId === 'webhook'
})

const webhookPath = computed(() => {
  if (!props.node) return ''
  const rawPath = fieldValues.value?.path || props.node.data?.config?.path
  const path = typeof rawPath === 'string' ? rawPath.trim() : ''
  return path.length > 0 ? path : props.node.id
})

const webhookMethod = computed(() => {
  const rawMethod = props.node?.data?.config?.http_method
  if (typeof rawMethod === 'string' && rawMethod.trim().length > 0) {
    return rawMethod.trim().toUpperCase()
  }
  return 'POST'
})

const webhookTestState = computed(() => props.editorState?.webhook_test || null)
const isWebhookListening = computed(() => {
  if (!props.node || !webhookTestState.value) return false
  if (webhookTestState.value.step_id) {
    return webhookTestState.value.step_id === props.node.id
  }
  return webhookTestState.value.path === webhookPath.value
})

const isWebhookListeningElsewhere = computed(() => {
  if (!props.node || !webhookTestState.value) return false
  return webhookTestState.value.step_id
    ? webhookTestState.value.step_id !== props.node.id
    : webhookTestState.value.path !== webhookPath.value
})

const webhookUrl = computed(() => {
  if (!props.node) return ''
  const path = webhookPath.value
  const baseUrl = window.location.origin
  
  if (webhookMode.value === 'test') {
    return `${baseUrl}/api/hook-test/${path}` // Draft/Test URL
  } else {
    return `${baseUrl}/api/hooks/${path}` // Production URL
  }
})

const copyWebhookUrl = () => {
  navigator.clipboard.writeText(webhookUrl.value)
  // detailed toast could go here
}
const slugify = (text: string) => {
  // Key-safe format: lowercase alphanumeric + underscores (matches backend to_step_id)
  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, '')
    .replace(/[\s]+/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_|_$/g, '')
}

const getExpressionFor = (sectionId: string, key?: string) => {
  if (key === sectionId && sectionId !== 'steps') return `{{ ${sectionId} }}`

  const isNumeric = (val: string) => /^\d+$/.test(val)
  const formatKey = (k: string) => isNumeric(k) ? `[${k}]` : `.${k}`
  const path = key ? formatKey(key) : ''

  switch (sectionId) {
    case 'json':
      return `{{ json${path} }}`
    case 'trigger':
      return `{{ trigger${path} }}`
    case 'variables':
      return `{{ variables${path} }}`
    case 'request':
      return `{{ request${path} }}`
    case 'steps':
      if (!key) return `{{ steps }}`
      // If we are referring to a step, use its slugified name
      // If it's the current node, we use the potentially updated editName
      const currentStepId = props.node?.id
      const currentStepName = props.node?.data?.name || ''
      const isCurrentStep = key === currentStepId || key === currentStepName
      const resolvedName = isCurrentStep ? editName.value : props.stepNameById?.[key]
      const stepName = resolvedName && resolvedName.length > 0 ? resolvedName : key
      const stepKey = stepName && stepName.length > 0 ? slugify(stepName) : key
      return `{{ steps["${stepKey}"].json }}`
    default:
      return `{{ ${sectionId}${path} }}`
  }
}

const copyExpression = (sectionId: string, key?: string) => {
  const expression = getExpressionFor(sectionId, key)
  navigator.clipboard.writeText(expression)
  // Could add toast notification here
}

const toggleWebhookListening = () => {
  if (!props.node || isWebhookListeningElsewhere.value) return
  emit('toggle_webhook_test', {
    action: isWebhookListening.value ? 'stop' : 'start',
    step_id: props.node.id,
    path: webhookPath.value,
    method: webhookMethod.value,
  })
}
</script>

<template>
  <div v-if="isOpen"
    class="fixed inset-0 z-[1100] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4 sm:p-6"
    @keydown.esc="closeModal">
    <div
      class="bg-base-100 rounded-3xl shadow-2xl w-full max-w-7xl h-[90vh] flex flex-col overflow-hidden border border-base-300 animate-in fade-in zoom-in duration-300"
      @mousedown.stop>
      <!-- Header -->
      <div class="px-6 py-4 border-b border-base-200 flex items-center justify-between bg-base-200/40">
        <div class="flex items-center gap-4">
          <div class="flex items-center justify-center w-12 h-12 rounded-2xl bg-primary/10 text-primary shadow-inner">
            <svg xmlns="http://www.w3.org/2000/svg" class="w-6 h-6" fill="none" viewBox="0 0 24 24"
              stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
            </svg>
          </div>
          <div>
            <div class="flex items-center gap-2">
              <div v-if="isEditingName" class="flex items-center gap-2">
                <input
                  v-model="editName"
                  type="text"
                  class="input input-sm input-primary bg-base-100 border-base-300 font-bold text-lg"
                  @keyup.enter="isEditingName = false"
                  @blur="isEditingName = false"
                  auto-focus
                />
              </div>
              <h2 v-else class="text-lg font-bold text-base-content leading-none group/name flex items-center gap-2">
                {{ editName }}
                <button
                  class="btn btn-ghost btn-xs btn-circle opacity-0 group-hover/name:opacity-100 transition-opacity"
                  @click="isEditingName = true"
                >
                  <PencilIcon class="size-3.5 text-base-content/40" />
                </button>
              </h2>
              <span class="badge badge-primary badge-sm font-mono opacity-80">{{ node?.id.slice(0, 8) }}</span>
            </div>
            <p class="text-xs text-base-content/50 mt-1 font-medium flex items-center gap-1.5">
              <span class="w-1.5 h-1.5 rounded-full bg-success"></span>
              {{ node?.data.type_id }} Step
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <div class="flex bg-base-300/50 p-1 rounded-xl">
            <button v-for="tab in (['config', 'output', 'pinned'] as const)" :key="tab"
              class="px-4 py-2 text-xs font-bold rounded-lg transition-all capitalize"
              :class="activeTab === tab ? 'bg-base-100 text-primary shadow-sm' : 'text-base-content/60 hover:text-base-content'"
              @click="activeTab = tab">
              {{ tab === 'config' ? 'Parameters' : tab }}
            </button>
          </div>

          <button class="btn btn-ghost btn-sm btn-circle hover:bg-error/10 hover:text-error ml-4" @click="closeModal">
            <svg xmlns="http://www.w3.org/2000/svg" class="w-5 h-5" fill="none" viewBox="0 0 24 24"
              stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
      </div>

      <!-- Main content -->
      <div class="flex-1 flex overflow-hidden bg-base-200/20">
        <!-- Variable Explorer (Left) -->
        <div class="w-80 border-r border-base-200 bg-base-100/50 flex flex-col overflow-hidden">
          <div class="p-4 border-b border-base-200 bg-base-200/10">
            <div class="relative">
              <svg xmlns="http://www.w3.org/2000/svg"
                class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40" fill="none"
                viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
              </svg>
              <input v-model="searchQuery" type="text" placeholder="Search variables..."
                class="input input-sm input-bordered w-full pl-9 bg-base-100 border-base-300 focus:border-primary text-xs font-medium" />
            </div>
          </div>
          <div class="flex-1 overflow-y-auto p-2 space-y-1 custom-scrollbar">
            <div v-for="section in explorerData" :key="section.id" class="overflow-hidden">
              <button
                class="w-full flex items-center justify-between p-2 rounded-xl text-xs font-bold transition-all hover:bg-primary/5 group"
                :class="expandedSections[section.id] ? 'text-primary bg-primary/5' : 'text-base-content/60'"
                @click="toggleSection(section.id)">
                <div class="flex items-center gap-2">
                  <span class="opacity-70 group-hover:opacity-100">
                    <component :is="section.icon" class="w-4 h-4" />
                  </span>
                  {{ section.label }}
                </div>
                <svg :class="{ 'rotate-90': expandedSections[section.id] }"
                  class="w-3 h-3 transition-transform opacity-40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path d="M9 5l7 7-7 7" stroke-width="2" />
                </svg>
              </button>
              <div v-if="expandedSections[section.id]" class="mt-1 ml-4 pl-2 border-l border-base-200 py-1 space-y-1 text-wrap">
                <template v-if="section.data && typeof section.data === 'object' && Object.keys(section.data).length > 0">
                  <div v-for="(val, key) in section.data" :key="key"
                    class="p-1.5 rounded-lg hover:bg-base-200 group cursor-pointer transition-all">
                    <div class="flex items-center justify-between">
                      <span class="text-[11px] font-mono text-base-content">{{ key }}</span>
                      <button @click.stop="copyExpression(section.id, String(key))"
                        class="opacity-0 group-hover:opacity-100 btn btn-xs btn-ghost btn-square h-4 w-4 transition-opacity"
                        :title="'Copy expression: ' + getExpressionFor(section.id, String(key))">
                        <svg xmlns="http://www.w3.org/2000/svg" class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3" />
                        </svg>
                      </button>
                    </div>
                    <div class="text-[10px] text-base-content/40 truncate mt-0.5">{{ JSON.stringify(val) }}</div>
                  </div>
                </template>
                <div v-else-if="section.data !== undefined && section.data !== null" class="p-1.5 rounded-lg bg-base-300/10 group">
                   <div class="flex items-center justify-between gap-2">
                     <div class="text-[10px] text-base-content/60 font-mono truncate flex-1">{{ formatDataForDisplay(section.data) }}</div>
                     <button @click.stop="copyExpression(section.id)"
                        class="opacity-0 group-hover:opacity-100 btn btn-xs btn-ghost btn-square h-4 w-4 transition-opacity"
                        :title="'Copy expression: ' + getExpressionFor(section.id)">
                        <svg xmlns="http://www.w3.org/2000/svg" class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3" />
                        </svg>
                      </button>
                   </div>
                </div>
                <div v-else class="p-2 text-[10px] text-base-content/40 italic">No variables available</div>
              </div>
            </div>
          </div>
          <div class="p-4 border-t border-base-200 bg-base-200/5">
            <div class="text-[10px] font-bold uppercase tracking-wider text-base-content/40 mb-2">Expression Tip</div>
            <p class="text-[11px] text-base-content/60 leading-relaxed">Click any variable to copy its Liquid expression
              to your clipboard.</p>
          </div>
        </div>

        <!-- Tab Content area (Config / Output) -->
        <div class="flex-1 overflow-y-auto p-8 custom-scrollbar">
          <div v-if="activeTab === 'config'" class="max-w-3xl mx-auto space-y-10 pb-20">
            <div class="space-y-1">
              <h3 class="text-lg font-semibold text-base-content tracking-tight">Step Configuration</h3>
              <p class="text-xs text-base-content/50 font-medium">Configure the parameters for this operation.</p>
            </div>

            <!-- Webhook Specific UI -->
            <div v-if="isWebhookTrigger" class="bg-base-100 border border-base-300 rounded-2xl p-5 space-y-4 shadow-sm">
              <div class="flex items-center justify-between">
                 <h4 class="text-sm font-bold text-base-content flex items-center gap-2">
                  <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
                  </svg>
                  Webhook URLs
                 </h4>
                 <div class="join bg-base-200/50 p-1 rounded-lg">
                   <button class="join-item btn btn-xs px-3" :class="webhookMode === 'test' ? 'btn-primary' : 'btn-ghost'" @click="webhookMode = 'test'">Test URL</button>
                   <button class="join-item btn btn-xs px-3" :class="webhookMode === 'production' ? 'btn-neutral' : 'btn-ghost'" @click="webhookMode = 'production'">Production URL</button>
                 </div>
              </div>

              <div class="relative">
                <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                  <span class="badge badge-sm font-mono text-[10px]" :class="webhookMode === 'test' ? 'badge-primary' : 'badge-neutral'">{{ webhookMethod }}</span>
                </div>
                <input type="text" readonly :value="webhookUrl" class="input input-sm w-full pl-16 font-mono text-xs bg-base-200/30 border-base-300 text-base-content/70 selection:bg-primary/20" @click="($event.target as HTMLInputElement).select()" />
                <div class="absolute inset-y-0 right-0 pr-1 flex items-center">
                   <button class="btn btn-xs btn-ghost btn-square" @click="copyWebhookUrl">
                    <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4 opacity-50" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3" />
                    </svg>
                   </button>
                </div>
              </div>

              <div v-if="webhookMode === 'test'" class="space-y-3 pt-2">
                <div class="flex items-center gap-4">
                  <button class="btn btn-sm w-full gap-2 shadow-lg"
                    :class="isWebhookListening ? 'btn-error shadow-error/20' : 'btn-primary shadow-primary/20'"
                    :disabled="isWebhookListeningElsewhere"
                    @click="toggleWebhookListening">
                    <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" :class="isWebhookListening ? '' : 'animate-pulse'" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.636 18.364a9 9 0 010-12.728m12.728 0a9 9 0 010 12.728m-9.9-2.829a5 5 0 010-7.07m7.072 0a5 5 0 010 7.07M13 12a1 1 0 11-2 0 1 1 0 012 0z" />
                    </svg>
                    {{ isWebhookListening ? 'Stop listening' : 'Listen for test event' }}
                  </button>
                  <p class="text-[10px] text-base-content/50 leading-tight flex-1">
                    {{ isWebhookListening ? 'Listening for a test request. Send it to the URL to capture payloads.' : 'Enable a temporary test listener while editing this draft.' }}
                  </p>
                </div>

                <div v-if="isWebhookListening" class="rounded-xl border border-primary/20 bg-primary/5 px-4 py-3 text-[11px] text-base-content/70">
                  Listening for test event. Send a {{ webhookMethod }} request to the Test URL.
                </div>
                <div v-else-if="isWebhookListeningElsewhere" class="rounded-xl border border-warning/20 bg-warning/5 px-4 py-3 text-[11px] text-base-content/70">
                  Another webhook trigger is already listening. Stop it to enable this one.
                </div>
              </div>
            </div>

            <div class="space-y-6">
              <div v-for="field in fields" :key="field.key" class="group relative">
                <div class="rounded-2xl border transition-all duration-300"
                  :class="fieldModes[field.key] === 'literal' ? 'border-base-300 bg-base-100 shadow-sm' : 'border-secondary/20 bg-secondary/[0.02] shadow-inner'">
                  <div class="px-5 py-3 border-b border-base-200/50 flex items-center justify-between">
                    <label class="block text-sm font-medium text-base-content tracking-tight">{{ field.label }}</label>

                    <div class="join">
                      <button class="join-item btn btn-xs capitalize"
                        :class="fieldModes[field.key] === 'literal' ? 'btn-primary' : 'btn-ghost'"
                        @click="toggleMode(field.key)">Fixed</button>
                      <button class="join-item btn btn-xs capitalize"
                        :class="fieldModes[field.key] === 'expression' ? 'btn-secondary' : 'btn-ghost'"
                        @click="toggleMode(field.key)">Expression</button>
                    </div>
                  </div>

                  <div class="p-5">
                    <template v-if="fieldModes[field.key] === 'literal'">
                      <textarea v-if="field.type === 'textarea' || field.type === 'json'" v-model="fieldValues[field.key]"
                        class="textarea textarea-bordered w-full font-mono text-xs bg-base-200/10 border-base-300 focus:border-primary min-h-[100px] rounded-xl"
                        :placeholder="field.type === 'json' ? '{ \n  &quot;key&quot;: &quot;value&quot; \n}' : ''"></textarea>
                      <input v-else v-model="fieldValues[field.key]" :type="field.type === 'number' ? 'number' : 'text'"
                        class="input input-md w-full bg-base-200/20 border-base-300 focus:border-primary font-medium text-sm rounded-xl" />
                    </template>
                    <template v-else>
                      <div class="space-y-3">
                        <textarea v-model="fieldValues[field.key]"
                          class="textarea w-full font-mono text-[13px] bg-base-100 border-2 border-secondary/10 focus:border-secondary/40 focus:ring-4 focus:ring-secondary/5 min-h-[80px] rounded-xl"
                          placeholder="{{ steps.PreviousStep.json.field }}"></textarea>
                        
                        <!-- Live Preview -->
                        <div v-if="hasPreviewFor(field.key)" class="overflow-hidden rounded-xl border border-base-200/60 bg-base-200/20">
                          <div
                            class="flex items-center justify-between px-4 py-1.5 border-b border-base-200/40 bg-base-200/30">
                            <span class="text-[9px] font-bold uppercase tracking-widest text-base-content/30">Live Preview</span>
                            <span class="text-[9px] font-bold text-success uppercase">Draft</span>
                          </div>
                          <div class="p-3 text-[11px] font-mono text-base-content/70">
                            <template v-if="typeof (previewValueFor(field.key)) === 'object' && previewValueFor(field.key) !== null">
                              <ExpressionPreviewError :error="previewValueFor(field.key)" />
                            </template>
                            <template v-else>
                              {{ previewValueFor(field.key) || 'Run a test to see preview results' }}
                            </template>
                          </div>
                        </div>

                        <!-- Result from execution -->
                        <div v-else-if="evaluatedConfig[field.key] !== undefined" class="overflow-hidden rounded-xl border border-secondary/20 bg-secondary/[0.03]">
                          <div
                            class="flex items-center justify-between px-4 py-1.5 border-b border-secondary/10 bg-secondary/5">
                            <span class="text-[9px] font-bold uppercase tracking-widest text-secondary/60">Resolved Result</span>
                            <span class="text-[9px] font-bold text-secondary uppercase">Value</span>
                          </div>
                          <div class="p-3 text-[11px] font-mono text-base-content/70">
                            {{ evaluatedConfig[field.key] }}
                          </div>
                        </div>

                        <!-- Live Preview (Mock or fallback) -->
                        <div v-else class="overflow-hidden rounded-xl border border-base-200/60 bg-base-200/20">
                          <div
                            class="flex items-center justify-between px-4 py-1.5 border-b border-base-200/40 bg-base-200/30">
                            <span class="text-[9px] font-bold uppercase tracking-widest text-base-content/30">Live Preview</span>
                            <span class="text-[9px] font-bold text-success uppercase">Draft</span>
                          </div>
                          <div class="p-3 text-[11px] font-mono text-base-content/70">
                            {{ 'Run a test to see preview results' }}
                          </div>
                        </div>
                      </div>
                    </template>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div v-else-if="activeTab === 'output'" class="max-w-4xl mx-auto p-4 space-y-8 h-full custom-scrollbar">
            <div v-if="activeStepExecution" class="space-y-8 pb-20">
              <section>
                <div class="flex items-center justify-between mb-3">
                  <h4 class="text-xs font-bold uppercase tracking-widest text-base-content/40">Input Data</h4>
                  <button @click.stop="copyExpression('json')" class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100">
                    <svg xmlns="http://www.w3.org/2000/svg" class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3" />
                    </svg>
                    Copy Expression
                  </button>
                </div>
                <div class="bg-base-300/30 rounded-2xl p-4 font-mono text-xs overflow-x-auto whitespace-pre">
                  {{ formatDataForDisplay(activeStepExecution.input_data) }}
                </div>
              </section>

              <section>
                <div class="flex items-center justify-between mb-3">
                  <h4 class="text-xs font-bold uppercase tracking-widest text-base-content/40">Output Data</h4>
                  <div class="flex items-center gap-2">
                    <button @click.stop="copyExpression('steps', node?.id)" class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100">
                      <svg xmlns="http://www.w3.org/2000/svg" class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3" />
                      </svg>
                      Copy Expression
                    </button>
                    <span v-if="activeStepExecution.status === 'completed'" class="badge badge-success badge-sm">Success</span>
                  </div>
                </div>
                <div class="bg-base-300/30 rounded-2xl p-4 font-mono text-xs overflow-x-auto whitespace-pre border-2 border-success/10">
                  {{ formatDataForDisplay(activeStepExecution.output_data) }}
                </div>
              </section>

              <section v-if="activeStepExecution.error">
                <h4 class="text-xs font-bold uppercase tracking-widest text-error/60 mb-3">Error</h4>
                <div class="bg-error/5 border border-error/20 rounded-2xl p-4 font-mono text-xs text-error">
                  {{ activeStepExecution.error }}
                </div>
              </section>
            </div>

            <div v-else class="h-full flex flex-col items-center justify-center opacity-40">
              <svg xmlns="http://www.w3.org/2000/svg" class="w-16 h-16 mb-4" fill="none" viewBox="0 0 24 24"
                stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M13 10V3L4 14h7v7l9-11h-7z" />
              </svg>
              <p class="text-sm font-bold">No execution data available</p>
              <p class="text-xs">Run the workflow to see inputs and outputs</p>
            </div>
          </div>

          <div v-else class="h-full flex flex-col items-center justify-center opacity-40">
            <svg xmlns="http://www.w3.org/2000/svg" class="w-16 h-16 mb-4" fill="none" viewBox="0 0 24 24"
              stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                d="M5 5a2 2 0 012-2h10a2 2 0 012 2v16l-7-3.5L5 21V5z" />
            </svg>
            <p class="text-sm font-bold">No pinned snapshots</p>
          </div>
        </div>
      </div>

      <!-- Footer -->
      <div class="px-8 py-5 border-t border-base-200 flex items-center justify-end bg-base-100">


        <div class="flex items-center gap-4">
          <button class="btn btn-ghost btn-sm font-bold text-base-content/60" @click="closeModal">Discard
            Changes</button>
          <button class="btn btn-primary px-8 rounded-xl font-bold shadow-lg shadow-primary/20" @click="saveConfig">Save
            Configuration</button>
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
