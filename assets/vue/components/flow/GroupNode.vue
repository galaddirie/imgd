<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue';
import type { NodeProps } from '@vue-flow/core';
import type { GroupNodeData } from '@/types/workflow';
import { DEFAULT_GROUP_COLOR } from '@/constants/layout';
import { PencilIcon, Squares2X2Icon } from '@heroicons/vue/24/outline';

// Simple debounce utility
function debounce<T extends (...args: any[]) => any>(
  func: T,
  delay: number
): (...args: Parameters<T>) => void {
  let timeoutId: number;
  return (...args: Parameters<T>) => {
    clearTimeout(timeoutId);
    timeoutId = setTimeout(() => func.apply(null, args), delay);
  };
}

const props = defineProps<NodeProps<GroupNodeData>>();

const DEFAULT_NAME = 'Group';

const stepCount = computed(() => props.data.step_ids?.length ?? 0);
const isEditing = ref(false);
const nameDraft = ref(props.data.name || DEFAULT_NAME);
const nameInputRef = ref<HTMLInputElement | null>(null);
const colorInputRef = ref<HTMLInputElement | null>(null);

watch(
  () => props.data.name,
  name => {
    if (!isEditing.value) {
      nameDraft.value = name || DEFAULT_NAME;
    }
  }
);

const normalizeHexColor = (color?: string) => {
  if (!color) return DEFAULT_GROUP_COLOR;
  if (/^#[0-9A-Fa-f]{6}$/.test(color)) return color;
  return DEFAULT_GROUP_COLOR;
};

const hexToRgba = (hex: string, alpha: number) => {
  const normalized = hex.replace('#', '');
  const r = parseInt(normalized.slice(0, 2), 16);
  const g = parseInt(normalized.slice(2, 4), 16);
  const b = parseInt(normalized.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
};

const accentColor = computed(() => normalizeHexColor(props.data.color));
const nodeStyle = computed(() => {
  const accent = accentColor.value;
  const ring = props.selected ? `, 0 0 0 2px ${hexToRgba(accent, 0.25)}` : '';
  return {
    borderColor: hexToRgba(accent, props.selected ? 0.55 : 0.35),
    backgroundColor: hexToRgba(accent, 0.12),
    boxShadow: `inset 0 2px 8px rgba(0, 0, 0, 0.08)${ring}`,
  };
});

const outlineStyle = computed(() => ({
  borderColor: hexToRgba(accentColor.value, 0.2),
}));

const countDotStyle = computed(() => ({
  backgroundColor: accentColor.value,
}));

const nodeClasses = computed(() => [
  'relative h-full w-full rounded-3xl border bg-base-200/30 p-4 transition-shadow',
  props.dragging ? 'cursor-grabbing shadow-lg' : 'cursor-grab',
]);

const startEditing = () => {
  isEditing.value = true;
  nameDraft.value = props.data.name || DEFAULT_NAME;
  nextTick(() => nameInputRef.value?.focus());
};

const commitName = () => {
  const nextName = nameDraft.value.trim() || DEFAULT_NAME;
  isEditing.value = false;

  if (nextName !== (props.data.name || DEFAULT_NAME)) {
    props.data.onUpdate?.(props.id, { name: nextName });
  }
};

const cancelName = () => {
  isEditing.value = false;
  nameDraft.value = props.data.name || DEFAULT_NAME;
};

const handleNameKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    commitName();
  } else if (event.key === 'Escape') {
    event.preventDefault();
    cancelName();
  }
};

const openColorPicker = () => {
  colorInputRef.value?.click();
};

const debouncedUpdateColor = debounce((color: string) => {
  props.data.onUpdate?.(props.id, { color });
}, 300);

const handleColorInput = (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  if (!target?.value) return;
  debouncedUpdateColor(target.value);
};
</script>

<template>
  <div :class="nodeClasses" :style="nodeStyle">
    <div
      class="pointer-events-none absolute inset-0 rounded-3xl border border-dashed"
      :style="outlineStyle"
    ></div>

    <div class="relative flex items-start justify-between gap-3">
      <div class="flex min-w-0 items-center gap-3">
        <div
          class="bg-base-100/80 border-base-200 text-base-content/70 flex h-9 w-9 items-center justify-center rounded-2xl border shadow-sm"
        >
          <Squares2X2Icon class="h-4.5 w-4.5" />
        </div>
        <div class="min-w-0">

          <div class="flex items-center gap-2">
            <input
              v-if="isEditing"
              ref="nameInputRef"
              v-model="nameDraft"
              class="input input-xs nodrag bg-base-100/90 text-base-content/80 h-6 w-36 rounded-lg text-xs font-semibold"
              type="text"
              @keydown="handleNameKeydown"
              @blur="commitName"
              @mousedown.stop
            />
            <h3
              v-else
              class="text-base-content truncate text-sm font-semibold"
              title="Double click to rename"
              @dblclick.stop="startEditing"
            >
              {{ data.name || DEFAULT_NAME }}
            </h3>
            <button
              class="btn btn-ghost btn-xs nodrag text-base-content/60 hover:text-base-content"
              type="button"
              title="Rename group"
              @click.stop="startEditing"
              @mousedown.stop
            >
              <PencilIcon class="h-3.5 w-3.5" />
            </button>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <button
          class="nodrag h-6 w-6 rounded-full border border-base-200 bg-base-100/90 shadow-sm"
          type="button"
          title="Edit group color"
          :style="{ backgroundColor: accentColor }"
          @click.stop="openColorPicker"
          @mousedown.stop
        ></button>
        <input
          ref="colorInputRef"
          class="absolute h-0 w-0 opacity-0"
          type="color"
          :value="accentColor"
          @input="handleColorInput"
          @mousedown.stop
        />
        <div
          class="bg-base-100/80 border-base-200 text-base-content/60 flex items-center gap-2 rounded-full border px-2 py-1 text-[10px] font-bold uppercase tracking-wide"
        >
          <span class="h-1.5 w-1.5 rounded-full" :style="countDotStyle"></span>
          {{ stepCount }} nodes
        </div>
      </div>
    </div>

    <div class="absolute bottom-3 right-3 text-base-content/40 text-sm font-medium">
      Drag nodes here to add them
    </div>
  </div>
</template>
