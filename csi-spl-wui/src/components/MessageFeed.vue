<template>
  <div class="feed-body">
    <p v-if="channel.loading" class="muted">Loading…</p>
    <p v-else-if="channel.error" class="muted">{{ channel.error }}</p>
    <p v-else-if="channel.feed.length === 0" class="muted">No messages yet.</p>
    <MessageCard
      v-for="m in channel.feed"
      :key="m.msg_id"
      :msg="m"
      :count="channel.repliesFor(m.task_id)"
      always-thread
      @open-thread="thread.openThread"
    />
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useThreadStore } from '~/stores/thread'

const channel = useChannelStore()
const thread = useThreadStore()
</script>
