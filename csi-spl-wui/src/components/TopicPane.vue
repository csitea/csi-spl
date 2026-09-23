<template>
  <aside v-if="topic.open" class="topic live-pane" data-test="topic-section" data-section="channel" :aria-label="t('topic.title')">
    <header>
      <strong>{{ t('topic.title') }}</strong>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-width:0">
        <VerbositySelector />
        <button
          class="icon-btn"
          type="button"
          data-test="topic-pane-close"
          :aria-label="t('common.close')"
          :title="t('common.close')"
          @click="topic.close()"
        >
          <UiIcon name="x" :size="18" />
        </button>
      </div>
    </header>
    <BornTopics />
    <div class="pinned-root" data-test="topic-root">
      <MessageCard v-if="root" :key="String(root.msg_id || '')" :msg="root" :since-ms="sinceMs" :editable="canEdit(root)" @edited="onEdited" />
      <p v-else-if="!loading && !loadError" class="muted">{{ t('topic.empty') }}</p>
    </div>
    <div class="feed-body">
      <ErrorNotice v-if="loadError" :message="loadError" source="topic" test-id="topic-error" />
      <LiveFeed
        :label="t('topic.replies_label')"
        :rows="replies"
        :has-older="false"
        :loading="loading"
        :search="search"
        :last-live="lastLive"
        :empty-text="t('topic.no_replies')"
        :since-ms="sinceMs"
        @clear-search="search = ''"
        @edited="onEdited"
      />
    </div>
  </aside>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useTopicStore } from '~/stores/topic'
import { useChannelStore } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { matchesSearch, mergeById, rootAndReplies } from '~/utils/feed.mjs'
import { applyVerbosity } from '~/utils/verbosity.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { applyEdit } from '~/utils/msg-edit.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'

const topic = useTopicStore()
const sinceMs = useNowTick(() => topic.open)
const channel = useChannelStore()
const api = useSpoolApi()
const { t } = useI18n({ useScope: 'global' })

/*
 * Live: a channel / DM feed row is a topic root only (view-v1 §4.3), so the
 * replies come from GET /v1/view/topics/{task_id} and then the WS frames.
 * 013 (X3): pinned root, replies newest first. The reply box is the top
 * Omnibox, not a second field in this pane.
 */
const liveRows = ref<SpoolMessage[]>([])
const loadError = ref('')
const loading = ref(false)
const search = ref('')
const lastLive = ref<SpoolMessage | null>(null)
/* 013 US7 FR-013: our own reply shows at once (the channel store holds it pending until the echo) */
const pendingHere = computed(() => channel.messages.filter((m) => m.pending && m.task_id === topic.parentTaskId) as SpoolMessage[])
const split = computed(() => rootAndReplies((api.mock ? topic.messages : mergeById(liveRows.value, pendingHere.value).rows) as SpoolMessage[]))
/* CLE-3427: a topic opened on a message that is not the task's oldest (or
   on a task the hub has no messages for yet) shows the row that was clicked
   as its root — topic.rootMsg — instead of the empty line. */
const root = computed(() => split.value.root || topic.rootMsg)
const replies = computed(() => {
  const rows = split.value.replies.filter((m: SpoolMessage) => matchesSearch(m, search.value))
  return (api.mock ? rows : applyVerbosity(rows, topic.verbosity)) as SpoolMessage[]
})

/** 013 US7 FR-015: after a reconnect, re-read the topic and merge it by msg_id. */
async function catchUp() {
  const id = topic.parentTaskId
  if (api.mock || !topic.open || !id) return
  try {
    const data = await withSessionRetry(api, () => api.getTopic(id)) as { messages?: SpoolMessage[] }
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
  if (api.mock || !open || !id) return
  loading.value = true
  try {
    const data = await withSessionRetry(api, () => api.getTopic(id)) as { messages?: SpoolMessage[] }
    if (topic.parentTaskId === id) liveRows.value = data.messages || []
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : t('topic.load_failed')
  } finally {
    loading.value = false
  }
}, { immediate: true })

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
 * CLE-3445 — an edit landed (here, or in another session via a
 * `message_edited` frame). This pane reads its own rows, so it patches its
 * own copy; the channel store holds the same message in the feed behind the
 * pane and is told too, or closing the pane would show the old body again.
 */
const { canEdit, applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  /* this pane reads its replies into a ref of its own, so it patches that
     itself and then hands the row to every store that may also hold it */
  liveRows.value = applyEdit(liveRows.value, row) as SpoolMessage[]
  applyEverywhere(row)
}

if (import.meta.client && !api.mock) {
  const liveEdits = useLive()
  const offEdited = liveEdits.onEdited((m) => onEdited(m as unknown as SpoolMessage))
  onUnmounted(() => { offEdited() })
}
</script>
