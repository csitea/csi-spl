<template>
  <div class="poll-body">
    <template v-for="(s, i) in segments" :key="i">
      <PollForm v-if="s.type === 'poll'" :form="s.poll" />
      <MessageBody v-else :body="s.text" :at="at" no-previews no-poll />
    </template>
  </div>
</template>

<script setup lang="ts">
import MessageBody from '~/components/MessageBody.vue'
import PollForm from '~/components/PollForm.vue'
import { splitPolls } from '~/utils/poll.mjs'

/* SPL-1637 poll-control: MessageBody hands a body that may hold a ```poll
   form here (lazily). The text around the form renders as before, each part
   through MessageBody; the form (at most one per message, owner b14c95a4)
   renders where it was written. Until the second catalogue holds the form's
   labels (i18n-first-screen.mjs ON_DEMAND_COMPONENTS), the form shows as the
   fence text it is, so the first paint of a feed is unchanged. */
const props = defineProps<{ body: string, at?: string | number }>()
const { te } = useI18n({ useScope: 'global' })
const segments = computed(() => (te('poll.chat') ? splitPolls(props.body) : [{ type: 'text', text: props.body }]) as Array<{ type: 'text', text: string } | { type: 'poll', poll: PollShape }>)
</script>

<script lang="ts">
export interface PollShape {
  multi: boolean,
  questions: Array<{
    text: string,
    kind?: 'button' | 'radio',
    options: Array<{ key: string, text: string }>
  }>
}
</script>

<style scoped>
.poll-body > * + * { margin-top: 4px; }
</style>
