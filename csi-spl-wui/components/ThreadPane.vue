<template>
  <aside v-if="thread.open" class="thread">
    <header>
      <strong>Thread</strong>
      <div style="display:flex;gap:8px;align-items:center">
        <VerbositySelector />
        <button class="btn ghost" type="button" @click="thread.close()">Close</button>
      </div>
    </header>
    <div class="feed-body">
      <MessageCard
        v-for="m in thread.messages"
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
import { useThreadStore } from '~/stores/thread'
import { useChannelStore } from '~/stores/channel'

const thread = useThreadStore()
const channel = useChannelStore()

async function onSend(text: string, parent?: string) {
  await channel.send(text, parent || thread.parentTaskId || undefined)
}
</script>
