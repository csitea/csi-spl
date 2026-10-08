<!-- Spec 096 §4: one person's dot. The FILL is presence (green online, grey
     offline, as before; hollow grey = the machine is online but the agent
     does not run, t1 bc1a43e1); the RING is the member's manual status - amber Busy,
     red Unavailable - and shows while offline too. The ring carries the
     words (aria-label + title), so colour is never the only signal. -->
<template>
  <span
    class="dot"
    :class="[{ on: online, 'dot--idle': notRunning }, words ? 'dot--' + words.ring : '']"
    :data-status="words ? words.ring : undefined"
    :data-presence="notRunning ? 'not_running' : undefined"
    :role="words || notRunning ? 'img' : undefined"
    :aria-label="words ? words.short : notRunning ? t('people.not_running') : undefined"
    :title="words ? words.full : notRunning ? t('people.not_running') : undefined"
  />
</template>

<script setup lang="ts">
import { useHumanStatusStore } from '~/stores/human-status'

const props = defineProps<{
  /** the member id, or id@box; an agent or unknown id has no status */
  id: string
  online: boolean
  /** t1 bc1a43e1: its machine is online, the agent does not run - a hollow
   *  grey dot titled "machine online, agent not running" */
  idle?: boolean
}>()
const status = useHumanStatusStore()
const { t } = useI18n({ useScope: 'global' })
const words = computed(() => status.statusLabel(props.id, t))
const notRunning = computed(() => Boolean(props.idle) && !props.online)
</script>
