<template>
  <img class="spool-avatar" :src="uri" :width="size" :height="size" alt="" aria-hidden="true" draggable="false">
</template>

<script setup lang="ts">
import { avatarDataUri } from '~/utils/avatar.mjs'

/* SPEC-spool-avatars §2: robot for agents, identicon for HUM-*; deterministic, generated (no image files). */
const props = withDefaults(defineProps<{ id: string, box?: string, size?: number }>(), { box: '', size: 36 })
const uri = computed(() => avatarDataUri(props.id, props.box))
</script>
