import { computed } from 'vue'
import { useFlowKeys } from '~/composables/useFlowBadge'
import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { loadMutedChannels } from '~/utils/notify.mjs'
import { dropTopicKey } from '~/utils/flow-keys.mjs'
import { tabUnread, unreadModel } from '~/utils/unread-model.mjs'

/* no 'topics': the Topics tab that summed them is gone (t1 e4bfddb1); the
   model still counts each topic's own row (rowOf('t:<task_id>')) */
export type UnreadSection = 'channels' | 'dms'

/**
 * Spec 079 FR-002: the one reader of the unread inputs. It feeds
 * unreadModel (FR-001) from the hub's Flow row keys, the notification
 * store's channel / DM unread and the topic read marks (the `t:` cursors,
 * read against the channel store's reply totals); every surface - row,
 * rail, card, tab title - reads its number from here (the grep gate in
 * tests/unit/unread-model.test.mjs, AC3).
 *
 *  - rowOf(key): one place's unread (`ch:<id>`, `dm:<peer>`, `t:<task_id>`), 0 if none
 *  - section(id): the sum of a section's rows (muted channels included)
 *  - title: the sum for the tab title (muted channels left out, spec Q2)
 *  - tabTitle: the tab title's number, the rows the sidebar lists (SPL-3587)
 *  - dropTopic(task, channel): a card opened, its t: key and its channel's ch:
 *    key drop together until the hub's next counts (SPL-3587)
 */
export function useUnread() {
  const keys = useFlowKeys()
  const notes = useNotificationStore()
  const channel = useChannelStore()

  const model = computed(() => {
    const channelUnread: Record<string, number> = {}
    const dmUnread: Record<string, number> = {}
    for (const [k, n] of Object.entries(notes.unread)) {
      if (k.startsWith('ch:')) channelUnread[k] = n
      else if (k.startsWith('dm:')) dmUnread[k] = n
    }
    const cursors: Record<string, { count: number }> = {}
    const topics: { task_id: string, total: number }[] = []
    for (const [id, count] of Object.entries(notes.topicRead)) {
      cursors['t:' + id] = { count }
      topics.push({ task_id: id, total: channel.repliesFor(id) })
    }
    /* read on every recompute, as the title did: a mute is a localStorage pref */
    const muted = import.meta.client ? loadMutedChannels() : []
    return unreadModel({ keys: keys.value, cursors, channelUnread, dmUnread, muted, topics })
  })

  function rowOf(key: string) {
    return model.value.rows.get(key) || 0
  }
  function section(id: UnreadSection) {
    return model.value.sections[id] || 0
  }
  const title = computed(() => model.value.title)
  /* SPL-3587: the listed rows only, as the rail sums them - a ch:issues key
     has no row, so it made the tab read (3) over a rail of 1 */
  const tabTitle = computed(() => tabUnread(model.value.rows, channel.ordered.map((c) => String(c.channel_id || '')), import.meta.client ? loadMutedChannels() : []))

  function dropTopic(taskId: string, channelId: string) {
    const next = dropTopicKey(keys.value, taskId, channelId)
    if (next !== keys.value) keys.value = next
  }

  return { rowOf, section, title, tabTitle, dropTopic }
}
