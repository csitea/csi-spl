<template>
  <div class="feed-body">
    <p v-if="channel.loading" class="muted">Loading…</p>
    <ErrorNotice v-else-if="channel.error" :message="channel.error" source="channel" test-id="channel-error" />
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
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useThreadStore } from '~/stores/thread'

const channel = useChannelStore()
const thread = useThreadStore()
</script>
