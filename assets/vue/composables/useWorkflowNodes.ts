import { computed } from 'vue'
import type { Node, XYPosition } from '@vue-flow/core'

import { generateColor } from '../lib/color'
import type {
  Workflow,
  StepType,
  StepExecution,
  EditorState,
  UserPresence,
  StepNodeData,
} from '../types/workflow'

interface UseWorkflowNodesOptions {
  workflow: () => Workflow
  stepTypes: () => StepType[]
  stepExecutions: () => StepExecution[]
  editorState: () => EditorState | undefined
  presences: () => UserPresence[]
  currentUserId: () => string | undefined
}

export function useWorkflowNodes(options: UseWorkflowNodesOptions) {
  const stepTypeById = computed<Record<string, StepType | undefined>>(() => {
    const map: Record<string, StepType> = {}
    for (const stepType of options.stepTypes()) {
      map[stepType.id] = stepType
    }
    return map
  })

  const stepExecutionByStepId = computed<Record<string, StepExecution | undefined>>(() => {
    const map: Record<string, StepExecution> = {}
    for (const stepExecution of options.stepExecutions()) {
      if (!map[stepExecution.step_id]) {
        map[stepExecution.step_id] = stepExecution
      }
    }
    return map
  })

  const transientPositions = computed<Record<string, XYPosition>>(() => {
    const positions: Record<string, XYPosition> = {}
    const currentUserId = options.currentUserId()

    for (const presence of options.presences()) {
      if (presence.user.id === currentUserId || !presence.dragging_steps) continue
      for (const [id, pos] of Object.entries(presence.dragging_steps)) {
        positions[id] = pos
      }
    }

    return positions
  })

  const nodes = computed<Node<StepNodeData>[]>(() => {
    const steps = options.workflow().draft?.steps || []
    const stepTypes = stepTypeById.value
    const stepExecutions = stepExecutionByStepId.value
    const editorState = options.editorState()
    const presences = options.presences()
    const currentUserId = options.currentUserId()

    return steps.map(step => {
      const stepType = stepTypes[step.type_id]
      const stepExecution = stepExecutions[step.id]
      const isPinned = editorState?.pinned_outputs?.[step.id] !== undefined
      const isDisabled = editorState?.disabled_steps?.includes(step.id)
      const lockedBy = editorState?.step_locks?.[step.id]

      const selectedBy = presences
        .filter(p => p.user.id !== currentUserId && p.selected_steps?.includes(step.id))
        .map(p => {
          const displayName = p.user.name || p.user.email || 'Unknown User'
          return {
            id: p.user.id,
            name: displayName,
            color: generateColor(displayName, 0),
          }
        })

      return {
        id: step.id,
        type: 'step',
        position: transientPositions.value[step.id] || step.position,
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
          stats: stepExecution
            ? { duration_us: stepExecution.duration_us, out: stepExecution.output_item_count }
            : undefined,
          hasInput: stepType?.step_kind !== 'trigger',
          hasOutput: true,
          disabled: isDisabled,
          pinned: isPinned,
          locked_by: lockedBy,
          selected_by: selectedBy,
        } satisfies StepNodeData,
      }
    })
  })

  return { nodes, transientPositions }
}
