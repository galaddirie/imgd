import { computed } from 'vue'

import type { Workflow } from '../types/workflow'

export function useWorkflowGraph(workflow: () => Workflow) {
  const stepNameById = computed<Record<string, string>>(() => {
    const steps = workflow().draft?.steps || []
    return steps.reduce((acc, step) => {
      if (step.id && step.name) {
        acc[step.id] = step.name
      }
      return acc
    }, {} as Record<string, string>)
  })

  const upstreamStepIdsByStepId = computed<Record<string, string[]>>(() => {
    const steps = workflow().draft?.steps || []
    const connections = workflow().draft?.connections || []

    const adjacency = new Map<string, string[]>()
    for (const connection of connections) {
      const list = adjacency.get(connection.target_step_id) ?? []
      list.push(connection.source_step_id)
      adjacency.set(connection.target_step_id, list)
    }

    const getUpstream = (id: string, visited = new Set<string>()): Set<string> => {
      const parents = adjacency.get(id) || []
      const result = new Set<string>()

      for (const parent of parents) {
        if (visited.has(parent)) continue
        visited.add(parent)
        result.add(parent)
        for (const upstream of getUpstream(parent, visited)) {
          result.add(upstream)
        }
      }

      return result
    }

    return steps.reduce((acc, step) => {
      acc[step.id] = Array.from(getUpstream(step.id))
      return acc
    }, {} as Record<string, string[]>)
  })

  return { stepNameById, upstreamStepIdsByStepId }
}
