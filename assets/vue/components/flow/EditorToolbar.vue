<script setup lang="ts">
import { computed } from 'vue'
import ThemeSelector from '../../ThemeSelector.vue'
import Avatar from '../ui/Avatar.vue'
import type { UserPresence } from '@/types/workflow'
import {
  BoltIcon,
  ArrowUturnLeftIcon,
  ArrowUturnRightIcon,
  CloudArrowUpIcon,
  PlayCircleIcon,
  UserCircleIcon,
  CheckCircleIcon,
  ExclamationCircleIcon,
  ArrowPathIcon,
} from '@heroicons/vue/24/outline'

// =============================================================================
// Props
// =============================================================================

interface Props {
  workflowName?: string
  workflowStatus?: 'draft' | 'active' | 'archived'
  lastSaved?: string
  isSaving?: boolean
  hasUnsavedChanges?: boolean
  canUndo?: boolean
  canRedo?: boolean
  presences?: UserPresence[]
  validationErrors?: string[]
}

const props = withDefaults(defineProps<Props>(), {
  workflowName: 'Untitled Workflow',
  workflowStatus: 'draft',
  lastSaved: 'Just now',
  isSaving: false,
  hasUnsavedChanges: false,
  canUndo: false,
  canRedo: false,
  presences: () => [],
  validationErrors: () => [],
})

// =============================================================================
// Emits
// =============================================================================

const emit = defineEmits<{
  (e: 'save'): void
  (e: 'undo'): void
  (e: 'redo'): void
  (e: 'run-test'): void
  (e: 'publish'): void
  (e: 'rename', name: string): void
}>()

// =============================================================================
// Computed
// =============================================================================

const statusBadge = computed(() => {
  const configs = {
    draft: { class: 'badge-warning', label: 'Draft' },
    active: { class: 'badge-success', label: 'Active' },
    archived: { class: 'badge-ghost', label: 'Archived' },
  }
  return configs[props.workflowStatus]
})

const hasErrors = computed(() => props.validationErrors.length > 0)

</script>

<template>
  <header
    class="h-16 bg-base-100/80 backdrop-blur-md border-b border-base-200 flex items-center justify-between px-6 shadow-sm z-30 shrink-0">
    <!-- Left Section: Logo & Title -->
    <div class="flex items-center gap-5">
      <!-- Logo -->
      <div class="w-11 h-11 rounded-2xl bg-primary/10 text-primary flex items-center justify-center shadow-inner">
        <BoltIcon class="h-7 w-7" />
      </div>

      <!-- Workflow Info -->
      <div>
        <div class="flex items-center gap-2.5">
          <h1 class="text-sm font-semibold text-base-content/90">
            {{ workflowName }}
          </h1>
          <span :class="['badge badge-sm font-bold opacity-80 gap-1.5 h-5', statusBadge.class]">
            <span class="w-1 h-1 rounded-full bg-current"></span>
            {{ statusBadge.label }}
          </span>

          <!-- Unsaved indicator -->
          <span v-if="hasUnsavedChanges" class="badge badge-ghost badge-xs">
            Unsaved
          </span>
        </div>

        <p class="text-xs text-base-content/40 font-semibold tracking-tight mt-0.5">
          <span v-if="isSaving" class="flex items-center gap-1">
            <ArrowPathIcon class="w-3 h-3 animate-spin" />
            Saving...
          </span>
          <span v-else>
            Last saved: {{ lastSaved }}
          </span>
        </p>
      </div>
    </div>

    <!-- Center Section: Undo/Redo Tools -->
    <div class="flex items-center bg-base-200/50 p-1.5 rounded-2xl gap-1 border border-base-300/30">
      <button
        class="btn btn-ghost btn-xs btn-square rounded-lg tooltip tooltip-bottom hover:bg-base-100 disabled:opacity-30"
        :disabled="!canUndo" data-tip="Undo (⌘Z)" @click="emit('undo')">
        <ArrowUturnLeftIcon class="h-4.5 w-4.5" />
      </button>
      <button
        class="btn btn-ghost btn-xs btn-square rounded-lg tooltip tooltip-bottom hover:bg-base-100 disabled:opacity-30"
        :disabled="!canRedo" data-tip="Redo (⌘⇧Z)" @click="emit('redo')">
        <ArrowUturnRightIcon class="h-4.5 w-4.5" />
      </button>
    </div>

    <!-- Right Section: Collaboration + Actions -->
    <div class="flex items-center gap-4">
      <!-- Collaborators -->
      <Avatar :presences="presences" />

      <!-- Validation Errors Indicator -->
      <div v-if="hasErrors" class="tooltip tooltip-bottom" :data-tip="`${validationErrors.length} validation error(s)`">
        <button class="btn btn-ghost btn-sm btn-circle text-error">
          <ExclamationCircleIcon class="w-5 h-5" />
        </button>
      </div>

      <!-- Theme Selector -->
      <div class="bg-base-200/50 p-1 rounded-full border border-base-300/30">
        <ThemeSelector />
      </div>

      <!-- Save Button -->
      <button
        class="btn btn-sm btn-ghost border border-base-300 bg-base-100 hover:bg-base-200 rounded-xl px-5 font-semibold transition-all flex gap-2 text-base-content/70 text-sm"
        :disabled="isSaving" @click="emit('save')">
        <span v-if="isSaving" class="loading loading-spinner loading-xs text-primary"></span>
        <CloudArrowUpIcon v-else class="h-5 w-5" />
        {{ isSaving ? 'Saving...' : 'Save' }}
      </button>

      <!-- Run Test Button -->
      <button
        class="btn btn-sm btn-primary rounded-xl px-6 flex gap-2 font-semibold shadow-lg shadow-primary/20 transition-all hover:scale-105 active:scale-95 text-sm"
        @click="emit('run-test')">
        <PlayCircleIcon class="h-5 w-5" />
        Run Test
      </button>
    </div>
  </header>
</template>

<style scoped>
.tooltip::before {
  font-size: 11px;
  padding: 4px 8px;
}
</style>