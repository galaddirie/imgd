<script setup lang="ts">
import { computed } from 'vue';

import type { UndoEntrySummary } from '@/stores/undoStore';
import type { WorkflowVersion } from '@/types/workflow';
import type { RevisionSelection } from '@/types/workflowEditor';

interface Props {
  isOpen: boolean;
  editStack: UndoEntrySummary[];
  versions: WorkflowVersion[];
  selectedRevision: RevisionSelection | null;
  isLoading: boolean;
  previewLabel: string;
  applyActionLabel: string;
  currentVersionTag?: string;
  workflowUpdatedAt?: string | null;
  hasPreviewDraft: boolean;
}

const props = defineProps<Props>();

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'select-undo', entry: UndoEntrySummary): void;
  (e: 'select-version', version: WorkflowVersion): void;
  (e: 'apply'): void;
  (e: 'reset'): void;
}>();

const isCurrentSelected = computed(() => !props.selectedRevision);

const formatRevisionTimestamp = (value?: string | null) => {
  if (!value) return 'Unknown';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
};
</script>

<template>
  <aside
    v-if="isOpen"
    class="bg-base-100 border-base-200 flex h-full w-96 shrink-0 flex-col border-l p-5"
  >
    <div class="flex items-start justify-between gap-4">
      <div>
        <h2 class="text-sm font-semibold text-base-content">Revisions</h2>
        <p class="text-xs text-base-content/50">
          Preview and restore past edits or published versions.
        </p>
      </div>
      <button class="btn btn-ghost btn-xs" @click="emit('close')">Close</button>
    </div>

    <div class="mt-4 flex-1 space-y-6 overflow-y-auto pr-1">
      <div>
        <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
          Current
        </div>
        <button
          class="mt-3 flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-3 text-left text-xs transition-all"
          :class="[
            isCurrentSelected
              ? 'border-primary/40 bg-primary/10 text-primary'
              : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
          ]"
          @click="emit('reset')"
        >
          <div>
            <div class="text-sm font-semibold text-base-content">Current draft</div>
            <div class="text-[11px] text-base-content/50">
              Last updated {{ formatRevisionTimestamp(workflowUpdatedAt) }}
            </div>
          </div>
          <span v-if="currentVersionTag" class="badge badge-ghost badge-xs">
            v{{ currentVersionTag }}
          </span>
        </button>
      </div>

      <div>
        <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
          Edit stack
        </div>
        <div
          v-if="editStack.length === 0"
          class="mt-3 rounded-xl border border-dashed border-base-300 bg-base-200/50 p-3 text-xs text-base-content/50"
        >
          No edits yet.
        </div>
        <div v-else class="mt-3 space-y-2">
          <button
            v-for="entry in editStack"
            :key="entry.id"
            class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-2 text-left text-xs transition-all"
            :class="[
              selectedRevision?.kind === 'undo' && selectedRevision?.id === entry.id
                ? 'border-primary/40 bg-primary/10 text-primary'
                : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
            ]"
            @click="emit('select-undo', entry)"
          >
            <div>
              <div class="text-sm font-semibold text-base-content">
                {{ entry.label || 'Untitled change' }}
              </div>
              <div class="text-[11px] text-base-content/50">
                {{ formatRevisionTimestamp(entry.timestamp) }}
              </div>
            </div>
            <span class="text-[10px] uppercase tracking-wide text-base-content/40">
              Undo {{ entry.depth }}
            </span>
          </button>
        </div>
      </div>

      <div>
        <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
          Published versions
        </div>
        <div
          v-if="versions.length === 0"
          class="mt-3 rounded-xl border border-dashed border-base-300 bg-base-200/50 p-3 text-xs text-base-content/50"
        >
          No published versions yet.
        </div>
        <div v-else class="mt-3 space-y-2">
          <button
            v-for="version in versions"
            :key="version.id"
            class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-2 text-left text-xs transition-all"
            :class="[
              selectedRevision?.kind === 'version' && selectedRevision?.id === version.id
                ? 'border-primary/40 bg-primary/10 text-primary'
                : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
            ]"
            @click="emit('select-version', version)"
          >
            <div>
              <div class="text-sm font-semibold text-base-content">v{{ version.version_tag }}</div>
              <div class="text-[11px] text-base-content/50">
                {{ formatRevisionTimestamp(version.published_at) }}
              </div>
            </div>
            <span
              v-if="currentVersionTag && currentVersionTag === version.version_tag"
              class="badge badge-xs"
            >
              Current
            </span>
          </button>
        </div>
      </div>
    </div>

    <div class="mt-4 border-t border-base-200 pt-4">
      <div v-if="selectedRevision" class="space-y-3">
        <div class="text-xs text-base-content/70">
          Previewing <span class="font-semibold">{{ previewLabel }}</span>
        </div>
        <div v-if="isLoading" class="text-xs text-base-content/50">Loading preview...</div>
        <div class="flex flex-wrap gap-2">
          <button
            class="btn btn-primary btn-sm"
            :disabled="isLoading || !hasPreviewDraft"
            @click="emit('apply')"
          >
            {{ applyActionLabel }}
          </button>
          <button class="btn btn-ghost btn-sm" @click="emit('reset')">Exit preview</button>
        </div>
        <p class="text-[11px] text-base-content/40">This change is fully undoable.</p>
      </div>
      <div v-else class="text-xs text-base-content/60">Select a revision to preview.</div>
    </div>
  </aside>
</template>
