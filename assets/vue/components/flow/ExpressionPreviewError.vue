<script setup lang="ts">
import { computed } from 'vue'

interface ErrorPayload {
  type: 'parse_error' | 'render_error'
  message?: string
  errors?: string[]
  line?: number
  column?: number
  text: string
}

const props = defineProps<{
  error: ErrorPayload
}>()

const errorMessage = computed(() => {
  if (props.error.message) return props.error.message
  if (props.error.errors?.length) return props.error.errors.join('\n')
  return 'Unknown error'
})

const lines = computed(() => props.error.text.split('\n'))

// For now we only highlight the specific character at the column
const errorMarker = computed(() => {
  if (props.error.column === undefined) return null
  
  // column is usually 1-indexed
  const col = props.error.column - 1
  return ' '.repeat(col) + '^'
})
</script>

<template>
  <div class="space-y-2 p-3 bg-error/5 rounded-lg border border-error/10">
    <div class="flex items-center gap-2 text-error text-[10px] font-bold uppercase tracking-wider">
      <div class="w-1.5 h-1.5 rounded-full bg-error animate-pulse" />
      Template Error
    </div>
    
    <div class="font-mono text-[11px] leading-relaxed overflow-x-auto whitespace-pre bg-base-300/50 p-2 rounded border border-base-content/5">
      <template v-for="(line, idx) in lines" :key="idx">
        <div class="flex gap-3" :class="{ 'bg-error/5': idx === (props.error.line ? props.error.line - 1 : 0) }">
          <span class="text-base-content/30 select-none w-4 text-right">{{ 1 + idx }}</span>
          <span class="text-base-content/90">{{ line }}</span>
        </div>
        <div v-if="idx === (props.error.line ? props.error.line - 1 : 0) && errorMarker" class="flex gap-3">
          <span class="w-4" />
          <span class="text-error font-bold leading-[0]">{{ errorMarker }}</span>
        </div>
      </template>
    </div>

    <div class="text-[11px] text-error leading-normal bg-error/10 p-2 rounded whitespace-pre-wrap">
      {{ errorMessage }}
    </div>
  </div>
</template>
