<template>
  <aside v-if="thread.open" class="thread live-pane" data-test="thread-section" data-section="channel" :aria-label="t('thread.title')">
    <header>
      <strong>{{ t('thread.title') }}</strong>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-width:0">
        <VerbositySelector />
        <button
          class="icon-btn"
          type="button"
          data-test="thread-pane-close"
          :aria-label="t('common.close')"
          :title="t('common.close')"
          @click="thread.close()"
        >
          <UiIcon name="x" :size="18" />
        </button>
      </div>
    </header>
    <div class="pinned-root" data-test="thread-root">
      <MessageCard v-if="root" :msg="root" :since-ms="sinceMs" />
      <p v-else-if="!loading && !loadError" class="muted">{{ t('thread.empty') }}</p>
    </div>
    <MessageComposer
      omnibox
      :parent-task-id="thread.parentTaskId || undefined"
      :placeholder="t('thread.reply_placeholder')"
      @send="onSend"
      @search="(q: string) => { search = q }"
    />
    <div class="feed-body">
      <ErrorNotice v-if="loadError" :message="loadError" source="thread" test-id="thread-error" />
      <LiveFeed
        :label="t('thread.replies_label')"
        :rows="replies"
        :has-older="false"
        :loading="loading"
        :search="search"
        :last-live="lastLive"
        :empty-text="t('thread.no_replies')"
        :since-ms="sinceMs"
        @clear-search="search = ''"
      />
    </div>
  </aside>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useThreadStore } from '~/stores/thread'
import { useChannelStore } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { matchesSearch, mergeById, rootAndReplies } from '~/utils/feed.mjs'
import { applyVerbosity } from '~/utils/verbosity.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { SpoolMessage } from '~/types/spool'

const thread = useThreadStore()
const sinceMs = useNowTick(() => thread.open)
const channel = useChannelStore()
const api = useSpoolApi()
const { t } = useI18n({ useScope: 'global' })

/*
 * Live: a channel / DM feed row is a thread root only (view-v1 §4.3), so the
 * replies come from GET /v1/view/threads/{task_id} and then the WS frames.
 * 013 (X3): pinned root, reply Omnibox, replies newest first — as LiveThreadPane.
 */
const liveRows = ref<SpoolMessage[]>([])
const loadError = ref('')
const loading = ref(false)
const search = ref('')
const lastLive = ref<SpoolMessage | null>(null)
/* 013 US7 FR-013: our own reply shows at once (the channel store holds it pending until the echo) */
const pendingHere = computed(() => channel.messages.filter((m) => m.pending && m.task_id === thread.parentTaskId) as SpoolMessage[])
const split = computed(() => rootAndReplies((api.mock ? thread.messages : mergeById(liveRows.value, pendingHere.value).rows) as SpoolMessage[]))
/* CLE-3427: a thread opened on a message that is not the task's oldest (or
   on a task the hub has no messages for yet) shows the row that was clicked
   as its root — thread.rootMsg — instead of the empty line. */
const root = computed(() => split.value.root || thread.rootMsg)
const replies = computed(() => {
  const rows = split.value.replies.filter((m: SpoolMessage) => matchesSearch(m, search.value))
  return (api.mock ? rows : applyVerbosity(rows, thread.verbosity)) as SpoolMessage[]
})

/** 013 US7 FR-015: after a reconnect, re-read the thread and merge it by msg_id. */
async function catchUp() {
  const id = thread.parentTaskId
  if (api.mock || !thread.open || !id) return
  try {
    const data = await withSessionRetry(api, () => api.getThread(id)) as { messages?: SpoolMessage[] }
    if (thread.parentTaskId === id) liveRows.value = mergeById(liveRows.value, data.messages || []).rows as SpoolMessage[]
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : t('thread.load_failed')
  }
}

watch(() => [thread.open, thread.parentTaskId] as const, async ([open, id]) => {
  liveRows.value = []
  loadError.value = ''
  search.value = ''
  lastLive.value = null
  if (api.mock || !open || !id) return
  loading.value = true
  try {
    const data = await withSessionRetry(api, () => api.getThread(id)) as { messages?: SpoolMessage[] }
    if (thread.parentTaskId === id) liveRows.value = data.messages || []
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : t('thread.load_failed')
  } finally {
    loading.value = false
  }
}, { immediate: true })

if (import.meta.client && !api.mock) {
  const live = useLive()
  const off = live.onMessage((m) => {
    const row = m as unknown as SpoolMessage
    const id = thread.parentTaskId
    if (!id || (row.task_id !== id && row.parent_task_id !== id)) return
    if (liveRows.value.some((r) => r.msg_id === row.msg_id)) return
    liveRows.value = [...liveRows.value, row]
    lastLive.value = row
  })
  const offReconnect = live.onReconnected(() => { void catchUp() })
  onUnmounted(() => { off(); offReconnect() })
}

/* CLE-3433: `files` was not in this signature, so an attachment picked in
   the thread composer was dropped on the floor - see utils comment in
   stores/channel.ts toFileRefs() for the measurement */
async function onSend(text: string, parent?: string, files?: File[]) {
  await channel.send(text, parent || thread.parentTaskId || undefined, files)
}
</script>
