/**
 * Spec 169 8.5.4 to 8.5.6 (row T19): the "Move to workspace" dialog's logic,
 * apart from its component so the unit tests read it. Loaded only with the
 * dialog (ChannelWorkspaceMoveDialog.vue, lazy) and by the lazy client's mock.
 *
 * The hub's routes (T14, T15, T17):
 *   POST /v1/channels/{channel}/workspace-move/plan  the plan with .blocked
 *   POST /v1/channels/{channel}/workspace-move       the confirm: the GO, P1
 *   GET  /v1/channel-moves/{move_id}                 where the move stands
 */

/** The e2e's opt-in: a JSON fixture of the hub's answers; unset = no move. */
export const MOVE_MOCK_KEY = 'spool.mock.channel_move'
/** The mock's record of the last confirm body (the e2e reads the GO sent). */
export const MOVE_MOCK_SENT_KEY = 'spool.mock.channel_move.sent'

const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
const HOURS_RE = /^hours: (HUM-[0-9]+) /

/** The states of 8.5.6's table, and running (no row of it). */
const MOVE_STATES = ['waiting', 'running', 'not_moved', 'cleanup_failed', 'traces', 'moved']

/**
 * The request body of the plan and the confirm. The dialog offers no copy and
 * no new name (8.5.1), so neither is sent.
 *
 * @param {string} dst
 * @param {{ keep?: string[], keepEmails?: string[], leaveHours?: string[] }} [pick]
 */
export function moveBody(dst, pick = {}) {
  return {
    dst: String(dst || ''),
    keep: [...(pick.keep || [])],
    keep_emails: [...(pick.keepEmails || [])],
    leave_hours: [...(pick.leaveHours || [])],
  }
}

/** @param {{ blocked?: unknown } | null | undefined} plan */
export function blockedLines(plan) {
  const b = plan && Array.isArray(plan.blocked) ? plan.blocked : []
  return b.map((l) => String(l || '')).filter(Boolean)
}

/**
 * The screen after a plan: blocked while any line stops the move, else the
 * confirm (8.5.4 items 2 and 3).
 *
 * @param {{ blocked?: unknown } | null | undefined} plan
 * @returns {'blocked' | 'confirm'}
 */
export function screenAfterPlan(plan) {
  return blockedLines(plan).length ? 'blocked' : 'confirm'
}

/**
 * What clears one stop: the hint's key under channel_move.clears (the
 * operator page's section 2.3), and the member an hours stop names (its
 * "leave these rows" choice, T7d's leave_hours).
 *
 * @param {string} line a .blocked line in the hub's words
 * @returns {{ kind: string, member: string }}
 */
export function stopKind(line) {
  const l = String(line || '')
  const h = HOURS_RE.exec(l)
  if (h) return { kind: 'hours', member: h[1] }
  if (/^seat .* has no desk in /.test(l)) return { kind: 'seat', member: '' }
  if (/^box .* is not pinned in /.test(l)) return { kind: 'pin', member: '' }
  if (l.startsWith('shared ')) return { kind: 'shared', member: '' }
  if (/^channel .* exists in /.test(l)) return { kind: 'name', member: '' }
  if (l.includes('has no orchestrator seat')) return { kind: 'orchestrator', member: '' }
  if (l.includes('file quota')) return { kind: 'quota', member: '' }
  return { kind: 'other', member: '' }
}

/**
 * The plan's counts as rows, largest first, the ones with nothing left out.
 *
 * @param {{ counts?: Record<string, unknown> } | null | undefined} plan
 * @returns {{ table: string, n: number }[]}
 */
export function countRows(plan) {
  const c = plan && plan.counts && typeof plan.counts === 'object' ? plan.counts : {}
  return Object.entries(c)
    .map(([table, n]) => ({ table, n: Number(n) || 0 }))
    .filter((r) => r.n > 0)
    .sort((a, b) => b.n - a.n || a.table.localeCompare(b.table))
}

/**
 * The move id a 409 move_open names in its detail, else ''.
 *
 * @param {unknown} err
 */
export function openMoveId(err) {
  const e = /** @type {{ token?: unknown, detail?: unknown }} */ (err && typeof err === 'object' ? err : {})
  if (e.token !== 'move_open') return ''
  const m = UUID_RE.exec(String(e.detail || ''))
  return m ? m[0].toLowerCase() : ''
}

/**
 * The stuck table's row for a status answer (8.5.6): its state (the key of
 * its line under channel_move.state), and what that row lists. Nothing
 * reads as moved before the hub said `moved` (done_at set).
 *
 * @param {Record<string, any> | null | undefined} st the route's answer
 */
export function statusView(st) {
  const s = st && typeof st === 'object' ? st : {}
  let state = MOVE_STATES.includes(String(s.state)) ? String(s.state) : 'running'
  if (state === 'waiting' && s.stuck === true) state = 'stuck'
  const proofs = (Array.isArray(s.proofs) ? s.proofs : [])
    .map((p) => ({ name: String(p?.name || ''), count: Number(p?.count) || 0 }))
    .filter((p) => p.name)
  const kept = (Array.isArray(s.kept) ? s.kept : [])
    .map((k) => ({ store: String(k?.store || ''), until: String(k?.until || k?.gone_by || '') }))
    .filter((k) => k.store)
  return {
    state,
    reason: ['not_moved', 'cleanup_failed'].includes(state) ? String(s.reason || '') : '',
    link: ['cleanup_failed', 'traces', 'moved'].includes(state) ? String(s.link || '') : '',
    proofs: state === 'traces' ? proofs : [],
    kept: state === 'moved' ? kept : [],
    dst: String(s.dst || ''),
    src: String(s.src || ''),
  }
}

/* ---- the mock (e2e only: with the key unset it offers no move) ---- */

function storeOf() {
  try {
    if (typeof globalThis.localStorage !== 'undefined') return globalThis.localStorage
  } catch { /* private mode */ }
  return null
}

/**
 * @param {number} status
 * @param {string} token
 * @param {string} [detail]
 */
function hubErr(status, token, detail = '') {
  return Object.assign(new Error(`spool ${status} ${token}`), { status, token, detail })
}

/**
 * @param {Storage | null} store
 * @returns {Record<string, any> | null}
 */
function fixture(store) {
  try {
    const raw = store ? store.getItem(MOVE_MOCK_KEY) : ''
    const f = raw ? JSON.parse(raw) : null
    return f && typeof f === 'object' ? f : null
  } catch {
    return null
  }
}

/** The mock's probe: the fixture's targets; without one, no move offered. */
export function mockMoveProbe(store = storeOf()) {
  const f = fixture(store)
  if (!f) return { allowed: false, targets: [] }
  return { allowed: true, targets: Array.isArray(f.targets) ? f.targets : [] }
}

/**
 * The mock's plan: the fixture's plan; an hours stop of a member in
 * leave_hours is cleared, as the hub's T7d detail clears it.
 *
 * @param {{ leave_hours?: string[] }} body
 */
export function mockMovePlan(body, store = storeOf()) {
  const f = fixture(store)
  if (!f) throw hubErr(403, 'channel_move_owner')
  const plan = f.plan && typeof f.plan === 'object' ? f.plan : {}
  const leave = new Set(body?.leave_hours || [])
  const blocked = blockedLines(plan).filter((l) => !leave.has(stopKind(l).member))
  return { ...plan, blocked }
}

/**
 * The mock's confirm: records the body, then the fixture's answer or error.
 *
 * @param {{ leave_hours?: string[] }} body
 */
export function mockMoveConfirm(body, store = storeOf()) {
  const f = fixture(store)
  if (!f) throw hubErr(403, 'channel_move_owner')
  try { store?.setItem(MOVE_MOCK_SENT_KEY, JSON.stringify(body)) } catch { /* full */ }
  const e = f.confirm_error
  if (e && typeof e === 'object') throw hubErr(Number(e.status) || 409, String(e.error || ''), String(e.detail || ''))
  if (mockMovePlan(body, store).blocked.length) throw hubErr(409, 'move_blocked', 'the move is blocked: clear every line of .blocked first')
  return f.confirm || {}
}

/**
 * The mock's status read: the fixture's status, else 404 unknown_move.
 *
 * @param {string} moveId
 */
export function mockMoveStatus(moveId, store = storeOf()) {
  const f = fixture(store)
  const st = f?.status
  if (!st || typeof st !== 'object') throw hubErr(404, 'unknown_move', 'no such move')
  return { move_id: String(moveId || ''), ...st }
}
