/**
 * Topic follow, door and presence helpers (gap row A3). Node tests import
 * this file; the live / roster stores and the pages wrap it.
 *
 * - Reconnect catch-up: wui-live-ws §7 — after a reconnect, one
 *   GET /v1/view/topics/{task_id}?after=<last cursor>, de-duplicated by msg_id.
 * - Door: view-v1 §2 — a 401 `view_door` is a prompt (sign in, or a view
 *   token), not a raw error.
 * - Presence: wui-live-ws §3 `presence` frames, last-writer-wins per peer,
 *   and the rows the people pane draws from them (`peopleRows`).
 */
import { displayName } from './channel-feed.mjs'
import { BROWSER_BOX } from './view-api.mjs'

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
 * The session-door arming in flight for a client, so concurrent callers share
 * one of them. Keyed by the api object and dropped as soon as it settles.
 * @type {WeakMap<object, Promise<{ armed: boolean, value?: unknown, error?: unknown }>>}
 */
const arming = new WeakMap()

/**
 * Switch the door to 'session' and prove it with one retry. A retry that fails
 * without an HTTP status (network / CORS) is a token door refusing credentials:
 * restore the door and report it unarmed, so every caller falls back to its own
 * 401 prompt (A3, 901ea06).
 * @param {{ door: string, setDoor: (d: string) => void }} api
 * @param {string} prev
 * @param {() => Promise<unknown>} read
 * @returns {Promise<{ armed: boolean, value?: unknown, error?: unknown }>}
 */
async function armSessionDoor(api, prev, read) {
  api.setDoor('session')
  try {
    return { armed: true, value: await read() }
  } catch (e) {
    const st = /** @type {{ status?: number }} */ (e || {}).status
    if (!st) {
      api.setDoor(prev)
      return { armed: false }
    }
    /* an answered retry: the door IS the session one, this read just failed */
    return { armed: true, error: e }
  }
}

/**
 * view-v1 §2 / 010 FR-009: a door that takes a member session needs the
 * sign-in cookie (credentials 'include'). On a 401 whose detail offers a
 * session, switch the client to door 'session' once and retry. The 401 detail
 * is the same for a token door, whose CORS refuses credentials: a retry that
 * fails without an HTTP status (network / CORS) restores the door and rethrows
 * the ORIGINAL 401, so the caller still shows the door prompt.
 *
 * The door is read BEFORE the read goes out, not in the catch: the shell fires
 * several reads at once (channels, roster, a topic), and reading it after the
 * fact sees the door a SIBLING caller has already switched, so this caller
 * rethrows a 401 that a retry would have answered — the channel list stayed
 * empty for a poll on prd (CLE-3415). Concurrent callers then share ONE arming
 * of the door (single-flight): the first switches it and proves it with its own
 * retry, the others wait for that verdict and re-issue their own read, which is
 * a different URL for each of them and cannot be shared.
 * @template T
 * @param {{ door: string, setDoor: (d: string) => void }} api
 * @param {() => Promise<T>} read
 * @returns {Promise<T>}
 */
export async function withSessionRetry(api, read) {
  const door = api.door
  try {
    return await read()
  } catch (e) {
    const err = /** @type {{ status?: number, detail?: string }} */ (e || {})
    if (!isDoor(err) || door === 'session' || !doorModes(err.detail).session) throw e
    const pending = arming.get(api)
    if (pending) {
      /* someone else is arming the door: their verdict, our own read */
      if (!(await pending).armed) throw e
      return /** @type {Promise<T>} */ (read())
    }
    const run = armSessionDoor(api, door, read)
    arming.set(api, run)
    let out
    try {
      out = await run
    } finally {
      if (arming.get(api) === run) arming.delete(api)
    }
    if (!out.armed) throw e
    if (out.error) throw out.error
    return /** @type {T} */ (out.value)
  }
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

/**
 * Everyone the reader can see, one row each, sorted by label.
 *
 * Three sources, in this order, first writer wins per label:
 *   - the agents of each box (view-v1 §4.1 `boxes`);
 *   - the tenant's members, folded into box-wui by `rosterFromView`, so a
 *     member is listed whether or not they are online right now;
 *   - a peer named ONLY by a live `presence` frame — a door-off guest
 *     (`GST-n@box-wui`) is in no roster at all (003 FR-028).
 *
 * `online` is the socket's list, not the snapshot's: wui-live-ws §3.2 is the
 * only thing that knows a human holds a browser socket.
 *
 * `self` marks the reader's own row. CLE-3448: the pane used to DROP that row,
 * which is why a human signed in alone saw no human at all — the one peer
 * guaranteed to be online was the one deliberately hidden.
 *
 * @param {Record<string, string[]>} roster box id → agent ids
 * @param {string[]} online peer labels the socket has called online
 * @param {string} selfId the reader's own agent id (`welcome.as`); '' = unknown
 * @param {string} [selfBox]
 * @returns {{ id: string, box: string, label: string, online: boolean, self: boolean }[]}
 */
export function peopleRows(roster, online, selfId, selfBox = BROWSER_BOX) {
  const lit = new Set(Array.isArray(online) ? online : [])
  const box0 = selfBox || BROWSER_BOX
  const mine = (id, box) => Boolean(selfId) && id === selfId && box === box0
  const rows = []
  const listed = new Set()
  const src = roster && typeof roster === 'object' ? roster : {}
  for (const [box, agents] of Object.entries(src)) {
    for (const id of Array.isArray(agents) ? agents : []) {
      if (!id) continue
      const label = displayName(id, box)
      if (listed.has(label)) continue
      listed.add(label)
      rows.push({ id, box, label, online: lit.has(label), self: mine(id, box) })
    }
  }
  for (const label of lit) {
    if (listed.has(label)) continue
    const { id, box } = splitPeer(label)
    if (!id || !box) continue
    listed.add(label)
    rows.push({ id, box, label, online: true, self: mine(id, box) })
  }
  return rows.sort((a, b) => a.label.localeCompare(b.label))
}

/**
 * Fold a fresh `/v1/view/roster` presence snapshot onto what the socket has
 * already said, and answer the new `online` list.
 *
 * The snapshot is authoritative for the boxes it reports on and ONLY those:
 * a box it calls offline really is offline, so its stale entries must go.
 * box-wui is excluded from that authority on purpose — it is listed as a box
 * (it has a pin row) but never holds a live box session, so the snapshot
 * always reads `online: false` for it, while whether the humans on it are
 * online is entirely a matter of who holds a browser socket.
 *
 * CLE-3448: letting the snapshot own box-wui deleted every human's dot on the
 * next refresh, and `refresh()` runs again on every reconnect.
 *
 * @param {string[]} online what the socket has said so far
 * @param {string[]} snapshot the snapshot's own online labels
 * @param {Record<string, string[]>} roster the snapshot's boxes
 * @returns {string[]}
 */
export function mergeSnapshotOnline(online, snapshot, roster) {
  const src = roster && typeof roster === 'object' ? roster : {}
  const owned = new Set(Object.keys(src).filter((b) => b !== BROWSER_BOX))
  const kept = (Array.isArray(online) ? online : []).filter((l) => !owned.has(splitPeer(l).box))
  return [...new Set([...(Array.isArray(snapshot) ? snapshot : []), ...kept])]
}
