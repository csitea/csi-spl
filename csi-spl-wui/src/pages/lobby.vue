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
        @older="store.loadOlder()"
        @clear-search="store.setSearch('')"
        @open-thread="(id: string) => pane.open(id)"
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

const store = useLiveFeed('main')
const pane = useLiveFeed('pane')
const live = useLive()
const notes = useNotificationStore()
const { t, te } = useI18n({ useScope: 'global' })
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
const lobbyId = computed(() => live.lobbyTaskId.value)

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => t('pages.message_placeholder', { target: '#lobby' }),
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
