<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2># lobby</h2>
      <span class="muted">{{ t('pages.lobby.status', { state: stateLabel(live.state.value), who: live.identity.value || '…' }) }}</span>
    </header>
    <div class="feed-body">
      <p v-if="!lobbyId" class="muted">{{ t('pages.lobby.no_lobby', { env: 'NUXT_PUBLIC_LOBBY_TASK_ID' }) }}</p>
      <ViewTokenForm v-if="store.door" :detail="store.door.detail" @saved="lobbyId && store.open(lobbyId)" />
      <ErrorNotice v-if="store.error" :message="store.error" source="lobby" test-id="lobby-error" />
      <!-- Pane 2 is the thread starter only. Later messages of the lobby task are replies and stay in pane 3. -->
      <LiveFeed
        :label="t('pages.feed_label', { target: '#lobby' })"
        :rows="store.lobbyRows"
        :has-older="store.lobbyHasOlder"
        :loading="store.loading"
        :search="store.search"
        :last-live="store.lastLive"
        :current-task-id="store.taskId"
        clickable
        @older="store.loadOlder('lobby')"
        @clear-search="store.setSearch('')"
        @open-thread="openRow"
        @edited="onEdited"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { shouldOpenHubSocket, startHubSocket, stopHubSocket } from '~/utils/shell-bootstrap.mjs'
import { useNotificationStore } from '~/stores/notification'
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { sendsNewThread } from '~/utils/omnibox-thread.mjs'
import { useThreadStore } from '~/stores/thread'
import { useThreadRoute } from '~/composables/useThreadRoute'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'

const store = useLiveFeed('main')
const channel = useChannelStore()
const pane = useLiveFeed('pane')
const thread = useThreadStore()
const live = useLive()
const api = useSpoolApi()
const session = useSessionStore()
const notes = useNotificationStore()
const { t, te } = useI18n({ useScope: 'global' })
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
const lobbyId = computed(() => live.lobbyTaskId.value)

/* CLE-3445: an edit landed on a lobby row. That row is the main feed store's
   AND the pinned root of the 3rd panel when its thread is open, so every
   store that may hold it is told through the one helper. */
const { applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

/*
 * Clicking the starter opens the lobby task in the right pane. Follow-ups
 * are later messages of that same task, so the pane reads the task and
 * shows them as replies. A message-rooted target (a deep link) still opens
 * the task it names.
 */
const { openRow } = useThreadRoute({
  currentTaskId: () => String(store.taskId || ''),
  rowFor: (msgId) => store.messages.find((m) => m.msg_id === msgId) as SpoolMessage | undefined,
  open: async (target, root) => {
    /* A row in this feed is a message of the lobby task. Opening it as a
       message-rooted thread would load an empty child task and hide the
       follow-ups. Open the task itself so pane 3 lists those follow-ups. */
    const feedTask = String(store.taskId || '')
    const rowTask = String((root && root.task_id) || '')
    if (root && rowTask && rowTask === feedTask) {
      thread.setTarget({ taskId: rowTask, mode: 'task', rootMsgId: String(root.msg_id || ''), parentTaskId: '' }, root)
      await pane.open(rowTask)
      return
    }
    thread.setTarget(target, root)
    await pane.open(target.taskId)
  },
  close: () => {
    thread.close()
    pane.close()
  },
})

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => t('search.placeholder_target', { target: '#lobby' }),
  send: (text: string, files: File[], threadId?: string, channelId?: string) => onSend(text, files, threadId, channelId),
  busy: () => store.sending,
})

onMounted(() => {
  notes.markRead('ch:lobby')
})

/* W5: same watch shape as spool-live.client.ts (cbac1cd). Mock has no socket
   (ensure() only sets identity). Live waits for a member session; a sign-in
   brings the socket up with no reload; a sign-out closes it so it does not
   retry. store.open also calls live.ensure(), so it sits behind the same gate. */
watch([lobbyId, () => session.state], ([id, st]) => {
  if (api.mock) {
    live.ensure()
    if (id) void store.open(id).then(() => loadLobbyThreads())
    return
  }
  if (shouldOpenHubSocket(st)) {
    startHubSocket(live)
    if (id) void store.open(id).then(() => loadLobbyThreads())
  } else {
    stopHubSocket(live)
  }
}, { immediate: true })

/* Threads posted into #lobby besides the room task, so a new thread is still
   here after a reload. The room task itself is already loaded by store.open. */
async function loadLobbyThreads() {
  try {
    const page = await api.listMessages({ channel: 'lobby', limit: 50 })
    store.admit((page.messages || []) as SpoolMessage[])
  } catch {
    /* the lobby task is already on screen */
  }
}

/* The right pane is closed and the line names no thread: one new thread,
   this message only. An open pane, or `in:` naming the lobby task, still
   posts into the room. `in:` naming some other thread replies there. */
async function onSend(text: string, files?: File[], threadId?: string, channelId?: string) {
  const here = String(store.taskId || '')
  if (threadId && threadId !== here) {
    await channel.send(text, threadId, files, channelId)
    return
  }
  const paneOpen = thread.open || Boolean(pane.taskId)
  if (sendsNewThread({ paneOpen, namedThreadId: threadId || '' })) {
    const sent = await channel.send(text, undefined, files, channelId || 'lobby')
    if (sent) store.admit([sent as SpoolMessage])
    return
  }
  await store.send(text, files || [])
}
</script>
