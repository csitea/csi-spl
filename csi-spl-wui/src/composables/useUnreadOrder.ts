/*
 * SPL-2506 (owner HUM-10, t1 43a1030f): every listing puts the items with
 * unread at the edge new posts go to, the most unread at the very edge
 * (utils/unread-first.mjs). The edge follows the person's Message order:
 * the top for newest first, the bottom for newest last (useViewPrefs).
 * The sidebar reads it, so it imports nothing beyond those two.
 */
import { useViewPrefs } from '~/composables/useViewPrefs'
import { unreadFirst } from '~/utils/unread-first.mjs'

export function useUnreadOrder() {
  const { newestLast } = useViewPrefs()
  /** `rows` in today's drawn order (top first), the unread moved to the edge */
  function order<T>(rows: T[], unreadOf: (row: T) => number, at?: (row: T) => string): T[] {
    return unreadFirst(rows, unreadOf, { atEnd: newestLast.value, at })
  }
  return { order }
}
