<script setup lang="ts">
import { computed, ref, watch, onMounted, onUnmounted } from 'vue'
import type { UserPresence } from '../../types/workflow'
import { generateColor } from '../../lib/color'
import { useLiveVue } from 'live_vue'

const props = defineProps<{
    presences: UserPresence[]
    currentUserId?: string
    zoom?: number
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

    const zoom = props.zoom || 1
    const inverseZoom = 1 / zoom

    return {
        // Position the tip of the arrow at the cursor position
        transform: `translate(${presence.cursor.x}px, ${presence.cursor.y}px) scale(${inverseZoom})`,
        // Smooth cursor movement with short transition
        // We include the scale in transition to keep it smooth if zoom changes
        transition: 'transform 100ms ease-out',
        willChange: 'transform',
        transformOrigin: '0 0'
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
                class="cursor-container absolute left-0 top-0 will-change-transform flex flex-col items-start" 
                :style="getCursorStyle(presence)">
                
                <!-- Figma-like Cursor Arrow -->
                <svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg" class="drop-shadow-[0_2px_2px_rgba(0,0,0,0.4)]">
                    <path d="M0 0L16 11L9 11L0 16V0Z" 
                        fill="white" 
                        stroke="black" 
                        stroke-width="1" />
                    <path d="M0 0L16 11L9 11L0 16V0Z" 
                        :fill="getCursorColor(presence.user)" />
                </svg>

                <!-- User name label underneath/offset -->
                <div class="cursor-label px-1.5 py-0.5 rounded-sm rounded-tl-none text-[10px] uppercase tracking-wider font-extrabold text-white whitespace-nowrap shadow-md translate-x-4 -translate-y-1.5"
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