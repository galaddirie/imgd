<script setup lang="ts">
import { ref, computed, onMounted, markRaw } from 'vue'
import type { Node, Edge, Connection as VueFlowConnection, Position, GraphNode } from '@vue-flow/core'
import { VueFlow, useVueFlow } from '@vue-flow/core'
import { Background } from '@vue-flow/background'
import { Controls } from '@vue-flow/controls'
import { MiniMap } from '@vue-flow/minimap'

import NodeLibrary from './components/flow/NodeLibrary.vue'
import StepConfigModal from './components/flow/StepConfigModal.vue'
import EditorToolbar from './components/flow/EditorToolbar.vue'
import ExecutionTracePanel from './components/flow/ExecutionTracePanel.vue'
import WorkflowStepNode from './components/flow/Node.vue'
import CustomEdge from './components/flow/Edge.vue'
import ContextMenu from './components/ui/ContextMenu.vue'
import type { MenuItem } from './ui/ContextMenu.vue'

import { useClientStore } from './store/clientStore'
import { oklchToHex } from './lib/color'
import { useLayout } from './lib/useLayout'

import {
  TrashIcon,
  DocumentDuplicateIcon,
  Cog6ToothIcon,
  EyeSlashIcon,
  BookmarkIcon,
  PlayIcon,
  PlusIcon,
  ClipboardDocumentIcon,
  ScissorsIcon,
  ArrowPathIcon,
} from '@heroicons/vue/24/outline'
import type {
  Workflow,
  Step,
  Connection,
  StepType,
  StepNodeData,
  EdgeData,
  Execution,
  StepExecution,
  EditorState,
  UserPresence,
} from './types/workflow'

// =============================================================================
// Props - Data from LiveView via LiveVue
// =============================================================================

interface Props {
  // Workflow document
  workflow: Workflow

  // Step type registry
  stepTypes?: StepType[]

  // Current execution (if running)
  execution?: Execution | null
  stepExecutions?: StepExecution[]

  // Collaboration state
  editorState?: EditorState
  presences?: UserPresence[]
}

const props = withDefaults(defineProps<Props>(), {
  stepTypes: () => [],
  execution: null,
  stepExecutions: () => [],
  editorState: undefined,
  presences: () => [],
})

// =============================================================================
// Emits - Events to LiveView via LiveVue
// =============================================================================

const emit = defineEmits<{
  // Step operations
  (e: 'add_step', payload: { type_id: string; position: { x: number; y: number } }): void
  (e: 'update_step', payload: { step_id: string; changes: Partial<Step> }): void
  (e: 'remove_step', payload: { step_id: string }): void
  (e: 'move_step', payload: { step_id: string; position: { x: number; y: number } }): void

  // Connection operations
  (e: 'add_connection', payload: { source_step_id: string; target_step_id: string; source_output?: string; target_input?: string }): void
  (e: 'remove_connection', payload: { connection_id: string }): void

  // Editor state operations
  (e: 'pin_output', payload: { step_id: string }): void
  (e: 'unpin_output', payload: { step_id: string }): void
  (e: 'disable_step', payload: { step_id: string; mode: 'skip' | 'exclude' }): void
  (e: 'enable_step', payload: { step_id: string }): void

  // Execution
  (e: 'run_test', payload?: { step_ids?: string[] }): void
  (e: 'cancel_execution'): void

  // Workflow
  (e: 'save_workflow'): void
  (e: 'publish_workflow', payload: { version_tag: string; changelog?: string }): void
}>()

// =============================================================================
// State Management (Pinia & Vue Flow)
// =============================================================================

const store = useClientStore()

const {
  onPaneClick,
  onConnect,
  onNodeDragStop,
  project,
  vueFlowRef,
  getNodes,
  getEdges,
  getSelectedNodes,
  updateNode,
  updateEdge,
} = useVueFlow()

const { layout, previousDirection } = useLayout()

const nodeTypes = {
  step: markRaw(WorkflowStepNode),
}

const edgeTypes = {
  custom: markRaw(CustomEdge),
}

// Local transient state
const clickTimer = ref<ReturnType<typeof setTimeout> | null>(null)

// =============================================================================
// Computed - Transform backend data to Vue Flow format
// =============================================================================

// Convert backend steps to Vue Flow nodes
const nodes = computed<Node<StepNodeData>[]>(() => {
  const steps = props.workflow.draft?.steps || []

  return steps.map(step => {
    const stepType = props.stepTypes.find(st => st.id === step.type_id)
    const stepExecution = props.stepExecutions.find(se => se.step_id === step.id)
    const isPinned = props.editorState?.pinned_outputs?.[step.id] !== undefined
    const isDisabled = props.editorState?.disabled_steps?.includes(step.id)
    const lockedBy = props.editorState?.step_locks?.[step.id]

    return {
      id: step.id,
      type: 'step',
      position: step.position,
      data: {
        id: step.id,
        type_id: step.type_id,
        name: step.name,
        config: step.config,
        notes: step.notes,
        icon: stepType?.icon,
        category: stepType?.category,
        step_kind: stepType?.step_kind,
        status: stepExecution?.status,
        stats: stepExecution ? {
          duration_us: stepExecution.duration_us,
        } : undefined,
        hasInput: stepType?.step_kind !== 'trigger',
        hasOutput: true,
        disabled: isDisabled,
        pinned: isPinned,
        locked_by: lockedBy,
      } satisfies StepNodeData,
    }
  })
})

// Convert backend connections to Vue Flow edges
const edges = computed<Edge<EdgeData>[]>(() => {
  const connections = props.workflow.draft?.connections || []

  return connections.map(conn => {
    const isAnimated = props.stepExecutions.some(
      se => se.step_id === conn.source_step_id && se.status === 'running'
    )

    return {
      id: conn.id,
      source: conn.source_step_id,
      target: conn.target_step_id,
      sourceHandle: conn.source_output,
      targetHandle: conn.target_input,
      type: 'custom',
      data: {
        animated: isAnimated,
      } satisfies EdgeData,
    }
  })
})

// Current selected node object
const selectedNode = computed<Node<StepNodeData> | null>(() => {
  if (!store.selectedNodeId) return null
  return nodes.value.find(n => n.id === store.selectedNodeId) || null
})

// Get step type for selected node
const selectedStepType = computed<StepType | null>(() => {
  if (!selectedNode.value) return null
  const typeId = selectedNode.value.data.type_id
  return props.stepTypes.find(st => st.id === typeId) ?? null
})

const selectedCount = computed(() => getSelectedNodes.value.length)
const tidyLabel = computed(() => selectedCount.value > 1 ? 'Tidy Up Selection' : 'Tidy Up Workflow')

// Context menu items based on target
const contextMenuItems = computed<MenuItem[]>(() => {
  const targetType = store.contextMenu.targetType
  const targetNodeId = store.contextMenu.targetNodeId

  if (targetType === 'node' && targetNodeId) {
    const node = nodes.value.find(n => n.id === targetNodeId)
    const isDisabled = node?.data?.disabled
    const isPinned = node?.data?.pinned

    return [
      { id: 'edit', label: 'Edit Step', icon: Cog6ToothIcon, shortcut: 'Enter' },
      { id: 'run-from', label: 'Run from Here', icon: PlayIcon },
      { id: 'divider-1', label: '', divider: true },
      { id: 'tidy-layout', label: tidyLabel.value, icon: ArrowPathIcon },
      { id: 'duplicate', label: 'Duplicate', icon: DocumentDuplicateIcon, shortcut: '⌘D' },
      { id: 'copy', label: 'Copy', icon: ClipboardDocumentIcon, shortcut: '⌘C' },
      { id: 'cut', label: 'Cut', icon: ScissorsIcon, shortcut: '⌘X' },
      { id: 'divider-2', label: '', divider: true },
      {
        id: 'toggle-disable',
        label: isDisabled ? 'Enable Step' : 'Disable Step',
        icon: EyeSlashIcon
      },
      {
        id: 'toggle-pin',
        label: isPinned ? 'Unpin Output' : 'Pin Output',
        icon: BookmarkIcon
      },
      { id: 'divider-3', label: '', divider: true },
      { id: 'delete', label: 'Delete', icon: TrashIcon, shortcut: '⌫', danger: true },
    ]
  }

  // Pane context menu
  return [
    { id: 'add-step', label: 'Add Step', icon: PlusIcon },
    { id: 'paste', label: 'Paste', icon: ClipboardDocumentIcon, shortcut: '⌘V', disabled: true },
    { id: 'divider-1', label: '', divider: true },
    { id: 'select-all', label: 'Select All', shortcut: '⌘A' },
    { id: 'tidy-layout', label: tidyLabel.value, icon: ArrowPathIcon },
    { id: 'fit-view', label: 'Fit to View', shortcut: '⌘1' },
  ]
})

// =============================================================================
// Validation Helpers
// =============================================================================

const isValidConnection = (connection: VueFlowConnection) => {
  // Source cannot be target
  if (connection.source === connection.target) return false

  // Basic cycle detection (cannot connect back to an ancestor)
  const currentEdges = getEdges.value

  const hasPath = (current: string, target: string, visited: Set<string> = new Set()): boolean => {
    if (current === target) return true
    if (visited.has(current)) return false
    visited.add(current)

    const outgoing = currentEdges.filter(e => e.source === current)
    for (const edge of outgoing) {
      if (hasPath(edge.target, target, visited)) return true
    }
    return false
  }

  // If there is already a path from target to source, adding this edge creates a cycle
  return !hasPath(connection.target, connection.source)
}

// =============================================================================
// Event Handlers
// =============================================================================

type LayoutNode = {
  id: string
  position: { x: number; y: number }
  targetPosition?: Position
  sourcePosition?: Position
}

const alignLayoutPositions = (originalNodes: LayoutNode[], layoutNodes: LayoutNode[]): LayoutNode[] => {
  if (!originalNodes.length || !layoutNodes.length) return layoutNodes

  const originalMin = originalNodes.reduce(
    (acc, node) => ({
      x: Math.min(acc.x, node.position.x),
      y: Math.min(acc.y, node.position.y),
    }),
    { x: Infinity, y: Infinity }
  )

  const layoutMin = layoutNodes.reduce(
    (acc, node) => ({
      x: Math.min(acc.x, node.position.x),
      y: Math.min(acc.y, node.position.y),
    }),
    { x: Infinity, y: Infinity }
  )

  const offset = {
    x: originalMin.x - layoutMin.x,
    y: originalMin.y - layoutMin.y,
  }

  return layoutNodes.map(node => ({
    ...node,
    position: {
      x: node.position.x + offset.x,
      y: node.position.y + offset.y,
    },
  }))
}

const applyLayoutPositions = (layoutNodes: LayoutNode[]) => {
  if (!layoutNodes.length) return

  layoutNodes.forEach(node => {
    updateNode(node.id, {
      position: node.position,
      targetPosition: node.targetPosition,
      sourcePosition: node.sourcePosition,
    })

    emit('move_step', {
      step_id: node.id,
      position: node.position,
    })
  })
}

const handleLayout = () => {
  const currentNodes = getNodes.value as unknown as LayoutNode[]
  if (!currentNodes.length) return

  const selectedNodes = getSelectedNodes.value as unknown as LayoutNode[]
  const nodesToLayout = selectedNodes.length > 1 ? selectedNodes : currentNodes
  const nodeIds = new Set(nodesToLayout.map(node => node.id))

  const edgesToLayout = getEdges.value.filter(
    edge => nodeIds.has(edge.source) && nodeIds.has(edge.target)
  )

  const layoutNodes = layout(
    nodesToLayout,
    edgesToLayout,
    previousDirection.value || 'LR'
  ) as LayoutNode[]

  const normalizedLayout = alignLayoutPositions(nodesToLayout, layoutNodes)

  applyLayoutPositions(normalizedLayout)
}

const handleNodeClick = (event: { node: Node<StepNodeData> }) => {
  const node = event.node

  if (clickTimer.value) {
    clearTimeout(clickTimer.value)
    clickTimer.value = null
  }

  clickTimer.value = setTimeout(() => {
    if (store.selectedNodeId === node.id) {
      store.isConfigModalOpen = true
    } else {
      store.selectNode(node.id)
    }
    clickTimer.value = null
  }, 250)
}

const handleNodeDoubleClick = (event: { node: Node<StepNodeData> }) => {
  if (clickTimer.value) {
    clearTimeout(clickTimer.value)
    clickTimer.value = null
  }
  store.openConfigModal(event.node.id)
}

type SelectionContextMenuEvent = {
  event: MouseEvent
  nodes: GraphNode<StepNodeData>[]
}

// The selection box sits above nodes, so map the click back to the node under the cursor
const findNodeUnderCursor = (event: MouseEvent, nodes: GraphNode<StepNodeData>[]) => {
  if (!vueFlowRef.value) return null

  const { left, top } = vueFlowRef.value.getBoundingClientRect()
  const point = project({
    x: event.clientX - left,
    y: event.clientY - top,
  })

  return nodes.find(node => {
    const width = node.dimensions.width
    const height = node.dimensions.height
    const position = node.computedPosition ?? node.position

    return (
      width > 0 &&
      height > 0 &&
      point.x >= position.x &&
      point.x <= position.x + width &&
      point.y >= position.y &&
      point.y <= position.y + height
    )
  }) ?? null
}

const handleNodeContextMenu = (event: { event: MouseEvent; node: Node<StepNodeData> }) => {
  event.event.preventDefault()
  event.event.stopPropagation()

  store.showContextMenu(event.event.clientX, event.event.clientY, 'node', event.node.id)
}

const handleSelectionContextMenu = ({ event, nodes }: SelectionContextMenuEvent) => {
  event.preventDefault()
  event.stopPropagation()

  const targetNode = findNodeUnderCursor(event, nodes) ?? nodes[0] ?? null

  store.showContextMenu(event.clientX, event.clientY, nodes.length ? 'node' : 'pane', targetNode?.id)
}

const handlePaneContextMenu = (event: MouseEvent) => {
  event.preventDefault()
  store.showContextMenu(event.clientX, event.clientY, 'pane')
}

const handleContextMenuSelect = (itemId: string) => {
  const nodeId = store.contextMenu.targetNodeId

  switch (itemId) {
    case 'edit':
      if (nodeId) {
        store.openConfigModal(nodeId)
      }
      break

    case 'delete':
      if (nodeId) {
        handleDeleteStep(nodeId)
      }
      break

    case 'duplicate':
      if (nodeId) {
        const node = nodes.value.find(n => n.id === nodeId)
        if (node) {
          emit('add_step', {
            type_id: node.data.type_id,
            position: { x: node.position.x + 50, y: node.position.y + 50 },
          })
        }
      }
      break

    case 'toggle-disable':
      if (nodeId) {
        const node = nodes.value.find(n => n.id === nodeId)
        if (node?.data.disabled) {
          emit('enable_step', { step_id: nodeId })
        } else {
          emit('disable_step', { step_id: nodeId, mode: 'skip' })
        }
      }
      break

    case 'toggle-pin':
      if (nodeId) {
        const node = nodes.value.find(n => n.id === nodeId)
        if (node?.data.pinned) {
          emit('unpin_output', { step_id: nodeId })
        } else {
          emit('pin_output', { step_id: nodeId })
        }
      }
      break

    case 'add-step':
      store.isLibraryOpen = true
      break

    case 'fit-view':
      // fitView()
      break

    case 'tidy-layout':
      handleLayout()
      break

    case 'run-from':
      console.log('Run from:', nodeId)
      break
  }

  store.hideContextMenu()
}

const closeContextMenu = () => {
  store.hideContextMenu()
}

const handleDragOver = (event: DragEvent) => {
  event.preventDefault()
  if (event.dataTransfer) {
    event.dataTransfer.dropEffect = 'move'
  }
}

const handleDrop = (event: DragEvent) => {
  const typeId = event.dataTransfer?.getData('application/vueflow')
  if (!typeId) return

  const { left, top } = vueFlowRef.value!.getBoundingClientRect()
  const position = project({
    x: event.clientX - left,
    y: event.clientY - top,
  })

  emit('add_step', {
    type_id: typeId,
    position,
  })
}

onPaneClick(() => {
  store.hideContextMenu()
})

onConnect((params: VueFlowConnection) => {
  // Validate connection
  if (!isValidConnection(params)) {
    console.warn('Invalid connection: cycles are not allowed.')
    return
  }

  // Emit to LiveView
  emit('add_connection', {
    source_step_id: params.source,
    target_step_id: params.target,
    source_output: params.sourceHandle ?? 'main',
    target_input: params.targetHandle ?? 'main',
  })
})

type EdgeUpdatePayload = {
  edge: Edge<EdgeData>
  connection: VueFlowConnection
}

const handleEdgeUpdate = ({ edge, connection }: EdgeUpdatePayload) => {
  if (!connection?.source || !connection?.target) return

  // Validate connection
  if (!isValidConnection(connection)) {
    console.warn('Invalid connection: cycles are not allowed.')
    return
  }

  const normalizedConnection = {
    ...connection,
    sourceHandle: connection.sourceHandle ?? edge.sourceHandle ?? 'main',
    targetHandle: connection.targetHandle ?? edge.targetHandle ?? 'main',
  }

  updateEdge(edge, normalizedConnection, false)

  emit('remove_connection', { connection_id: edge.id })
  emit('add_connection', {
    source_step_id: normalizedConnection.source,
    target_step_id: normalizedConnection.target,
    source_output: normalizedConnection.sourceHandle ?? null,
    target_input: normalizedConnection.targetHandle ?? null,
  })
}

onNodeDragStop((event: { nodes: Node<StepNodeData>[] }) => {
  for (const node of event.nodes) {
    emit('move_step', {
      step_id: node.id,
      position: node.position,
    })
  }
})

// =============================================================================
// Modal Handlers
// =============================================================================

const handleSaveConfig = (payload: {
  id: string
  name: string
  config: Record<string, unknown>
  notes?: string
}) => {
  emit('update_step', {
    step_id: payload.id,
    changes: {
      name: payload.name,
      config: payload.config,
      notes: payload.notes,
    },
  })
}

const handleDeleteStep = (stepId: string) => {
  emit('remove_step', { step_id: stepId })
}

// =============================================================================
// Toolbar & Panel Handlers
// =============================================================================

const handleSave = () => emit('save_workflow')
const handleRunTest = () => emit('run_test')
const handleCancelExecution = () => emit('cancel_execution')

const selectTraceStep = (stepId: string) => {
  store.selectNode(stepId)
}
</script>

<template>
  <div class="flex flex-col h-screen overflow-hidden bg-base-300 text-base-content font-sans">
    <!-- Top Toolbar -->
    <EditorToolbar :workflow-name="workflow?.name ?? 'Untitled Workflow'" :is-saving="false"
      :presences="presences" @save="handleSave" @run-test="handleRunTest" />

    <div class="flex-1 flex overflow-hidden relative">
      <!-- Left Sidebar: Node Library -->
      <NodeLibrary v-if="store.isLibraryOpen" :step-types="stepTypes" class="shrink-0" @collapse="store.isLibraryOpen = false" />

      <button v-else
        class="absolute left-0 top-1/2 -translate-y-1/2 btn btn-xs btn-circle bg-base-200 border-base-300 z-50 ml-1"
        @click="store.isLibraryOpen = true">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 rotate-90" fill="none" viewBox="0 0 24 24"
          stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <!-- Main Canvas Area -->
      <div class="flex-1 flex flex-col min-w-0 relative">
        <div class="flex-1 overflow-hidden relative">
          <VueFlow :nodes="nodes" :edges="edges" :node-types="nodeTypes" :edge-types="edgeTypes"
            :nodes-connectable="true" :nodes-draggable="true" :edges-updatable="true"
            :default-viewport="{ zoom: 1.2, x: 100, y: 50 }"
            fit-view-on-init @node-click="handleNodeClick" @node-double-click="handleNodeDoubleClick"
            @node-context-menu="handleNodeContextMenu"
            @selection-context-menu="handleSelectionContextMenu" @pane-context-menu="handlePaneContextMenu"
            @edge-update="handleEdgeUpdate" @dragover="handleDragOver" @drop="handleDrop">
            <Background :pattern-color="oklchToHex('oklch(50% 0.05 260)')" :gap="24" />
            <Controls position="bottom-right" />
            <MiniMap position="bottom-left" />
          </VueFlow>
        </div>

        <!-- Bottom Panel: Execution Trace -->
        <ExecutionTracePanel :execution="execution" :step-executions="stepExecutions"
          :is-expanded="store.isTracePanelExpanded" @toggle="store.toggleTracePanel" @close="store.isTracePanelExpanded = false"
          @select-step="selectTraceStep" @run-test="handleRunTest" @cancel="handleCancelExecution" />
      </div>

      <!-- Step Configuration Modal -->
      <StepConfigModal :is-open="store.isConfigModalOpen" :node="selectedNode" :step-type="selectedStepType"
        @close="store.closeConfigModal" @save="handleSaveConfig" @delete="handleDeleteStep" />

      <!-- Context Menu -->
      <ContextMenu :show="store.contextMenu.show" :x="store.contextMenu.x" :y="store.contextMenu.y" :items="contextMenuItems"
        @select="handleContextMenuSelect" @close="closeContextMenu" />
    </div>
  </div>
</template>

<style>
/* Vue Flow control overrides */
.vue-flow__panel {
  margin: 15px;
}

.vue-flow__controls {
  display: flex;
  flex-direction: row !important;
  gap: 2px;
  background-color: var(--color-base-100);
  border: 1px solid var(--color-base-300);
  padding: 3px;
  border-radius: 10px;
  box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
}

.vue-flow__controls-button {
  background-color: var(--color-base-200);
  color: var(--color-base-content);
  border: none !important;
  border-radius: 6px !important;
  width: 20px !important;
  height: 20px !important;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: all 0.15s ease-in-out;
  cursor: pointer;
}

.vue-flow__controls-button:hover {
  background-color: var(--color-base-300);
  transform: scale(1.05);
}

.vue-flow__controls-button svg {
  width: 12px !important;
  height: 12px !important;
  stroke-width: 2.5 !important;
}

.vue-flow__minimap {
  border-radius: 12px;
  background-color: var(--color-base-100);
  border: 1px solid var(--color-base-300);
  box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1);
}

.vue-flow__minimap-mask {
  fill: var(--color-base-300);
  fill-opacity: 0.5;
}
</style>
