// Spec 067 rule 3 (L7): a DM that carries ref_task_id is about a channel
// topic. The card heads it "about #channel / topic", linked to the topic. One
// topic read (limit 1) per ref per tab, shared by every card that names it.
// A topic this reader may not read (404) or one that failed resolves to null:
// the card then shows no header, never a guess.
import { useSpoolApi } from '~/composables/useSpoolApi'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { topicTitleFromRows } from '~/utils/view-api.mjs'
import type { SpoolMessage } from '~/types/spool'

export type DmRef = { channel: string, title: string }

const cache = new Map<string, Ref<DmRef | null>>()

export function useDmRef() {
  const api = useSpoolApi()

  function load(id: string, out: Ref<DmRef | null>) {
    void withSessionRetry(api, () => api.getTopic(id, { limit: 1 }))
      .then((data) => {
        const rows = ((data as { messages?: SpoolMessage[] }).messages || [])
        const root = rows.find((m) => String(m.task_id || '') === id) || rows[0]
        const channel = String((root && root.channel) || '').replace(/^#/, '')
        if (channel) out.value = { channel, title: topicTitleFromRows(rows, null) }
      })
      .catch(() => { cache.delete(id) /* a later card may retry; none shows meanwhile */ })
  }

  /** The topic a DM row is about, once read; null until then or when unreadable. */
  function refOf(taskId: string): Ref<DmRef | null> {
    const id = String(taskId || '').toLowerCase()
    let hit = cache.get(id)
    if (!hit) {
      hit = shallowRef<DmRef | null>(null)
      cache.set(id, hit)
      if (id) load(id, hit)
    }
    return hit
  }

  return { refOf }
}
