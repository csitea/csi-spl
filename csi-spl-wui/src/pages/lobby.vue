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
      <LiveFeed
        :label="t('pages.feed_label', { target: '#lobby' })"
        :rows="store.newestFirst"
        :has-older="store.hasOlder"
        :loading="store.loading"
        :search="store.search"
        :last-live="store.lastLive"
        :current-task-id="store.taskId"
        clickable
        @older="store.loadOlder()"
        @clear-search="store.setSearch('')"
        @open-thread="openRow"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'
import { useNotificationStore } from '~/stores/notification'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useThreadStore } from '~/stores/thread'
import { useThreadRoute } from '~/composables/useThreadRoute'
import type { SpoolMessage } from '~/types/spool'

const store = useLiveFeed('main')
const pane = useLiveFeed('pane')
const thread = useThreadStore()
const live = useLive()
const notes = useNotificationStore()
const { t, te } = useI18n({ useScope: 'global' })
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
const lobbyId = computed(() => live.lobbyTaskId.value)

/*
 * CLE-3427: clicking a message opens ITS thread in the pane, always. The
 * lobby is one task, so a row is not a thread root and threadTargetFor gives
 * it a message-rooted thread keyed by its msg_id — empty until someone
 * replies, which is exactly the case the owner asked for. The pane is the
 * live 'pane' store; the clicked row is handed over as the pinned root
 * because it lives in the lobby task, not in the task the pane reads.
 */
const { openRow } = useThreadRoute({
  currentTaskId: () => String(store.taskId || ''),
  rowFor: (msgId) => store.messages.find((m) => m.msg_id === msgId) as SpoolMessage | undefined,
  open: async (target, root) => {
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
  send: (text: string, files: File[]) => onSend(text, undefined, files),
  busy: () => store.sending,
})

onMounted(() => {
  live.ensure()
  notes.markRead('ch:lobby')
  watch(lobbyId, (id) => { if (id) void store.open(id) }, { immediate: true })
})

async function onSend(text: string, _parent?: string, files?: File[]) {
  await store.send(text, files || [])
}
</script>
