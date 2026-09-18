<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2># lobby</h2>
      <span class="muted">live · {{ live.state.value }} · you are {{ live.identity.value || '…' }}</span>
    </header>
    <MessageComposer placeholder="Message #lobby — Enter to send" :busy="store.sending" @send="onSend" />
    <div class="feed-body">
      <p v-if="!lobbyId" class="muted">No lobby configured (NUXT_PUBLIC_LOBBY_TASK_ID, or the hub welcome).</p>
      <p v-if="store.error" class="muted">{{ store.error }}</p>
      <MessageCard v-for="m in store.newestFirst" :key="m.msg_id" :msg="m" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useLiveStore } from '~/stores/live'
import { useLive } from '~/composables/useLive'

const store = useLiveStore()
const live = useLive()
const lobbyId = computed(() => live.lobbyTaskId.value)

onMounted(() => {
  live.ensure()
  watch(lobbyId, (id) => { if (id) void store.open(id) }, { immediate: true })
})

async function onSend(text: string, _parent?: string, files?: File[]) {
  await store.send(text, files || [])
}
</script>
