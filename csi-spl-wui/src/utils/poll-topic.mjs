import { shallowRef } from 'vue'

/* SPL-5954: the whole topic of a poll form, read once and shared by every
   form of that topic; a form mounted again after FRESH_MS reads it again.
   R7 W2: the rows belong to the member who read them, so sign-out drops
   them all (clearPollTopics); a read still in flight then fills a holder
   nobody reads any more. */
export const FRESH_MS = 60_000
const cache = new Map()

/** the held rows of `task` ({ rows: ShallowRef }), refilled by `read(task)` when stale */
export function heldTopic(task, read, now = Date.now()) {
  let h = cache.get(task)
  if (!h) cache.set(task, h = { rows: shallowRef([]), at: 0, busy: false })
  if (!h.busy && now - h.at > FRESH_MS) {
    const fill = h
    fill.busy = true
    Promise.resolve()
      .then(() => read(task))
      .then((r) => { fill.rows.value = r; fill.at = Date.now() })
      .catch(() => { /* the feed's own rows still show what they hold */ })
      .finally(() => { fill.busy = false })
  }
  return h
}

/** sign-out: the next member in this tab starts with no topic rows */
export function clearPollTopics() {
  cache.clear()
}
