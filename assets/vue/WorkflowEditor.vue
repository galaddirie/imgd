<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount, markRaw, watch, nextTick } from 'vue';
import { useLiveVue } from 'live_vue';
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
import GroupNode from './components/flow/GroupNode.vue';
import CustomEdge from './components/flow/Edge.vue';
import ContextMenu from './components/ui/ContextMenu.vue';
import CollaborativeCursors from './components/flow/CollaborativeCursors.vue';
import type { MenuItem } from './components/ui/ContextMenu.vue';

import { useWorkflowEdges } from './composables/useWorkflowEdges';
import { useWorkflowGraph } from './composables/useWorkflowGraph';
import { useWorkflowNodes } from './composables/useWorkflowNodes';
import {
  CURSOR_THROTTLE_MS,
  DEFAULT_GROUP_COLOR,
  DEFAULT_GROUP_DIMENSIONS,
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
  RectangleGroupIcon,
  FolderMinusIcon,
} from '@heroicons/vue/24/outline';
import type {
  Workflow,
  Step,
  StepType,
  NodeLibraryItem,
  StepNodeData,
  GroupNodeData,
  WorkflowNodeData,
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
  (
    e: 'add_step',
    payload: { type_id: string; position: { x: number; y: number }; group_id?: string | null }
  ): void;
  (
    e: 'add_group',
    payload: {
      name?: string;
      step_ids: string[];
      color?: string;
      position: { x: number; y: number; width: number; height: number };
      step_positions?: Record<string, XYPosition>;
    }
  ): void;
  (
    e: 'update_group',
    payload: {
      group_id: string;
      changes: {
        name?: string;
        position?: { x?: number; y?: number; width?: number; height?: number };
        collapsed?: boolean;
        output_step_id?: string;
        color?: string;
      };
    }
  ): void;
  (e: 'remove_group', payload: { group_id: string }): void;
  (
    e: 'set_group_membership',
    payload: {
      group_id?: string | null;
      step_ids: string[];
      step_positions?: Record<string, XYPosition>;
    }
  ): void;
  (
    e: 'duplicate_steps',
    payload: {
      step_ids: string[];
      position_by_step_id: Record<string, XYPosition>;
      group_id_by_step_id?: Record<string, string>;
    }
  ): void;
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
  (e: 'run_node', payload: { step_id: string }): void;
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
const live = useLiveVue();

const {
  onPaneClick,
  onConnect,
  onNodesChange,
  onEdgesChange,
  onNodeDragStart,
  onNodeDragStop,
  onNodeDrag,
  project,
  getNodes,
  getEdges,
  getSelectedNodes,
  updateNode,
  updateNodeData,
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
const pendingGroupRemovalIds = new Set<string>();
const pendingEdgeRemovalIds = new Set<string>();
const isUpdatingSelection = ref(false);
onMounted(() => {
  isMounted.value = true;
  syncDraftState();
  window.addEventListener('keydown', handleGlobalKeydown);
  live.handleEvent('duplicate_selection', payload => {
    if (!payload || typeof payload !== 'object') return;
    const data = payload as { step_ids?: string[] };
    if (!Array.isArray(data.step_ids) || data.step_ids.length === 0) return;
    pendingDuplicateSelection.value = data.step_ids;
    nextTick(() => {
      applyPendingDuplicateSelection();
    });
  });
});

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleGlobalKeydown);
});

const { layout, previousDirection } = useLayout();

const handleRunNode = (stepId: string) => emit('run_node', { step_id: stepId });
const handleMoveSteps = (stepPositions: Record<string, XYPosition>) => {
  Object.entries(stepPositions).forEach(([stepId, position]) => {
    emit('move_step', { step_id: stepId, position });
  });
};

const { nodes } = useWorkflowNodes({
  workflow: () => props.workflow,
  stepTypes: () => props.stepTypes,
  stepExecutions: () => props.stepExecutions,
  editorState: () => props.editorState,
  presences: () => props.presences,
  currentUserId: () => props.currentUserId,
  onRunNode: stepId => handleRunNode(stepId),
  onUpdateGroup: (groupId, changes) => emit('update_group', { group_id: groupId, changes }),
  onMoveSteps: handleMoveSteps,
  groupingPreview: () => groupingPreview.value,
});

const { edges } = useWorkflowEdges({
  workflow: () => props.workflow,
  stepExecutions: () => props.stepExecutions,
});

const { stepNameById, upstreamStepIdsByStepId } = useWorkflowGraph(() => props.workflow);

const nodeTypes = {
  step: markRaw(WorkflowStepNode),
  group: markRaw(GroupNode),
};

const edgeTypes = {
  custom: markRaw(CustomEdge as any),
};

const groupByStepId = computed(() => {
  const map = new Map<string, string>();
  for (const group of props.workflow.draft?.groups || []) {
    for (const stepId of group.step_ids || []) {
      map.set(stepId, group.id);
    }
  }
  return map;
});

const clickTimer = ref<ReturnType<typeof setTimeout> | null>(null);
const canvasRef = ref<HTMLElement | null>(null);
const DUPLICATE_OFFSET: XYPosition = { x: 50, y: 50 };
const GROUP_PADDING = 60;
const clipboard = ref<{ stepIds: string[] } | null>(null);
const clipboardPasteCount = ref(0);
const pendingDuplicateSelection = ref<string[] | null>(null);
type GroupingPreview = { groupId: string | null; stepIds: string[]; color: string | null };

const groupingPreview = ref<GroupingPreview>({ groupId: null, stepIds: [], color: null });
const lastGroupingPreview = ref<GroupingPreview>({ groupId: null, stepIds: [], color: null });
const ungroupDragStepIds = ref<string[] | null>(null);

// Consolidated interaction tracking (mouse + transient dragging)
const emitInteraction = useThrottleFn(
  (x: number, y: number, dragging_steps?: Record<string, XYPosition> | null) => {
    emit('mouse_move', { x, y, dragging_steps });
  },
  CURSOR_THROTTLE_MS
);

const isGroupNode = (
  node: GraphNode<WorkflowNodeData> | Node<WorkflowNodeData>
): node is GraphNode<GroupNodeData> => node.type === 'group';

const isStepNode = (
  node: GraphNode<WorkflowNodeData> | Node<WorkflowNodeData>
): node is GraphNode<StepNodeData> => node.type === 'step';

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
  } else {
    const draggingStepNodes = getNodes.value.filter(node => node.dragging).filter(isStepNode);
    updateGroupingPreview(draggingStepNodes, flowPosition, event.shiftKey);
  }
};

const getAbsoluteNodePosition = (node: GraphNode<WorkflowNodeData>) => {
  return node.computedPosition ?? node.position;
};

const hexToRgba = (hex: string, alpha: number) => {
  const normalized = hex.replace('#', '');
  const r = parseInt(normalized.slice(0, 2), 16);
  const g = parseInt(normalized.slice(2, 4), 16);
  const b = parseInt(normalized.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
};

const miniMapNodeColor = (node: GraphNode<WorkflowNodeData>) => {
  if (node.type === 'group') {
    const color = (node.data as GroupNodeData | undefined)?.color || DEFAULT_GROUP_COLOR;
    return hexToRgba(color, 0.45);
  }
  return 'color-mix(in oklch, var(--color-base-100) 72%, var(--color-base-content) 28%)';
};

type NodeRect = { x: number; y: number; width: number; height: number };

const parseNodeSize = (value: unknown) => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = parseFloat(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
};

const getNodeSize = (node: GraphNode<WorkflowNodeData>) => {
  if (node.dimensions.width > 0 && node.dimensions.height > 0) {
    return { width: node.dimensions.width, height: node.dimensions.height };
  }

  const style = typeof node.style === 'function' ? node.style(node) : node.style;
  const styleWidth = parseNodeSize(style?.width);
  const styleHeight = parseNodeSize(style?.height);
  if (styleWidth && styleHeight) {
    return { width: styleWidth, height: styleHeight };
  }

  return node.type === 'group' ? DEFAULT_GROUP_DIMENSIONS : DEFAULT_NODE_DIMENSIONS;
};

const getNodeRect = (node: GraphNode<WorkflowNodeData>): NodeRect => {
  const position = getAbsoluteNodePosition(node);
  const { width, height } = getNodeSize(node);
  return { x: position.x, y: position.y, width, height };
};

const getOverlapArea = (rectA: NodeRect, rectB: NodeRect) => {
  const xOverlap = Math.max(
    0,
    Math.min(rectA.x + rectA.width, rectB.x + rectB.width) - Math.max(rectA.x, rectB.x)
  );
  const yOverlap = Math.max(
    0,
    Math.min(rectA.y + rectA.height, rectB.y + rectB.height) - Math.max(rectA.y, rectB.y)
  );
  return xOverlap * yOverlap;
};

const findGroupAtPoint = (point: XYPosition) => {
  const groupNodes = getNodes.value.filter(isGroupNode);
  for (const node of [...groupNodes].reverse()) {
    const { width, height } = getNodeSize(node);
    const position = getAbsoluteNodePosition(node);
    if (
      width > 0 &&
      height > 0 &&
      point.x >= position.x &&
      point.x <= position.x + width &&
      point.y >= position.y &&
      point.y <= position.y + height
    ) {
      return node;
    }
  }
  return null;
};

const findGroupByIntersection = (draggedStepNodes: GraphNode<WorkflowNodeData>[]) => {
  if (draggedStepNodes.length === 0) return null;

  const groupNodes = getNodes.value.filter(isGroupNode);
  let bestGroup: GraphNode<GroupNodeData> | null = null;
  let bestOverlap = 0;

  groupNodes.forEach(groupNode => {
    const groupRect = getNodeRect(groupNode);
    draggedStepNodes.forEach(stepNode => {
      if (!isStepNode(stepNode)) return;
      const stepRect = getNodeRect(stepNode);
      const overlap = getOverlapArea(stepRect, groupRect);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestGroup = groupNode as GraphNode<GroupNodeData>;
      }
    });
  });

  return bestOverlap > 0 ? bestGroup : null;
};

const applyGroupingPreview = (nextPreview: GroupingPreview) => {
  const prevPreview = lastGroupingPreview.value;
  const prevStepIds = new Set(prevPreview.stepIds);
  const nextStepIds = new Set(nextPreview.stepIds);

  if (prevPreview.groupId && prevPreview.groupId !== nextPreview.groupId) {
    updateNodeData(prevPreview.groupId, { isGroupingTarget: false, groupingColor: undefined });
  }
  if (nextPreview.groupId) {
    updateNodeData(nextPreview.groupId, {
      isGroupingTarget: true,
      groupingColor: nextPreview.color ?? undefined,
    });
  }

  prevStepIds.forEach(stepId => {
    if (!nextStepIds.has(stepId)) {
      updateNodeData(stepId, { isGroupingCandidate: false, groupingColor: undefined });
    }
  });
  nextStepIds.forEach(stepId => {
    if (!prevStepIds.has(stepId) || prevPreview.color !== nextPreview.color) {
      updateNodeData(stepId, {
        isGroupingCandidate: true,
        groupingColor: nextPreview.color ?? undefined,
      });
    }
  });

  lastGroupingPreview.value = {
    groupId: nextPreview.groupId,
    stepIds: Array.from(nextStepIds),
    color: nextPreview.color,
  };
};

const clearGroupingPreview = () => {
  const nextPreview: GroupingPreview = { groupId: null, stepIds: [], color: null };
  groupingPreview.value = nextPreview;
  applyGroupingPreview(nextPreview);
};

const updateGroupingPreview = (
  draggedStepNodes: GraphNode<WorkflowNodeData>[],
  flowPosition: XYPosition | null,
  shiftKey: boolean
) => {
  if (shiftKey || draggedStepNodes.length === 0) {
    clearGroupingPreview();
    return;
  }

  const targetGroup =
    (flowPosition ? findGroupAtPoint(flowPosition) : null) ??
    findGroupByIntersection(draggedStepNodes);
  if (!targetGroup) {
    clearGroupingPreview();
    return;
  }

  const targetGroupId = targetGroup.id;
  const stepIdsToGroup = draggedStepNodes
    .filter(node => groupByStepId.value.get(node.id) !== targetGroupId)
    .map(node => node.id);

  if (stepIdsToGroup.length === 0) {
    clearGroupingPreview();
    return;
  }

  const groupColor = targetGroup.data?.color || DEFAULT_GROUP_COLOR;
  const nextPreview: GroupingPreview = {
    groupId: targetGroupId,
    stepIds: stepIdsToGroup,
    color: groupColor,
  };
  groupingPreview.value = nextPreview;
  applyGroupingPreview(nextPreview);
};

const buildGroupBounds = (groupNodes: GraphNode<WorkflowNodeData>[], padding = GROUP_PADDING) => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const node of groupNodes) {
    if (!isStepNode(node)) continue;
    const position = getAbsoluteNodePosition(node);
    const width = node.dimensions.width || DEFAULT_NODE_DIMENSIONS.width;
    const height = node.dimensions.height || DEFAULT_NODE_DIMENSIONS.height;

    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + width);
    maxY = Math.max(maxY, position.y + height);
  }

  if (!isFinite(minX) || !isFinite(minY)) return null;

  const paddedWidth = maxX - minX + padding * 2;
  const paddedHeight = maxY - minY + padding * 2;

  return {
    x: minX - padding,
    y: minY - padding,
    width: Math.max(paddedWidth, DEFAULT_GROUP_DIMENSIONS.width),
    height: Math.max(paddedHeight, DEFAULT_GROUP_DIMENSIONS.height),
  };
};

const buildGroupBoundsFromPositions = (
  groupNodes: GraphNode<WorkflowNodeData>[],
  positions: Map<string, XYPosition>,
  padding = GROUP_PADDING
) => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const node of groupNodes) {
    if (!isStepNode(node)) continue;
    const position = positions.get(node.id) ?? getAbsoluteNodePosition(node);
    const width = node.dimensions.width || DEFAULT_NODE_DIMENSIONS.width;
    const height = node.dimensions.height || DEFAULT_NODE_DIMENSIONS.height;

    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + width);
    maxY = Math.max(maxY, position.y + height);
  }

  if (!isFinite(minX) || !isFinite(minY)) return null;

  const paddedWidth = maxX - minX + padding * 2;
  const paddedHeight = maxY - minY + padding * 2;

  return {
    x: minX - padding,
    y: minY - padding,
    width: Math.max(paddedWidth, DEFAULT_GROUP_DIMENSIONS.width),
    height: Math.max(paddedHeight, DEFAULT_GROUP_DIMENSIONS.height),
  };
};

const buildGroupName = () => {
  const existingNames = new Set(
    (props.workflow.draft?.groups || [])
      .map(group => group.name)
      .filter((name): name is string => !!name)
  );

  if (!existingNames.has('Group')) return 'Group';

  let index = 2;
  let candidate = `Group ${index}`;
  while (existingNames.has(candidate)) {
    index += 1;
    candidate = `Group ${index}`;
  }
  return candidate;
};

const buildRelativePositions = (
  nodes: GraphNode<WorkflowNodeData>[],
  groupNode: GraphNode<GroupNodeData>
) => {
  const positions: Record<string, XYPosition> = {};
  const groupPosition = getAbsoluteNodePosition(groupNode);

  nodes.forEach(node => {
    if (!isStepNode(node)) return;
    const absolute = getAbsoluteNodePosition(node);
    positions[node.id] = {
      x: absolute.x - groupPosition.x,
      y: absolute.y - groupPosition.y,
    };
  });

  return positions;
};

const buildAbsolutePositions = (nodes: GraphNode<WorkflowNodeData>[]) => {
  const positions: Record<string, XYPosition> = {};
  nodes.forEach(node => {
    if (!isStepNode(node)) return;
    const absolute = getAbsoluteNodePosition(node);
    positions[node.id] = { x: absolute.x, y: absolute.y };
  });
  return positions;
};

const emitGroupPositionUpdate = (groupNode: GraphNode<GroupNodeData>) => {
  const width = groupNode.dimensions.width || DEFAULT_GROUP_DIMENSIONS.width;
  const height = groupNode.dimensions.height || DEFAULT_GROUP_DIMENSIONS.height;

  emit('update_group', {
    group_id: groupNode.id,
    changes: {
      position: {
        x: groupNode.position.x,
        y: groupNode.position.y,
        width,
        height,
      },
    },
  });
};

// Track transient node positions during drag
const handleNodeDrag = (event: {
  event: MouseEvent | TouchEvent;
  node: GraphNode<WorkflowNodeData>;
  nodes: GraphNode<WorkflowNodeData>[];
}) => {
  // Get mouse position from drag event
  const mouseEvent = 'clientX' in event.event ? event.event : event.event.touches[0];
  const flowPosition = getFlowPositionFromEvent(mouseEvent);
  if (!flowPosition) return;

  const shiftKey = 'shiftKey' in event.event ? event.event.shiftKey : false;
  const draggedStepNodes = event.nodes.filter(isStepNode);

  const dragging_steps: Record<string, XYPosition> = {};
  event.nodes.forEach(node => {
    if (!isStepNode(node)) return;
    dragging_steps[node.id] = node.position;
  });

  const hasDraggingSteps = Object.keys(dragging_steps).length > 0;
  emitInteraction(flowPosition.x, flowPosition.y, hasDraggingSteps ? dragging_steps : null);
  updateGroupingPreview(draggedStepNodes, flowPosition, shiftKey);
};

onNodeDrag(handleNodeDrag);
onNodeDragStart((event: {
  event: MouseEvent | TouchEvent;
  nodes: GraphNode<WorkflowNodeData>[];
}) => {
  const shiftKey = 'shiftKey' in event.event ? event.event.shiftKey : false;
  const draggedStepNodes = event.nodes.filter(isStepNode);
  const hasGroupedSteps = draggedStepNodes.some(node => groupByStepId.value.has(node.id));

  if (shiftKey && hasGroupedSteps) {
    ungroupDragStepIds.value = draggedStepNodes.map(node => node.id);
    draggedStepNodes.forEach(node => {
      updateNode(node.id, { expandParent: false });
    });
  } else {
    ungroupDragStepIds.value = null;
  }
});

// =============================================================================
// Collaboration: Selection Tracking
// =============================================================================

// Track selection changes and emit to server
const handleSelectionChange = ({ nodes }: { nodes: Node<WorkflowNodeData>[] }) => {
  const selectedIds = nodes.filter(isStepNode).map(n => n.id);
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
    const selectedIds = newSelection.filter(isStepNode).map(n => n.id);
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

watch(
  () => getNodes.value.map(node => node.id),
  () => {
    applyPendingDuplicateSelection();
  }
);

const syncDraftState = async () => {
  if (!isMounted.value) return;
  isSyncingDraft.value = true;
  setNodes(nodes.value);
  setEdges(edges.value);
  await nextTick();
  pendingNodeRemovalIds.clear();
  pendingGroupRemovalIds.clear();
  pendingEdgeRemovalIds.clear();
  isSyncingDraft.value = false;
};

watch(
  () => [props.workflow.draft?.steps, props.workflow.draft?.connections, props.workflow.draft?.groups],
  () => {
    syncDraftState();
  },
  { deep: true }
);

onNodesChange(((changes: NodeChange[]) => {
  if (isSyncingDraft.value) return;

  const nextChanges: NodeChange[] = [];

  for (const change of changes) {
    if (change.type === 'remove') {
      const removedNode = getNodes.value.find(node => node.id === change.id);
      if (removedNode && isGroupNode(removedNode)) {
        if (!pendingGroupRemovalIds.has(change.id)) {
          pendingGroupRemovalIds.add(change.id);
          emit('remove_group', { group_id: change.id });
        }
      } else if (!pendingNodeRemovalIds.has(change.id)) {
        pendingNodeRemovalIds.add(change.id);
        emit('remove_step', { step_id: change.id });
      }
    }

    nextChanges.push(change);
  }

  const nextNodes = applyNodeChanges(nextChanges);
  setNodes(nextNodes);
}) as any);

onEdgesChange(((changes: EdgeChange[]) => {
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
}) as any);

// =============================================================================
// Derived state
// =============================================================================

const selectedNode = computed<Node<StepNodeData> | null>(() => {
  if (!store.selectedNodeId) return null;
  const node = nodes.value.find(n => n.id === store.selectedNodeId);
  if (!node || node.type !== 'step') return null;
  return node as Node<StepNodeData>;
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
const canPaste = computed(() => (clipboard.value?.stepIds.length ?? 0) > 0);

const isExecutionFailed = computed(() => props.execution?.status === 'failed');

const isExecutionRunning = computed(() => {
  const status = props.execution?.status;
  return status === 'running' || status === 'pending';
});

// Filter out current user from presences for cursor display
const otherUserPresences = computed(() => {
  return props.presences.filter(p => p.user.id !== props.currentUserId);
});

const selectedStepNodes = computed(() => getSelectedNodes.value.filter(isStepNode));
const selectedStepIds = computed(() => selectedStepNodes.value.map(node => node.id));
const canGroupSelection = computed(() => selectedStepIds.value.length > 0);
const canUngroupSelection = computed(() =>
  selectedStepIds.value.some(stepId => groupByStepId.value.has(stepId))
);

const contextMenuItems = computed<MenuItem[]>(() => {
  const targetType = store.contextMenu.targetType;
  const targetNodeId = store.contextMenu.targetNodeId;

  if (targetType === 'node' && targetNodeId) {
    const node = nodes.value.find(n => n.id === targetNodeId);
    if (node?.type === 'group') {
      return [
        { id: 'tidy-group', label: 'Tidy up node group', icon: ArrowPathIcon },
        { id: 'divider-group', label: '', divider: true },
        { id: 'delete-group', label: 'Remove Group', icon: TrashIcon, danger: true },
      ];
    }

    const isDisabled = node?.data?.disabled;
    const isPinned = node?.data?.pinned;
    const groupItems: MenuItem[] = [];
    if (canGroupSelection.value) {
      groupItems.push({
        id: 'group-selection',
        label: 'Group Selection',
        icon: RectangleGroupIcon,
        shortcut: '⌘G',
      });
    }
    if (canUngroupSelection.value) {
      groupItems.push({
        id: 'ungroup-selection',
        label: 'Remove from Group',
        icon: FolderMinusIcon,
      });
    }

    return [
      { id: 'edit', label: 'Edit Step', icon: Cog6ToothIcon, shortcut: 'Enter' },
      { id: 'run-from', label: 'Run from Here', icon: PlayIcon },
      ...(groupItems.length ? [{ id: 'divider-groups', label: '', divider: true }] : []),
      ...groupItems,
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
    {
      id: 'paste',
      label: 'Paste',
      icon: ClipboardDocumentIcon,
      shortcut: '⌘V',
      disabled: !canPaste.value,
    },
    { id: 'divider-1', label: '', divider: true },
    { id: 'select-all', label: 'Select All', shortcut: '⌘A' },
    { id: 'tidy-layout', label: tidyLabel.value, icon: ArrowPathIcon },
    { id: 'fit-view', label: 'Fit to View', shortcut: '⌘1' },
  ];
});

const createGroupFromSelection = () => {
  const selectedNodes = selectedStepNodes.value;
  if (selectedNodes.length === 0) return;

  const bounds = buildGroupBounds(selectedNodes);
  if (!bounds) return;

  const stepIds = selectedNodes.map(node => node.id);
  const stepPositions: Record<string, XYPosition> = {};

  selectedNodes.forEach(node => {
    const absolute = getAbsoluteNodePosition(node);
    stepPositions[node.id] = {
      x: absolute.x - bounds.x,
      y: absolute.y - bounds.y,
    };
  });

  emit('add_group', {
    name: buildGroupName(),
    step_ids: stepIds,
    color: DEFAULT_GROUP_COLOR,
    position: bounds,
    step_positions: stepPositions,
  });
};

const ungroupSelectedSteps = () => {
  const selectedNodes = selectedStepNodes.value;
  if (selectedNodes.length === 0) return;

  emit('set_group_membership', {
    group_id: null,
    step_ids: selectedNodes.map(node => node.id),
    step_positions: buildAbsolutePositions(selectedNodes),
  });
};

const removeGroup = (groupId: string) => {
  emit('remove_group', { group_id: groupId });
};

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
  parentNode?: string;
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

type LayoutOptions = { groupId?: string };

const handleLayout = (options: LayoutOptions = {}) => {
  const stepNodes = getNodes.value.filter(isStepNode) as unknown as GraphNode<StepNodeData>[];
  if (!stepNodes.length) return;

  const groupNodes = getNodes.value.filter(isGroupNode) as unknown as GraphNode<GroupNodeData>[];
  const groupNodeById = new Map(groupNodes.map(node => [node.id, node]));

  let nodesToLayout: LayoutNode[] = [];
  const groupsToResize = new Set<string>();

  if (options.groupId) {
    nodesToLayout = stepNodes
      .filter(node => node.parentNode === options.groupId)
      .map(node => ({
        ...node,
        position: getAbsoluteNodePosition(node),
      }));
    groupsToResize.add(options.groupId);
  } else {
    const selection = getSelectedNodes.value;
    const selectedSteps = selection.filter(isStepNode) as unknown as GraphNode<StepNodeData>[];
    const selectedGroups = selection.filter(isGroupNode) as unknown as GraphNode<GroupNodeData>[];

    if (selection.length > 1) {
      const stepsFromGroups = selectedGroups.flatMap(group =>
        stepNodes.filter(node => node.parentNode === group.id)
      );
      const combined = [...selectedSteps, ...stepsFromGroups];
      const unique = new Map(combined.map(node => [node.id, node]));
      nodesToLayout = Array.from(unique.values()).map(node => ({
        ...node,
        position: getAbsoluteNodePosition(node),
      }));

      nodesToLayout.forEach(node => {
        if (node.parentNode) groupsToResize.add(node.parentNode);
      });
      selectedGroups.forEach(group => groupsToResize.add(group.id));
    } else {
      nodesToLayout = stepNodes.map(node => ({
        ...node,
        position: getAbsoluteNodePosition(node),
      }));
      groupNodes.forEach(group => groupsToResize.add(group.id));
    }
  }

  if (!nodesToLayout.length) return;

  const nodeIds = new Set(nodesToLayout.map(node => node.id));
  const edgesToLayout = getEdges.value.filter(
    edge => nodeIds.has(edge.source) && nodeIds.has(edge.target)
  );

  const layoutDirection = (previousDirection.value === 'RL' ? 'RL' : 'LR') as LayoutDirection;
  let normalizedLayout = nodesToLayout;

  if (nodesToLayout.length > 1) {
    const nodeLookup = new Map(nodesToLayout.map(node => [node.id, node]));
    const hasEdgeLabels = edgesToLayout.some(edge => hasEdgeLabel(nodeLookup.get(edge.source)));
    const layoutNodes = layout(nodesToLayout, edgesToLayout, layoutDirection, {
      ranksep: hasEdgeLabels ? EDGE_LABEL_GAP : undefined,
    }) as LayoutNode[];
    normalizedLayout = alignLayoutPositions(
      nodesToLayout,
      layoutNodes,
      edgesToLayout,
      layoutDirection
    );
  }

  const layoutById = new Map(normalizedLayout.map(node => [node.id, node]));
  const desiredAbsolutePositions = new Map<string, XYPosition>();
  stepNodes.forEach(node => {
    desiredAbsolutePositions.set(node.id, getAbsoluteNodePosition(node));
  });
  normalizedLayout.forEach(node => {
    desiredAbsolutePositions.set(node.id, node.position);
  });

  const groupBoundsById = new Map<string, { x: number; y: number; width: number; height: number }>();
  groupsToResize.forEach(groupId => {
    const groupNode = groupNodeById.get(groupId);
    if (!groupNode) return;
    const groupSteps = stepNodes.filter(node => node.parentNode === groupId);
    const bounds = buildGroupBoundsFromPositions(groupSteps, desiredAbsolutePositions);
    if (!bounds) return;
    groupBoundsById.set(groupId, bounds);

    updateNode(groupId, {
      position: { x: bounds.x, y: bounds.y },
      style: { width: `${bounds.width}px`, height: `${bounds.height}px` },
    });
    emit('update_group', { group_id: groupId, changes: { position: bounds } });
  });

  const currentGroupPositions = new Map<string, XYPosition>();
  groupNodes.forEach(group => {
    currentGroupPositions.set(group.id, getAbsoluteNodePosition(group));
  });

  stepNodes.forEach(node => {
    const shouldUpdate = layoutById.has(node.id) || (node.parentNode && groupBoundsById.has(node.parentNode));
    if (!shouldUpdate) return;

    const desiredAbsolute = desiredAbsolutePositions.get(node.id);
    if (!desiredAbsolute) return;

    if (node.parentNode) {
      const groupId = node.parentNode;
      const groupBounds = groupBoundsById.get(groupId);
      const groupPosition = groupBounds
        ? { x: groupBounds.x, y: groupBounds.y }
        : currentGroupPositions.get(groupId);
      if (!groupPosition) return;

      const relativePosition = {
        x: desiredAbsolute.x - groupPosition.x,
        y: desiredAbsolute.y - groupPosition.y,
      };
      const layoutNode = layoutById.get(node.id);
      const positionChanged =
        relativePosition.x !== node.position.x || relativePosition.y !== node.position.y;

      if (positionChanged || layoutNode) {
        updateNode(node.id, {
          position: relativePosition,
          targetPosition: layoutNode?.targetPosition,
          sourcePosition: layoutNode?.sourcePosition,
        });
      }
      if (positionChanged) {
        emit('move_step', { step_id: node.id, position: relativePosition });
      }
    } else {
      const layoutNode = layoutById.get(node.id);
      const positionChanged =
        desiredAbsolute.x !== node.position.x || desiredAbsolute.y !== node.position.y;
      if (positionChanged || layoutNode) {
        updateNode(node.id, {
          position: desiredAbsolute,
          targetPosition: layoutNode?.targetPosition,
          sourcePosition: layoutNode?.sourcePosition,
        });
      }
      if (positionChanged) {
        emit('move_step', { step_id: node.id, position: desiredAbsolute });
      }
    }
  });
};

// =============================================================================
// Clipboard & Duplication
// =============================================================================

const resolveActiveNodeIds = (fallbackNodeId?: string | null) => {
  const selectedIds = getSelectedNodes.value.filter(isStepNode).map(node => node.id);
  if (selectedIds.length) return Array.from(new Set(selectedIds));
  if (fallbackNodeId) {
    const fallbackNode = nodes.value.find(node => node.id === fallbackNodeId);
    if (fallbackNode?.type === 'step') return [fallbackNodeId];
  }
  if (store.selectedNodeId) return [store.selectedNodeId];
  return [];
};

const buildPositionByStepId = (stepIds: string[], offset: XYPosition) => {
  const nodeById = new Map(getNodes.value.map(node => [node.id, node]));
  const positions: Record<string, XYPosition> = {};

  for (const stepId of stepIds) {
    const node = nodeById.get(stepId);
    if (!node) continue;
    positions[stepId] = {
      x: node.position.x + offset.x,
      y: node.position.y + offset.y,
    };
  }

  return positions;
};

const buildGroupIdsByStepId = (stepIds: string[]) => {
  const groupIds: Record<string, string> = {};
  for (const stepId of stepIds) {
    const groupId = groupByStepId.value.get(stepId);
    if (groupId) {
      groupIds[stepId] = groupId;
    }
  }
  return groupIds;
};

const emitDuplicateSteps = (stepIds: string[], offset: XYPosition) => {
  if (!stepIds.length) return;
  const positionByStepId = buildPositionByStepId(stepIds, offset);
  const groupIds = buildGroupIdsByStepId(stepIds);
  emit('duplicate_steps', {
    step_ids: stepIds,
    position_by_step_id: positionByStepId,
    group_id_by_step_id: Object.keys(groupIds).length ? groupIds : undefined,
  });
};

const handleCopySteps = (stepIds: string[]) => {
  if (!stepIds.length) return;
  clipboard.value = { stepIds };
  clipboardPasteCount.value = 0;
};

const handlePasteSteps = () => {
  const stepIds = clipboard.value?.stepIds ?? [];
  if (!stepIds.length) return;
  clipboardPasteCount.value += 1;
  emitDuplicateSteps(stepIds, {
    x: DUPLICATE_OFFSET.x * clipboardPasteCount.value,
    y: DUPLICATE_OFFSET.y * clipboardPasteCount.value,
  });
};

const handleDuplicateSteps = (stepIds: string[]) => {
  emitDuplicateSteps(stepIds, DUPLICATE_OFFSET);
};

const handleCutSteps = (stepIds: string[]) => {
  if (!stepIds.length) return;
  handleCopySteps(stepIds);
  stepIds.forEach(requestNodeRemoval);
};

const applyDuplicateSelection = (stepIds: string[]) => {
  if (!stepIds.length) return;
  const idSet = new Set(stepIds);

  isUpdatingSelection.value = true;
  store.selectNode(stepIds.length === 1 ? stepIds[0] : null);

  const nextNodes = getNodes.value.map(node => ({
    ...node,
    selected: idSet.has(node.id),
  }));

  setNodes(nextNodes);

  nextTick(() => {
    isUpdatingSelection.value = false;
  });
};

const applyPendingDuplicateSelection = () => {
  const pending = pendingDuplicateSelection.value;
  if (!pending || pending.length === 0) return;

  const existingIds = new Set(getNodes.value.map(node => node.id));
  const allAvailable = pending.every(id => existingIds.has(id));
  if (!allAvailable) return;

  pendingDuplicateSelection.value = null;
  applyDuplicateSelection(pending);
};

const isEditableTarget = (target: EventTarget | null) => {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName.toLowerCase();
  return tag === 'input' || tag === 'textarea' || tag === 'select';
};

const handleGlobalKeydown = (event: KeyboardEvent) => {
  if (event.repeat || isEditableTarget(event.target)) return;
  if (!event.metaKey && !event.ctrlKey) return;

  const key = event.key.toLowerCase();
  if (key === 'c') {
    const stepIds = resolveActiveNodeIds();
    if (!stepIds.length) return;
    event.preventDefault();
    handleCopySteps(stepIds);
    return;
  }

  if (key === 'v') {
    if (!canPaste.value) return;
    event.preventDefault();
    handlePasteSteps();
    return;
  }

  if (key === 'x') {
    const stepIds = resolveActiveNodeIds();
    if (!stepIds.length) return;
    event.preventDefault();
    handleCutSteps(stepIds);
    return;
  }

  if (key === 'g') {
    if (event.shiftKey) {
      if (!canUngroupSelection.value) return;
      event.preventDefault();
      ungroupSelectedSteps();
      return;
    }

    if (!canGroupSelection.value) return;
    event.preventDefault();
    createGroupFromSelection();
  }
};

const handleNodeClick = (event: { node: Node<WorkflowNodeData> }) => {
  const node = event.node;

  if (clickTimer.value) {
    clearTimeout(clickTimer.value);
    clickTimer.value = null;
  }

  clickTimer.value = setTimeout(() => {
    if (node.type === 'step') {
      store.selectNode(node.id);
    } else {
      store.selectNode(null);
    }
    clickTimer.value = null;
  }, DOUBLE_CLICK_DELAY_MS);
};

const handleNodeDoubleClick = (event: { node: Node<WorkflowNodeData> }) => {
  if (clickTimer.value) {
    clearTimeout(clickTimer.value);
    clickTimer.value = null;
  }
  if (event.node.type === 'step') {
    store.openConfigModal(event.node.id);
  }
};

type SelectionContextMenuEvent = { event: MouseEvent; nodes: GraphNode<WorkflowNodeData>[] };

const findNodeUnderCursor = (event: MouseEvent, nodes: GraphNode<WorkflowNodeData>[]) => {
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
    case 'group-selection':
      createGroupFromSelection();
      break;
    case 'ungroup-selection':
      ungroupSelectedSteps();
      break;
    case 'delete-group':
      if (nodeId) removeGroup(nodeId);
      break;
    case 'tidy-group':
      if (nodeId) handleLayout({ groupId: nodeId });
      break;
    case 'edit':
      if (nodeId) store.openConfigModal(nodeId);
      break;
    case 'delete':
      if (nodeId) requestNodeRemoval(nodeId);
      break;
    case 'duplicate':
      handleDuplicateSteps(resolveActiveNodeIds(nodeId));
      break;
    case 'copy':
      handleCopySteps(resolveActiveNodeIds(nodeId));
      break;
    case 'cut':
      handleCutSteps(resolveActiveNodeIds(nodeId));
      break;
    case 'paste':
      handlePasteSteps();
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
      if (nodeId) handleRunNode(nodeId);
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
    const targetGroup = findGroupAtPoint(position);
    if (targetGroup) {
      const groupPosition = getAbsoluteNodePosition(targetGroup);
      emit('add_step', {
        type_id: typeId,
        position: {
          x: position.x - groupPosition.x,
          y: position.y - groupPosition.y,
        },
        group_id: targetGroup.id,
      });
    } else {
      emit('add_step', { type_id: typeId, position });
    }
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

const restoreExpandParent = () => {
  if (!ungroupDragStepIds.value) return;
  const stepIds = ungroupDragStepIds.value;
  ungroupDragStepIds.value = null;

  stepIds.forEach(stepId => {
    const node = getNodes.value.find(item => item.id === stepId);
    updateNode(stepId, { expandParent: node?.parentNode ? true : undefined });
  });
};

onNodeDragStop((event: { event: MouseEvent | TouchEvent; nodes: GraphNode<WorkflowNodeData>[] }) => {
  // Clear transient drag positions and emit final positions for persistence
  // We can just emit null for dragging_steps to clear it.
  // For now, we use 0,0 for the cursor as it will be updated by the next mousemove anyway.
  emitInteraction(0, 0, null);
  clearGroupingPreview();
  restoreExpandParent();

  const draggedStepNodes = event.nodes.filter(isStepNode);
  const draggedGroupNodes = event.nodes.filter(isGroupNode);

  draggedGroupNodes.forEach(groupNode => {
    emitGroupPositionUpdate(groupNode);
  });

  let handledStepIds = new Set<string>();
  let targetGroupId: string | null = null;

  if (draggedStepNodes.length > 0) {
    const pointerEvent =
      'clientX' in event.event
        ? event.event
        : event.event.changedTouches?.[0] ?? event.event.touches?.[0] ?? null;
    const shiftKey = 'shiftKey' in event.event ? event.event.shiftKey : false;

    if (shiftKey) {
      const stepIds = draggedStepNodes.map(node => node.id);
      const hasGroupedSteps = stepIds.some(stepId => groupByStepId.value.has(stepId));

      if (hasGroupedSteps) {
        emit('set_group_membership', {
          group_id: null,
          step_ids: stepIds,
          step_positions: buildAbsolutePositions(draggedStepNodes),
        });
        handledStepIds = new Set(stepIds);
      }
    } else if (pointerEvent) {
      const flowPosition = getFlowPositionFromEvent(pointerEvent);
      const targetGroup = flowPosition ? findGroupAtPoint(flowPosition) : null;

      if (targetGroup) {
        targetGroupId = targetGroup.id;
        const membershipChanged = draggedStepNodes.some(
          node => groupByStepId.value.get(node.id) !== targetGroupId
        );

        if (membershipChanged) {
          const stepIds = draggedStepNodes.map(node => node.id);
          emit('set_group_membership', {
            group_id: targetGroupId,
            step_ids: stepIds,
            step_positions: buildRelativePositions(draggedStepNodes, targetGroup),
          });
          handledStepIds = new Set(stepIds);
        }
      }
    }
  }

  for (const node of draggedStepNodes) {
    if (handledStepIds.has(node.id)) continue;
    emit('move_step', { step_id: node.id, position: node.position });
  }

  const affectedGroupIds = new Set<string>();
  draggedStepNodes.forEach(node => {
    const groupId = groupByStepId.value.get(node.id);
    if (groupId) affectedGroupIds.add(groupId);
  });
  if (targetGroupId) {
    affectedGroupIds.add(targetGroupId);
  }

  affectedGroupIds.forEach(groupId => {
    const groupNode = getNodes.value.find(node => node.id === groupId);
    if (groupNode && isGroupNode(groupNode)) {
      emitGroupPositionUpdate(groupNode);
    }
  });
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
            <MiniMap position="bottom-left" :node-color="miniMapNodeColor" />
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
