<script setup lang="ts">
import { ref, computed, onMounted, markRaw, watch, nextTick } from 'vue';
import type {
  Node,
  Edge,
  NodeChange,
  EdgeChange,
  NodeMouseEvent,
  Connection as VueFlowConnection,
  XYPosition,
  Position,
  GraphNode,
} from '@vue-flow/core';
import { VueFlow, useVueFlow } from '@vue-flow/core';
import { Background } from '@vue-flow/background';
import { Controls } from '@vue-flow/controls';
import { MiniMap } from '@vue-flow/minimap';
import { useThrottleFn } from '@vueuse/core';

import NodeLibrary from './components/flow/NodeLibrary.vue';
import StepConfigModal from './components/flow/StepConfigModal.vue';
import EditorToolbar from './components/flow/EditorToolbar.vue';
import ExecutionTracePanel from './components/flow/ExecutionTracePanel.vue';
import WorkflowStepNode from './components/flow/Node.vue';
import CustomEdge from './components/flow/Edge.vue';
import ContextMenu from './components/ui/ContextMenu.vue';
import CollaborativeCursors from './components/flow/CollaborativeCursors.vue';
import type { MenuItem } from './components/ui/ContextMenu.vue';

import { useWorkflowEdges } from './composables/useWorkflowEdges';
import { useWorkflowGraph } from './composables/useWorkflowGraph';
import { useWorkflowNodes } from './composables/useWorkflowNodes';
import {
  CURSOR_THROTTLE_MS,
  DEFAULT_NODE_DIMENSIONS,
  DEFAULT_VIEWPORT,
  DOUBLE_CLICK_DELAY_MS,
  EDGE_LABEL_GAP,
  EDGE_LABEL_HALF_HEIGHT,
  EDGE_LABEL_HALF_WIDTH,
  EDGE_LABEL_POSITION,
} from './constants/layout';
import { useClientStore } from './store/clientStore';
import { oklchToHex } from './lib/color';
import { useLayout } from './lib/useLayout';

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
} from '@heroicons/vue/24/outline';
import type {
  Workflow,
  Step,
  StepType,
  NodeLibraryItem,
  StepNodeData,
  EdgeData,
  Execution,
  StepExecution,
  EditorState,
  UserPresence,
} from './types/workflow';

// =============================================================================
// Props - Data from LiveView via LiveVue
// =============================================================================

interface Props {
  workflow: Workflow;
  stepTypes?: StepType[];
  nodeLibraryItems?: NodeLibraryItem[];
  execution?: Execution | null;
  stepExecutions?: StepExecution[];
  editorState?: EditorState;
  presences?: UserPresence[];
  currentUserId?: string;
  expressionPreviews?: Record<string, unknown>;
}

const props = withDefaults(defineProps<Props>(), {
  stepTypes: () => [],
  nodeLibraryItems: () => [],
  execution: null,
  stepExecutions: () => [],
  editorState: undefined,
  presences: () => [],
  currentUserId: undefined,
  expressionPreviews: () => ({}),
});

// =============================================================================
// Emits - Events to LiveView via LiveVue
// =============================================================================

const emit = defineEmits<{
  (e: 'add_step', payload: { type_id: string; position: { x: number; y: number } }): void;
  (e: 'update_step', payload: { step_id: string; changes: Partial<Step> }): void;
  (e: 'remove_step', payload: { step_id: string }): void;
  (e: 'move_step', payload: { step_id: string; position: { x: number; y: number } }): void;
  (
    e: 'add_connection',
    payload: {
      source_step_id: string;
      target_step_id: string;
      source_output?: string;
      target_input?: string;
    }
  ): void;
  (e: 'remove_connection', payload: { connection_id: string }): void;
  (e: 'pin_output', payload: { step_id: string }): void;
  (e: 'unpin_output', payload: { step_id: string }): void;
  (e: 'disable_step', payload: { step_id: string; mode: 'skip' | 'exclude' }): void;
  (e: 'enable_step', payload: { step_id: string }): void;
  (e: 'run_test', payload?: { step_ids?: string[] }): void;
  (e: 'cancel_execution'): void;
  (e: 'save_workflow'): void;
  (e: 'publish_workflow', payload: { version_tag: string; changelog?: string }): void;
  // Collaboration events
  (
    e: 'mouse_move',
    payload: { x: number; y: number; dragging_steps?: Record<string, XYPosition> | null }
  ): void;
  (e: 'selection_changed', payload: { step_ids: string[] }): void;
  (
    e: 'preview_expression',
    payload: { step_id: string; field_key: string; expression: string }
  ): void;
  (
    e: 'toggle_webhook_test',
    payload: { step_id: string; action: 'start' | 'stop'; path?: string; method?: string }
  ): void;
}>();

// =============================================================================
// State Management
// =============================================================================

const store = useClientStore();

const {
  onPaneClick,
  onConnect,
  onNodesChange,
  onEdgesChange,
  onNodeDragStop,
  onNodeDrag,
  project,
  getNodes,
  getEdges,
  getSelectedNodes,
  updateNode,
  updateEdge,
  applyNodeChanges,
  applyEdgeChanges,
  removeNodes,
  setNodes,
  setEdges,
  viewport,
} = useVueFlow();

const vueFlowRef = ref<InstanceType<typeof VueFlow> | null>(null);

const isMounted = ref(false);
const isSyncingDraft = ref(false);
const pendingNodeRemovalIds = new Set<string>();
const pendingEdgeRemovalIds = new Set<string>();
const isUpdatingSelection = ref(false);
onMounted(() => {
  isMounted.value = true;
  syncDraftState();
});

const { layout, previousDirection } = useLayout();

const { nodes } = useWorkflowNodes({
  workflow: () => props.workflow,
  stepTypes: () => props.stepTypes,
  stepExecutions: () => props.stepExecutions,
  editorState: () => props.editorState,
  presences: () => props.presences,
  currentUserId: () => props.currentUserId,
});

const { edges } = useWorkflowEdges({
  workflow: () => props.workflow,
  stepExecutions: () => props.stepExecutions,
});

const { stepNameById, upstreamStepIdsByStepId } = useWorkflowGraph(() => props.workflow);

const nodeTypes = {
  step: markRaw(WorkflowStepNode),
};

const edgeTypes = {
  custom: markRaw(CustomEdge),
};

const clickTimer = ref<ReturnType<typeof setTimeout> | null>(null);
const canvasRef = ref<HTMLElement | null>(null);

// Consolidated interaction tracking (mouse + transient dragging)
const emitInteraction = useThrottleFn(
  (x: number, y: number, dragging_steps?: Record<string, XYPosition> | null) => {
    emit('mouse_move', { x, y, dragging_steps });
  },
  CURSOR_THROTTLE_MS
);

const getFlowPositionFromEvent = (point: { clientX: number; clientY: number }) => {
  if (!canvasRef.value) return null;

  const { left, top } = canvasRef.value.getBoundingClientRect();
  return project({
    x: point.clientX - left,
    y: point.clientY - top,
  });
};

const handlePaneMouseMove = (event: MouseEvent) => {
  const flowPosition = getFlowPositionFromEvent(event);
  if (!flowPosition) return;

  // If we're dragging, onNodeDrag handles the emission
  // Otherwise, we emit just the cursor position
  if (!getSelectedNodes.value.some(n => n.dragging)) {
    emitInteraction(flowPosition.x, flowPosition.y);
  }
};

// Track transient node positions during drag
const handleNodeDrag = (event: {
  event: MouseEvent | TouchEvent;
  node: Node<StepNodeData>;
  nodes: Node<StepNodeData>[];
}) => {
  // Get mouse position from drag event
  const mouseEvent = 'clientX' in event.event ? event.event : event.event.touches[0];
  const flowPosition = getFlowPositionFromEvent(mouseEvent);
  if (!flowPosition) return;

  const dragging_steps: Record<string, XYPosition> = {};
  event.nodes.forEach(node => {
    dragging_steps[node.id] = node.position;
  });

  emitInteraction(flowPosition.x, flowPosition.y, dragging_steps);
};

onNodeDrag(handleNodeDrag);

// =============================================================================
// Collaboration: Selection Tracking
// =============================================================================

// Track selection changes and emit to server
const handleSelectionChange = ({ nodes }: { nodes: Node<StepNodeData>[] }) => {
  const selectedIds = nodes.map(n => n.id);
  // Update local store selection to match VueFlow's selection
  isUpdatingSelection.value = true;
  store.selectNode(selectedIds.length === 1 ? selectedIds[0] : null);
  isUpdatingSelection.value = false;
  emit('selection_changed', { step_ids: selectedIds });
};

// Also watch for programmatic selection changes
watch(
  () => getSelectedNodes.value,
  newSelection => {
    const selectedIds = newSelection.map(n => n.id);
    emit('selection_changed', { step_ids: selectedIds });
  },
  { deep: true }
);

// Watch for store selection changes and sync to Vue Flow
watch(
  () => store.selectedNodeId,
  newSelectedId => {
    if (isUpdatingSelection.value) {
      return; // Avoid infinite loop
    }

    const nodes = getNodes.value.map(node => ({
      ...node,
      selected: node.id === newSelectedId,
    }));
    setNodes(nodes);
  }
);

const syncDraftState = async () => {
  if (!isMounted.value) return;
  isSyncingDraft.value = true;
  setNodes(nodes.value);
  setEdges(edges.value);
  await nextTick();
  pendingNodeRemovalIds.clear();
  pendingEdgeRemovalIds.clear();
  isSyncingDraft.value = false;
};

watch(
  () => [props.workflow.draft?.steps, props.workflow.draft?.connections],
  () => {
    syncDraftState();
  },
  { deep: true }
);

onNodesChange((changes: NodeChange[]) => {
  if (isSyncingDraft.value) return;

  const nextChanges: NodeChange[] = [];

  for (const change of changes) {
    if (change.type === 'remove') {
      if (!pendingNodeRemovalIds.has(change.id)) {
        pendingNodeRemovalIds.add(change.id);
        emit('remove_step', { step_id: change.id });
      }
    }

    nextChanges.push(change);
  }

  const nextNodes = applyNodeChanges(nextChanges);
  setNodes(nextNodes);
});

onEdgesChange((changes: EdgeChange[]) => {
  if (isSyncingDraft.value) return;

  const nextChanges: EdgeChange[] = [];

  for (const change of changes) {
    if (change.type === 'remove') {
      if (!pendingEdgeRemovalIds.has(change.id)) {
        pendingEdgeRemovalIds.add(change.id);
        const connectionId = resolveConnectionId(change);
        if (connectionId) {
          emit('remove_connection', { connection_id: connectionId });
        }
      }
    }

    nextChanges.push(change);
  }

  const nextEdges = applyEdgeChanges(nextChanges);
  setEdges(nextEdges);
});

// =============================================================================
// Derived state
// =============================================================================

const selectedNode = computed<Node<StepNodeData> | null>(() => {
  if (!store.selectedNodeId) return null;
  return nodes.value.find(n => n.id === store.selectedNodeId) || null;
});

const selectedStepType = computed<StepType | null>(() => {
  if (!selectedNode.value) return null;
  const typeId = selectedNode.value.data?.type_id;
  return props.stepTypes.find(st => st.id === typeId) ?? null;
});

const selectedCount = computed(() => getSelectedNodes.value.length);
const tidyLabel = computed(() =>
  selectedCount.value > 1 ? 'Tidy Up Selection' : 'Tidy Up Workflow'
);

const isExecutionFailed = computed(() => props.execution?.status === 'failed');

const isExecutionRunning = computed(() => {
  const status = props.execution?.status;
  return status === 'running' || status === 'pending';
});

// Filter out current user from presences for cursor display
const otherUserPresences = computed(() => {
  return props.presences.filter(p => p.user.id !== props.currentUserId);
});

const contextMenuItems = computed<MenuItem[]>(() => {
  const targetType = store.contextMenu.targetType;
  const targetNodeId = store.contextMenu.targetNodeId;

  if (targetType === 'node' && targetNodeId) {
    const node = nodes.value.find(n => n.id === targetNodeId);
    const isDisabled = node?.data?.disabled;
    const isPinned = node?.data?.pinned;

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
        icon: EyeSlashIcon,
      },
      { id: 'toggle-pin', label: isPinned ? 'Unpin Output' : 'Pin Output', icon: BookmarkIcon },
      { id: 'divider-3', label: '', divider: true },
      { id: 'delete', label: 'Delete', icon: TrashIcon, shortcut: '⌫', danger: true },
    ];
  }

  return [
    { id: 'add-step', label: 'Add Step', icon: PlusIcon },
    { id: 'paste', label: 'Paste', icon: ClipboardDocumentIcon, shortcut: '⌘V', disabled: true },
    { id: 'divider-1', label: '', divider: true },
    { id: 'select-all', label: 'Select All', shortcut: '⌘A' },
    { id: 'tidy-layout', label: tidyLabel.value, icon: ArrowPathIcon },
    { id: 'fit-view', label: 'Fit to View', shortcut: '⌘1' },
  ];
});

// =============================================================================
// Validation & Event Handlers (unchanged from original)
// =============================================================================

const isValidConnection = (connection: VueFlowConnection) => {
  if (connection.source === connection.target) return false;
  const currentEdges = getEdges.value;

  const hasPath = (current: string, target: string, visited: Set<string> = new Set()): boolean => {
    if (current === target) return true;
    if (visited.has(current)) return false;
    visited.add(current);
    const outgoing = currentEdges.filter(e => e.source === current);
    for (const edge of outgoing) {
      if (hasPath(edge.target, target, visited)) return true;
    }
    return false;
  };

  return !hasPath(connection.target, connection.source);
};

type LayoutNode = {
  id: string;
  position: { x: number; y: number };
  targetPosition?: Position;
  sourcePosition?: Position;
  dimensions?: { width: number; height: number };
  data?: StepNodeData;
};

type LayoutBounds = { minX: number; minY: number; maxX: number; maxY: number };
type LayoutDirection = 'LR' | 'RL';

const getNodeDimensions = (node: LayoutNode) => ({
  width: node.dimensions?.width || DEFAULT_NODE_DIMENSIONS.width,
  height: node.dimensions?.height || DEFAULT_NODE_DIMENSIONS.height,
});

const hasEdgeLabel = (node?: LayoutNode) => {
  const count = node?.data?.stats?.out;
  return !(count === undefined || count === null || count === 0);
};

const updateBounds = (bounds: LayoutBounds, x: number, y: number) => {
  bounds.minX = Math.min(bounds.minX, x);
  bounds.minY = Math.min(bounds.minY, y);
  bounds.maxX = Math.max(bounds.maxX, x);
  bounds.maxY = Math.max(bounds.maxY, y);
};

const getLayoutBounds = (nodes: LayoutNode[], edges: Edge<EdgeData>[]): LayoutBounds => {
  const bounds: LayoutBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
  const nodeLookup = new Map(nodes.map(node => [node.id, node]));

  nodes.forEach(node => {
    const { width, height } = getNodeDimensions(node);
    updateBounds(bounds, node.position.x, node.position.y);
    updateBounds(bounds, node.position.x + width, node.position.y + height);
  });

  edges.forEach(edge => {
    const source = nodeLookup.get(edge.source);
    const target = nodeLookup.get(edge.target);
    if (!source || !target || !hasEdgeLabel(source)) return;

    const sourceSize = getNodeDimensions(source);
    const targetSize = getNodeDimensions(target);
    const sourceX = source.position.x + sourceSize.width;
    const sourceY = source.position.y + sourceSize.height / 2;
    const targetX = target.position.x;
    const targetY = target.position.y + targetSize.height / 2;

    const labelX = sourceX + (targetX - sourceX) * EDGE_LABEL_POSITION;
    const labelY = sourceY + (targetY - sourceY) * EDGE_LABEL_POSITION;

    updateBounds(bounds, labelX - EDGE_LABEL_HALF_WIDTH, labelY - EDGE_LABEL_HALF_HEIGHT);
    updateBounds(bounds, labelX + EDGE_LABEL_HALF_WIDTH, labelY + EDGE_LABEL_HALF_HEIGHT);
  });

  return bounds;
};

const alignLayoutPositions = (
  originalNodes: LayoutNode[],
  layoutNodes: LayoutNode[],
  edges: Edge<EdgeData>[],
  direction: LayoutDirection
): LayoutNode[] => {
  if (!originalNodes.length || !layoutNodes.length) return layoutNodes;

  const originalBounds = getLayoutBounds(originalNodes, edges);
  const layoutBounds = getLayoutBounds(layoutNodes, edges);
  const offset = {
    x: originalBounds.minX - layoutBounds.minX,
    y: originalBounds.minY - layoutBounds.minY,
  };

  if (direction === 'LR') {
    offset.x = originalBounds.maxX - layoutBounds.maxX;
  }

  return layoutNodes.map(node => ({
    ...node,
    position: { x: node.position.x + offset.x, y: node.position.y + offset.y },
  }));
};

const applyLayoutPositions = (layoutNodes: LayoutNode[]) => {
  if (!layoutNodes.length) return;
  layoutNodes.forEach(node => {
    updateNode(node.id, {
      position: node.position,
      targetPosition: node.targetPosition,
      sourcePosition: node.sourcePosition,
    });
    emit('move_step', { step_id: node.id, position: node.position });
  });
};

const handleLayout = () => {
  const currentNodes = getNodes.value as unknown as LayoutNode[];
  if (!currentNodes.length) return;

  const selectedNodes = getSelectedNodes.value as unknown as LayoutNode[];
  const nodesToLayout = selectedNodes.length > 1 ? selectedNodes : currentNodes;
  const nodeIds = new Set(nodesToLayout.map(node => node.id));

  const edgesToLayout = getEdges.value.filter(
    edge => nodeIds.has(edge.source) && nodeIds.has(edge.target)
  );

  const layoutDirection = (previousDirection.value === 'RL' ? 'RL' : 'LR') as LayoutDirection;
  const nodeLookup = new Map(nodesToLayout.map(node => [node.id, node]));
  const hasEdgeLabels = edgesToLayout.some(edge => hasEdgeLabel(nodeLookup.get(edge.source)));
  const layoutNodes = layout(nodesToLayout, edgesToLayout, layoutDirection, {
    ranksep: hasEdgeLabels ? EDGE_LABEL_GAP : undefined,
  }) as LayoutNode[];
  const normalizedLayout = alignLayoutPositions(
    nodesToLayout,
    layoutNodes,
    edgesToLayout,
    layoutDirection
  );
  applyLayoutPositions(normalizedLayout);
};

const handleNodeClick = (event: { node: Node<StepNodeData> }) => {
  const node = event.node;

  if (clickTimer.value) {
    clearTimeout(clickTimer.value);
    clickTimer.value = null;
  }

  clickTimer.value = setTimeout(() => {
    store.selectNode(node.id);
    clickTimer.value = null;
  }, DOUBLE_CLICK_DELAY_MS);
};

const handleNodeDoubleClick = (event: { node: Node<StepNodeData> }) => {
  if (clickTimer.value) {
    clearTimeout(clickTimer.value);
    clickTimer.value = null;
  }
  store.openConfigModal(event.node.id);
};

type SelectionContextMenuEvent = { event: MouseEvent; nodes: GraphNode<StepNodeData>[] };

const findNodeUnderCursor = (event: MouseEvent, nodes: GraphNode<StepNodeData>[]) => {
  const flowElement = (vueFlowRef.value?.$el as HTMLElement | undefined) ?? canvasRef.value;
  if (!flowElement) return null;
  const { left, top } = flowElement.getBoundingClientRect();
  const point = project({ x: event.clientX - left, y: event.clientY - top });

  return (
    nodes.find(node => {
      const width = node.dimensions.width;
      const height = node.dimensions.height;
      const position = node.computedPosition ?? node.position;
      return (
        width > 0 &&
        height > 0 &&
        point.x >= position.x &&
        point.x <= position.x + width &&
        point.y >= position.y &&
        point.y <= position.y + height
      );
    }) ?? null
  );
};

const handleNodeContextMenu = (event: NodeMouseEvent) => {
  event.event.preventDefault();
  event.event.stopPropagation();
  const mouseEvent = event.event as MouseEvent;
  store.showContextMenu(mouseEvent.clientX, mouseEvent.clientY, 'node', event.node.id);
};

const handleSelectionContextMenu = ({ event, nodes }: SelectionContextMenuEvent) => {
  event.preventDefault();
  event.stopPropagation();
  const targetNode = findNodeUnderCursor(event, nodes) ?? nodes[0] ?? null;
  store.showContextMenu(
    event.clientX,
    event.clientY,
    nodes.length ? 'node' : 'pane',
    targetNode?.id
  );
};

const handlePaneContextMenu = (event: MouseEvent) => {
  event.preventDefault();
  store.showContextMenu(event.clientX, event.clientY, 'pane');
};

const handleContextMenuSelect = (itemId: string) => {
  const nodeId = store.contextMenu.targetNodeId;

  switch (itemId) {
    case 'edit':
      if (nodeId) store.openConfigModal(nodeId);
      break;
    case 'delete':
      if (nodeId) requestNodeRemoval(nodeId);
      break;
    case 'duplicate':
      if (nodeId) {
        const node = nodes.value.find(n => n.id === nodeId);
        if (node && node.data?.type_id) {
          emit('add_step', {
            type_id: node.data.type_id,
            position: { x: node.position.x + 50, y: node.position.y + 50 },
          });
        }
      }
      break;
    case 'toggle-disable':
      if (nodeId) {
        const node = nodes.value.find(n => n.id === nodeId);
        if (node?.data?.disabled) {
          emit('enable_step', { step_id: nodeId });
        } else {
          emit('disable_step', { step_id: nodeId, mode: 'skip' });
        }
      }
      break;
    case 'toggle-pin':
      if (nodeId) {
        const node = nodes.value.find(n => n.id === nodeId);
        if (node?.data?.pinned) {
          emit('unpin_output', { step_id: nodeId });
        } else {
          emit('pin_output', { step_id: nodeId });
        }
      }
      break;
    case 'add-step':
      store.isLibraryOpen = true;
      break;
    case 'tidy-layout':
      handleLayout();
      break;
    case 'run-from':
      break;
  }

  store.hideContextMenu();
};

const closeContextMenu = () => store.hideContextMenu();

const handleDragOver = (event: DragEvent) => {
  event.preventDefault();
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
};

const handleDrop = (event: DragEvent) => {
  const typeId = event.dataTransfer?.getData('application/vueflow');
  if (!typeId) return;

  const position = getFlowPositionFromEvent(event);
  if (position) {
    emit('add_step', { type_id: typeId, position });
  }
};

onPaneClick(() => store.hideContextMenu());

onConnect((params: VueFlowConnection) => {
  if (!isValidConnection(params)) {
    console.warn('Invalid connection: cycles are not allowed.');
    return;
  }
  emit('add_connection', {
    source_step_id: params.source,
    target_step_id: params.target,
    source_output: params.sourceHandle ?? 'main',
    target_input: params.targetHandle ?? 'main',
  });
});

type EdgeUpdatePayload = { edge: Edge<EdgeData>; connection: VueFlowConnection };

const handleEdgeUpdate = ({ edge, connection }: EdgeUpdatePayload) => {
  if (!connection?.source || !connection?.target) return;
  if (!isValidConnection(connection)) {
    console.warn('Invalid connection: cycles are not allowed.');
    return;
  }

  const normalizedConnection = {
    ...connection,
    sourceHandle: connection.sourceHandle ?? edge.sourceHandle ?? 'main',
    targetHandle: connection.targetHandle ?? edge.targetHandle ?? 'main',
  };

  // TODO: is this efficient?
  const resolvedEdge = getEdges.value.find(e => e.id === edge.id);
  if (!resolvedEdge) {
    console.warn('Could not find resolved edge for update');
    return;
  }

  updateEdge(resolvedEdge, normalizedConnection, false);
  const connectionId = resolveConnectionId(edge);
  if (connectionId) {
    emit('remove_connection', { connection_id: connectionId });
  }
  emit('add_connection', {
    source_step_id: normalizedConnection.source,
    target_step_id: normalizedConnection.target,
    source_output: normalizedConnection.sourceHandle ?? null,
    target_input: normalizedConnection.targetHandle ?? null,
  });
};

onNodeDragStop((event: { nodes: Node<StepNodeData>[] }) => {
  // Clear transient drag positions and emit final positions for persistence
  // We can just emit null for dragging_steps to clear it.
  // For now, we use 0,0 for the cursor as it will be updated by the next mousemove anyway.
  emitInteraction(0, 0, null);

  for (const node of event.nodes) {
    emit('move_step', { step_id: node.id, position: node.position });
  }
});

const handleSaveConfig = (payload: {
  id: string;
  name: string;
  config: Record<string, unknown>;
  notes?: string;
}) => {
  emit('update_step', {
    step_id: payload.id,
    changes: { name: payload.name, config: payload.config, notes: payload.notes },
  });
};

const handleDeleteStep = (stepId: string) => requestNodeRemoval(stepId);

const handleSave = () => emit('save_workflow');
const handleRunTest = () => emit('run_test');
const handleCancelExecution = () => emit('cancel_execution');
const handlePreviewExpression = (payload: {
  step_id: string;
  field_key: string;
  expression: string;
}) => emit('preview_expression', payload);
const handleToggleWebhookTest = (payload: {
  step_id: string;
  action: 'start' | 'stop';
  path?: string;
  method?: string;
}) => emit('toggle_webhook_test', payload);
const selectTraceStep = (stepId: string) => {
  store.selectNode(stepId);
};

type ConnectionLookupEdge = {
  id: string;
  source: string;
  target: string;
  sourceHandle?: string | null;
  targetHandle?: string | null;
};

const resolveConnectionId = (edge: ConnectionLookupEdge) => {
  const connections = props.workflow.draft?.connections || [];
  const directMatch = connections.find(conn => conn.id === edge.id);
  if (directMatch) return directMatch.id;

  const sourceHandle = edge.sourceHandle ?? 'main';
  const targetHandle = edge.targetHandle ?? 'main';

  const endpointMatch = connections.find(
    conn =>
      conn.source_step_id === edge.source &&
      conn.target_step_id === edge.target &&
      conn.source_output === sourceHandle &&
      conn.target_input === targetHandle
  );

  if (!endpointMatch) {
    console.warn('No matching connection found for edge deletion', edge);
    return null;
  }

  return endpointMatch.id;
};

const requestNodeRemoval = (nodeId: string) => {
  removeNodes(nodeId, true);
};
</script>

<template>
  <div class="bg-base-300 text-base-content flex h-screen flex-col overflow-hidden font-sans">
    <EditorToolbar
      :workflow-name="workflow?.name ?? 'Untitled Workflow'"
      :is-saving="false"
      :presences="presences"
      @save="handleSave"
      @run-test="handleRunTest"
    />

    <div class="relative flex flex-1 overflow-hidden">
      <NodeLibrary
        v-if="store.isLibraryOpen"
        :library-items="nodeLibraryItems"
        class="shrink-0"
        @collapse="store.isLibraryOpen = false"
      />

      <button
        v-else
        class="btn btn-xs btn-circle bg-base-200 border-base-300 absolute top-1/2 left-0 z-50 ml-1 -translate-y-1/2"
        @click="store.isLibraryOpen = true"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4 rotate-90"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M19 9l-7 7-7-7"
          />
        </svg>
      </button>

      <div class="relative flex min-w-0 flex-1 flex-col">
        <div
          ref="canvasRef"
          class="relative flex-1 overflow-hidden"
          @mousemove="handlePaneMouseMove"
        >
          <VueFlow
            ref="vueFlowRef"
            :nodes="nodes"
            :edges="edges"
            :node-types="nodeTypes"
            :edge-types="edgeTypes"
            :nodes-connectable="true"
            :nodes-draggable="true"
            :edges-updatable="true"
            :apply-default="false"
            :default-viewport="DEFAULT_VIEWPORT"
            fit-view-on-init
            @node-click="handleNodeClick"
            @node-double-click="handleNodeDoubleClick"
            @node-context-menu="handleNodeContextMenu"
            @selection-change="handleSelectionChange"
            @selection-context-menu="handleSelectionContextMenu"
            @pane-context-menu="handlePaneContextMenu"
            @edge-update="handleEdgeUpdate"
            @dragover="handleDragOver"
            @drop="handleDrop"
          >
            <Background :pattern-color="oklchToHex('oklch(50% 0.05 260)')" :gap="24" />
            <Controls position="bottom-right" />
            <MiniMap position="bottom-left" />
          </VueFlow>

          <!-- Execution Failure Overlay -->
          <div
            v-if="isExecutionFailed"
            class="pointer-events-none absolute inset-0 z-40 opacity-100 transition-opacity duration-1000 ease-out"
            style="
              background: radial-gradient(
                ellipse at center,
                transparent 70%,
                rgba(239, 68, 68, 0.04) 90%,
                rgba(239, 68, 68, 0.06) 100%
              );
            "
          ></div>

          <!-- Collaborative Cursors - rendered in overlay with viewport transform -->
          <!-- We move it back to manual sync because direct nesting in VueFlow slots can break in LiveVue SSR -->
          <div
            v-if="isMounted"
            class="pointer-events-none absolute inset-0 z-[1000]"
            :style="{
              transform: `translate(${viewport.x}px, ${viewport.y}px) scale(${viewport.zoom})`,
              transformOrigin: '0 0',
            }"
          >
            <CollaborativeCursors
              :presences="otherUserPresences"
              :current-user-id="currentUserId"
              :zoom="viewport.zoom"
            />
          </div>

          <div
            class="pointer-events-auto absolute bottom-16 left-1/2 z-[1100] -translate-x-1/2 transform transition-all duration-300 ease-in-out"
          >
            <button
              v-if="!isExecutionRunning"
              class="btn btn-primary shadow-primary/20 flex items-center gap-3 rounded-xl px-8 py-3 text-base font-semibold shadow-lg transition-all hover:scale-105 active:scale-95"
              @click="handleRunTest"
            >
              <PlayIcon class="h-6 w-6" />
              <span class="text-base font-semibold">Execute Workflow</span>
            </button>
            <button
              v-else
              class="btn btn-warning shadow-warning/20 flex items-center gap-3 rounded-xl px-8 py-3 text-base font-semibold shadow-lg transition-all hover:scale-105 active:scale-95"
              @click="handleCancelExecution"
            >
              <ArrowPathIcon class="h-6 w-6 animate-spin" />
              <span class="text-base font-semibold">Stop Execution</span>
            </button>
          </div>
        </div>

        <ExecutionTracePanel
          :execution="execution"
          :step-executions="stepExecutions"
          :step-name-by-id="stepNameById"
          :selected-step-id="store.selectedNodeId"
          :is-expanded="store.isTracePanelExpanded"
          @toggle="store.toggleTracePanel"
          @close="store.isTracePanelExpanded = false"
          @select-step="selectTraceStep"
          @run-test="handleRunTest"
          @cancel="handleCancelExecution"
        />
      </div>

      <StepConfigModal
        :is-open="store.isConfigModalOpen"
        :node="selectedNode"
        :step-type="selectedStepType"
        :execution="execution"
        :step-executions="stepExecutions"
        :expression-previews="expressionPreviews"
        :editor-state="editorState"
        :step-name-by-id="stepNameById"
        :upstream-step-ids="upstreamStepIdsByStepId"
        @close="store.closeConfigModal"
        @save="handleSaveConfig"
        @delete="handleDeleteStep"
        @preview_expression="handlePreviewExpression"
        @toggle_webhook_test="handleToggleWebhookTest"
      />

      <ContextMenu
        :show="store.contextMenu.show"
        :x="store.contextMenu.x"
        :y="store.contextMenu.y"
        :items="contextMenuItems"
        @select="handleContextMenuSelect"
        @close="closeContextMenu"
      />
    </div>
  </div>
</template>

<style>
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
  z-index: 1100;
}

.vue-flow__minimap-mask {
  fill: var(--color-base-300);
  fill-opacity: 0.5;
}
</style>
