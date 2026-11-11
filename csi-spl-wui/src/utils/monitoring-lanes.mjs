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
import { emptySheetFilters, sheetFiltersActive, sheetRowMatches } from './column-sheet.mjs'

/** Polling while the tab is open and the browser tab visible (decision P4). */
export const LANES_POLL_MS = 60000
/** Lag after which the data is amber (1.5x the timer) and red (3x), as Tokens. */
const LANES_STALE_AMBER_S = 90
const LANES_STALE_RED_S = 180
/** e2e opt-in (mock only): '' = three lanes, 'empty' = none active, 'topics' =
 *  the three plus a fourth on c-085's topic (Monitoring -> Topics, SPL-4421),
 *  'links' = the three plus the ids an agent writes (SPL-4798): a
 *  dispatch-<topic8> task, SPL-4791 + DVN-3 keys and lane (c)'s `unknown`. */
export const LANES_MOCK_KEY = 'spool.mock.fleet_lanes'
/** The mock's operator admin is the Tokens tab's (the same key shows both tabs). */
export const LANES_MOCK_OPERATOR_KEY = TOKENS_MOCK_OPERATOR_KEY

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const KEY_RE = /^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,8}$/
const str = (v) => (typeof v === 'string' ? v : '')
const int = (v) => (Number.isFinite(Number(v)) && Number(v) >= 0 ? Math.trunc(Number(v)) : 0)
/** An issue prio, 1 (highest) .. 5; 0 = none (spec 153 3.14). */
const prio = (v) => { const n = int(v); return n >= 1 && n <= 5 ? n : 0 }

/**
 * The hub's answer as the page's view, in the hub's order. A row without an
 * agent id is dropped; an issue without a key is dropped. Every row keeps
 * the workspace it belongs to (spec 153 3.8: name, else id) and whether it
 * is a role seat (3.11).
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
    /* SPL-4421: the topic's channel, for Monitoring -> Topics; '' until the hub sends it */
    topicChannel: str(l.topic_channel),
    issues: (Array.isArray(l.issues) ? l.issues : []).filter((i) => i && typeof i === 'object' && str(i.key))
      .map((i) => ({ key: str(i.key), status: str(i.status), priority: prio(i.priority) })),
    /* spec 153 3.14: the highest prio among the issues (1 highest); 0 = none */
    priority: prio(l.priority),
    /* spec 153 3.12: the issue the lane came from; null for none, never a guess */
    originIssue: l.origin_issue && typeof l.origin_issue === 'object' && str(l.origin_issue.key)
      ? { key: str(l.origin_issue.key), status: str(l.origin_issue.status) } : null,
    updatedAt: str(l.updated_at),
    ageS: int(l.age_s),
    lastActive: str(l.last_active),
    state: str(l.state) || 'live',
    /* spec 153 3.11: a role seat names no topic and no issue by design */
    roleSeat: l.role_seat === true,
  }))
  return { asOf: str(b.as_of), fleet: str(b.fleet), lanes }
}

/** The agent as the row names it: id@box (no box: the id alone). */
export function laneName(lane) {
  return lane.box ? lane.agentId + '@' + lane.box : lane.agentId
}

/** lane (c)'s value for an old row's discussion or issue: stays text (SPL-4798). */
export const LANE_UNKNOWN = 'unknown'
/* a spool dispatch task, dispatch-<topic8> (the hub stores it as sent) */
const TASK_RE = /^dispatch-[0-9a-f]{8}$/i

/**
 * SPL-4798 (owner HUM-10, t1 0c2d08a2, msg ea369ab0: "a renderer on the
 * page ... which continas those to links"): the typed ref (utils/note-links.mjs,
 * the one renderer of `type:id` objects) a lane's discussion names, or null
 * (it stays text). A topic uuid opens on the lane's workspace host; a uuid
 * the hub found in no workspace and sent no title for (workspace = the page's
 * own) names nothing, so it stays text. `dispatch-<topic8>` is a spool task
 * of the page's workspace. The trigger is render time, not the row write:
 * every row already written, by any writer, links the same way, and the host
 * comes from the env at render (no host is stored in a row).
 * @param {{ topicId: string, topicTitle?: string, workspace?: string }} lane
 * @param {string} pageTenant the workspace that answered the read
 * @returns {{ kind: 'topic', workspace_id: string, ref: string } | null}
 */
export function laneTopicRef(lane, pageTenant) {
  const id = str(lane && lane.topicId).trim()
  const page = str(pageTenant)
  const ws = str(lane && lane.workspace) || page
  if (!id || id.toLowerCase() === LANE_UNKNOWN || !ws) return null
  if (TASK_RE.test(id)) return { kind: 'topic', workspace_id: page || ws, ref: id.toLowerCase() }
  if (!UUID_RE.test(id)) return null
  if (!str(lane.topicTitle) && ws === page) return null
  return { kind: 'topic', workspace_id: ws, ref: id.toLowerCase() }
}

/**
 * The typed ref a lane's issue key names, or null (text). A key the hub sent
 * a status for is the page's workspace's; a key with none is another
 * prefix: it opens in the lane's workspace when that is not the page's (the
 * hub placed the lane there), else it stays text. `unknown` stays text.
 * @param {{ key: string, status?: string }} issue
 * @param {{ workspace?: string }} lane
 * @param {string} pageTenant
 * @returns {{ kind: 'issue', workspace_id: string, ref: string } | null}
 */
export function laneIssueRef(issue, lane, pageTenant) {
  const key = str(issue && issue.key).trim()
  const page = str(pageTenant)
  if (!KEY_RE.test(key)) return null
  if (str(issue.status)) return page ? { kind: 'issue', workspace_id: page, ref: key } : null
  const ws = str(lane && lane.workspace)
  return ws && ws !== page ? { kind: 'issue', workspace_id: ws, ref: key } : null
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

/**
 * SPL-5276 (owner HUM-10, t1 e1e97af9, msg 7ccb6bfa: "Sorting and filtering
 * in lanes should behave exactly as sorting and filtering for the event
 * log"): the sheet is the Event log's column sheet (utils/column-sheet.mjs,
 * components/SheetHead.vue and SheetPhoneBar.vue). Every column sorts by its
 * name and has one filter under it: a text column keeps the lanes whose cell
 * holds the text, a choice column the lanes equal to the value picked. The
 * two times pick an age (within 1 h, within 24 h, older), as the Updated
 * filter did; the free-text box over four columns is gone, each column has
 * its own.
 * @type {readonly { col: string, key: string, kind: 'text' | 'choice', words?: 'date' | 'num' | 'text' }[]}
 */
export const LANE_SHEET_COLUMNS = Object.freeze([
  { col: 'agent', key: 'monitoring.tokens.col_agent', kind: 'text' },
  { col: 'box', key: 'monitoring.lanes.col_box', kind: 'choice' },
  { col: 'priority', key: 'issues.field_priority', kind: 'choice', words: 'num' },
  { col: 'vendor', key: 'monitoring.tokens.col_vendor', kind: 'choice' },
  { col: 'state', key: 'monitoring.lanes.col_state', kind: 'choice' },
  { col: 'scope', key: 'monitoring.lanes.col_scope', kind: 'text' },
  { col: 'topic', key: 'issues.discussion', kind: 'text' },
  { col: 'issues', key: 'issues.title', kind: 'text' },
  { col: 'origin', key: 'monitoring.lanes.col_origin_issue', kind: 'text' },
  { col: 'updated', key: 'monitoring.lanes.col_updated', kind: 'choice', words: 'date' },
  { col: 'active', key: 'monitoring.tokens.col_last', kind: 'choice', words: 'date' },
  { col: 'workspace', key: 'sidebar.tenant', kind: 'choice' },
])

/** The sortable columns, in the table's order. */
export const LANE_COLUMNS = LANE_SHEET_COLUMNS.map((c) => c.col)

/** The list's own order, the phone bar's words for no sort: Updated, newest first (the hub's). */
export const LANES_DEFAULT_SORT = Object.freeze({ colKey: 'monitoring.lanes.col_updated', dirKey: 'issues_mobile.dir_date_desc' })

/** The age filter: written within 1 h, within 24 h, or longer ago. */
export const LANE_AGES = ['1h', '24h', 'older']
const AGE_S = { '1h': 3600, '24h': 86400 }

/** The columns whose filter picks an age. */
export const LANE_AGE_COLUMNS = ['updated', 'active']

/** No filter: every lane shows (one empty filter per column). */
export const LANES_NO_FILTER = Object.freeze(emptySheetFilters(LANE_SHEET_COLUMNS))

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
    case 'priority': return lane.priority || null
    case 'topic': return lane.topicTitle || lane.topicId || null
    case 'issues': return lane.issues.length ? lane.issues[0].key : null
    case 'origin': return lane.originIssue ? lane.originIssue.key : null
    case 'updated': return timeOf(lane.updatedAt)
    case 'active': return timeOf(lane.lastActive)
    case 'workspace': return lane.workspaceName || null
    default: return str(lane[col]) || null
  }
}

/**
 * Rows in a sheet sort ({ col: '', dir: '' } = the given order), by
 * `valueOf(row, col)`: a time in ms, else text; null = empty. Text compares
 * as words with numbers (c-9 before c-10); times oldest first when
 * ascending. An empty cell sorts last either way; ties keep the given order.
 * The Lanes and Topics sheets share it (SPL-4421).
 * @template T
 * @param {T[]} rows
 * @param {{ col: string, dir: string }} sort
 * @param {string[]} columns the sortable columns
 * @param {(row: T, col: string) => string | number | null} valueOf
 * @returns {T[]}
 */
export function sortRowsBy(rows, sort, columns, valueOf) {
  if (!sort || !columns.includes(sort.col)) return rows.slice()
  const sign = sort.dir === 'desc' ? -1 : 1
  const keyed = rows.map((r, i) => ({ r, i, v: valueOf(r, sort.col) }))
  keyed.sort((a, b) => {
    if (a.v === null || b.v === null) return a.v === b.v ? a.i - b.i : a.v === null ? 1 : -1
    const c = typeof a.v === 'number' && typeof b.v === 'number' ? a.v - b.v : String(a.v).localeCompare(String(b.v), undefined, { numeric: true, sensitivity: 'base' })
    return c === 0 ? a.i - b.i : sign * c
  })
  return keyed.map((k) => k.r)
}

/**
 * The lanes in a sheet sort ({ col: '', dir: '' } = the hub's order).
 * @template T
 * @param {T[]} lanes
 * @param {{ col: string, dir: string }} sort
 * @returns {T[]}
 */
export function sortLanes(lanes, sort) {
  return sortRowsBy(lanes, sort, LANE_COLUMNS, sortValue)
}

/** Whether a row's ageS is in an age filter ('' = any); Topics reuses it. */
export function ageMatches(lane, age) {
  if (!age) return true
  const s = Number(lane.ageS)
  if (age === 'older') return s >= AGE_S['24h']
  return s < AGE_S[age]
}

/** A text column's words (the cell as shown, its id too). */
function laneText(lane, col) {
  switch (col) {
    case 'agent': return laneName(lane)
    case 'topic': return [lane.topicTitle, lane.topicId].filter(Boolean).join(' ')
    case 'issues': return lane.issues.map((i) => i.key).join(' ')
    case 'origin': return lane.originIssue ? lane.originIssue.key : ''
    default: return str(lane[col])
  }
}

/** A choice column's value: the box, prio (1..5), vendor, state or workspace id. */
function laneChoice(lane, col) {
  if (col === 'state') return laneState(lane)
  if (col === 'priority') return lane.priority ? String(lane.priority) : ''
  return str(lane[col])
}

/** Seconds from the lane's last token minute to the answer's as_of; null for none. */
function activeSeconds(lane, asOf) {
  const ref = Date.parse(str(asOf))
  const at = Date.parse(str(lane.lastActive))
  return Number.isFinite(ref) && Number.isFinite(at) ? Math.max(0, (ref - at) / 1000) : null
}

/**
 * The lanes the filter row keeps: each column's filter '' (All) or matching,
 * the Event log's rule (utils/column-sheet.mjs sheetRowMatches). Updated
 * picks the write's age, Last active the age of the last token minute
 * against the answer's `asOf` (a lane with none matches no age).
 * @template T
 * @param {T[]} lanes
 * @param {Record<string, string>} f
 * @param {string} [asOf]
 * @returns {T[]}
 */
export function filterLanes(lanes, f, asOf = '') {
  if (!lanesFiltered(f)) return lanes.slice()
  const cells = {
    textOf: laneText,
    choiceOf: laneChoice,
    custom: (l, col, q) => {
      if (col === 'updated') return ageMatches(l, q)
      if (col !== 'active') return undefined
      const s = activeSeconds(l, asOf)
      return s !== null && ageMatches({ ageS: s }, q)
    },
  }
  return lanes.filter((l) => sheetRowMatches(l, f, LANE_SHEET_COLUMNS, cells))
}

/** True when any filter is set. */
export function lanesFiltered(f) {
  return sheetFiltersActive(f, LANE_SHEET_COLUMNS)
}

/** The distinct non-empty values, sorted as words with numbers. */
export function uniqSorted(vals) {
  return [...new Set(vals.filter(Boolean))].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
}

/** The workspaces in the answer, each once by id, shown by name (else the id), sorted by name (SPL-4705). */
function laneWorkspaceChoices(lanes) {
  const byId = new Map()
  for (const l of lanes) if (l.workspace && !byId.has(l.workspace)) byId.set(l.workspace, l.workspaceName || l.workspace)
  return [...byId].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))
}

/** Each select's choices: the distinct non-empty values in the answer, sorted (prio 1 first). */
export function laneFilterChoices(lanes) {
  const uniq = uniqSorted
  return { box: uniq(lanes.map((l) => l.box)), priority: uniq(lanes.map((l) => (l.priority ? String(l.priority) : ''))),
    vendor: uniq(lanes.map((l) => l.vendor)), state: uniq(lanes.map(laneState)), workspace: laneWorkspaceChoices(lanes) }
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

/** The mock discussion's title. */
const LANES_MOCK_TOPIC_TITLE = 'Monitoring: the tab row beside the heading, and a live Lanes tab'

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
      topic_id: LANES_MOCK_TOPIC, topic_title: LANES_MOCK_TOPIC_TITLE, topic_channel: 'monitoring',
      issues: [{ key: 'SPL-3075', status: 'wip', priority: 2 }, { key: 'SPL-3215', status: 'wip', priority: 3 }], priority: 2, origin_issue: { key: 'SPL-3158', status: 'done' }, updated_at: ago(240), age_s: 240, last_active: ago(60),
      workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE },
    { agent_id: 'a-277', agent_box: 'box-b', vendor: 'agy', scope: 'Review the locale text',
      topic_id: '0b0c0d0e-1111-4222-8333-444455556666', topic_title: '',
      issues: [{ key: 'SPL-3216', status: '' }], origin_issue: { key: 'OPS-7', status: '' }, updated_at: ago(1500), age_s: 1500, last_active: '',
      workspace: 'w2', workspace_name: 'Other workspace' },
    { agent_id: 'm-039', agent_box: 'box-b', vendor: 'mistral', scope: '', topic_id: '', topic_title: '',
      issues: [], updated_at: ago(3000), age_s: 3000, last_active: '', workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE },
  ]
  if (get(LANES_MOCK_KEY) === 'links') {
    out.lanes.push(
      { agent_id: 'c-791', agent_box: 'box-a', vendor: 'claude', scope: 'Lane ids as links', topic_id: 'dispatch-' + LANES_MOCK_TOPIC.slice(0, 8), topic_title: '',
        issues: [{ key: 'SPL-4791', status: 'wip', priority: 2 }, { key: 'DVN-3', status: '' }], priority: 2, updated_at: ago(3300), age_s: 3300, last_active: '',
        workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE },
      { agent_id: 'c-792', agent_box: 'box-a', vendor: 'claude', scope: 'An old row', topic_id: LANE_UNKNOWN, topic_title: '',
        issues: [{ key: LANE_UNKNOWN, status: '' }], updated_at: ago(3400), age_s: 3400, last_active: '', workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE })
  }
  /* 3.25 (SPL-5235, W1): a lane with four issue keys, its phone card still three lines */
  if (get(LANES_MOCK_KEY) === 'keys') {
    out.lanes.push({ agent_id: 'c-404', agent_box: 'box-a', vendor: 'claude', scope: 'A lane with four issue keys',
      topic_id: LANES_MOCK_TOPIC, topic_title: LANES_MOCK_TOPIC_TITLE, topic_channel: 'monitoring',
      issues: [{ key: 'SPL-4041', status: 'wip', priority: 2 }, { key: 'SPL-4042', status: 'wip' }, { key: 'SPL-4043', status: '' }, { key: 'SPL-4044', status: '' }],
      priority: 2, origin_issue: { key: 'SPL-4040', status: 'done' }, updated_at: ago(900), age_s: 900, last_active: ago(120),
      workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE })
  }
  if (get(LANES_MOCK_KEY) === 'topics') {
    out.lanes.splice(1, 0, { agent_id: 'c-733', agent_box: 'box-a', vendor: 'claude', scope: 'Monitoring -> Topics',
      topic_id: LANES_MOCK_TOPIC, topic_title: LANES_MOCK_TOPIC_TITLE, topic_channel: 'monitoring',
      issues: [{ key: 'SPL-3215', status: 'wip', priority: 3 }, { key: 'SPL-4421', status: 'eval', priority: 1 }], priority: 1, updated_at: ago(600), age_s: 600, last_active: '',
      workspace: 'mock', workspace_name: LANES_MOCK_WORKSPACE })
  }
  return out
}
