<template>
  <span class="msg-author" :title="title">{{ label }}</span>
</template>

<script setup lang="ts">
import { displayName } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

const props = defineProps<{ id: string, box?: string }>()
const { t } = useI18n({ useScope: 'global' })
/* A human's chosen display name; the member id stays in the tooltip. */
const people = useHumanNames()
const label = computed(() => (props.id ? people.label(props.id, props.box) : t('feed.unknown_author')))
const title = computed(() => {
  if (!props.id) return label.value
  const id = displayName(props.id, props.box)
  return label.value === id ? id : `${label.value} (${id})`
})
</script>
