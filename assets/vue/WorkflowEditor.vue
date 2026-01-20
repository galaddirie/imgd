<script setup lang="ts">
import { reactive } from 'vue';
import EditorToolbar from '@/components/flow/EditorToolbar.vue';
import ExecutionTracePanel from '@/components/flow/ExecutionTracePanel.vue';
import NodeLibrary from '@/components/flow/NodeLibrary.vue';
import StepConfigModal from '@/components/flow/StepConfigModal.vue';
import WorkflowCanvas from '@/components/flow/WorkflowCanvas.vue';
import ContextMenu from '@/components/ui/ContextMenu.vue';
import { useWorkflowEditor } from '@/composables/workflow/useWorkflowEditor';
import type { WorkflowEditorEmits, WorkflowEditorProps } from '@/types/workflowEditor';

const props = withDefaults(defineProps<WorkflowEditorProps>(), {
  stepTypes: () => [],
  nodeLibraryItems: () => [],
  execution: null,
  stepExecutions: () => [],
  editorState: undefined,
  presences: () => [],
  currentUserId: undefined,
  expressionPreviews: () => ({}),
});

const emit = defineEmits<WorkflowEditorEmits>();
const editor = reactive(useWorkflowEditor(props, emit));
</script>

<template>
  <div class="bg-base-300 text-base-content flex h-screen flex-col overflow-hidden font-sans">
    <EditorToolbar
      :workflow-name="editor.workflow?.name ?? 'Untitled Workflow'"
      :is-saving="false"
      :presences="editor.presences"
      :can-undo="editor.undoStore.canUndo"
      :can-redo="editor.undoStore.canRedo"
      :undo-tooltip="editor.undoStore.undoTooltip"
      :redo-tooltip="editor.undoStore.redoTooltip"
      :is-undo-pending="editor.undoStore.isPending"
      @save="editor.handleSave"
      @undo="editor.handleUndo"
      @redo="editor.handleRedo"
      @run-test="editor.handleRunTest"
      @open-revisions="emit('navigate_revisions')"
    />

    <div class="relative flex flex-1 overflow-hidden">
      <NodeLibrary
        v-if="editor.store.isLibraryOpen"
        :library-items="editor.nodeLibraryItems"
        class="shrink-0"
        @collapse="editor.store.isLibraryOpen = false"
      />

      <button
        v-else
        class="btn btn-xs btn-circle bg-base-200 border-base-300 absolute top-1/2 left-0 z-50 ml-1 -translate-y-1/2"
        @click="editor.store.isLibraryOpen = true"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4 rotate-90"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <div class="relative flex min-w-0 flex-1 flex-col">
        <WorkflowCanvas
          :nodes="editor.nodes"
          :edges="editor.edges"
          :node-types="editor.nodeTypes"
          :edge-types="editor.edgeTypes"
          :can-edit="editor.canEdit"
          :is-revision-preview-active="false"
          preview-label=""
          :is-mounted="editor.isMounted"
          :other-user-presences="editor.otherUserPresences"
          :current-user-id="editor.currentUserId"
          :viewport="editor.viewport"
          :mini-map-node-color="editor.miniMapNodeColor"
          :set-canvas-ref="editor.setCanvasRef"
          :set-vue-flow-ref="editor.setVueFlowRef"
          :handle-pane-mouse-move="editor.handlePaneMouseMove"
          :handle-node-click="editor.handleNodeClick"
          :handle-node-double-click="editor.handleNodeDoubleClick"
          :handle-node-context-menu="editor.handleNodeContextMenu"
          :handle-selection-change="editor.handleSelectionChange"
          :handle-selection-context-menu="editor.handleSelectionContextMenu"
          :handle-pane-context-menu="editor.handlePaneContextMenu"
          :handle-edge-update="editor.handleEdgeUpdate"
          :handle-drag-over="editor.handleDragOver"
          :handle-drop="editor.handleDrop"
          :is-execution-failed="editor.isExecutionFailed"
          :is-execution-running="editor.isExecutionRunning"
          :on-run-test="editor.handleRunTest"
          :on-cancel-execution="editor.handleCancelExecution"
        />

        <ExecutionTracePanel
          :execution="editor.execution"
          :step-executions="editor.stepExecutions"
          :step-name-by-id="editor.stepNameById"
          :selected-step-id="editor.store.selectedNodeId"
          :is-expanded="editor.store.isTracePanelExpanded"
          @toggle="editor.store.toggleTracePanel"
          @close="editor.store.isTracePanelExpanded = false"
          @select-step="editor.selectTraceStep"
          @run-test="editor.handleRunTest"
          @cancel="editor.handleCancelExecution"
        />
      </div>

      <StepConfigModal
        :is-open="editor.store.isConfigModalOpen"
        :node="editor.selectedNode"
        :step-type="editor.selectedStepType"
        :execution="editor.execution"
        :step-executions="editor.stepExecutions"
        :expression-previews="editor.expressionPreviews"
        :editor-state="editor.editorState"
        :step-name-by-id="editor.stepNameById"
        :upstream-step-ids="editor.upstreamStepIdsByStepId"
        :can-edit="editor.canEdit"
        @close="editor.store.closeConfigModal"
        @save="editor.handleSaveConfig"
        @delete="editor.handleDeleteStep"
        @preview_expression="editor.handlePreviewExpression"
        @pin_output="editor.handlePinOutput"
        @unpin_output="editor.handleUnpinOutput"
        @toggle_webhook_test="editor.handleToggleWebhookTest"
      />

      <ContextMenu
        :show="editor.store.contextMenu.show"
        :x="editor.store.contextMenu.x"
        :y="editor.store.contextMenu.y"
        :items="editor.contextMenuItems"
        @select="editor.handleContextMenuSelect"
        @close="editor.closeContextMenu"
      />
    </div>
  </div>
</template>
