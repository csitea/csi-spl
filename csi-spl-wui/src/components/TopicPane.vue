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
      <!-- SPL-1133: the X at the chosen corner (Mac = here, the default) -->
      <UiCloseButton side="start" class="icon-btn topic-close" data-test="topic-pane-close" @click="topic.close()" />
      <strong class="topic-heading__title" :class="{ 'is-archived': archivedAt }" data-test="topic-heading" data-selected="true" aria-current="true" :title="heading"><span v-if="titleText" class="topic-heading__label">{{ t('topic.list_title', { text: '' }) }}</span><span class="topic-heading__text">{{ titleText || t('topic.title') }}</span></strong>
      <ArchivedBadge v-if="archivedAt" :at="archivedAt" :show-when="true" :task-id="topic.parentTaskId || ''" @unarchived="archivedAt = ''" />
      <!-- SPL-2807: the slot holds the lazy control's box, so the title does not jump when it mounts -->
      <span class="clip-slot"><LazyCardClipControl pane="thread" /></span>
      <UiCloseButton side="end" class="icon-btn topic-close" data-test="topic-pane-close" @click="topic.close()" />
    </header>
    <!-- Topic c6994436: newest last puts the new-topic cards under the feed,
         at the newest end of the pane. -->
    <BornTopics v-if="!newestLast" />
    <div class="pinned-root feed-body" data-test="topic-root">
      <!-- SPL-1839: one plain sentence + Try again; the technical part only with the Debug pane on (own box: a bare lazy v-if threw insertBefore in #lobby) -->
      <div v-if="loadError" class="plain-err-slot">
        <LazyPlainErrorNotice :message="loadError" :error="loadErr" retry source="topic" test-id="topic-error" @retry="retryTick++" />
      </div>
      <LiveFeed
        clip
        clip-pane="thread"
        hold-scroll
        topic-card-menu
        :label="t('topic.replies_label')"
        :rows="messages"
        :has-older="hasOlder"
        :loading="loading"
        :failed="!!loadError"
        :loading-older="loadingOlder"
        :search="search"
        :last-live="lastLive"
        :last-msg-id="latestId"
        :empty-text="t('topic.empty')"
        :since-ms="sinceMs"
        :unread-boundary="unreadBoundary"
        @older="loadOlder"
        @clear-search="search = ''"
        @edited="onEdited"
        @deleted="onDeleted"
        @reacted="onReacted"
        :move-ctx="moveCtx"
      />
    </div>
    <BornTopics v-if="newestLast" />
    <!-- 050: the thread panel's collapse triangle, bottom corner. Distinct from
         the header X: the X closes the topic, this collapses it to a strip and
         keeps it loaded. A DIRECT child of .topic so the collapse CSS hides its
         siblings and keeps only this strip. -->
    <PaneCollapseToggle pane="threads" />
  </aside>
</template>

<script setup lang="ts">
import { useTopicStore } from '~/stores/topic'
import { useNotificationStore } from '~/stores/notification'
import { useChannelStore } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { matchesSearch, mergeById, newestFirst, withoutMsg } from '~/utils/feed.mjs'
import { rowsForRightPane } from '~/utils/channel-feed.mjs'
import { topicTitleFromRows } from '~/utils/view-api.mjs'
import { plainText } from '~/utils/plain-text.mjs'
import { topicKey } from '~/utils/read-cursor.mjs'
import { latestMessageId } from '~/utils/topic-archive.mjs'
import { applyEdit } from '~/utils/msg-edit.mjs'
import { applyReactions as patchReactions } from '~/utils/emoji.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { onDeleteRestore } from '~/composables/useDeleteUndo'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { useMove } from '~/composables/useMove'
import { useTopicPaneRead } from '~/composables/useTopicPaneRead'
import { POLL_ROWS } from '~/utils/poll-fence.mjs'
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'

const topic = useTopicStore()
/* SPL-2430 (owner, t1 89010926): the "new" divider before the first unseen
   reply, from the topic's mark as the open found it (topic.openTarget) */
const notes = useNotificationStore()
const unreadBoundary = computed(() => notes.boundary[topicKey(topic.parentTaskId || '')] || null)
const { newestLast } = useViewPrefs()
const { onTopicPaneClick } = useTopicPaneClick()
const sinceMs = useNowTick(() => topic.open)
const channel = useChannelStore()
const api = useSpoolApi()
const { t } = useI18n({ useScope: 'global' })

/* the topic read and paging (first page, Load more, catch-up, #<msg_id>): composables/useTopicPaneRead.ts */
const {
  liveRows, loadError, loadErr, retryTick, loading, search, lastLive,
  loadingOlder, oldestRow, archivedAt, hasOlder, catchUp, loadOlder,
} = useTopicPaneRead({ topic, api, t })
/* A reply with is_parent 0 lives in the channel store as well as here.
   Keep it on this pane after the send stops being pending. */
const paneRows = computed(() => {
  const mockRows = liveRows.value.length ? mergeById(topic.messages, liveRows.value).rows : topic.messages
  return (api.mock ? mockRows : rowsForRightPane(liveRows.value, channel.messages, topic.parentTaskId || '')) as SpoolMessage[]
})
const messages = computed(() => newestFirst(paneRows.value.filter((m) => matchesSearch(m, search.value))) as SpoolMessage[])
/* SPL-1637: a ```poll form in this topic reads its answers from these replies */
provide(POLL_ROWS, () => paneRows.value)
/* HUM-10: the topic's latest message offers Archive topic, a search or not */
const latestId = computed(() => latestMessageId(paneRows.value))
/* The open topic's own title, selected at the top of this pane. */
const titleText = computed(() => {
  const rows = (api.mock ? topic.messages : liveRows.value) as SpoolMessage[]
  const subject = topicTitleFromRows(oldestRow.value ? [oldestRow.value, ...rows] : rows, topic.rootMsg)
  return plainText(subject)
})
const heading = computed(() => (titleText.value ? t('topic.list_title', { text: titleText.value }) : t('topic.title')))

/*
 * SPL-1024: a reply of a channel topic may be moved to another topic (drag
 * it onto a middle card, or its menu's Move to topic…). A DM pane offers
 * nothing. This pane reads its rows into a ref of its own, so a move is
 * applied here too: a reply that left the open topic goes, a topic that
 * gained one is read again. With no channel page behind it (the /t/ topic
 * browser, a DM) each row's own channel decides: a DM row moves only when an
 * agent sent it to the viewer, out to a channel topic (move.mjs; owner, t1
 * ffc3b83c).
 */
const moveCtx = computed(() => ({
  channel: channel.peer ? '' : channel.active || '',
  opener: String(topic.target?.rootMsgId || ''),
  topic: String(topic.parentTaskId || ''),
}))
const offMoved = useMove().onMoved((f, m) => {
  const id = String(topic.parentTaskId || '')
  // 714c7028: a merge / unmerge touching this pane's topic re-reads it (the rows
  // changed task in one transaction; a hand-patch would drift).
  const mf = m.mergeFrame(f)
  if (mf) {
    if (id && (mf.task_id === id || mf.from_task === id)) void catchUp()
    return
  }
  let rows = m.applyMoveRows(liveRows.value, f) as SpoolMessage[]
  const gone = m.moveLeavesTask(f, id)
  if (gone.length) rows = rows.filter((r) => !gone.includes(String(r.msg_id || '')))
  if (rows !== liveRows.value) liveRows.value = rows
  if (m.moveJoinsTask(f, id)) void catchUp()
})
onUnmounted(() => offMoved())

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
/* CLE-77840: Undo of a Delete-key delete hands the row back to this pane's own rows */
const offRestore = onDeleteRestore((row) => {
  if (String(row.task_id || '') !== String(topic.parentTaskId || '')) return
  liveRows.value = mergeById(liveRows.value, [row]).rows as SpoolMessage[]
})
onUnmounted(() => offRestore())

if (import.meta.client && !api.mock) {
  const liveEdits = useLive()
  const offEdited = liveEdits.onEdited((m) => onEdited(m as unknown as SpoolMessage))
  const offDeleted = liveEdits.onDeleted((m) => onDeleted(m as { msg_id?: string }))
  const offReaction = liveEdits.onReaction((m) => onReacted(m as unknown as ReactionUpdate))
  onUnmounted(() => { offEdited(); offDeleted(); offReaction() })
}
</script>
