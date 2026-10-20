import { defineStore } from 'pinia'
import { dismissBornTopic, noteBornTopic } from '~/utils/born-topics'
import { applyReactions as patchReactions } from '~/utils/emoji.mjs'
import { topicOf } from '~/utils/channel-feed.mjs'
import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { usePaneFocus } from '~/stores/pane-focus'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { SpoolMessage } from '~/types/spool'

/** Which topic the pane shows (utils/topic-open.mjs topicTargetFor). */
export interface TopicTarget {
  /** the task the pane reads: the row's own task, or the message's msg_id */
  taskId: string
  /** 'task' = the row is its own topic root; 'message' = the row IS the topic */
  mode: 'task' | 'message'
  rootMsgId: string
  /** message mode: the task the pinned root was posted in (the reply's parent) */
  parentTaskId: string
  /** an archived topic opened from its link: the route path it stays open on (topic-open.mjs keepsArchivedTopic) */
  archived?: string
}

/*
 * The thread just opened is read. t1 e4bfddb1: a channel card's open kept the
 * Channels number, the row and the title until a reload, while the Flow's
 * open (live.ts readOpen) dropped them at once: it also pushes the read to
 * the hub, whose flow frame carries the counts. The card's open does too.
 */
async function readOpened(taskId: string, count: number) {
  useNotificationStore().markTopicRead(taskId, count)
  if (!import.meta.client) return
  const sync = await import('~/utils/read-sync-boot')
  sync.pushReads(useSpoolApi())
}

/* The pane's state: the refs the store hands out as they are. */
function topicState() {
  const open = ref(false)
  const parentTaskId = ref<string | null>(null)

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
  /**
   * The right pane is the selected surface. While this is set, the message
   * the topic was opened from is not highlighted.
   */
  const paneSelected = ref(false)
  /** New Omnibox topics shown at the top of the right pane, newest first. */
  const born = ref<SpoolMessage[]>([])
  return { open, parentTaskId, target, rootMsg, paneSelected, born }
}

type TopicState = ReturnType<typeof topicState>

function bornActions(s: TopicState) {
  function noteBorn(paneOpen: boolean, topicId: string | undefined, row: SpoolMessage | null | undefined) {
    s.born.value = noteBornTopic(s.born.value, paneOpen, topicId, row) as SpoolMessage[]
  }
  function dismissBorn(msgId: string) {
    s.born.value = dismissBornTopic(s.born.value, msgId) as SpoolMessage[]
  }
  function clearBorn() {
    s.born.value = []
  }
  return { noteBorn, dismissBorn, clearBorn }
}

function openActions(s: TopicState, channel: ReturnType<typeof useChannelStore>) {
  /** A click on the topic pane selects the pane. The topic that opened it stays selected too. */
  function selectPane() {
    s.paneSelected.value = true
  }

  /** The channel / DM pane: open this target and show the pane. */
  function openTarget(next: TopicTarget, root: SpoolMessage | null = null) {
    s.target.value = next
    s.rootMsg.value = root
    s.parentTaskId.value = next.taskId
    s.open.value = true
    s.paneSelected.value = false
    usePaneFocus().openedTopic()
    /* CLE-77804 (topic 35053f95): opening the thread reads it — snapshot the
       current reply total so the card's "<unread>/<total>" clears to plain.
       SPL-2430: the pane's "new" divider keeps the mark the open found. */
    if (next.taskId) useNotificationStore().enterTopic(next.taskId)
    if (next.taskId) void readOpened(next.taskId, channel.repliesFor(next.taskId))
  }

  /** The channel / DM pane by task id (the pre-CLE-3427 entry point). */
  function openTopic(taskId: string) {
    openTarget({ taskId, mode: 'task', rootMsgId: '', parentTaskId: '' })
  }

  /** Any pane: the target a click (or a ?topic= URL) resolved to. */
  function setTarget(next: TopicTarget | null, root: SpoolMessage | null = null) {
    s.target.value = next
    s.rootMsg.value = root
    /* opening or re-clicking a message selects that message, not the pane */
    s.paneSelected.value = false
    /* the channel / DM pane is driven by `open`; the live pane by its own store */
    if (!next) {
      s.open.value = false
      s.parentTaskId.value = null
    }
  }

  function close() {
    s.open.value = false
    s.parentTaskId.value = null
    s.target.value = null
    s.rootMsg.value = null
    s.born.value = []
    s.paneSelected.value = false
  }
  return { selectPane, openTarget, openTopic, setTarget, close }
}

function rootActions(s: TopicState, dismissBorn: (msgId: string) => void) {
  /**
   * the pinned root of a MESSAGE-rooted topic is held here, not in
   * the feed store — so an edit to that message has to be applied here too or
   * the 3rd panel keeps showing the old body while every other view updates.
   */
  function applyEditedRoot(row: { msg_id?: string } | null) {
    const id = String((row && row.msg_id) || '')
    if (!id || !s.rootMsg.value || String(s.rootMsg.value.msg_id || '') !== id) return
    s.rootMsg.value = { ...s.rootMsg.value, ...(row as Partial<SpoolMessage>) }
  }

  /** An emoji on the pinned root, or on a born card, which neither feed owns. */
  function applyReactionsUpdate(update: { msg_id?: string, reactions?: SpoolMessage['reactions'] } | null) {
    const id = String((update && update.msg_id) || '')
    if (!id) return
    const reactions = Array.isArray(update?.reactions) ? update.reactions : []
    if (s.rootMsg.value && String(s.rootMsg.value.msg_id || '') === id) {
      s.rootMsg.value = { ...s.rootMsg.value, reactions }
    }
    if (s.born.value.some((m) => String(m.msg_id || '') === id)) {
      s.born.value = patchReactions(s.born.value, update) as SpoolMessage[]
    }
  }

  /** The deleted message is no longer the pinned root, and no longer a born card. */
  function dropRoot(msgId: string) {
    const id = String(msgId || '')
    if (!id) return
    if (s.rootMsg.value && String(s.rootMsg.value.msg_id || '') === id) s.rootMsg.value = null
    dismissBorn(id)
  }
  return { applyEditedRoot, applyReactionsUpdate, dropRoot }
}

export const useTopicStore = defineStore('topic', () => {
  const s = topicState()
  const { open, parentTaskId, target, rootMsg, paneSelected, born } = s
  const { noteBorn, dismissBorn, clearBorn } = bornActions(s)

  const channel = useChannelStore()

  const messages = computed(() => topicOf(channel.messages, parentTaskId.value))

  const { selectPane, openTarget, openTopic, setTarget, close } = openActions(s, channel)

  /* SPL-2286 (c-311, msg 9b718269): a cold /channel/<ch>?topic=<id> opens the
     pane before the channel feed loads, so the open marked the thread at the
     total held then (0): the hub row dropped and the card kept "2/2 >>". While
     the pane is open, a reply total above the thread's mark is read too. */
  watch(() => (open.value && parentTaskId.value ? channel.repliesFor(parentTaskId.value) : -1), (n) => {
    const id = parentTaskId.value
    if (!id || n <= 0) return
    const seen = useNotificationStore().topicRead[id]
    if (Number.isFinite(seen) && n <= Number(seen)) return
    void readOpened(id, n)
  })
  const { applyEditedRoot, applyReactionsUpdate, dropRoot } = rootActions(s, dismissBorn)

  return { open, parentTaskId, messages, target, rootMsg, born, paneSelected, noteBorn, dismissBorn, clearBorn, openTopic, openTarget, setTarget, selectPane, applyEditedRoot, applyReactionsUpdate, dropRoot, close }
})
