/* SPL-1643 (owner HUM-10, t1 1ccf3a20): closing an epic closes and archives
   its issues. The hub refuses a close of an epic that still has open issues
   with 409 epic_close_confirm, naming the count, until the member confirms
   (cascade: true); its answer then names what it archived. */

/** The open-issue count of an epic_close_confirm refusal; null for any other error. */
export function epicCloseOpenCount(err) {
  if (!err || err.token !== 'epic_close_confirm') return null
  const m = /has (\d+) open issues/.exec(String(err.detail || ''))
  return m ? Number(m[1]) : 0
}

/** The keys an update's answer archived (the row first, then its issues); [] when none. */
export function epicClosedKeys(key, data) {
  if (!data || data.archived !== true) return []
  return [key, ...(Array.isArray(data.descendants) ? data.descendants.map(String) : [])]
}
