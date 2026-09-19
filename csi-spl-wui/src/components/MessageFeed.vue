<template>
  <div class="feed-body">
    <ErrorNotice v-if="channel.error" :message="channel.error" source="channel" test-id="channel-error" />
    <LiveFeed
      :label="label"
      :rows="channel.newestFirst"
      :has-older="channel.hasOlder"
      :loading="channel.loading"
      :search="channel.search"
      :last-live="channel.lastLive"
      :count-for="channel.repliesFor"
      always-thread
      @older="channel.loadOlder()"
      @clear-search="channel.setSearch('')"
      @open-thread="thread.openThread"
    />
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useThreadStore } from '~/stores/thread'

/* 013 on /channel and /dm (X3): the lobby's LiveFeed over the channel store, newest first. */
defineProps<{ label: string }>()
const channel = useChannelStore()
const thread = useThreadStore()
</script>
