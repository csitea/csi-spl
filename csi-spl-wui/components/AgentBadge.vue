<template>
  <span class="msg-author" :title="label">{{ label }}</span>
</template>

<script setup lang="ts">
import { displayName } from '~/utils/channel-feed.mjs'

const props = defineProps<{ id: string, box?: string }>()
const label = computed(() => displayName(props.id, props.box))
</script>
