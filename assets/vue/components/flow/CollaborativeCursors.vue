<script setup lang="ts">
import { computed } from 'vue'
import { useVueFlow } from '@vue-flow/core'
import type { UserPresence } from '../../types/workflow'
import { generateColor } from '../../lib/color'

const props = defineProps<{
    presences: UserPresence[]
    currentUserId?: string
}>()

const { viewport } = useVueFlow()

// Filter out current user and users without a cursor position
const otherPresences = computed(() => {
    return props.presences.filter(p =>
        p.user.id !== props.currentUserId &&
        p.cursor &&
        p.cursor.x !== undefined &&
        p.cursor.y !== undefined
    )
})

const getCursorColor = (user: UserPresence['user']) => {
    const name = user.name || user.email
    return generateColor(name, 0)
}

// Map presence to style for positioning
const getCursorStyle = (presence: UserPresence) => {
    if (!presence.cursor) return {}

    // Vue Flow coordinates are in "graph space"
    // We want to position them relative to the zoom/pan of the canvas
    // However, if we put this inside the .vue-flow__viewport container,
    // we just use the raw x,y.
    return {
        transform: `translate(${presence.cursor.x}px, ${presence.cursor.y}px)`,
        transition: 'transform 0.1s linear',
        zIndex: 1000,
    }
}
</script>

<template>
    <div class="collaborative-cursors-layer pointer-events-none absolute inset-0 overflow-hidden">
        <div
            v-for="presence in otherPresences"
            :key="presence.user.id"
            class="absolute left-0 top-0 will-change-transform"
            :style="getCursorStyle(presence)"
        >
            <!-- Custom SVG Cursor -->
            <svg
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                xmlns="http://www.w3.org/2000/svg"
                class="drop-shadow-sm"
                :style="{ color: getCursorColor(presence.user) }"
            >
                <path
                    d="M5.65376 12.3673H5.46026L5.31717 12.4976L0.500002 16.8829L0.500002 1.19841L11.7841 12.3673H5.65376Z"
                    fill="currentColor"
                    stroke="white"
                    stroke-width="1"
                />
            </svg>

            <!-- User Label -->
            <div
                class="ml-3 mt-3 px-2 py-1 rounded-md text-[10px] font-bold text-white whitespace-nowrap shadow-sm backdrop-blur-sm"
                :style="{ backgroundColor: getCursorColor(presence.user) }"
            >
                {{ presence.user.name || presence.user.email }}
            </div>
        </div>
    </div>
</template>

<style scoped>
.collaborative-cursors-layer {
    z-index: 1000;
}
</style>
