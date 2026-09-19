<template>
  <aside v-if="thread.open" class="thread">
    <header>
      <strong>Thread</strong>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-width:0">
        <VerbositySelector />
        <button class="btn ghost" type="button" @click="thread.close()">Close</button>
      </div>
    </header>
    <div class="feed-body">
      <ErrorNotice v-if="loadError" :message="loadError" source="thread" test-id="thread-error" />
      <MessageCard
        v-for="m in shown"
        :key="m.msg_id"
        :msg="m"
      />
    </div>
    <MessageComposer
      :parent-task-id="thread.parentTaskId || undefined"
      placeholder="Reply in thread"
      @send="onSend"
    />
  </aside>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useThreadStore } from '~/stores/thread'
import { useChannelStore } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { applyVerbosity } from '~/utils/verbosity.mjs'
import type { SpoolMessage } from '~/types/spool'

const thread = useThreadStore()
const channel = useChannelStore()
const api = useSpoolApi()

/*
 * Live: a channel / DM feed row is a thread root only (view-v1 §4.3), so the
 * replies come from GET /v1/view/threads/{task_id} and then the WS frames.
 */
const liveRows = ref<SpoolMessage[]>([])
const loadError = ref('')
const shown = computed(() => api.mock
  ? thread.messages
  : applyVerbosity(liveRows.value, thread.verbosity))

watch(() => [thread.open, thread.parentTaskId] as const, async ([open, id]) => {
  liveRows.value = []
  loadError.value = ''
  if (api.mock || !open || !id) return
  try {
    const data = await api.getThread(id) as { messages?: SpoolMessage[] }
    if (thread.parentTaskId === id) liveRows.value = data.messages || []
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : 'thread load failed'
  }
}, { immediate: true })

if (import.meta.client && !api.mock) {
  const off = useLive().onMessage((m) => {
    const row = m as unknown as SpoolMessage
    const id = thread.parentTaskId
    if (!id || (row.task_id !== id && row.parent_task_id !== id)) return
    if (liveRows.value.some((r) => r.msg_id === row.msg_id)) return
    liveRows.value = [...liveRows.value, row]
  })
  onUnmounted(() => { off() })
}

async function onSend(text: string, parent?: string) {
  await channel.send(text, parent || thread.parentTaskId || undefined)
}
</script>
