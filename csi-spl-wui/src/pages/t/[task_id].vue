<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2><NuxtLink :to="localePath('/')">{{ t('nav.threads') }}</NuxtLink> / <code>{{ shortId }}</code></h2>
      <span class="muted">{{ t('pages.task.status', { n: store.messages.length, state: stateLabel(live.state.value) }) }}</span>
      <VerbositySelector />
    </header>
    <div class="pinned-root">
      <MessageCard v-if="store.thread.root" :key="String(store.thread.root.msg_id || '')" :msg="store.thread.root" :since-ms="sinceMs" :editable="canEdit(store.thread.root)" @edited="onEdited" />
    </div>
    <div class="feed-body">
      <ViewTokenForm v-if="store.door" :detail="store.door.detail" @saved="reopen" />
      <ErrorNotice v-if="store.error" :message="store.error" source="thread" test-id="thread-error" />
      <LiveFeed
        :label="t('thread.replies_label')"
        :rows="replies"
        :has-older="false"
        :loading="store.loading"
        :search="store.search"
        :last-live="store.lastLive"
        :since-ms="sinceMs"
        @clear-search="store.setSearch('')"
        @edited="onEdited"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useLive } from '~/composables/useLive'
import { useThreadStore } from '~/stores/thread'
import { applyVerbosity } from '~/utils/verbosity.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'

const route = useRoute()
const store = useLiveFeed('main')
const side = useLiveFeed('pane')
const channel = useChannelStore()
const live = useLive()
const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
const thread = useThreadStore()
const sinceMs = useNowTick(() => Boolean(taskId.value))
/* 005 FR-013: the same verbosity filter as the thread pane */
const replies = computed(() => applyVerbosity(store.thread.replies, thread.verbosity))

function reopen() {
  if (taskId.value) void store.open(taskId.value, { all: true })
}

onMounted(() => {
  watch(taskId, reopen, { immediate: true })
})

/* CLE-3445: an edit landed on this page's own feed store (the live store
   already applies a `message_edited` frame from another session itself). */
const { canEdit, applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

/* The open task does not capture the box. `in:` naming this task replies
   here; `in:` naming another replies there; anything else is a new message. */
async function onSend(text: string, files?: File[], threadId?: string, channelId?: string) {
  if (threadId && threadId === taskId.value && store.taskId) {
    await store.send(text, files || [])
    return
  }
  const sent = await channel.send(text, threadId || undefined, files, channelId)
  thread.noteBorn(thread.open || Boolean(side.taskId), threadId, sent as SpoolMessage)
}
useOmniboxTarget({
  placeholder: () => t('search.placeholder_target', { target: shortId.value }),
  send: onSend,
  busy: () => store.sending,
})
</script>
