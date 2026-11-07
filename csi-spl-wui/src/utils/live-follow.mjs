/**
 * Topic follow, door and presence helpers (gap row A3). Node tests import
 * this file; the live / roster stores and the pages wrap it.
 *
 * - Reconnect catch-up: wui-live-ws §7 — after a reconnect, one
 *   GET /v1/view/topics/{task_id}?after=<last cursor>, de-duplicated by msg_id.
 * - The door and presence helpers are in live-follow-core.mjs.
 */

import { safeRedirect } from './auth-client-core.mjs'
import { splitPeer } from './live-follow-core.mjs'

export {
  applyIdle,
  applyPresence,
  doorModes,
  isDoor,
  mergeSnapshotOnline,
  peopleRows,
  splitPeer,
  withSessionRetry,
} from './live-follow-core.mjs'

/**
 * The cursor of the newest stored row (view-v1 §4.4: cursors are opaque, the
 * hub orders by received_at). Rows without a cursor (a mock-mode local send)
 * are skipped. Ties keep the later row in the array.
 * @param {Array<{ cursor?: string, received_at?: string }>} messages
 * @returns {string}
 */
export function lastCursor(messages) {
  let best = null
  for (const m of Array.isArray(messages) ? messages : []) {
    if (!m || !m.cursor) continue
    if (!best || String(m.received_at || '') >= String(best.received_at || '')) best = m
  }
  return best ? String(best.cursor) : ''
}

/**
 * Rows of `incoming` whose msg_id is not in `have` (nor repeated in incoming).
 * @template {{ msg_id?: string }} T
 * @param {T[]} have
 * @param {T[]} incoming
 * @returns {T[]}
 */
export function newRows(have, incoming) {
  const seen = new Set((Array.isArray(have) ? have : []).map((m) => m && m.msg_id))
  const out = []
  for (const m of Array.isArray(incoming) ? incoming : []) {
    if (!m || !m.msg_id || seen.has(m.msg_id)) continue
    seen.add(m.msg_id)
    out.push(m)
  }
  return out
}

/**
 * One catch-up read after a reconnect. `getTopic` is the spool client's
 * (taskId, { after, limit }) → { messages }. Without a cursor there is nothing
 * to anchor on, so this returns null and the caller re-opens instead.
 * @template {{ msg_id?: string, cursor?: string, received_at?: string }} T
 * @param {(id: string, opts: { after: string, limit?: number }) => Promise<{ messages: T[] }>} getTopic
 * @param {string} taskId
 * @param {T[]} messages
 * @param {number} [limit]
 * @returns {Promise<null | { after: string, rows: T[] }>}
 */
export async function catchUp(getTopic, taskId, messages, limit = 200) {
  const after = lastCursor(messages)
  if (!taskId || !after) return null
  const data = await getTopic(taskId, { after, limit })
  return { after, rows: newRows(messages, (data && data.messages) || []) }
}

/**
 * The sign-in link a door prompt shows: /login?redirect=<here>&tenant=<t>.
 * redirect goes through safeRedirect; tenant only when it is a DNS label.
 * @param {string} path
 * @param {string} [tenant]
 * @returns {string}
 */
export function signInHref(path, tenant) {
  const q = new URLSearchParams({ redirect: safeRedirect(path || '/') })
  const t = String(tenant || '')
  if (/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(t)) q.set('tenant', t)
  return `/login?${q}`
}

/**
 * specs/058 (CLE-77932): the DM list is every roster peer PLUS every
 * `<id>@<box>` the reader has a DM with (`dmAt`, keyed by label), so a DM
 * never vanishes from the list because its box stopped announcing that id -
 * the owner could not find his DM with the home CLE-001 once a second
 * CLE-001 was seated on another box. Each address is its own row with its
 * own history. A label without a box, a broadcast and the reader are skipped.
 *
 * @param {Array<{ id: string, box: string, label: string, online: boolean, idle?: boolean }>} rows roster peers
 * @param {Record<string, string>} dmAt last DM moment per peer label
 * @param {string} selfId the reader's id (bare, or id@box)
 */
export function withDmPeers(rows, dmAt, selfId = '') {
  const list = Array.isArray(rows) ? rows : []
  const have = new Set(list.map((p) => p && p.label))
  const me = splitPeer(selfId).id
  const extra = []
  for (const label of Object.keys(dmAt && typeof dmAt === 'object' ? dmAt : {})) {
    const { id, box } = splitPeer(label)
    if (!id || !box || have.has(label) || id === me || /^ALL-0$/.test(id)) continue
    have.add(label)
    extra.push({ id, box, label, online: false, idle: false })
  }
  return extra.length ? [...list, ...extra] : list
}
