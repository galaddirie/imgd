<script setup lang="ts">
import { Handle } from '@vue-flow/core'
import type { HandleProps } from '@vue-flow/core'

interface Props extends HandleProps {
    // Allow additional props
    [key: string]: any
}

const props = defineProps<Props>()
</script>

<template>
    <Handle v-bind="props" :connectable="true" :connectable-start="true" :connectable-end="true"
        class="h-6! w-2.5! p-0 rounded-full! border-2 border-base-300! bg-primary! "
        style="box-shadow: inset 0px 2px 2px 0px rgba(255,255,255,0.25), 0 3px 2px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000), 0 4px 3px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000);" />
</template>
