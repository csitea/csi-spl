import { defineStore } from 'pinia'
import { dismissBornTopic, noteBornTopic } from '~/utils/born-topics.mjs'
import { topicOf } from '~/utils/channel-feed.mjs'
import { applyVerbosity, loadVerbosity, saveVerbosity } from '~/utils/verbosity.mjs'
import { useChannelStore } from '~/stores/channel'
import type { SpoolMessage } from '~/types/spool'

export type Verbosity = 'minimal' | 'normal' | 'verbose'

/** Which topic the pane shows (utils/topic-open.mjs topicTargetFor). */
export interface TopicTarget {
  /** the task the pane reads: the row's own task, or the message's msg_id */
  taskId: string
  /** 'task' = the row is its own topic root; 'message' = the row IS the topic */
  mode: 'task' | 'message'
  rootMsgId: string
  /** message mode: the task the pinned root was posted in (the reply's parent) */
  parentTaskId: string
}

export const useTopicStore = defineStore('topic', () => {
  const open = ref(false)
  const parentTaskId = ref<string | null>(null)
  const verbosity = ref<Verbosity>(loadVerbosity())
  watch(verbosity, (v) => { saveVerbosity(v) })

  /*
   * CLE-3427. Both panes (TopicPane over the channel store, LiveTopicPane
   * over the live 'pane' store) read `target`: it is what the feed row
   * highlights itself from and what the URL carries, so the two panes cannot
   * disagree about which topic is open. `rootMsg` is the pinned root of a
   * MESSAGE-rooted topic — that message is not in the task the pane reads
   * (it lives in `target.parentTaskId`), so the pane cannot derive it and is
   * handed it by the feed that was clicked. A deep link arrives without one
   * and the pane looks it up in the feed instead.
   */
  const target = ref<TopicTarget | null>(null)
  const rootMsg = ref<SpoolMessage | null>(null)
  /** New Omnibox topics shown at the top of the right pane, newest first. */
  const born = ref<SpoolMessage[]>([])

  function noteBorn(paneOpen: boolean, topicId: string | undefined, row: SpoolMessage | null | undefined) {
    born.value = noteBornTopic(born.value, paneOpen, topicId, row) as SpoolMessage[]
  }
  function dismissBorn(msgId: string) {
    born.value = dismissBornTopic(born.value, msgId) as SpoolMessage[]
  }
  function clearBorn() {
    born.value = []
  }

  const channel = useChannelStore()

  const messages = computed(() => {
    const all = topicOf(channel.messages, parentTaskId.value)
    return applyVerbosity(all, verbosity.value)
  })

  /** The channel / DM pane: open this target and show the pane. */
  function openTarget(next: TopicTarget, root: SpoolMessage | null = null) {
    target.value = next
    rootMsg.value = root
    parentTaskId.value = next.taskId
    open.value = true
  }

  /** The channel / DM pane by task id (the pre-CLE-3427 entry point). */
  function openTopic(taskId: string) {
    openTarget({ taskId, mode: 'task', rootMsgId: '', parentTaskId: '' })
  }

  /** Any pane: the target a click (or a ?topic= URL) resolved to. */
  function setTarget(next: TopicTarget | null, root: SpoolMessage | null = null) {
    target.value = next
    rootMsg.value = root
    /* the channel / DM pane is driven by `open`; the live pane by its own store */
    if (!next) {
      open.value = false
      parentTaskId.value = null
    }
  }

  function close() {
    open.value = false
    parentTaskId.value = null
    target.value = null
    rootMsg.value = null
    born.value = []
  }

  /**
   * CLE-3445: the pinned root of a MESSAGE-rooted topic is held here, not in
   * the feed store — so an edit to that message has to be applied here too or
   * the 3rd panel keeps showing the old body while every other view updates.
   */
  function applyEditedRoot(row: { msg_id?: string } | null) {
    const id = String((row && row.msg_id) || '')
    if (!id || !rootMsg.value || String(rootMsg.value.msg_id || '') !== id) return
    rootMsg.value = { ...rootMsg.value, ...(row as Partial<SpoolMessage>) }
  }

  return { open, parentTaskId, verbosity, messages, target, rootMsg, born, noteBorn, dismissBorn, clearBorn, openTopic, openTarget, setTarget, applyEditedRoot, close }
})
