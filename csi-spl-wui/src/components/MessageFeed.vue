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
      always-topic
      clickable
      open-button
      clip
      :loading-older="channel.loadingOlder"
      @older="channel.loadOlder()"
      @clear-search="channel.setSearch('')"
      @open-topic="openRow"
      @edited="onEdited"
    />
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useTopicStore } from '~/stores/topic'
import { useTopicRoute } from '~/composables/useTopicRoute'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'

/* 013 on /channel and /dm (X3): the lobby's LiveFeed over the channel store, newest first. */
defineProps<{ label: string }>()
const channel = useChannelStore()
const topic = useTopicStore()

/* CLE-3445: the same message can be on screen in the feed AND as the pinned
   root of the 3rd panel, so every store that may hold it is told. */
const { applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

/* CLE-3427: a click anywhere on a row opens its topic in the pane and puts
   it in the URL. Every row here is a topic root of its own (the feed is
   rootsByTask), so this is the task-rooted case the pane already handled —
   what is new is that the whole row does it, that it works from the keyboard,
   and that a reload comes back to the same topic. */
const { openRow } = useTopicRoute({
  open: (target, root) => topic.openTarget(target, root),
  close: () => topic.close(),
  rowFor: (msgId) => channel.messages.find((m) => m.msg_id === msgId) as SpoolMessage | undefined,
})
</script>
