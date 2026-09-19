<template>
  <span class="msg-author" :title="label">{{ label }}</span>
</template>

<script setup lang="ts">
import { displayName } from '~/utils/channel-feed.mjs'

const props = defineProps<{ id: string, box?: string }>()
const { t } = useI18n({ useScope: 'global' })
const label = computed(() => (props.id ? displayName(props.id, props.box) : t('feed.unknown_author')))
</script>
