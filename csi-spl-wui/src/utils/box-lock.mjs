/**
 * The box owner lock in the WUI (spec 025 box-owner-lock.md, row B8,
 * SPL-3015). A locked box's agents are reached only by the lock's owners;
 * the hub refuses everyone else with 403 `box_locked` (B3, B5) and serves
 * the lock itself only to an owner (`GET /v1/boxes/{box}/lock`, B2). The
 * WUI only carries what the owner's box signed (`spool lock create`): it
 * holds no key and signs nothing (6.2).
 *
 * The mock hook `spool.mock.box-lock` = { box, owners, peer_boxes? } stands
 * in for a hub with that lock: the mock refuses a non-owner's send to an
 * agent of that box, and answers its lock to an owner only. With no hook
 * every box is open, as on a hub with no lock row. Loaded lazily, with the
 * pane and the mock: none of it rides the initial JS.
 */
import { storageGetJson } from './prefs.mjs'

export const BOX_LOCK_MOCK_KEY = 'spool.mock.box-lock'
/** the box command whose printed output the confirm dialog takes */
export const BOX_LOCK_CREATE_CMD = 'spool lock create'

const refused = (status, token, msg) => Object.assign(new Error(msg), { status, token })
const strList = (v) => (Array.isArray(v) ? v.map(String) : [])

/** The mock hook's lock, or null: { box, owners[], peer_boxes[] }. */
function mockBoxLockHook() {
  const h = storageGetJson(BOX_LOCK_MOCK_KEY, null)
  if (!h || typeof h.box !== 'string' || !h.box) return null
  return { box: h.box, owners: strList(h.owners), peer_boxes: strList(h.peer_boxes) }
}

/**
 * The mock twin of the hub's dispatchCheck refusal (B3, path 2): a send to
 * an agent seated on the hooked box, by someone not in its owners, is 403
 * box_locked. The detail is the hub's and never names an owner (5.2).
 */
export function mockBoxSendRefusal(me, seatBox) {
  const lock = mockBoxLockHook()
  if (!lock || !seatBox || lock.box !== seatBox || lock.owners.includes(me)) return
  throw refused(403, 'box_locked', "this box's agents are reachable only by its lock's owners")
}

/**
 * The pasted `spool lock create` output: { signed_body, signature,
 * box_signature }, and the lock body it signs. `error` is an i18n key when
 * the text is not that output, or names another box.
 */
export function parseLockCreate(text, box) {
  let req
  let body
  try {
    req = JSON.parse(String(text || ''))
    body = JSON.parse(String((req && req.signed_body) || ''))
  } catch {
    return { error: 'box_lock.paste_bad' }
  }
  const str = (k) => (typeof req[k] === 'string' ? req[k] : '')
  if (!str('signature') || !str('box_signature') || !body || !strList(body.owners).length) return { error: 'box_lock.paste_bad' }
  if (body.box_id !== box) return { error: 'box_lock.paste_other_box' }
  return {
    req: { signed_body: str('signed_body'), signature: str('signature'), box_signature: str('box_signature') },
    owners: strList(body.owners),
    peers: strList(body.peer_boxes),
  }
}

/** The i18n key for a lock route's refusal (6.2): each token its own line. */
export function lockRefusalKey(err) {
  const t = err && typeof err === 'object' ? /** @type {{ token?: unknown }} */ (err).token : ''
  switch (t) {
    case 'not_owner': return 'box_lock.err_not_owner'
    case 'bad_box_sig': return 'box_lock.err_bad_box_sig'
    case 'bad_sig': return 'box_lock.err_bad_sig'
    case 'box_locked': return 'box_lock.err_already'
    case 'bad_body': return 'box_lock.err_bad_body'
    case 'not_found': return 'box_lock.err_no_box'
    default: return 'box_lock.err_failed'
  }
}

/** The lock as the pane shows it: owners, peer boxes, version, audit newest first. */
export function lockViewOf(row) {
  const r = row && typeof row === 'object' ? row : {}
  const audit = (Array.isArray(r.audit) ? r.audit : []).map((a) => ({
    who: String(a.human_id || a.from_box || ''),
    path: String(a.path || ''),
    verdict: String(a.verdict || ''),
    count: Number(a.count) || 1,
    at: String(a.last_at || a.first_at || ''),
  }))
  return { owners: strList(r.owners), peers: strList(r.peer_boxes), version: Number(r.version) || 0, audit }
}

/**
 * The mock lock routes. `me` is the mock viewer's HUM id. GET answers the
 * hooked or created lock to an owner and 404 to anyone else, as the hub
 * does; POST takes the pasted output as the hub's create does (B2).
 */
export function createMockBoxLock() {
  const made = new Map()
  const row = (box, owners, peers, audit) => ({
    tenant_id: 'mock', box_id: box, lock_pubkey: 'mock', box_pubkey: 'mock', owners, peer_boxes: peers, hide_posts: true, version: 1, audit,
  })
  const lockOf = (box) => {
    if (made.has(box)) return made.get(box)
    const h = mockBoxLockHook()
    if (!h || h.box !== box) return null
    return row(box, h.owners, h.peer_boxes, [
      { human_id: 'HUM-2', path: 'dispatch', verdict: 'refused', first_at: '2026-10-23T08:00:00Z', last_at: '2026-10-23T08:01:00Z', count: 2 },
    ])
  }
  return {
    get(box, me) {
      const l = lockOf(box)
      if (!l || !l.owners.includes(me)) throw refused(404, 'not_found', 'no such box lock')
      return l
    },
    create(box, req, me) {
      const p = parseLockCreate(JSON.stringify(req || {}), box)
      if (p.error) throw refused(400, 'bad_body', 'signed_body is not a lock body')
      if (!p.owners.includes(me)) throw refused(403, 'not_owner', 'the confirming member is not an owner in the lock body')
      if (lockOf(box)) throw refused(409, 'box_locked', 'this box is already locked')
      const l = row(box, p.owners, p.peers, [])
      made.set(box, l)
      return l
    },
  }
}
