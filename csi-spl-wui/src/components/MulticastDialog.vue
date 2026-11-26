<!-- Spec 186 4.1 step 2, 4.4, 4.6 (row M11; owner HUM-10, t1 032d8010,
     msgs 5fdfff6c and 4b3833e7): the Multicast dialog. The selected topics,
     grouped by channel, each with its check verdict and a remove cross;
     and the dialog's OWN MessageComposer, above them for newest first and
     below them for newest last (owner, t1 c9b86153) (H5: not the page's, so the
     page composer and its draft are untouched), whose send it handles. Send
     is held (busy) until the check says every target is ok (Q9 ALL). Once
     sent, the text stays and each target shows its copy's state; a refused
     copy gets Retry under the same msg_id. Every copy acked: it closes and
     the selection empties. UiDialog makes it a full-screen sheet on a phone
     (Back closes it and keeps the selection). Loaded lazily. -->
<template>
  <UiDialog :open="open" :title="t('multicast.title', { n: count })" size="md" @update:open="(v: boolean) => { if (!v) close() }">
    <div class="mc" data-test="multicast-dialog" :data-phase="phase" :data-can-send="canSend ? '1' : '0'" :data-prompt="newestLast ? 'bottom' : 'top'">
      <template v-for="part in parts" :key="part">
      <div v-if="part === 'targets'" class="mc__part" data-test="multicast-targets">
      <p v-if="!count" class="muted mc__note" data-test="multicast-none">{{ t('multicast.none') }}</p>
      <section v-for="g in groups" :key="g.channel" class="mc__group">
        <h3 class="mc__channel">#{{ g.channel }}</h3>
        <ul class="mc__list">
          <li v-for="l in g.lines" :key="l.task_id" class="mc__row" data-test="multicast-target" :data-task="l.task_id" :data-ok="l.ok === null ? '' : String(l.ok)" :data-state="l.state">
            <span class="mc__title">{{ l.title || l.task_id }}</span>
            <UiIcon v-if="l.state === 'sent'" name="check" :size="16" class="mc__state" data-test="multicast-state" />
            <span v-else-if="l.state" class="mc__state muted" data-test="multicast-state">{{ stateText(l) }}</span>
            <span v-else-if="l.ok === false" class="mc__state issues-error" data-test="multicast-refused">{{ t('multicast.refused', { topic: l.title || l.task_id, reason: l.error }) }}</span>
            <button v-if="phase === 'compose'" type="button" class="btn ghost mc__remove" data-test="multicast-remove" :aria-label="t('multicast.remove', { title: l.title || l.task_id })" :title="t('multicast.remove', { title: l.title || l.task_id })" @click="remove(l.task_id)">
              <UiIcon name="x" :size="16" />
            </button>
          </li>
        </ul>
      </section>
      <p v-if="checkError && checkError !== 'multicast_none'" class="mc__note issues-error" role="status" data-test="multicast-check-error">{{ checkDetail || checkError }}</p>
      </div>
      <div v-else class="mc__part" data-test="multicast-prompt">
      <template v-if="phase === 'compose'">
        <p class="mc__note" data-test="multicast-send-label">{{ t('multicast.send', { n: count }) }}</p>
        <div class="mc__composer" data-test="multicast-composer" @input="onInput">
          <MessageComposer :dock="false" :busy="!canSend" :placeholder="t('multicast.send', { n: count })" @send="onSend" @ready="box = $event" />
        </div>
      </template>
      <template v-else>
        <blockquote class="mc__text" data-test="multicast-text">{{ sentText }}</blockquote>
        <p v-if="sentCount" class="mc__note muted" role="status" data-test="multicast-sent">{{ t('multicast.sent', { n: sentCount }) }}</p>
        <button v-if="phase === 'failed'" type="button" class="btn mc__retry" data-test="multicast-retry" @click="retry()">{{ t('multicast.retry') }}</button>
      </template>
      </div>
      </template>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useMulticastSend, type McLine } from '~/composables/useMulticastSend'
import { useViewPrefs } from '~/composables/useViewPrefs'

const { t } = useI18n({ useScope: 'global' })
const { open, lines, phase, count, canSend, checkError, checkDetail, sentText, setBody, remove, send, retry, close } = useMulticastSend()
/* owner HUM-10, t1 c9b86153: the prompt sits at the targets' newest end, read live from
   Settings -> Behaviour "Message order" (newest first = on top). Keyed parts: the DOM, so
   the tab order, follows, and a flip moves the composer without remounting it */
const { newestLast } = useViewPrefs()
const parts = computed(() => (newestLast.value ? ['targets', 'prompt'] : ['prompt', 'targets']))
/* the dialog composer's own box: a send the final check refused puts the text back */
const box = ref<{ setText: (s: string) => void } | null>(null)

const groups = computed(() => {
  const by = new Map<string, McLine[]>()
  for (const l of lines.value) by.set(l.channel, [...(by.get(l.channel) || []), l])
  return [...by].map(([channel, ls]) => ({ channel, lines: ls }))
})
const sentCount = computed(() => lines.value.filter((l) => l.state === 'sent').length)

/* a sent row shows a check mark; the count line under the list says it in words (7.1.4 has no one-topic key) */
function stateText(l: McLine): string {
  if (l.state === 'waiting') return t('composer.waiting_network')
  if (l.state === 'failed') return t('multicast.refused', { topic: l.title || l.task_id, reason: l.error })
  return t('composer.sending')
}

/* the composer's field is its own; its input events bubble here, so the check reads the text (4.1, debounced) */
function onInput(ev: Event) {
  const el = ev.target as HTMLTextAreaElement | null
  if (el && el.tagName === 'TEXTAREA') setBody(el.value)
}

/* the composer emptied its box on emit: back it comes when nothing was sent */
async function onSend(text: string, _topic?: string, files?: File[]) {
  await send(text, files)
  if (phase.value === 'compose') box.value?.setText(text)
}
</script>

<style scoped>
.mc { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.5rem 1rem 1rem; min-height: 0; }
.mc__part { display: flex; flex-direction: column; gap: 0.5rem; min-height: 0; }
.mc__group { display: flex; flex-direction: column; gap: 0.25rem; }
.mc__channel { margin: 0; font-size: 0.875rem; color: var(--color-muted); }
.mc__list { list-style: none; margin: 0; padding: 0; overflow-y: auto; max-height: min(40vh, 20rem); }
.mc__row { display: flex; align-items: center; gap: 0.5rem; min-height: 2.5rem; padding: 0 0.25rem; }
.mc__title { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mc__state { flex: 0 1 auto; font-size: 0.8125rem; }
.mc__remove { flex: 0 0 auto; min-width: var(--tap, 44px); min-height: var(--tap, 44px); justify-content: center; padding: 0; }
.mc__note { margin: 0; font-size: 0.875rem; }
.mc__text { margin: 0; padding: 0.5rem 0.75rem; border-inline-start: 3px solid var(--color-border); white-space: pre-wrap; overflow-wrap: anywhere; }
.mc__retry { align-self: flex-start; }
</style>
