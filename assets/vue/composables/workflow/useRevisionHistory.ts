import { computed, onMounted, ref } from 'vue';
import type { LiveHook } from 'live_vue';

import type { Workflow, WorkflowDraft, WorkflowVersion } from '@/types/workflow';
import type { UndoEntrySummary } from '@/stores/undoStore';
import type {
  RevisionSelection,
  RevisionPreviewPayload,
  WorkflowEditorEmits,
} from '@/types/workflowEditor';
import type { useClientStore } from '@/stores/clientStore';
import type { useUndoStore } from '@/stores/undoStore';

interface UseRevisionHistoryOptions {
  workflow: () => Workflow;
  workflowVersions: () => WorkflowVersion[];
  emit: WorkflowEditorEmits;
  store: ReturnType<typeof useClientStore>;
  undoStore: ReturnType<typeof useUndoStore>;
  live: LiveHook;
}

export function useRevisionHistory(options: UseRevisionHistoryOptions) {
  const isRevisionPanelOpen = ref(false);
  const isRevisionPreviewLoading = ref(false);
  const previewDraft = ref<WorkflowDraft | null>(null);
  const selectedRevision = ref<RevisionSelection | null>(null);

  const isRevisionPreviewActive = computed(() => !!previewDraft.value);
  const canEdit = computed(() => !isRevisionPreviewActive.value);

  const editStack = computed<UndoEntrySummary[]>(() => options.undoStore.state.undoStack ?? []);
  const revisionVersions = computed<WorkflowVersion[]>(() => options.workflowVersions() ?? []);

  const formatRevisionTimestamp = (value?: string | null) => {
    if (!value) return 'Unknown';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return value;
    return date.toLocaleString();
  };

  const previewLabel = computed(() => selectedRevision.value?.label ?? 'Revision preview');
  const applyActionLabel = computed(() =>
    selectedRevision.value?.kind === 'version' ? 'Apply version' : 'Revert to this edit'
  );
  const isCurrentSelected = computed(() => !selectedRevision.value);

  const buildPreviewDraft = (draft: Partial<WorkflowDraft>): WorkflowDraft => {
    const workflow = options.workflow();

    return {
      id: draft.id ?? workflow.draft?.id ?? workflow.id,
      workflow_id: draft.workflow_id ?? workflow.draft?.workflow_id ?? workflow.id,
      steps: draft.steps ?? [],
      connections: draft.connections ?? [],
      groups: draft.groups ?? [],
      triggers: draft.triggers ?? workflow.draft?.triggers ?? [],
      settings: draft.settings ?? workflow.draft?.settings ?? {},
    };
  };

  const resetRevisionPreview = () => {
    previewDraft.value = null;
    selectedRevision.value = null;
    isRevisionPreviewLoading.value = false;
    options.store.closeConfigModal();
    options.store.hideContextMenu();
    options.store.selectNode(null);
  };

  const toggleRevisionPanel = () => {
    isRevisionPanelOpen.value = !isRevisionPanelOpen.value;
    if (isRevisionPanelOpen.value) {
      options.store.isLibraryOpen = false;
      options.store.closeConfigModal();
      options.store.hideContextMenu();
    } else {
      resetRevisionPreview();
    }
  };

  const selectUndoEntry = (entry: UndoEntrySummary) => {
    selectedRevision.value = {
      kind: 'undo',
      id: entry.id,
      label: entry.label ?? 'Undo',
      depth: entry.depth,
    };
    previewDraft.value = null;
    isRevisionPreviewLoading.value = true;
    options.emit('preview_revision', { kind: 'undo', depth: entry.depth });
  };

  const selectVersion = (version: WorkflowVersion) => {
    selectedRevision.value = {
      kind: 'version',
      id: version.id,
      label: `v${version.version_tag}`,
      versionTag: version.version_tag,
    };
    previewDraft.value = buildPreviewDraft({
      steps: version.steps ?? [],
      connections: version.connections ?? [],
      groups: version.groups ?? [],
    });
    isRevisionPreviewLoading.value = false;
  };

  const applySelectedRevision = () => {
    if (!selectedRevision.value) return;

    if (selectedRevision.value.kind === 'undo') {
      options.emit('apply_revision', {
        kind: 'undo',
        depth: selectedRevision.value.depth ?? 1,
      });
    } else {
      options.emit('apply_revision', {
        kind: 'version',
        version_id: selectedRevision.value.id,
      });
    }

    resetRevisionPreview();
  };

  onMounted(() => {
    options.live.handleEvent('undo_state', payload => {
      if (payload && typeof payload === 'object') {
        options.undoStore.handleStateUpdate(payload as any);
      }
    });

    options.live.handleEvent('undo_applied', () => options.undoStore.handleUndoApplied());
    options.live.handleEvent('undo_conflict', () => options.undoStore.handleUndoConflict());
    options.live.handleEvent('redo_applied', () => options.undoStore.handleRedoApplied());
    options.live.handleEvent('redo_conflict', () => options.undoStore.handleRedoConflict());

    options.live.handleEvent('revision_preview', payload => {
      if (!payload || typeof payload !== 'object') return;
      const data = payload as RevisionPreviewPayload;
      if (data.kind !== 'undo') return;
      if (!selectedRevision.value || selectedRevision.value.kind !== 'undo') return;
      if (data.depth !== selectedRevision.value.depth) return;

      previewDraft.value = buildPreviewDraft(data.draft ?? {});
      isRevisionPreviewLoading.value = false;
    });
  });

  return {
    isRevisionPanelOpen,
    isRevisionPreviewLoading,
    previewDraft,
    selectedRevision,
    isRevisionPreviewActive,
    canEdit,
    editStack,
    revisionVersions,
    previewLabel,
    applyActionLabel,
    isCurrentSelected,
    formatRevisionTimestamp,
    toggleRevisionPanel,
    selectUndoEntry,
    selectVersion,
    applySelectedRevision,
    resetRevisionPreview,
  };
}
