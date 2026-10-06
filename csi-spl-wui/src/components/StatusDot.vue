<!-- Spec 096 §4: one person's dot. The FILL is presence (green online, grey
     offline, as before); the RING is the member's manual status - amber Busy,
     red Unavailable - and shows while offline too. The ring carries the
     words (aria-label + title), so colour is never the only signal. -->
<template>
  <span
    class="dot"
    :class="[{ on: online }, words ? 'dot--' + words.ring : '']"
    :data-status="words ? words.ring : undefined"
    :role="words ? 'img' : undefined"
    :aria-label="words ? words.short : undefined"
    :title="words ? words.full : undefined"
  />
</template>

<script setup lang="ts">
import { useHumanStatusStore } from '~/stores/human-status'

const props = defineProps<{
  /** the member id, or id@box; an agent or unknown id has no status */
  id: string
  online: boolean
}>()
const status = useHumanStatusStore()
const { t } = useI18n({ useScope: 'global' })
const words = computed(() => status.statusLabel(props.id, t))
</script>
