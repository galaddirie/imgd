<script setup lang="ts">
import { computed } from 'vue'
import type { UserPresence } from '../../types/workflow'
import { generateColor } from '../../lib/color'

const props = defineProps<{
    presences: UserPresence[]
    currentUserId?: string
}>()

// Filter out current user and users without valid cursor positions
const visibleCursors = computed(() => {
    return props.presences.filter(p => {
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
        transform: `translate(${presence.cursor.x}px, ${presence.cursor.y}px)`,
        // Smooth cursor movement with short transition
        transition: 'transform 100ms ease-out',
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
    <div class="collaborative-cursors pointer-events-none absolute inset-0 overflow-visible">
        <TransitionGroup name="cursor">
            <div v-for="presence in visibleCursors" :key="presence.user.id"
                class="cursor-container absolute left-0 top-0 will-change-transform" :style="getCursorStyle(presence)">
                <!-- Cursor pointer SVG -->
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"
                    class="cursor-icon drop-shadow-md" :style="{ color: getCursorColor(presence.user) }">
                    <!-- Cursor shape with white outline for visibility -->
                    <path
                        d="M5.65376 12.3673H5.46026L5.31717 12.4976L0.500002 16.8829L0.500002 1.19841L11.7841 12.3673H5.65376Z"
                        fill="currentColor" stroke="white" stroke-width="1.5" />
                </svg>

                <!-- User name label -->
                <div class="cursor-label ml-4 mt-1 px-2 py-0.5 rounded-md text-[11px] font-semibold text-white whitespace-nowrap shadow-md"
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

.cursor-icon {
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