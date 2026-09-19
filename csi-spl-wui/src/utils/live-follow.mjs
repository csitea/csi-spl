/**
 * Thread follow, door and presence helpers (gap row A3). Node tests import
 * this file; the live / roster stores and the pages wrap it.
 *
 * - Reconnect catch-up: wui-live-ws §7 — after a reconnect, one
 *   GET /v1/view/threads/{task_id}?after=<last cursor>, de-duplicated by msg_id.
 * - Door: view-v1 §2 — a 401 `view_door` is a prompt (sign in, or a view
 *   token), not a raw error.
 * - Presence: wui-live-ws §3 `presence` frames, last-writer-wins per peer.
 */

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
 * One catch-up read after a reconnect. `getThread` is the spool client's
 * (taskId, { after, limit }) → { messages }. Without a cursor there is nothing
 * to anchor on, so this returns null and the caller re-opens instead.
 * @template {{ msg_id?: string, cursor?: string, received_at?: string }} T
 * @param {(id: string, opts: { after: string, limit?: number }) => Promise<{ messages: T[] }>} getThread
 * @param {string} taskId
 * @param {T[]} messages
 * @param {number} [limit]
 * @returns {Promise<null | { after: string, rows: T[] }>}
 */
export async function catchUp(getThread, taskId, messages, limit = 200) {
  const after = lastCursor(messages)
  if (!taskId || !after) return null
  const data = await getThread(taskId, { after, limit })
  return { after, rows: newRows(messages, (data && data.messages) || []) }
}

/**
 * A view-door refusal (view-v1 §2): 401 with `view_door`, or a bare 401.
 * @param {unknown} err
 * @returns {boolean}
 */
export function isDoor(err) {
  const e = /** @type {{ status?: number, token?: string }} */ (err || {})
  return e.status === 401 && (!e.token || e.token === 'view_door')
}

/**
 * Which ways in the door offers. The hub's 401 detail names them ("a view
 * token or a member session is required"); no detail → offer both.
 * @param {string} [detail]
 * @returns {{ session: boolean, token: boolean }}
 */
export function doorModes(detail) {
  const d = String(detail || '').toLowerCase()
  if (!d) return { session: true, token: true }
  const session = /session|sign[ -]?in|member/.test(d)
  const token = /token/.test(d)
  return session || token ? { session, token } : { session: true, token: true }
}

/**
 * The sign-in link a door prompt shows: /login?redirect=<here>&tenant=<t>.
 * redirect stays a same-site path; tenant only when it is a DNS label.
 * @param {string} path
 * @param {string} [tenant]
 * @returns {string}
 */
export function signInHref(path, tenant) {
  let p = String(path || '/')
  if (!p.startsWith('/') || p.startsWith('//') || p.startsWith('/\\') || p.startsWith('/login')) p = '/'
  const q = new URLSearchParams({ redirect: p })
  const t = String(tenant || '')
  if (/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(t)) q.set('tenant', t)
  return `/login?${q}`
}

/**
 * Apply one presence frame to the online list (labels `<agent>@<box>`).
 * Last writer wins; anything that is not a presence frame is ignored.
 * @param {string[]} online
 * @param {{ type?: string, peer?: string, status?: string }} frame
 * @returns {string[]} a new list when it changed, else the same one
 */
export function applyPresence(online, frame) {
  const list = Array.isArray(online) ? online : []
  const f = frame || {}
  if (f.type !== undefined && f.type !== 'presence') return list
  const peer = String(f.peer || '')
  if (!peer) return list
  const has = list.includes(peer)
  if (f.status === 'online') return has ? list : [...list, peer]
  if (f.status === 'offline') return has ? list.filter((p) => p !== peer) : list
  return list
}

/**
 * Split an `<agent>@<box>` label. A bare id has box ''.
 * @param {string} label
 * @returns {{ id: string, box: string }}
 */
export function splitPeer(label) {
  const s = String(label || '')
  const at = s.indexOf('@')
  return at < 0 ? { id: s, box: '' } : { id: s.slice(0, at), box: s.slice(at + 1) }
}
