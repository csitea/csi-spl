<!-- t1 8fb802cd (owner: "If a topic is archived it should be clearly marked
     as archived"): the archive glyph and the word, wherever an archived topic
     still renders (the topic pane's header, a topic row). The full stamp is
     the hover title; the word is never icon-only, so a phone shows it too.
     t1 64ce816a: the open topic header also prints the archive day
     (show-when). A row stays the word plus the hover title.
     SPL-1763 (owner HUM-10, t1 0bb05176: "whenever one clicks on the
     "Archived" label, that label is a button which will unarchive the topic
     ... And on mobile first"): given its topic (task-id), the badge asks the
     hub whether this viewer may unarchive it (utils/archived-card.mjs, lazy)
     and, on a yes, is that button, named "Unarchive topic". Everyone else
     keeps the plain label. Same box either way, so the header never jumps;
     the 44 px tap area is an invisible ::after around it. -->
<template>
  <component
    :is="canUnarchive ? 'button' : 'span'"
    class="archived-badge"
    :class="{ 'archived-badge--when': showWhen && date, 'archived-badge--btn': canUnarchive }"
    data-test="archived-badge"
    :type="canUnarchive ? 'button' : undefined"
    :disabled="canUnarchive && busy ? true : undefined"
    :aria-label="canUnarchive ? t('archive.unarchive_topic') : undefined"
    :title="title"
    @click="canUnarchive && unarchive()"
  >
    <UiIcon name="archive" :size="12" :stroke-width="2" />
    <span class="archived-badge__label">{{ t('archive.badge') }}</span>
    <span v-if="showWhen && date" class="archived-badge__when" dir="ltr">{{ date }}</span>
  </component>
</template>

<script setup lang="ts">
import { isoDate, isoDateTime } from '~/utils/date-iso.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
/* static: both already ride the entry; a dynamic import() of a module the
   entry holds makes the build add its export table to the entry (initial JS) */
import { noteError } from '~/composables/errorJournal.mjs'
import { topicErrorKey } from '~/utils/topic-archive.mjs'

/* taskId: the archived topic; omitted = the label only (no hub probe) */
const props = defineProps<{ at?: string | null, showWhen?: boolean, taskId?: string }>()
const emit = defineEmits<{ unarchived: [] }>()
const { t } = useI18n({ useScope: 'global' })
const when = computed(() => (props.at ? isoDateTime(props.at) : ''))
const date = computed(() => (props.showWhen && props.at ? isoDate(props.at) : ''))

const api = useSpoolApi()
const live = useLive()
const card = shallowRef<{ msgId: string, canUnarchive: boolean } | null>(null)
const busy = ref(false)
const canUnarchive = computed(() => Boolean(card.value?.canUnarchive))
const title = computed(() => {
  const stamp = when.value ? t('archive.archived_at', { when: when.value }) : ''
  if (!canUnarchive.value) return stamp || undefined
  return stamp ? `${stamp} · ${t('archive.unarchive_topic')}` : t('archive.unarchive_topic')
})

let mod: Promise<typeof import('~/utils/archived-card')> | null = null
const lazy = () => (mod ||= import('~/utils/archived-card'))

watch(() => [props.taskId, props.at] as const, async ([task, at]) => {
  card.value = null
  if (!import.meta.client || !task || !at) return
  const got = await (await lazy()).archivedCardOf(api, task, live.lobbyTaskId.value)
  if (props.taskId === task && props.at === at) card.value = got
}, { immediate: true })

async function unarchive() {
  const c = card.value
  if (!c || busy.value) return
  busy.value = true
  try {
    /* the client fires spool:topic-archived (archived: false); onEvent below emits */
    await api.archiveTopic(c.msgId, false)
    card.value = null
    /* the card comes back to this tab's feeds and topic lists, as Undo does */
    void import('~/composables/useArchiveUndo').then((m) => m.rereadFeeds())
  } catch (e) {
    noteError({ source: 'archived-badge', name: 'ArchivedBadge', message: t(topicErrorKey(e, 'archive')), error: e })
  } finally {
    busy.value = false
  }
}

/* Any badge on this topic (the pane header, the DM header) hears the
   unarchive, whichever one was tapped, and tells its view to drop the mark. */
function onEvent(ev: Event) {
  const task = props.taskId
  if (!task) return
  void lazy().then((m) => { if (m.unarchivedTopic((ev as CustomEvent).detail, task)) emit('unarchived') })
}
onMounted(() => window.addEventListener('spool:topic-archived', onEvent))
onUnmounted(() => window.removeEventListener('spool:topic-archived', onEvent))
</script>

<style scoped>
.archived-badge {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  flex: none;
  padding: 1px 6px;
  border: 1px solid var(--color-warn);
  border-radius: var(--radius-pill);
  color: var(--color-warn);
  font-size: 0.625rem;
  font-weight: 600;
  letter-spacing: 0.06em;
  line-height: 1.4;
  text-transform: uppercase;
  white-space: nowrap;
  vertical-align: middle;
}
/* The day sits under the word, so the badge stays about as wide as the
   word alone. The title beside it keeps its room in the 380px pane and
   on a phone. The header itself stays one row (the pane CSS). */
.archived-badge--when {
  display: inline-grid;
  grid-template-columns: auto auto;
  column-gap: 3px;
  row-gap: 0;
  align-items: center;
  line-height: 1.2;
}
.archived-badge__when {
  grid-column: 1 / -1;
  letter-spacing: 0;
  text-transform: none;
}
/* SPL-1763: the button keeps the label's box (font, margin, background reset)
   so the header does not move when the hub's answer turns it into one. The
   tap area is at least 44 x 44 px, centred on it, without growing the box. */
.archived-badge--btn {
  position: relative;
  margin: 0;
  background: transparent;
  font-family: inherit;
  cursor: pointer;
}
.archived-badge--btn::after {
  content: '';
  position: absolute;
  left: 50%;
  top: 50%;
  width: max(100%, var(--tap, 44px));
  height: max(100%, var(--tap, 44px));
  transform: translate(-50%, -50%);
}
.archived-badge--btn:hover { background: color-mix(in srgb, var(--color-warn) 12%, transparent); }
.archived-badge--btn:focus-visible { outline: 2px solid var(--color-accent, currentColor); outline-offset: 2px; }
.archived-badge--btn:disabled { cursor: progress; opacity: 0.6; }
</style>
