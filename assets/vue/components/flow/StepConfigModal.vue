<script setup lang="ts">
import { ref, computed, watch } from 'vue'

interface NodeData {
  id: string
  type_id: string
  name: string
  config?: Record<string, unknown>
  [key: string]: any
}

interface Node {
  id: string
  data: NodeData
  [key: string]: any
}

interface Props {
  node: Node | null
  isOpen: boolean
  execution?: any
}

const props = defineProps<Props>()
const emit = defineEmits(['close', 'save'])

const activeTab = ref<'config' | 'output' | 'pinned'>('config')
const fieldModes = ref<Record<string, 'literal' | 'expression'>>({})
const fieldValues = ref<Record<string, any>>({})
const searchQuery = ref('')

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
  }
}, { immediate: true })

const closeModal = () => emit('close')

const saveConfig = () => {
  emit('save', {
    id: props.node?.id,
    config: { ...fieldValues.value }
  })
  closeModal()
}

const toggleMode = (field: string) => {
  fieldModes.value[field] = fieldModes.value[field] === 'literal' ? 'expression' : 'literal'
}

// Mock schema inference
const fields = computed(() => {
  if (!props.node) return []
  const config = props.node.data.config || {}
  return Object.keys(config).map(key => ({
    key,
    label: key.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase()),
    type: inferType(config[key]),
  }))
})

const inferType = (val: any) => {
  if (typeof val === 'boolean') return 'boolean'
  if (typeof val === 'number') return 'number'
  if (typeof val === 'string' && val.length > 50) return 'textarea'
  return 'text'
}

// Variable Explorer Mock Data
const explorerSections = [
  { id: 'json', label: 'Current Input', icon: 'hero-arrow-right-on-rectangle' },
  { id: 'steps', label: 'Upstream Steps', icon: 'hero-cpu-chip' },
  { id: 'variables', label: 'Workflow Variables', icon: 'hero-variable' },
  { id: 'system', label: 'System', icon: 'hero-globe-alt' },
]

const expandedSections = ref<Record<string, boolean>>({ json: true, steps: true })

const toggleSection = (id: string) => {
  expandedSections.value[id] = !expandedSections.value[id]
}
</script>

<template>
  <div v-if="isOpen"
    class="fixed inset-0 z-[100] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4 sm:p-6"
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
              <h2 class="text-lg font-bold text-base-content leading-none">{{ node?.data.name }}</h2>
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
            <div v-for="section in explorerSections" :key="section.id" class="overflow-hidden">
              <button
                class="w-full flex items-center justify-between p-2 rounded-xl text-xs font-bold transition-all hover:bg-primary/5 group"
                :class="expandedSections[section.id] ? 'text-primary bg-primary/5' : 'text-base-content/60'"
                @click="toggleSection(section.id)">
                <div class="flex items-center gap-2">
                  <span class="opacity-70 group-hover:opacity-100">
                    <!-- Icon Placeholder -->
                    <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path d="M4 6h16M4 12h16m-7 6h7" stroke-width="2" stroke-linecap="round" />
                    </svg>
                  </span>
                  {{ section.label }}
                </div>
                <svg :class="{ 'rotate-90': expandedSections[section.id] }"
                  class="w-3 h-3 transition-transform opacity-40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path d="M9 5l7 7-7 7" stroke-width="2" />
                </svg>
              </button>
              <div v-if="expandedSections[section.id]" class="mt-1 ml-4 pl-2 border-l border-base-200 py-1 space-y-1">
                <div class="p-2 text-[10px] text-base-content/40 italic">No variables available</div>
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
                      <textarea v-if="field.type === 'textarea'" v-model="fieldValues[field.key]"
                        class="textarea textarea-bordered w-full font-mono text-xs bg-base-200/10 border-base-300 focus:border-primary min-h-[100px] rounded-xl"></textarea>
                      <input v-else v-model="fieldValues[field.key]" :type="field.type === 'number' ? 'number' : 'text'"
                        class="input input-md w-full bg-base-200/20 border-base-300 focus:border-primary font-medium text-sm rounded-xl" />
                    </template>
                    <template v-else>
                      <div class="space-y-3">
                        <textarea v-model="fieldValues[field.key]"
                          class="textarea w-full font-mono text-[13px] bg-base-100 border-2 border-secondary/10 focus:border-secondary/40 focus:ring-4 focus:ring-secondary/5 min-h-[80px] rounded-xl"
                          placeholder="{{ steps.PreviousStep.json.field }}"></textarea>
                        <div class="overflow-hidden rounded-xl border border-base-200/60 bg-base-200/20">
                          <div
                            class="flex items-center justify-between px-4 py-1.5 border-b border-base-200/40 bg-base-200/30">
                            <span class="text-[9px] font-bold uppercase tracking-widest text-base-content/30">Live
                              Preview</span>
                            <span class="text-[9px] font-bold text-success uppercase">Success</span>
                          </div>
                          <div class="p-3 text-[11px] font-mono text-base-content/70">
                            {{ fieldValues[field.key] }}
                          </div>
                        </div>
                      </div>
                    </template>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div v-else-if="activeTab === 'output'" class="h-full flex flex-col items-center justify-center opacity-40">
            <svg xmlns="http://www.w3.org/2000/svg" class="w-16 h-16 mb-4" fill="none" viewBox="0 0 24 24"
              stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            <p class="text-sm font-bold">No output available yet</p>
            <p class="text-xs">Run this step to see captured data</p>
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
