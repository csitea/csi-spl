<template>
  <div class="feed-col">
    <header class="feed-header">
      <span class="dot" :class="{ on: online }" />
      <h2>{{ peer }}</h2>
      <span class="muted">{{ online ? t('pages.dm.online') : t('pages.dm.offline_queued') }}</span>
    </header>
    <!-- CLE-3433: the DM route is where a visitor is most likely to land
         from a link, so the signed-out state matters most here -->
    <SignedOutNotice v-if="signedOut" />
    <MessageFeed v-else :label="t('pages.feed_label', { target: peer })" />
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { isSignedOutVisitor } from '~/utils/shell-bootstrap.mjs'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useThreadStore } from '~/stores/thread'
import { omniboxParentTaskId, omniboxPlaceholderKey } from '~/utils/omnibox-thread.mjs'

const route = useRoute()
const channel = useChannelStore()
const thread = useThreadStore()
/* the task an Omnibox send hangs off: the open thread, or a new one */
const replyTo = computed(() => omniboxParentTaskId(thread))
const roster = useRosterStore()
const events = useSpoolEvents()
const api = useSpoolApi()
const session = useSessionStore()
/* CLE-3433: a settled signed-out probe, so the notice never flashes at a human mid-probe */
const signedOut = computed(() => isSignedOutVisitor(session.state, api.mock))
const { t } = useI18n({ useScope: 'global' })
const peer = computed(() => decodeURIComponent(String(route.params.peer || '')))
const online = computed(() => {
  const [id, box] = peer.value.split('@')
  return roster.isOnline(id, box)
})

/* the shell reads (channels + roster) belong to the plugin's createShellBootstrap
   (once per app). This page only selects the open DM: mock hydrates immediately,
   live waits for a member session — same predicate as onSession. */
watch([peer, () => session.state], async ([p, st]) => {
  if (!p) return
  if (!api.mock && String(st) !== 'in') return
  await channel.selectDm(p)
}, { immediate: true })

/* read cursors follow channel.peer in plugins/notify.client.ts */
onMounted(() => {
  events.start()
})

/* CLE-3433 / OA-38: while `?thread=` names a thread, the Omnibox writes into
   THAT thread. Without this, channel.sendLive's `task_id: parentTaskId ||
   newId()` minted a new task per send and the exchange scattered. */
async function onSend(text: string, files?: File[]) {
  await channel.send(text, replyTo.value || undefined, files)
}

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => (replyTo.value
    ? t(omniboxPlaceholderKey(replyTo.value))
    : t('search.placeholder_target', { target: peer.value })),
  send: onSend,
})
</script>
