<template>
  <aside
    v-if="topic.open"
    class="topic live-pane"
    :class="{ selected: topic.paneSelected }"
    data-pane="topic"
    data-test="topic-section"
    data-section="channel"
    :data-selected="topic.paneSelected ? 'true' : undefined"
    :aria-label="heading"
    @click="onTopicPaneClick"
  >
    <!-- Owner 2026-09-26 (prd topic b8cbfbe1): one row - the X first, then the
         title on one line, cut with an ellipsis (full title on hover). SPL-945:
         the replies' height control at the right edge; lazy, so the shell's
         initial chunk does not grow. -->
    <header>
      <!-- SPL-989: on a phone the chevron is Back (level 3 -> 2); the X hides -->
      <MobileBack />
      <button
        class="icon-btn topic-close"
        type="button"
        data-test="topic-pane-close"
        :aria-label="t('common.close')"
        :title="t('common.close')"
        @click="topic.close()"
      >
        <UiIcon name="x" :size="18" />
      </button>
      <strong class="topic-heading__title" data-test="topic-heading" data-selected="true" aria-current="true" :title="heading">{{ heading }}</strong>
      <LazyCardClipControl pane="thread" />
    </header>
    <!-- Topic c6994436: newest last puts the new-topic cards under the feed,
         at the newest end of the pane. -->
    <BornTopics v-if="!newestLast" />
    <div class="pinned-root feed-body" data-test="topic-root">
      <ErrorNotice v-if="loadError" :message="loadError" source="topic" test-id="topic-error" />
      <LiveFeed
        clip
        clip-pane="thread"
        hold-scroll
        :label="t('topic.replies_label')"
        :rows="messages"
        :has-older="hasOlder"
        :loading="loading"
        :loading-older="loadingOlder"
        :search="search"
        :last-live="lastLive"
        :empty-text="t('topic.empty')"
        :since-ms="sinceMs"
        @older="loadOlder"
        @clear-search="search = ''"
        @edited="onEdited"
        @deleted="onDeleted"
        @reacted="onReacted"
        :move-ctx="moveCtx"
      />
    </div>
    <BornTopics v-if="newestLast" />
  </aside>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useTopicStore } from '~/stores/topic'
import { WINDOW, useChannelStore } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { matchesSearch, mergeById, newestFirst, withoutMsg } from '~/utils/feed.mjs'
import { rowsForRightPane } from '~/utils/channel-feed.mjs'
import { topicTitleFromRows } from '~/utils/view-api.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { applyEdit } from '~/utils/msg-edit.mjs'
import { applyReactions as patchReactions } from '~/utils/emoji.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { useMove } from '~/composables/useMove'
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'

const topic = useTopicStore()
const { newestLast } = useViewPrefs()
const { onTopicPaneClick } = useTopicPaneClick()
const sinceMs = useNowTick(() => topic.open)
const channel = useChannelStore()
const api = useSpoolApi()
const { t } = useI18n({ useScope: 'global' })

/*
 * Live: a channel / DM feed row is a topic root only (view-v1 §4.3), so the
 * replies come from GET /v1/view/topics/{task_id} and then the WS frames.
 * Messages prepend at the top: the newest is the first row, and a message
 * that just arrived sorts above the ones already there. The reply box is
 * the top Omnibox, not a second field in this pane.
 * The newest WINDOW (30) replies come first (order=desc); Load more reads the
 * next 30 older ones with before=<next>, so a long topic is never cut off.
 */
const liveRows = ref<SpoolMessage[]>([])
const loadError = ref('')
const loading = ref(false)
const search = ref('')
const lastLive = ref<SpoolMessage | null>(null)
const olderCursor = ref<string | null>(null)
const loadingOlder = ref(false)
/* The topic's first message, for the heading, when the newest page does not reach it. */
const oldestRow = ref<SpoolMessage | null>(null)
const hasOlder = computed(() => !api.mock && Boolean(olderCursor.value))
/* A reply with is_parent 0 lives in the channel store as well as here.
   Keep it on this pane after the send stops being pending. */
const messages = computed(() => {
  const base = (api.mock ? topic.messages : rowsForRightPane(liveRows.value, channel.messages, topic.parentTaskId || '')) as SpoolMessage[]
  return newestFirst(base.filter((m) => matchesSearch(m, search.value))) as SpoolMessage[]
})
/* The open topic's own title, selected at the top of this pane. */
const heading = computed(() => {
  const rows = (api.mock ? topic.messages : liveRows.value) as SpoolMessage[]
  const text = topicTitleFromRows(oldestRow.value ? [oldestRow.value, ...rows] : rows, topic.rootMsg)
  return text ? t('topic.list_title', { text }) : t('topic.title')
})

/*
 * SPL-1024: a reply of a channel topic may be moved to another topic (drag
 * it onto a middle card, or its menu's Move to topic…). A DM pane offers
 * nothing. This pane reads its rows into a ref of its own, so a move is
 * applied here too: a reply that left the open topic goes, a topic that
 * gained one is read again.
 */
const moveCtx = computed(() => (channel.active && !channel.peer
  ? { channel: channel.active, opener: String(topic.target?.rootMsgId || ''), topic: String(topic.parentTaskId || '') }
  : null))
const offMoved = useMove().onMoved((f, m) => {
  const id = String(topic.parentTaskId || '')
  let rows = m.applyMoveRows(liveRows.value, f) as SpoolMessage[]
  const gone = m.moveLeavesTask(f, id)
  if (gone.length) rows = rows.filter((r) => !gone.includes(String(r.msg_id || '')))
  if (rows !== liveRows.value) liveRows.value = rows
  if (m.moveJoinsTask(f, id)) void catchUp()
})
onUnmounted(() => offMoved())

/** 013 US7 FR-015: after a reconnect, re-read the topic and merge it by msg_id. */
async function catchUp() {
  const id = topic.parentTaskId
  if (api.mock || !topic.open || !id) return
  try {
    const data = await withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: 50 })) as { messages?: SpoolMessage[] }
    if (topic.parentTaskId === id) liveRows.value = mergeById(liveRows.value, data.messages || []).rows as SpoolMessage[]
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : t('topic.load_failed')
  }
}

watch(() => [topic.open, topic.parentTaskId] as const, async ([open, id]) => {
  liveRows.value = []
  loadError.value = ''
  search.value = ''
  lastLive.value = null
  olderCursor.value = null
  oldestRow.value = null
  if (api.mock || !open || !id) return
  loading.value = true
  try {
    const data = await withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: WINDOW })) as { messages?: SpoolMessage[], next?: string | null }
    if (topic.parentTaskId !== id) return
    liveRows.value = data.messages || []
    olderCursor.value = data.next || null
    if (olderCursor.value && !topic.rootMsg) void loadOldestRow(id)
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : t('topic.load_failed')
  } finally {
    loading.value = false
  }
}, { immediate: true })

/** Load more: the next WINDOW older replies (before=<next>), merged by msg_id. */
async function loadOlder() {
  const id = topic.parentTaskId
  if (api.mock || !id || !olderCursor.value || loadingOlder.value) return
  loadingOlder.value = true
  try {
    const data = await withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: WINDOW, before: olderCursor.value || undefined })) as { messages?: SpoolMessage[], next?: string | null }
    if (topic.parentTaskId !== id) return
    liveRows.value = mergeById(liveRows.value, data.messages || []).rows as SpoolMessage[]
    olderCursor.value = data.next || null
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : t('feed.error.load_older_failed')
    olderCursor.value = null
  } finally {
    loadingOlder.value = false
  }
}

async function loadOldestRow(id: string) {
  try {
    const data = await withSessionRetry(api, () => api.getTopic(id, { limit: 1 })) as { messages?: SpoolMessage[] }
    if (topic.parentTaskId === id) oldestRow.value = (data.messages || [])[0] || null
  } catch {
    /* the heading falls back to the oldest row held */
  }
}

if (import.meta.client && !api.mock) {
  const live = useLive()
  const off = live.onMessage((m) => {
    const row = m as unknown as SpoolMessage
    const id = topic.parentTaskId
    if (!id || (row.task_id !== id && row.parent_task_id !== id)) return
    if (liveRows.value.some((r) => r.msg_id === row.msg_id)) return
    liveRows.value = [...liveRows.value, row]
    lastLive.value = row
  })
  const offReconnect = live.onReconnected(() => { void catchUp() })
  onUnmounted(() => { off(); offReconnect() })
}

/*
 * an edit landed (here, or in another session via a
 * `message_edited` frame). This pane reads its own rows, so it patches its
 * own copy; the channel store holds the same message in the feed behind the
 * pane and is told too, or closing the pane would show the old body again.
 */
const { applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  /* this pane reads its replies into a ref of its own, so it patches that
     itself and then hands the row to every store that may also hold it */
  liveRows.value = applyEdit(liveRows.value, row) as SpoolMessage[]
  applyEverywhere(row)
}

/** This pane's own copy. The card already told the stores. */
function onReacted(update: ReactionUpdate) {
  liveRows.value = patchReactions(liveRows.value, update) as SpoolMessage[]
}

/** This pane's own copy of the thread. The stores are dropped separately. */
function onDeleted(row: { msg_id?: string }) {
  liveRows.value = withoutMsg(liveRows.value, String(row?.msg_id || '')) as SpoolMessage[]
}

if (import.meta.client && !api.mock) {
  const liveEdits = useLive()
  const offEdited = liveEdits.onEdited((m) => onEdited(m as unknown as SpoolMessage))
  const offDeleted = liveEdits.onDeleted((m) => onDeleted(m as { msg_id?: string }))
  const offReaction = liveEdits.onReaction((m) => onReacted(m as unknown as ReactionUpdate))
  onUnmounted(() => { offEdited(); offDeleted(); offReaction() })
}
</script>
