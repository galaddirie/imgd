<script setup lang="ts">
import { computed } from 'vue'
import { generateColor } from '@/lib/color'
import type { UserPresence } from '@/types/workflow'

// =============================================================================
// Props
// =============================================================================

interface Props {
  presences: UserPresence[]
}

const props = withDefaults(defineProps<Props>(), {
  presences: () => [],
})

// =============================================================================
// Computed
// =============================================================================

// Show up to 3 user avatars, then "+N"
const visiblePresences = computed(() => props.presences.slice(0, 3))
const extraPresenceCount = computed(() => Math.max(0, props.presences.length - 3))

// Get initials from name/email
const getInitials = (user: UserPresence['user']): string => {
  if (user.name) {
    return user.name.split(' ').map(n => n[0]).join('').toUpperCase().slice(0, 2)
  }
  return user.email[0].toUpperCase()
}

// Generate consistent gradient from user name
const getUserGradient = (user: UserPresence['user']): string => {
  const name = user.name || user.email
  const startColor = generateColor(name, 0)
  const endColor = generateColor(name, 10) // Offset to get a different but related color
  return `linear-gradient(135deg, ${startColor}, ${endColor})`
}
</script>

<template>
  <div v-if="presences.length > 0" class="flex items-center -space-x-2">
    <div v-for="presence in visiblePresences" :key="presence.user.id" class="tooltip tooltip-bottom"
      :data-tip="presence.user.name || presence.user.email">
      <div :class="[
        'w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold text-white ring-2 ring-base-100'
      ]" :style="{ background: getUserGradient(presence.user) }">
        {{ getInitials(presence.user) }}
      </div>
    </div>

    <div v-if="extraPresenceCount > 0"
      class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center text-xs font-bold ring-2 ring-base-100">
      +{{ extraPresenceCount }}
    </div>
  </div>
</template>

<style scoped>
.tooltip::before {
  font-size: 11px;
  padding: 4px 8px;
}
</style>
