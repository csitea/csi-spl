<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2># lobby</h2>
      <span class="muted">live · {{ live.state.value }} · you are {{ live.identity.value || '…' }}</span>
    </header>
    <MessageComposer
      omnibox
      placeholder="Message #lobby — Enter to send · /search to filter"
      :busy="store.sending"
      @send="onSend"
      @search="store.setSearch"
    />
    <div class="feed-body">
      <p v-if="!lobbyId" class="muted">No lobby configured (NUXT_PUBLIC_LOBBY_TASK_ID, or the hub welcome).</p>
      <ViewTokenForm v-if="store.door" :detail="store.door.detail" @saved="lobbyId && store.open(lobbyId)" />
      <ErrorNotice v-if="store.error" :message="store.error" source="lobby" test-id="lobby-error" />
      <LiveFeed
        label="#lobby, newest first"
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

const store = useLiveFeed('main')
const pane = useLiveFeed('pane')
const live = useLive()
const notes = useNotificationStore()
const lobbyId = computed(() => live.lobbyTaskId.value)

onMounted(() => {
  live.ensure()
  notes.markRead('ch:lobby')
  watch(lobbyId, (id) => { if (id) void store.open(id) }, { immediate: true })
})

async function onSend(text: string, _parent?: string, files?: File[]) {
  await store.send(text, files || [])
}
</script>
