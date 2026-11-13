/**
 * Spec 153 3.10 (row B10, SPL-4421; owner HUM-10, t1 08213e0e, msg
 * 8caf41ec): Monitoring -> Topics, one narrow row per topic (discussion)
 * with its lanes and its issues. No hub read of its own: the rows are the
 * Lanes answer (GET /v1/operator/fleet-lanes, else /v1/view/lanes) grouped
 * by topic, so the read, the poll, the sort engine and the links are
 * monitoring-lanes.mjs's, reused, never copied.
 *
 * Last activity is lane activity: the newest token minute or row write of
 * the topic's lanes, not the topic's last message (the hub sends none).
 *
 * 3.29 (SPL-5430; owner HUM-10, t1 5804c44c, msg b65c7989: "The visual
 * layout of the topics in the monitoring should be quite similar to the
 * visual layout of the lanes, and it should behave the same way"): the
 * sheet is the Lanes page's, the Event log's (utils/column-sheet.mjs): each
 * column sorts and has one filter under its name, the address carries both
 * (utils/sheet-list-url.mjs, TOPICS_URL_SPEC).
 *
 * Only the Topics page imports this file, so none of it rides the initial
 * JS (ci_initial_gzip_kb). Node tests import it.
 */

import { LANE_AGES, ageMatches, laneName, laneState, sortRowsBy, uniqSorted } from './monitoring-lanes.mjs'
import { emptySheetFilters, sheetFiltersActive, sheetRowMatches } from './column-sheet.mjs'

/**
 * The sheet's columns, in the table's order: a text filter for the topic,
 * its lanes and its issues, a choice for the workspace, the channel and the
 * last activity's age. The Lanes column's text finds a lane by id@box,
 * vendor or state, so it holds the old box, vendor and state selects.
 * @type {readonly { col: string, key: string, kind: 'text' | 'choice', words?: 'date' | 'num' | 'text' }[]}
 */
export const TOPIC_SHEET_COLUMNS = Object.freeze([
  { col: 'topic', key: 'issues.discussion', kind: 'text' },
  { col: 'workspace', key: 'sidebar.tenant', kind: 'choice' },
  { col: 'channel', key: 'monitoring.topics.col_channel', kind: 'choice' },
  { col: 'active', key: 'monitoring.topics.col_active', kind: 'choice', words: 'date' },
  { col: 'lanes', key: 'monitoring.tab.lanes', kind: 'text', words: 'num' },
  { col: 'issues', key: 'issues.title', kind: 'text' },
])

/** The sortable columns, in the table's order. */
const TOPIC_COLUMNS = TOPIC_SHEET_COLUMNS.map((c) => c.col)

/** The columns whose filter picks an age (LANE_AGES). */
export const TOPIC_AGE_COLUMNS = ['active']

/** The list's own order, the phone bar's words for no sort: Last activity, newest first. */
export const TOPICS_DEFAULT_SORT = Object.freeze({ colKey: 'monitoring.topics.col_active', dirKey: 'issues_mobile.dir_date_desc' })

/** No filter: every topic shows (one empty filter per column). */
export const TOPICS_NO_FILTER = Object.freeze(emptySheetFilters(TOPIC_SHEET_COLUMNS))

/** The Topics sheet's address (utils/sheet-list-url.mjs), as the Lanes sheet's. */
export const TOPICS_URL_SPEC = Object.freeze({
  columns: TOPIC_SHEET_COLUMNS,
  ageColumns: TOPIC_AGE_COLUMNS,
  ages: LANE_AGES,
  noFilter: TOPICS_NO_FILTER,
})

const str = (v) => (typeof v === 'string' ? v : '')
const timeOf = (iso) => {
  const t = Date.parse(str(iso))
  return Number.isFinite(t) ? t : null
}

/** A lane's newest activity in ms: its last token minute, else its row write; null for none. */
function laneAt(lane) {
  const a = timeOf(lane.lastActive)
  const u = timeOf(lane.updatedAt)
  if (a === null) return u
  return u === null ? a : Math.max(a, u)
}

/** A new topic row from its first lane: the topic's id, title, channel and workspace. */
function topicRow(lane) {
  return {
    topicId: lane.topicId, topicTitle: lane.topicTitle, topicChannel: str(lane.topicChannel),
    workspace: lane.workspace, workspaceName: lane.workspaceName,
    lanes: [], issues: [], lastAtMs: null, lastAt: '', ageS: 0,
  }
}

/** Adds a lane to its topic row: the lane, its new issue keys, a newer activity. */
function addLane(row, lane) {
  row.lanes.push({ name: laneName(lane), agentId: lane.agentId, box: lane.box, vendor: lane.vendor, state: laneState(lane) })
  for (const i of lane.issues) {
    const had = row.issues.find((x) => x.key === i.key)
    if (!had) row.issues.push({ key: i.key, status: i.status })
    else if (!had.status && i.status) had.status = i.status
  }
  if (!row.topicTitle && lane.topicTitle) row.topicTitle = lane.topicTitle
  if (!row.topicChannel && lane.topicChannel) row.topicChannel = lane.topicChannel
  const at = laneAt(lane)
  if (at !== null && (row.lastAtMs === null || at > row.lastAtMs)) {
    row.lastAtMs = at
    row.lastAt = lane.lastActive && timeOf(lane.lastActive) === at ? lane.lastActive : lane.updatedAt
  }
}

/**
 * The lanes view (fleetLanesOf) as one row per topic, newest activity
 * first. Lanes on no topic share one row with topicId ''. A topic's issues
 * are its lanes' issues, each key once, in the order first met. `ageS` is
 * the seconds from the newest activity to the answer's as_of (the age
 * filter's measure).
 * @param {{ asOf: string, lanes: any[] }} view
 */
export function topicsOf(view) {
  const byId = new Map()
  for (const lane of view.lanes) {
    const id = str(lane.topicId)
    if (!byId.has(id)) byId.set(id, topicRow(lane))
    addLane(byId.get(id), lane)
  }
  const ref = timeOf(view.asOf)
  const rows = [...byId.values()]
  for (const r of rows) r.ageS = ref !== null && r.lastAtMs !== null ? Math.max(0, Math.floor((ref - r.lastAtMs) / 1000)) : 0
  return sortRowsBy(rows, { col: 'active', dir: 'desc' }, TOPIC_COLUMNS, sortValue)
}

/** What a column sorts by: a time in ms, a count, else text; null = empty (always last). */
function sortValue(row, col) {
  switch (col) {
    case 'topic': return row.topicTitle || row.topicId || null
    case 'workspace': return row.workspaceName || null
    case 'channel': return row.topicChannel || null
    case 'active': return row.lastAtMs
    case 'lanes': return row.lanes.length
    case 'issues': return row.issues.length ? row.issues[0].key : null
    default: return null
  }
}

/**
 * The topics in a sheet sort ({ col: '', dir: '' } = newest activity first).
 * @template T
 * @param {T[]} rows
 * @param {{ col: string, dir: string }} sort
 * @returns {T[]}
 */
export function sortTopics(rows, sort) {
  return sortRowsBy(rows, sort, TOPIC_COLUMNS, sortValue)
}

/** A text column's words: the topic's title and id, its lanes (id@box, vendor, state), its issue keys. */
function topicText(row, col) {
  if (col === 'topic') return [row.topicTitle, row.topicId].filter(Boolean).join(' ')
  if (col === 'lanes') return row.lanes.map((l) => [l.name, l.vendor, l.state].filter(Boolean).join(' ')).join(' ')
  if (col === 'issues') return row.issues.map((i) => i.key).join(' ')
  return ''
}

/** A choice column's value: the workspace id or the channel (the age is matched apart). */
function topicChoice(row, col) {
  if (col === 'workspace') return str(row.workspace)
  if (col === 'channel') return str(row.topicChannel)
  return ''
}

/**
 * The topics the filter row keeps: every column's filter must match (the
 * Event log's rule, utils/column-sheet.mjs); Last activity's is the newest
 * activity's age band.
 * @template T
 * @param {T[]} rows
 * @param {Record<string, string>} f
 * @returns {T[]}
 */
export function filterTopics(rows, f) {
  if (!topicsFiltered(f)) return rows.slice()
  const cells = {
    textOf: topicText,
    choiceOf: topicChoice,
    custom: (r, col, q) => (col === 'active' ? ageMatches(r, q) : undefined),
  }
  return rows.filter((r) => sheetRowMatches(r, f, TOPIC_SHEET_COLUMNS, cells))
}

/** True when any filter is set. */
export function topicsFiltered(f) {
  return sheetFiltersActive(f, TOPIC_SHEET_COLUMNS)
}

/** The workspaces in the topics, each once by id, shown by name (else the id), sorted by name. */
function topicWorkspaceChoices(rows) {
  const byId = new Map()
  for (const r of rows) if (r.workspace && !byId.has(r.workspace)) byId.set(r.workspace, r.workspaceName || r.workspace)
  return [...byId].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))
}

/** Each choice column's options: the workspaces by id and name, the distinct channels, sorted. */
export function topicFilterChoices(rows) {
  return { workspace: topicWorkspaceChoices(rows), channel: uniqSorted(rows.map((r) => r.topicChannel)) }
}
