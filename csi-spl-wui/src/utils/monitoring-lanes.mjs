/**
 * Spec 153 3.2 (build row B4, SPL-3215; owner HUM-10, prd t1 5e7b15c9, msgs
 * 5949d68e and 5c7d1395): Monitoring -> Lanes over GET
 * /v1/operator/fleet-lanes (hub internal/hub/fleet_lanes_view.go, B3). The
 * body as a view, the 60 s poll, the row's links and the mock answer.
 *
 * The hub decides which lanes are active (decision P1) and sorts them newest
 * write first; this file keeps its order and drops junk, never re-filters.
 *
 * Only the Lanes page and the lazy spool client import this file, so none of
 * it rides the initial JS (ci_initial_gzip_kb, case C20). Node tests import it.
 */

import { mockRefused } from './act-as-mock.mjs'
import { isoSeconds } from './iso-seconds.mjs'
import { lagSeconds, TOKENS_MOCK_OPERATOR_KEY } from './monitoring-tokens.mjs'

/** Polling while the tab is open and the browser tab visible (decision P4). */
export const LANES_POLL_MS = 60000
/** Lag after which the data is amber (1.5x the timer) and red (3x), as Tokens. */
const LANES_STALE_AMBER_S = 90
const LANES_STALE_RED_S = 180
/** e2e opt-in (mock only): '' = three lanes, 'empty' = none active. */
export const LANES_MOCK_KEY = 'spool.mock.fleet_lanes'
/** The mock's operator admin is the Tokens tab's (the same key shows both tabs). */
export const LANES_MOCK_OPERATOR_KEY = TOKENS_MOCK_OPERATOR_KEY

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const KEY_RE = /^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,8}$/
const str = (v) => (typeof v === 'string' ? v : '')
const int = (v) => (Number.isFinite(Number(v)) && Number(v) >= 0 ? Math.trunc(Number(v)) : 0)

/**
 * The hub's answer as the page's view, in the hub's order. A row without an
 * agent id is dropped; an issue without a key is dropped. Every row keeps
 * the workspace it belongs to (spec 153 3.8: name, else id).
 * @param {unknown} body
 */
export function fleetLanesOf(body) {
  const b = body && typeof body === 'object' ? /** @type {Record<string, any>} */ (body) : {}
  const lanes = (Array.isArray(b.lanes) ? b.lanes : []).filter((l) => l && typeof l === 'object' && str(l.agent_id)).map((l) => ({
    agentId: str(l.agent_id),
    workspace: str(l.workspace),
    workspaceName: str(l.workspace_name) || str(l.workspace),
    box: str(l.agent_box),
    vendor: str(l.vendor),
    scope: str(l.scope),
    topicId: str(l.topic_id),
    topicTitle: str(l.topic_title),
    issues: (Array.isArray(l.issues) ? l.issues : []).filter((i) => i && typeof i === 'object' && str(i.key))
      .map((i) => ({ key: str(i.key), status: str(i.status) })),
    updatedAt: str(l.updated_at),
    ageS: int(l.age_s),
    lastActive: str(l.last_active),
    state: str(l.state) || 'live',
  }))
  return { asOf: str(b.as_of), fleet: str(b.fleet), lanes }
}

/** The agent as the row names it: id@box (no box: the id alone). */
export function laneName(lane) {
  return lane.box ? lane.agentId + '@' + lane.box : lane.agentId
}

/**
 * The discussion link, /t/<uuid> (C17), or '' when the topic is no topic of
 * this workspace (the hub sends no title, 3.3) or not a full uuid: the cell
 * then shows the id as text, never a link that leads nowhere.
 */
export function laneTopicPath(lane) {
  return lane.topicTitle && UUID_RE.test(lane.topicId) ? '/t/' + lane.topicId : ''
}

/**
 * An issue's link, /issues?issue=<KEY>, or '' for a key the hub found no
 * status for (another workspace's prefix: listed as sent, 3.3).
 */
export function laneIssuePath(issue) {
  return issue.status && KEY_RE.test(issue.key) ? '/issues?issue=' + encodeURIComponent(issue.key) : ''
}

/** Whole minutes from an ISO time to the answer's as_of; null when either is missing. */
export function minutesAgo(at, asOf) {
  const ref = Date.parse(str(asOf))
  if (!Number.isFinite(ref) || !str(at)) return null
  const s = lagSeconds(at, ref)
  return Number.isFinite(s) ? Math.floor(s / 60) : null
}

/** The stale marker for a lag in seconds: 'ok' up to 90 s, 'amber' up to 180 s, then 'red'. */
export function lanesStaleLevel(lagS) {
  if (!Number.isFinite(Number(lagS))) return 'red'
  const v = Number(lagS)
  if (v > LANES_STALE_RED_S) return 'red'
  if (v > LANES_STALE_AMBER_S) return 'amber'
  return 'ok'
}

/* ---- sort and filter (SPL-3887; owner HUM-10, t1 31f6f470, msgs 1eedefed
   and 08b25696: "the lanes listing in the monitoring section must be
   sortable and filterable", the same controls as the issues listing). The
   header button is the Issues sheet's (components/SheetSortButton.vue, the
   cycle utils/sheet-sort.mjs); no sort = the hub's order, newest write first. */

/** The sortable columns, in the table's order. */
export const LANE_COLUMNS = ['agent', 'vendor', 'state', 'scope', 'topic', 'issues', 'updated', 'active', 'workspace']

/** The age filter: written within 1 h, within 24 h, or longer ago. */
export const LANE_AGES = ['1h', '24h', 'older']
const AGE_S = { '1h': 3600, '24h': 86400 }

/** No filter: every lane shows. */
export const LANES_NO_FILTER = Object.freeze({ text: '', box: '', vendor: '', state: '', age: '' })

/** A lane's state; a hub without the field sends live lanes only. */
export function laneState(lane) {
  return str(lane.state) || 'live'
}

const timeOf = (iso) => {
  const t = Date.parse(str(iso))
  return Number.isFinite(t) ? t : null
}

/** What a column sorts by: a time in ms, else text; null = empty (always last). */
function sortValue(lane, col) {
  switch (col) {
    case 'agent': return laneName(lane)
    case 'state': return laneState(lane)
    case 'topic': return lane.topicTitle || lane.topicId || null
    case 'issues': return lane.issues.length ? lane.issues[0].key : null
    case 'updated': return timeOf(lane.updatedAt)
    case 'active': return timeOf(lane.lastActive)
    case 'workspace': return lane.workspaceName || null
    default: return str(lane[col]) || null
  }
}

/**
 * The lanes in a sheet sort ({ col: '', dir: '' } = the hub's order). Text
 * compares as words with numbers (c-9 before c-10); times oldest first when
 * ascending. An empty cell sorts last either way; ties keep the hub's order.
 * @template T
 * @param {T[]} lanes
 * @param {{ col: string, dir: string }} sort
 * @returns {T[]}
 */
export function sortLanes(lanes, sort) {
  if (!sort || !LANE_COLUMNS.includes(sort.col)) return lanes.slice()
  const sign = sort.dir === 'desc' ? -1 : 1
  const rows = lanes.map((l, i) => ({ l, i, v: sortValue(l, sort.col) }))
  rows.sort((a, b) => {
    if (a.v === null || b.v === null) return a.v === b.v ? a.i - b.i : a.v === null ? 1 : -1
    const c = typeof a.v === 'number' && typeof b.v === 'number' ? a.v - b.v : String(a.v).localeCompare(String(b.v), undefined, { numeric: true, sensitivity: 'base' })
    return c === 0 ? a.i - b.i : sign * c
  })
  return rows.map((r) => r.l)
}

/** The words a text filter searches: the agent, scope, discussion, issue keys and workspace. */
function laneWords(lane) {
  return [laneName(lane), lane.vendor, lane.scope, lane.topicTitle, lane.topicId, ...lane.issues.map((i) => i.key), lane.workspaceName, lane.workspace]
    .join(' ').toLowerCase()
}

function ageMatches(lane, age) {
  if (!age) return true
  const s = Number(lane.ageS)
  if (age === 'older') return s >= AGE_S['24h']
  return s < AGE_S[age]
}

/**
 * The lanes the filter row keeps: every word of `text` in the lane's words,
 * and box, vendor, state and age each '' (any) or equal.
 * @template T
 * @param {T[]} lanes
 * @param {{ text?: string, box?: string, vendor?: string, state?: string, age?: string }} f
 * @returns {T[]}
 */
export function filterLanes(lanes, f) {
  const words = str(f.text).toLowerCase().split(/\s+/).filter(Boolean)
  return lanes.filter((l) => (!f.box || l.box === f.box)
    && (!f.vendor || l.vendor === f.vendor)
    && (!f.state || laneState(l) === f.state)
    && ageMatches(l, str(f.age))
    && (words.length === 0 || words.every((w) => laneWords(l).includes(w))))
}

/** True when any filter is set. */
export function lanesFiltered(f) {
  return Boolean(str(f.text).trim() || f.box || f.vendor || f.state || f.age)
}

/** Each select's choices: the distinct non-empty values in the answer, sorted. */
export function laneFilterChoices(lanes) {
  const uniq = (vals) => [...new Set(vals.filter(Boolean))].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
  return { box: uniq(lanes.map((l) => l.box)), vendor: uniq(lanes.map((l) => l.vendor)), state: uniq(lanes.map(laneState)) }
}

/**
 * The poll's rule (C18): fetch when visible and nothing is in hand yet or a
 * full LANES_POLL_MS has passed since the last fetch; never while hidden,
 * never after a 403.
 * @param {{ visibilityState: string, lastAt: number, now: number, forbidden?: boolean }} s
 */
export function lanesShouldFetch({ visibilityState, lastAt, now, forbidden = false }) {
  if (forbidden || visibilityState !== 'visible') return false
  return !lastAt || now - lastAt >= LANES_POLL_MS
}

/**
 * The page's poll (C18): a fetch at once, then one per LANES_POLL_MS while
 * the browser tab is visible. A fetch out of turn (a tab shown again after a
 * missed tick: `wake`; the Refresh button: `refresh`) restarts the minute,
 * so the next one is a full minute later, never sooner and never later. The
 * clock and the timer are injectable for the unit test.
 * @param {{ load: () => unknown, visibility: () => string, forbidden?: () => boolean,
 *   now?: () => number, setTimer?: (fn: () => void, ms: number) => unknown, clearTimer?: (h: unknown) => void }} o
 */
export function startLanesPoll(o) {
  const now = o.now || (() => Date.now())
  const setTimer = o.setTimer || ((fn, ms) => setInterval(fn, ms))
  const clearTimer = o.clearTimer || ((h) => clearInterval(/** @type {any} */ (h)))
  const forbidden = o.forbidden || (() => false)
  let lastAt = 0
  let handle = null
  const fetchNow = () => { lastAt = now(); o.load() }
  const restart = () => {
    if (handle !== null) clearTimer(handle)
    handle = setTimer(tick, LANES_POLL_MS)
  }
  function tick() {
    if (lanesShouldFetch({ visibilityState: o.visibility(), lastAt, now: now(), forbidden: forbidden() })) fetchNow()
  }
  tick()
  restart()
  return {
    wake: () => {
      if (!lanesShouldFetch({ visibilityState: o.visibility(), lastAt, now: now(), forbidden: forbidden() })) return
      fetchNow()
      restart()
    },
    refresh: () => { fetchNow(); restart() },
    stop: () => { if (handle !== null) clearTimer(handle); handle = null },
  }
}

/* ---- the agent card's Lanes tab (spec 153 3.9, SPL-4206; owner HUM-10, t1
   fb9b6e4b, msgs 78f2071b and 470ae116): the lanes an agent works on, each
   linking to its row on Monitoring -> Lanes (?lane=<id@box>). The hub's lane
   row carries no spawner or owner field, so a role seat lists only its own
   lane rows, never the lanes it placed. */

/** The query key of the Lanes page's deep link: the lane it selects and scrolls to. */
export const LANE_QUERY = 'lane'

/**
 * An agent's own lanes, in the order given: the same id, and the same box
 * when both name one (an id runs on more than one box).
 * @template {{ agentId: string, box: string }} T
 * @param {T[]} lanes
 * @param {string} agentId
 * @param {string} box
 * @returns {T[]}
 */
export function agentLanes(lanes, agentId, box) {
  return lanes.filter((l) => l.agentId === agentId && (!l.box || !box || l.box === box))
}

/** The link to a lane's row on Monitoring -> Lanes. */
export function laneDeepLink(lane) {
  return { path: '/monitoring/lanes', query: { [LANE_QUERY]: laneName(lane) } }
}

/**
 * One read of the lanes: the fleet route for an operator admin, else (after
 * its 403, remembered in `s.own`) the workspace's own, as the Lanes page.
 * @param {{ getFleetLanes: (own?: boolean) => Promise<unknown> }} api
 * @param {{ own: boolean, operatorVisible: boolean }} s
 */
export async function readLanes(api, s) {
  if (s.own && !s.operatorVisible) return api.getFleetLanes(true)
  try {
    return await api.getFleetLanes(false)
  } catch (e) {
    if (/** @type {{ status?: number }} */ (e)?.status !== 403 || s.operatorVisible) throw e
    s.own = true
    return api.getFleetLanes(true)
  }
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

/** The mock's discussion: a topic of the mock workspace (a full uuid). */
export const LANES_MOCK_TOPIC = '5e7b15c9-2995-427d-8b05-659762fbb9d8'

/** The mock workspace's name, the rows' last column (3.8). */
const LANES_MOCK_WORKSPACE = 'Mock workspace'

/**
 * The mock's GET: 403 operator.workspaces unless the e2e opted into the
 * operator admin, else three active lanes as the hub answers them: one on a
 * topic of this workspace with two issues, one on another workspace's topic
 * (no title, its own key only), one with no topic, no issue and no burn.
 * Each row names its workspace (3.8).
 */
export function mockFleetLanes(store = mockStore(), now = new Date()) {
  const get = (k) => { try { return store ? store.getItem(k) : null } catch { return null } }
  if (get(LANES_MOCK_OPERATOR_KEY) !== '1') throw mockRefused('/v1/operator/fleet-lanes', mockForbidden())
  const asOf = new Date(Math.floor(now.getTime() / 1000) * 1000)
  const ago = (s) => isoSeconds(new Date(asOf.getTime() - s * 1000))
  const out = { as_of: isoSeconds(asOf), fleet: 'main', lanes: /** @type {any[]} */ ([]) }
  if (get(LANES_MOCK_KEY) === 'empty') return out
  out.lanes = [
    { agent_id: 'c-085', agent_box: 'box-a', vendor: 'claude', scope: 'Spec 153 build row B4: the Lanes tab of Monitoring, its page, its poll and its locale keys',
      topic_id: LANES_MOCK_TOPIC, topic_title: 'Monitoring: the tab row beside the heading, and a live Lanes tab',
      issues: [{ key: 'SPL-3075', status: 'wip' }, { key: 'SPL-3215', status: 'wip' }], updated_at: ago(240), age_s: 240, last_active: ago(60),
      workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE },
    { agent_id: 'a-277', agent_box: 'box-b', vendor: 'agy', scope: 'Review the locale text',
      topic_id: '0b0c0d0e-1111-4222-8333-444455556666', topic_title: '',
      issues: [{ key: 'SPL-3216', status: '' }], updated_at: ago(1500), age_s: 1500, last_active: '',
      workspace: 'w2', workspace_name: 'Other workspace' },
    { agent_id: 'm-039', agent_box: 'box-b', vendor: 'mistral', scope: '', topic_id: '', topic_title: '',
      issues: [], updated_at: ago(3000), age_s: 3000, last_active: '', workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE },
  ]
  return out
}
