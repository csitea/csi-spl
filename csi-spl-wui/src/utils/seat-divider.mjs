/**
 * Spec 061 3.6, lane L10: the "new holder since" divider. Agent ids are
 * reused (3-digit rolling ids 004-999 after a 24 h quarantine), and history
 * keeps the bare id, so a DM with c-004 holds the previous holder's messages
 * too. The hub's roster says when the current holder was seated
 * (view-v1 §4.1 boxes[].seated_at, rdb 0107); the divider goes at the first
 * message on or after that time.
 */
import { when } from './read-cursor.mjs'

/**
 * The msg_id of the chronologically-first message at or after `seatedAt`,
 * or '' when there is no divider to draw: no seat time, no message after it,
 * or no message before it (nothing of a previous holder is on screen, so the
 * whole feed is the current holder's and a divider would say nothing).
 */
export function seatDividerId(messages, seatedAt) {
  const seat = Date.parse(String(seatedAt || ''))
  if (!Number.isFinite(seat)) return ''
  let older = false
  let best = null
  for (const m of messages || []) {
    const at = Date.parse(when(m))
    if (!Number.isFinite(at)) continue
    if (at < seat) {
      older = true
      continue
    }
    const id = String((m && m.msg_id) || '')
    if (!best || at < best.at || (at === best.at && id < best.id)) best = { at, id }
  }
  return older && best ? best.id : ''
}

/** The seat time of `id` on `box` from the roster store's per-box detail, '' when none. */
export function seatedAtFor(boxes, id, box) {
  if (!id || !box) return ''
  const b = boxes && boxes[box]
  const s = b && b.seated_at
  return String((s && s[id]) || '')
}
