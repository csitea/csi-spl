import { computed } from 'vue'
import { useFlowKeys } from '~/composables/useFlowBadge'
import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { loadMutedChannels } from '~/utils/notify.mjs'
import { unreadModel } from '~/utils/unread-model.mjs'

export type UnreadSection = 'channels' | 'dms' | 'topics'

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

  return { rowOf, section, title }
}
