/**
 * Spec 153 3.22.3 (row Q4, SPL-6740; owner HUM-10, t1 906c1b28, msg of
 * 11-06 23:50Z): Monitoring -> Queue, read only, over GET
 * /v1/operator/fleet-queue (hub internal/hub/fleet_queue_view.go, row Q3).
 * The body as a view, the cells' words and links, and the mock answer.
 *
 * The hub decides the line (3.22.4: the orch rows queued, or acked with an
 * enqueued_at, the placing ones first, then by position, as
 * spl_spawn_q_rows) and, with placed=1, appends the closed rows newest
 * first; this file keeps that order and drops junk, never re-sorts.
 *
 * Only the Queue page and the lazy spool client import this file, and both
 * import it on demand, so none of it rides the initial JS (C107,
 * ci_initial_gzip_kb). Node tests import it.
 */

import { mockRefused } from './act-as-mock.mjs'
import { isoSeconds } from './iso-seconds.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from './monitoring-tokens.mjs'

/** e2e opt-in (mock only): '' = a line of four and three closed rows, 'empty' = no row. */
export const QUEUE_MOCK_KEY = 'spool.mock.fleet_queue'
/** The mock's operator admin is the Tokens and Lanes tabs' (the same key shows every fleet tab). */
const QUEUE_MOCK_OPERATOR_KEY = TOKENS_MOCK_OPERATOR_KEY

/** The route, with the Placed filter (3.22.3: off by default). */
export function queuePath(placed = false) {
  return '/v1/operator/fleet-queue' + (placed ? '?placed=1' : '')
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const KEY_RE = /^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,8}$/
/* the hub's one lane form, fleetQueuePlacedRe: <ID>@<box> */
const LANE_RE = /^([acgmoqu]-[0-9]{3})@([a-z0-9][a-z0-9-]{0,31})$/
const str = (v) => (typeof v === 'string' ? v : '')
const int = (v) => (Number.isFinite(Number(v)) && Number(v) >= 0 ? Math.trunc(Number(v)) : 0)
const prio = (v) => { const n = int(v); return n >= 1 && n <= 5 ? n : 0 }

/** Where a request's priority came from (3.22.6; store AskPrioOwn, AskPrioDiscussion, AskPrioDefault). */
const QUEUE_PRIO_SOURCES = Object.freeze(['own', 'discussion', 'default'])
/** The classes the placer knows (3.22.3); another is shown as sent. */
const QUEUE_CLASSES = Object.freeze(['ci', 'refactor', 'bug', 'feature'])
/** The flags a row may carry (store fleet_ask.go: urgent on a bug, bypass on a feature). */
const QUEUE_FLAGS = Object.freeze(['urgent', 'bypass'])
/** The closed states a Placed row is in (rdb 0097). */
const QUEUE_CLOSED = Object.freeze(['done', 'declined', 'dead'])

/**
 * The hub's answer as the page's view, in the hub's order. A row without an
 * ask id is dropped; a lane not in the hub's one form is dropped (C104: never
 * guessed).
 * @param {unknown} body
 */
export function fleetQueueOf(body) {
  const b = body && typeof body === 'object' ? /** @type {Record<string, any>} */ (body) : {}
  const rows = (Array.isArray(b.rows) ? b.rows : []).filter((r) => r && typeof r === 'object' && str(r.ask_id)).map((r) => ({
    askId: str(r.ask_id),
    state: str(r.state) || 'queued',
    position: int(r.position),
    priority: prio(r.priority),
    prioritySource: QUEUE_PRIO_SOURCES.includes(str(r.priority_source)) ? str(r.priority_source) : '',
    class: str(r.class),
    flag: QUEUE_FLAGS.includes(str(r.flag)) ? str(r.flag) : '',
    summary: str(r.summary),
    discussion: str(r.discussion),
    issueKey: str(r.issue_key),
    vendor: str(r.vendor),
    enqueuedAt: str(r.enqueued_at),
    inLineS: int(r.in_line_s),
    holdReason: str(r.hold_reason),
    lane: LANE_RE.test(str(r.lane)) ? str(r.lane) : '',
  }))
  return { asOf: str(b.as_of), fleet: str(b.fleet), total: int(b.total), rows }
}

/**
 * The Position cell (3.22.3): `n/total` for a queued row, the word for a
 * placing one, the closed state for a Placed row.
 * @param {{ state: string, position: number }} row
 * @param {number} total
 * @returns {{ key?: string, text?: string }}
 */
export function queuePositionCell(row, total) {
  if (row.state === 'queued' && row.position > 0) return { text: row.position + '/' + total }
  if (row.state === 'placing') return { key: 'monitoring.queue.placing' }
  if (QUEUE_CLOSED.includes(row.state)) return { key: 'monitoring.queue.state_' + row.state }
  return { text: '—' }
}

/** The Class cell's key, or null to show the class as sent. */
export function queueClassKey(cls) {
  return QUEUE_CLASSES.includes(cls) ? 'monitoring.queue.class_' + cls : null
}

/**
 * The In line cell (3.22.3: since enqueued_at, the hub's clock): minutes
 * under an hour, hours and minutes under a day, else days and hours.
 * @param {number} s
 * @returns {{ key: string, params: Record<string, number> }}
 */
export function queueInLine(s) {
  const m = Math.floor(int(s) / 60)
  if (m < 60) return { key: 'monitoring.queue.in_line_min', params: { n: m } }
  if (m < 1440) return { key: 'monitoring.queue.in_line_h', params: { h: Math.floor(m / 60), m: m % 60 } }
  return { key: 'monitoring.queue.in_line_d', params: { d: Math.floor(m / 1440), h: Math.floor((m % 1440) / 60) } }
}

/** Whether a row is in the line (Waits on, In line apply) rather than a closed Placed row. */
export function queueOpen(row) {
  return row.state === 'queued' || row.state === 'placing'
}

/**
 * The typed ref (utils/note-links.mjs) a row's discussion names, or null: the
 * asks are the operator workspace's, so a topic uuid is the page's own
 * workspace's topic.
 * @param {{ discussion: string }} row
 * @param {string} pageTenant
 * @returns {{ kind: 'topic', workspace_id: string, ref: string } | null}
 */
export function queueTopicRef(row, pageTenant) {
  const id = str(row && row.discussion).trim()
  if (!pageTenant || !UUID_RE.test(id)) return null
  return { kind: 'topic', workspace_id: pageTenant, ref: id.toLowerCase() }
}

/**
 * The typed ref a row's issue key names, or null (text).
 * @param {{ issueKey: string }} row
 * @param {string} pageTenant
 * @returns {{ kind: 'issue', workspace_id: string, ref: string } | null}
 */
export function queueIssueRef(row, pageTenant) {
  const key = str(row && row.issueKey).trim()
  if (!pageTenant || !KEY_RE.test(key)) return null
  return { kind: 'issue', workspace_id: pageTenant, ref: key }
}

/**
 * The Lane cell (3.22.3): a placed row's lane links to its row on
 * Monitoring -> Lanes (laneDeepLink's shape) while that lane is active, else
 * it reads "ended" with its agent id as text. No lane: null.
 * @param {{ lane: string }} row
 * @param {Set<string> | null} active the active lanes' id@box, null = not read
 * @returns {{ lane: string, agentId: string, to: { path: string, query: { lane: string } } | null } | null}
 */
export function queueLaneCell(row, active) {
  const m = LANE_RE.exec(str(row && row.lane))
  if (!m) return null
  const live = active === null || active.has(row.lane)
  return { lane: row.lane, agentId: m[1], to: live ? { path: '/monitoring/lanes', query: { lane: row.lane } } : null }
}

function mockForbidden() {
  const e = /** @type {Error & { status?: number, token?: string, permission?: string }} */ (new Error('only an admin of the operator workspace reads the fleet'))
  e.status = 403
  e.token = 'forbidden'
  e.permission = 'operator.workspaces'
  return e
}

function mockStore() {
  try { return typeof localStorage === 'undefined' ? null : localStorage } catch { return null }
}

/** The mock rows' discussion, the Lanes mock's topic (one workspace, one topic). */
export const QUEUE_MOCK_TOPIC = '5e7b15c9-2995-427d-8b05-659762fbb9d8'

/**
 * The mock's GET: 403 operator.workspaces unless the e2e opted into the
 * operator admin, else the hub's answer: one row placing, three queued (a ci
 * row of its own priority 1, a feature at its discussion's 2 with an issue,
 * a bug at the default 3 held by a reason), and with placed the closed rows:
 * one placed as a lane the Lanes mock has active (c-085@box-a), one placed as
 * a lane that ended, one declined.
 */
export function mockFleetQueue(placed = false, store = mockStore(), now = new Date()) {
  const get = (k) => { try { return store ? store.getItem(k) : null } catch { return null } }
  if (get(QUEUE_MOCK_OPERATOR_KEY) !== '1') throw mockRefused(queuePath(placed), mockForbidden())
  const asOf = new Date(Math.floor(now.getTime() / 1000) * 1000)
  const ago = (s) => isoSeconds(new Date(asOf.getTime() - s * 1000))
  const out = { as_of: isoSeconds(asOf), fleet: 'main', total: 0, rows: /** @type {any[]} */ ([]) }
  if (get(QUEUE_MOCK_KEY) === 'empty') return out
  const row = (o) => ({ priority: 3, priority_source: 'default', class: 'feature', summary: '', from: 'c-001@box-a', topic: 'dispatch-' + QUEUE_MOCK_TOPIC.slice(0, 8), ...o })
  const id = (n) => '6a1e0c55-0000-4000-8000-00000000000' + n
  out.rows = [
    row({ ask_id: id(1), state: 'placing', priority: 2, priority_source: 'discussion', class: 'bug',
      summary: 'Lanes: the Prio cell sorts a dash last', discussion: QUEUE_MOCK_TOPIC, issue_key: 'SPL-6701', placement: 'claude:c001-prio-dash', vendor: 'claude',
      enqueued_at: ago(1800), in_line_s: 1800 }),
    row({ ask_id: id(2), state: 'queued', position: 1, queue_len: 3, priority: 1, priority_source: 'own', priority_by: 'HUM-10',
      class: 'ci', summary: 'CI: the e2e job reads the generated bundle', placement: 'claude:c001-ci-e2e-bundle', vendor: 'claude',
      enqueued_at: ago(600), in_line_s: 600 }),
    row({ ask_id: id(3), state: 'queued', position: 2, queue_len: 3, priority: 2, priority_source: 'discussion', class: 'feature', flag: 'bypass',
      summary: 'Spec 153 build round, row Q5: the 1..5 chooser on a request and in the Lanes Prio cell, the PUT on the lane, and its locale keys in every language',
      discussion: QUEUE_MOCK_TOPIC, issue_key: 'SPL-6741', placement: 'agy:c001-s153-q5', vendor: 'agy', enqueued_at: ago(5400), in_line_s: 5400 }),
    row({ ask_id: id(4), state: 'queued', position: 3, queue_len: 3, class: 'bug', flag: 'urgent',
      summary: 'The desk tail misses a post from another box', placement: 'grok:c001-desk-tail', vendor: 'grok',
      enqueued_at: ago(93780), in_line_s: 93780, hold_reason: 'grok weekly limit' }),
  ]
  out.total = 3
  if (placed) {
    out.rows.push(
      row({ ask_id: id(5), state: 'done', class: 'feature', summary: 'Spec 153 build row B4: the Lanes tab',
        discussion: QUEUE_MOCK_TOPIC, issue_key: 'SPL-3215', placement: 'claude:c001-s153-b4', vendor: 'claude', enqueued_at: ago(7200), in_line_s: 0,
        reason: 'placed: c-085@box-a', lane: 'c-085@box-a' }),
      row({ ask_id: id(6), state: 'done', class: 'refactor', summary: 'Refactor round 14 row 02',
        placement: 'claude:r14-02', vendor: 'claude', enqueued_at: ago(9000), in_line_s: 0, reason: 'placed: c-412@box-b', lane: 'c-412@box-b' }),
      row({ ask_id: id(7), state: 'declined', class: 'bug', summary: 'A duplicate of SPL-6701',
        placement: 'claude:c001-dup', vendor: 'claude', enqueued_at: ago(9600), in_line_s: 0, reason: 'superseded by SPL-6701' }),
    )
  }
  return out
}
