<template>
  <div class="feed-col" data-pane="msgs">
    <FeedHeader
      title="#lobby"
      :status="live.state.value === 'open' ? 'on' : 'off'"
      :status-text="t('pages.lobby.status', { state: stateLabel(live.state.value), who: live.identity.value ? people.label(live.identity.value) : '…' })"
    />
    <div class="feed-body">
      <!-- SPL-989: not before the hub's welcome - a direct load used to flash
           "No lobby configured" for 2-4 s while the socket came up -->
      <p v-if="!lobbyId && (api.mock || live.welcomed.value)" class="muted" data-testid="lobby-none">{{ t('pages.lobby.no_lobby', { env: 'NUXT_PUBLIC_LOBBY_TASK_ID' }) }}</p>
      <ViewTokenForm v-if="store.door" :detail="store.door.detail" @saved="lobbyId && store.open(lobbyId)" />
      <ErrorNotice v-if="store.error" :message="store.error" source="lobby" test-id="lobby-error" />
      <!-- Pane 2 is the topic starter only. Later messages of the lobby task are replies and stay in pane 3. -->
      <LiveFeed
        :label="t('pages.feed_label', { target: '#lobby' })"
        :rows="store.lobbyRows"
        :has-older="store.lobbyHasOlder"
        :loading="store.loading"
        :search="store.search"
        :last-live="store.lastLive"
        :current-task-id="store.taskId"
        clickable
        open-button
        clip
        :loading-older="store.loadingOlder"
        @older="store.loadOlder('lobby')"
        @clear-search="store.setSearch('')"
        @open-topic="openRow"
        @edited="onEdited"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { shouldOpenHubSocket, startHubSocket, stopHubSocket } from '~/utils/shell-bootstrap.mjs'
import { useNotificationStore } from '~/stores/notification'
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { isParentFlag, omniboxReplyTaskId, sendsNewTopic, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { useTopicStore } from '~/stores/topic'
import { useTopicRoute } from '~/composables/useTopicRoute'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'
import { withSessionRetry } from '~/utils/live-follow.mjs'

const store = useLiveFeed('main')
const channel = useChannelStore()
const pane = useLiveFeed('pane')
const topic = useTopicStore()
const sidePane = useSidePane()
const live = useLive()
/* SPL-6: the status line names the viewer by display name, not the member id */
const people = useHumanNames()
const api = useSpoolApi()
const session = useSessionStore()
const notes = useNotificationStore()
const { t, te } = useI18n({ useScope: 'global' })
/* SPL-976: the placeholder names the keys of the person's Behaviour setting */
const { hintFor: sk } = useSubmitKey()
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
const lobbyId = computed(() => live.lobbyTaskId.value)

/* CLE-3445: an edit landed on a lobby row. That row is the main feed store's
   AND the pinned root of the 3rd panel when its topic is open, so every
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
const { openRow } = useTopicRoute({
  currentTaskId: () => String(store.taskId || ''),
  rowFor: (msgId) => store.messages.find((m) => m.msg_id === msgId) as SpoolMessage | undefined,
  open: async (target, root) => {
    /* A row in this feed is a message of the lobby task. Opening it as a
       message-rooted topic would load an empty child task and hide the
       follow-ups. Open the task itself so pane 3 lists those follow-ups. */
    const feedTask = String(store.taskId || '')
    const rowTask = String((root && root.task_id) || '')
    if (root && rowTask && rowTask === feedTask) {
      topic.setTarget({ taskId: rowTask, mode: 'task', rootMsgId: String(root.msg_id || ''), parentTaskId: '' }, root)
      await pane.open(rowTask)
      return
    }
    topic.setTarget(target, root)
    await pane.open(target.taskId)
  },
  close: () => {
    topic.close()
    pane.close()
  },
})

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
/* The open right pane takes the line only while it was the pane selected
   last; a click back in the middle makes the next line a new topic. */
const paneFocus = usePaneFocus()
function lobbyPaneOpen() {
  return paneTakesLine({ paneOpen: Boolean(topic.open || pane.taskId), lastPane: paneFocus.last })
}

function lobbyReplyId() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: String(pane.taskId || ''),
    namedTopicId: '',
    paneVisible: lobbyPaneOpen(),
    lastPane: paneFocus.last,
  })
}

useOmniboxTarget({
  placeholder: () => (lobbyReplyId() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: '#lobby' })),
  send: (text: string, files: File[], topicId?: string, channelId?: string) => onSend(text, files, topicId, channelId),
  busy: () => store.sending,
})

onMounted(() => {
  notes.markRead('ch:lobby')
})

/* Declared above the immediate watch below, which calls followLobbyChannel()
   on the first tick: a `let` below it is still in its dead zone then
   ("Cannot access before initialization", dev 57a7d4a).

   A new lobby topic is a NEW task in channel lobby, and the main store only
   merges live frames of the room task. So another reader's new topic reached
   nobody but its sender until a reload (measured 2026-09-25 on dev 5b16c0f,
   a second tab, n=1). The page follows the channel and admits its frames;
   channelView keeps a level-2 line (is_parent 0) out of the middle. The
   channel subscription is left in place on leave: it is idempotent, and the
   channel store may be following #lobby too. */
let offLobbyChannel: (() => void) | null = null
function followLobbyChannel() {
  const client = live.ensure()
  if (client) client.subscribeChannel('lobby')
  if (offLobbyChannel) return
  offLobbyChannel = live.onMessage((m) => {
    if (m.channel === 'lobby' && m.task_id !== store.taskId) store.admit([m as unknown as SpoolMessage])
  })
}
onBeforeUnmount(() => {
  if (offLobbyChannel) offLobbyChannel()
  offLobbyChannel = null
})

/* W5: same watch shape as spool-live.client.ts (cbac1cd). Mock has no socket
   (ensure() only sets identity). Live waits for a member session; a sign-in
   brings the socket up with no reload; a sign-out closes it so it does not
   retry. store.open also calls live.ensure(), so it sits behind the same gate. */
watch([lobbyId, () => session.state], ([id, st]) => {
  if (api.mock) {
    live.ensure()
    if (id) openLobby(id)
    return
  }
  if (shouldOpenHubSocket(st)) {
    startHubSocket(live)
    followLobbyChannel()
    if (id) openLobby(id)
  } else {
    stopHubSocket(live)
  }
}, { immediate: true })

/* The room task (store.open) and the topics posted into #lobby besides it
   (so a new topic is still here after a reload) are independent reads: both
   go out now. The topics are admitted only once the room task is open,
   because opening resets the rows. They used to be read only AFTER the room
   task answered, and every lobby row comes from them: first message ~560 ms
   later on dev (CLE-34984). */
function openLobby(id: string) {
  const topics = withSessionRetry(api, () => api.listMessages({ channel: 'lobby', limit: 50 }))
  topics.catch(() => { /* handled below */ })
  void store.open(id).then(() => loadLobbyTopics(topics))
}
async function loadLobbyTopics(pending: ReturnType<typeof api.listMessages>) {
  try {
    const page = await pending
    store.admit((page.messages || []) as SpoolMessage[])
  } catch {
    /* the lobby task is already on screen */
  }
}

/* The right pane is closed and the line names no topic: one new topic,
   this message only. An open pane, or `in:` naming the lobby task, still
   posts into the room. `in:` naming some other topic replies there. */
function parentBit(replyTaskId = '', fresh = false) {
  return isParentFlag({ paneVisible: lobbyPaneOpen() && !fresh, replyTaskId })
}

async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const here = String(store.taskId || '')
  /* SPL-996 B: the open topic takes the line; `@someone` first starts a new one */
  const fresh = startsNewTopic(text)
  if (topicId && topicId !== here) {
    await channel.send(text, topicId, files, channelId, parentBit(topicId))
    return
  }
  const replyHere = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: String(pane.taskId || ''),
    namedTopicId: '',
    paneVisible: lobbyPaneOpen(),
    lastPane: paneFocus.last,
    newTopic: fresh,
  })
  if (replyHere && pane.taskId && replyHere === pane.taskId) {
    await pane.send(text, files || [], { isParent: parentBit(replyHere) })
    return
  }
  if (sendsNewTopic({ paneOpen: lobbyPaneOpen() && !fresh, namedTopicId: topicId || '' })) {
    const sent = await channel.send(text, undefined, files, channelId || 'lobby', parentBit('', fresh))
    if (sent) store.admit([sent as SpoolMessage])
    return
  }
  /* SPL-985 K4: the lobby room is the lobby, whatever its older rows carry */
  await store.send(text, files || [], { isParent: parentBit(), pokeChannel: '' })
}
</script>
