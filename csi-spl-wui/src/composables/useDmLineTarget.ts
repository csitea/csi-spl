/*
 * Which task the Omnibox line goes to on a DM (r18-08, moved from
 * pages/dm/[peer].vue): the open right pane, a named topic or a new middle
 * card. The page keeps the useOmniboxTarget registration and reads
 * onSend / replyTarget from here, and channelPane from its selectDm watch.
 */
import type { ComputedRef } from 'vue'
import type { useChannelStore } from '~/stores/channel'
import type { useTopicStore } from '~/stores/topic'
import type { useLiveFeed } from '~/stores/live'
import type { useSidePane } from '~/composables/useSidePane'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus'
import type { SpoolMessage } from '~/types/spool'

type DmLineOpts = {
  channel: ReturnType<typeof useChannelStore>
  topic: ReturnType<typeof useTopicStore>
  livePane: ReturnType<typeof useLiveFeed>
  lobbyTaskId: ComputedRef<string>
  sidePane: ReturnType<typeof useSidePane>
}

export function useDmLineTarget(o: DmLineOpts) {
  const { channel, topic, livePane, lobbyTaskId, sidePane } = o

  /* An open right pane takes the line. `in: <title>` still names a topic.
     A closed pane starts a new middle card. */
  /* The open right pane takes the line only while it was the pane selected
     last; a click back in the middle makes the next line a new topic. */
  const paneFocus = usePaneFocus()
  function paneOpen() {
    return paneTakesLine({ paneOpen: Boolean(topic.open || dmPaneTask()), lastPane: paneFocus.last })
  }

  function openTaskId() {
    return topic.open ? String(topic.parentTaskId || dmPaneTask()) : dmPaneTask()
  }

  /* SPL-2765 (prd msg 86530802, 2026-10-21): a note to a person was stored on
     #lobby, in the lobby welcome discussion. The live pane had that discussion
     open from /lobby; a channel -> DM route keeps the pane (topic-pane.mjs
     routeLeavesTopic) and releaseStaleTopic closes only the topic store, so the
     pane's task took the DM line and the hub filed it under that task's channel
     (hub channels.go tagChannel / wuiChannel). A pane on the lobby task, or on
     a task whose rows carry a channel, is not part of this DM: it never takes
     the line here, and it closes once this person's list has loaded. */
  function channelPane() {
    const id = String(livePane.taskId || '')
    if (!id) return false
    if (id === String(lobbyTaskId.value || '')) return true
    return livePane.messages.some((m) => m.task_id === id && Boolean(m.channel))
  }

  function dmPaneTask() {
    return channelPane() ? '' : String(livePane.taskId || '')
  }

  async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
    /* the open topic takes the line, `@agent <text>` too (owner c3f0f2cf retired SPL-996 B) */
    const fresh = startsNewTopic(text)
    const reply = omniboxReplyTaskId({
      tab: sidePane.current.value,
      selectedTaskId: openTaskId(),
      namedTopicId: topicId || '',
      paneVisible: paneOpen(),
      lastPane: paneFocus.last,
      newTopic: fresh,
    })
    if (reply) topicId = reply
    const sent = await channel.send(text, topicId || undefined, files, channelId, isParentFlag({ paneVisible: paneOpen() && !fresh, replyTaskId: topicId || '' }))
    if (sent && sent.is_parent === 0 && livePane.taskId && (sent.task_id === livePane.taskId || sent.parent_task_id === livePane.taskId)) {
      livePane.admit([sent as SpoolMessage])
    }
    /* SPL-996: a new topic is its middle card and nothing else. It used to be
       drawn a second time at the top of the open right pane (BornTopics), which
       read as one message that is both an opening and a reply of that topic. */
  }

  function replyTarget() {
    return omniboxReplyTaskId({
      tab: sidePane.current.value,
      selectedTaskId: openTaskId(),
      namedTopicId: '',
      paneVisible: paneOpen(),
      lastPane: paneFocus.last,
    })
  }

  return { onSend, replyTarget, channelPane }
}
