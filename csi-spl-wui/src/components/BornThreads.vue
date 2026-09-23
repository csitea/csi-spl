<template>
  <div v-if="thread.born.length" class="born-threads" data-test="born-threads">
    <MessageCard
      v-for="m in thread.born"
      :key="String(m.msg_id || '')"
      :msg="m"
      clickable
      @open-thread="open"
    />
  </div>
</template>

<script setup lang="ts">
import { useLiveFeed } from '~/stores/live'
import { useThreadStore } from '~/stores/thread'
import type { SpoolMessage } from '~/types/spool'

/* New Omnibox threads, newest at the top of the right pane. */
const thread = useThreadStore()
const pane = useLiveFeed('pane')

function open(msg: SpoolMessage) {
  thread.dismissBorn(String(msg.msg_id || ''))
  const id = String(msg.task_id || '')
  if (!id) return
  /* The live pane outranks the channel pane, so a lobby / threads-list
     right pane has to open the task itself or the card would vanish. */
  if (pane.taskId && !thread.open) {
    thread.setTarget({ taskId: id, mode: 'task', rootMsgId: String(msg.msg_id || ''), parentTaskId: '' }, msg)
    void pane.open(id)
    return
  }
  thread.openThread(id)
}
</script>
