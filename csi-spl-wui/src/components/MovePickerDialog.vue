<!-- SPL-1024 (specs/045 §3.1 / §3.2): the keyboard and touch way to move.
     Move to channel… lists the channels the viewer may post in (the current
     one, the lobby and `issues` left out); Move to topic… lists the topics of
     those channels, newest first, with a filter. Picking a row moves at once
     (the toast offers Undo). Loaded lazily (LazyMovePickerDialog): only once
     the menu entry is picked. UiDialog owns focus, Escape, the phone full
     screen and the Back overlay (SPL-993 / SPL-994). -->
<template>
  <UiDialog :open="open" :title="title" size="md" @update:open="emit('update:open', $event)">
    <div class="move-picker" :data-testid="`move-picker-${mode}`">
      <input
        v-model="query"
        class="move-picker__filter"
        type="search"
        data-autofocus
        data-testid="move-picker-filter"
        autocomplete="off"
        :placeholder="t('feed.move.filter')"
        :aria-label="t('feed.move.filter')"
        @keydown.enter.prevent="pickFirst"
      >
      <p v-if="loading" class="muted move-picker__empty">{{ t('common.loading') }}</p>
      <p v-else-if="!rows.length" class="muted move-picker__empty" data-testid="move-picker-empty">
        {{ mode === 'channel' ? t('feed.move.no_channels') : t('feed.move.no_topics') }}
      </p>
      <ul v-else class="move-picker__list">
        <li v-for="row in rows" :key="row.id">
          <button
            type="button"
            class="move-picker__row"
            data-testid="move-picker-row"
            :data-target="row.id"
            :disabled="busy"
            @click="pick(row)"
          >
            <span v-if="mode === 'channel'" class="move-picker__hash" aria-hidden="true">#</span>
            <span class="move-picker__label">{{ row.label }}</span>
            <span v-if="row.hint" class="muted move-picker__hint">{{ row.hint }}</span>
          </button>
        </li>
      </ul>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useMove } from '~/composables/useMove'
import { useChannelStore } from '~/stores/channel'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { moveChannelTargets, moveTopicChoices } from '~/utils/move-apply.mjs'
import { topicOpening } from '~/utils/view-api.mjs'
import type { SpoolMessage } from '~/types/spool'

type Row = { id: string, label: string, hint: string }

const props = defineProps<{
  open: boolean
  /** 714c7028: 'merge' lists topics like 'topic', but a pick opens the merge confirm */
  mode: 'channel' | 'topic' | 'merge'
  msg: SpoolMessage
  /** the topic the reply is in now (topic mode): never offered */
  topicTask?: string
}>()
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const live = useLive()
const move = useMove()
const channel = useChannelStore()
const query = ref('')
const loading = ref(false)
const busy = ref(false)
const topics = ref<{ task_id: string, channel?: string | null, subject?: string, last_ts?: string }[]>([])

const title = computed(() => t(props.mode === 'channel' ? 'feed.move.channel_title' : props.mode === 'merge' ? 'feed.merge.pick_title' : 'feed.move.topic_title'))

/* the cards of the channel on screen are known at once; the hub's topic list adds the rest */
const heldCards = computed(() => channel.newestFirst.map((m) => ({
  task_id: String(m.task_id || ''),
  channel: m.channel || channel.active || '',
  subject: topicOpening(String(m.body || '')),
  last_ts: String((m as { last_ts?: string }).last_ts || m.received_at || m.ts || ''),
})))

const rows = computed<Row[]>(() => {
  const q = query.value.trim().toLowerCase()
  if (props.mode === 'channel') {
    return moveChannelTargets(channel.channels, props.msg.channel || channel.active || '')
      .filter((c) => !q || c.channel_id.includes(q) || c.name.toLowerCase().includes(q))
      .map((c) => ({ id: c.channel_id, label: c.name, hint: '' }))
  }
  // In merge mode the source is a topic card: never offer its own topic.
  const exclude = [props.topicTask || '', String(props.msg.task_id || ''), String(props.msg.msg_id || '')]
  return moveTopicChoices([...heldCards.value, ...topics.value], {
    channels: channel.channels,
    exclude,
    query: q,
    lobbyTaskId: live.lobbyTaskId.value,
  }).map((r) => ({ id: r.task_id, label: r.title || r.task_id, hint: '#' + r.channel }))
})

async function load() {
  if (props.mode === 'channel') return
  loading.value = true
  try {
    const page = await withSessionRetry(api, () => api.listTopics({ limit: 50 }))
    topics.value = page.topics
  } catch {
    /* the held cards still list */
  } finally {
    loading.value = false
  }
}
onMounted(() => { if (props.open) void load() })
watch(() => props.open, (v) => { if (v) void load() })

/* Closes the dialog BEFORE the move runs (the emit below), so the picker is
   already gone while the move is in flight; `busy` only guards a double pick. */
async function pick(row: Row) {
  if (busy.value) return
  busy.value = true
  try {
    emit('update:open', false)
    const id = String(props.msg.msg_id || '')
    if (props.mode === 'channel') await move.run({ kind: 'topic', msgId: id, toChannel: row.id })
    else if (props.mode === 'merge') move.askMerge({ msgId: id, toTask: row.id, sourceTitle: '', targetTitle: row.label })
    else await move.run({ kind: 'message', msgId: id, toTask: row.id }, row.label)
  } finally {
    busy.value = false
  }
}

function pickFirst() {
  const first = rows.value[0]
  if (first) void pick(first)
}
</script>

<style scoped>
.move-picker { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.5rem 1rem 1rem; min-height: 0; }
.move-picker__filter {
  width: 100%;
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
}
.move-picker__empty { margin: 0.5rem 0; }
.move-picker__list { list-style: none; margin: 0; padding: 0; overflow-y: auto; max-height: min(60vh, 28rem); }
.move-picker__row {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
  width: 100%;
  min-height: 2.5rem;
  padding: 0.5rem 0.75rem;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.move-picker__row:hover { background: var(--color-surface-hover); }
.move-picker__hash { color: var(--color-muted); }
.move-picker__label { min-width: 0; flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.move-picker__hint { flex: none; font-size: 0.75rem; }
</style>
