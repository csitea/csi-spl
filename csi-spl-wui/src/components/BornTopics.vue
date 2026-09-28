<template>
  <div v-if="topic.born.length" class="born-topics" :class="{ 'born-topics--last': newestLast }" data-test="born-topics">
    <MessageCard
      v-for="m in cards"
      :key="String(m.msg_id || '')"
      :msg="m"
      clickable
      topic-menu
      :clip-mode="clipMode"
      @open-topic="open"
    />
  </div>
</template>

<script setup lang="ts">
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import type { SpoolMessage } from '~/types/spool'
import { useCardClip } from '~/composables/useCardClip'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { displayOrder } from '~/utils/view-prefs.mjs'

/* New Omnibox topics, newest at the top of the right pane. SPL-963: they
   sit in that pane, so they take its titles / 5 rows / full mode. */
const topic = useTopicStore()
const { mode: clipMode } = useCardClip('thread')
const pane = useLiveFeed('pane')
/* Topic c6994436: newest last draws them oldest first, under the thread
   (LiveTopicPane / TopicPane move this block below the feed). */
const { newestLast } = useViewPrefs()
const cards = computed(() => displayOrder(topic.born, newestLast.value ? 'newest-last' : 'newest-first') as SpoolMessage[])

function open(msg: SpoolMessage) {
  topic.dismissBorn(String(msg.msg_id || ''))
  const id = String(msg.task_id || '')
  if (!id) return
  /* The live pane outranks the channel pane, so a lobby / topics-list
     right pane has to open the task itself or the card would vanish. */
  if (pane.taskId && !topic.open) {
    topic.setTarget({ taskId: id, mode: 'task', rootMsgId: String(msg.msg_id || ''), parentTaskId: '' }, msg)
    void pane.open(id)
    return
  }
  topic.openTopic(id)
}
</script>

<style scoped>
/* below the thread: the rule sits on the top edge instead (main.css draws the bottom one) */
.born-topics--last { border-bottom: 0; border-top: 1px solid var(--color-border); }
</style>
