<script setup lang="ts">
import { computed, ref, watch, onMounted, onUnmounted } from 'vue'
import type { UserPresence } from '../../types/workflow'
import { generateColor } from '../../lib/color'
import { useLiveVue } from 'live_vue'

const props = defineProps<{
    presences: UserPresence[]
    currentUserId?: string
}>()

// Use local state for presences to allow fast updates via events
// independent of the slower prop update cycle
// Initialize with props data
const localPresences = ref<UserPresence[]>(props.presences)

// Sync with props when they change (initial load or full updates)
// This ensures consistency if the server pushes a full update via assigns
watch(() => props.presences, (newVal) => {
    localPresences.value = newVal
})

const live = useLiveVue()

onMounted(() => {
    // Listen for fast cursor updates bypassing the DOM prop cycle
    live.handleEvent("presence_update", (payload: any) => {
        // payload is { presences: [...] }
        if (payload && payload.presences) {
            localPresences.value = payload.presences
        }
    })
})

// Filter out current user and users without valid cursor positions
const visibleCursors = computed(() => {
    return localPresences.value.filter(p => {
        // Skip current user
        if (p.user.id === props.currentUserId) return false

        // Skip users without cursor data
        if (!p.cursor) return false

        // Skip invalid coordinates
        if (typeof p.cursor.x !== 'number' || typeof p.cursor.y !== 'number') return false
        if (isNaN(p.cursor.x) || isNaN(p.cursor.y)) return false

        return true
    })
})

const getCursorColor = (user: UserPresence['user']) => {
    const name = user.name || user.email || user.id
    return generateColor(name, 0)
}

// Style for positioning cursor in flow coordinates
// The parent container (viewport-top slot) handles the transform
const getCursorStyle = (presence: UserPresence) => {
    if (!presence.cursor) return { display: 'none' }

    return {
        // Center the cursor circle at the cursor position
        transform: `translate(${presence.cursor.x - 8}px, ${presence.cursor.y - 8}px)`,
        // Smooth cursor movement with short transition
        transition: 'transform 100ms ease-out',
        willChange: 'transform',
    }
}

const getUserDisplayName = (user: UserPresence['user']) => {
    if (user.name) return user.name
    if (user.email) {
        // Show first part of email
        const [local] = user.email.split('@')
        return local
    }
    return 'Anonymous'
}
</script>

<template>
    <div class="collaborative-cursors pointer-events-none absolute top-0 left-0 w-0 h-0 overflow-visible">
        <TransitionGroup name="cursor">
            <div v-for="presence in visibleCursors" :key="presence.user.id"
                class="cursor-container absolute left-0 top-0 will-change-transform flex flex-col items-center" :style="getCursorStyle(presence)">
                <!-- Cursor circle -->
                <div class="cursor-circle w-4 h-4 rounded-full border-2 border-white shadow-lg"
                    :style="{ backgroundColor: getCursorColor(presence.user) }">
                </div>

                <!-- User name label underneath -->
                <div class="cursor-label -mt-1 px-2 py-0.5 rounded-md text-[11px] font-semibold text-white whitespace-nowrap shadow-md"
                    :style="{ backgroundColor: getCursorColor(presence.user) }">
                    {{ getUserDisplayName(presence.user) }}
                </div>
            </div>
        </TransitionGroup>
    </div>
</template>

<style scoped>
.collaborative-cursors {
    z-index: 1000;
}

.cursor-container {
    z-index: 1000;
}

.cursor-circle {
    filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.3));
}

.cursor-label {
    max-width: 150px;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* Transition for cursor enter/leave */
.cursor-enter-active {
    transition: opacity 0.2s ease-out;
}

.cursor-leave-active {
    transition: opacity 0.15s ease-in;
}

.cursor-enter-from,
.cursor-leave-to {
    opacity: 0;
}
</style>