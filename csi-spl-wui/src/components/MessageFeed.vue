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
      clickable
      @older="channel.loadOlder()"
      @clear-search="channel.setSearch('')"
      @open-thread="openRow"
    />
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useThreadStore } from '~/stores/thread'
import { useThreadRoute } from '~/composables/useThreadRoute'
import type { SpoolMessage } from '~/types/spool'

/* 013 on /channel and /dm (X3): the lobby's LiveFeed over the channel store, newest first. */
defineProps<{ label: string }>()
const channel = useChannelStore()
const thread = useThreadStore()

/* CLE-3427: a click anywhere on a row opens its thread in the pane and puts
   it in the URL. Every row here is a thread root of its own (the feed is
   rootsByTask), so this is the task-rooted case the pane already handled —
   what is new is that the whole row does it, that it works from the keyboard,
   and that a reload comes back to the same thread. */
const { openRow } = useThreadRoute({
  open: (target, root) => thread.openTarget(target, root),
  close: () => thread.close(),
  rowFor: (msgId) => channel.messages.find((m) => m.msg_id === msgId) as SpoolMessage | undefined,
})
</script>
