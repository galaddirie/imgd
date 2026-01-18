<script setup lang="ts">
import { computed } from 'vue';
import type { NodeProps } from '@vue-flow/core';
import type { GroupNodeData } from '@/types/workflow';
import { Squares2X2Icon } from '@heroicons/vue/24/outline';

const props = defineProps<NodeProps<GroupNodeData>>();

const stepCount = computed(() => props.data.step_ids?.length ?? 0);
const nodeClasses = computed(() => [
  'relative h-full w-full rounded-3xl border bg-base-200/40 p-4 shadow-inner transition',
  props.selected ? 'border-primary/70 ring-2 ring-primary/30' : 'border-base-300/60',
]);
</script>

<template>
  <div :class="nodeClasses">
    <div class="pointer-events-none absolute inset-0 rounded-3xl border border-dashed border-base-300/40"></div>

    <div class="relative flex items-start justify-between gap-3">
      <div class="flex items-center gap-3">
        <div
          class="bg-base-100/80 border-base-200 text-base-content/70 flex h-9 w-9 items-center justify-center rounded-2xl border shadow-sm"
        >
          <Squares2X2Icon class="h-4.5 w-4.5" />
        </div>
        <div class="min-w-0">
          <p class="text-base-content/50 text-[10px] font-semibold tracking-[0.2em] uppercase">
            Group
          </p>
          <h3 class="text-base-content truncate text-sm font-semibold">
            {{ data.name || 'Group' }}
          </h3>
        </div>
      </div>

      <div
        class="bg-base-100/80 border-base-200 text-base-content/60 flex items-center gap-2 rounded-full border px-2 py-1 text-[10px] font-bold uppercase tracking-wide"
      >
        <span class="bg-primary/70 h-1.5 w-1.5 rounded-full"></span>
        {{ stepCount }} nodes
      </div>
    </div>

    <div class="text-base-content/40 mt-4 text-xs font-medium">
      Drag nodes here to add them
    </div>
  </div>
</template>
