<script lang="ts">
  import {Background, Controls, MiniMap, SvelteFlow} from "@xyflow/svelte"
  import type {Edge, Node} from "@xyflow/svelte"

  type FlowProps = {
    nodes?: Node[]
    edges?: Edge[]
  }

  const fallbackNodes: Node[] = [
    {
      id: "start",
      data: {label: "Brief"},
      position: {x: 40, y: 40},
    },
    {
      id: "review",
      data: {label: "Review"},
      position: {x: 260, y: 140},
    },
    {
      id: "ship",
      data: {label: "Ship"},
      position: {x: 500, y: 60},
    },
  ]

  const fallbackEdges: Edge[] = [
    {id: "start-review", source: "start", target: "review"},
    {id: "review-ship", source: "review", target: "ship"},
  ]

  const {nodes: initialNodes, edges: initialEdges}: FlowProps = $props()

  let nodes = $state.raw(fallbackNodes)
  let edges = $state.raw(fallbackEdges)

  $effect(() => {
    if (initialNodes) {
      nodes = initialNodes
    }

    if (initialEdges) {
      edges = initialEdges
    }

    $inspect("initialNodes", nodes)
    $inspect("initialEdges", edges)
  })
</script>
<div class="h-full w-full">
  <SvelteFlow bind:nodes bind:edges class="h-full w-full">
    <Controls />
    <Background />
    <MiniMap />
  </SvelteFlow>
</div>