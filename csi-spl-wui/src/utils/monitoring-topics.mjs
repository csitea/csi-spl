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
 * Only the Topics page imports this file, so none of it rides the initial
 * JS (ci_initial_gzip_kb). Node tests import it.
 */

import { ageMatches, laneName, laneState, sortRowsBy, uniqSorted } from './monitoring-lanes.mjs'

/** The sortable columns, in the table's order. */
export const TOPIC_COLUMNS = ['topic', 'workspace', 'channel', 'active', 'lanes', 'issues']

/** No filter: every topic shows. */
export const TOPICS_NO_FILTER = Object.freeze({ text: '', box: '', vendor: '', state: '', age: '' })

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

/** The words a text filter searches: the topic, channel, workspace, lanes and issue keys. */
function topicWords(row) {
  return [row.topicTitle, row.topicId, row.topicChannel, row.workspaceName, row.workspace,
    ...row.lanes.map((l) => l.name), ...row.issues.map((i) => i.key)].join(' ').toLowerCase()
}

/**
 * The topics the filter row keeps: every word of `text` in the topic's
 * words; box, vendor and state each '' (any) or held by one of its lanes;
 * age '' or the newest activity's age in that band.
 * @template T
 * @param {T[]} rows
 * @param {{ text?: string, box?: string, vendor?: string, state?: string, age?: string }} f
 * @returns {T[]}
 */
export function filterTopics(rows, f) {
  const words = str(f.text).toLowerCase().split(/\s+/).filter(Boolean)
  const any = (r, k, v) => !v || r.lanes.some((l) => l[k] === v)
  return rows.filter((r) => any(r, 'box', f.box) && any(r, 'vendor', f.vendor) && any(r, 'state', f.state)
    && ageMatches(r, str(f.age))
    && (words.length === 0 || words.every((w) => topicWords(r).includes(w))))
}

/** Each select's choices: the distinct non-empty values across the topics' lanes, sorted. */
export function topicFilterChoices(rows) {
  const lanes = rows.flatMap((r) => r.lanes)
  return { box: uniqSorted(lanes.map((l) => l.box)), vendor: uniqSorted(lanes.map((l) => l.vendor)), state: uniqSorted(lanes.map((l) => l.state)) }
}
