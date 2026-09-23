/**
 * Where an Omnibox line goes.
 *
 * The open topic pane does not decide. The line does:
 *   - `in: <topic title>` replies into that topic. The title is the first
 *     message of the topic (the same text pane 2 shows on the starter card).
 *   - anything else, including `@receiver`, starts a new message.
 *
 * A unique prefix is not a title. Enter in the dropdown inserts the full
 * title; send matches that exact title, longest first. An `in:` that names
 * nothing is left in the body and the send stays a new message.
 */

import { fenceStateAt } from './code-blocks.mjs'

const IN_AT_CARET = /(^|\s)in:\s*([\s\S]*)$/i
const TITLE_MAX = 140

function titleOf(body) {
  const line = String(body || '').split('\n')[0].trim()
  return line.length > TITLE_MAX ? line.slice(0, TITLE_MAX) : line
}

/**
 * The in-progress `in:` query at the caret (text after `in:`, which may be
 * empty). Null when the caret is not inside an `in:` token.
 */
export function activeInQuery(text, cursor) {
  const s = String(text || '')
  const n = Number(cursor)
  const i = Number.isFinite(n) ? Math.max(0, Math.min(s.length, n)) : s.length
  const m = s.slice(0, i).match(IN_AT_CARET)
  if (!m) return null
  return m[2]
}

/** Case-insensitive substring of the title. Empty query returns the first 8. */
export function filterTopicTitles(topics, query) {
  const rows = Array.isArray(topics) ? topics : []
  const q = String(query || '').trim().toLowerCase()
  const matched = q
    ? rows.filter((t) => String((t && t.title) || '').toLowerCase().includes(q))
    : rows.slice()
  return matched.slice(0, 8)
}

/** Replace the in-progress query with the full title. */
export function insertInClause(text, cursor, title) {
  const s = String(text || '')
  const n = Number(cursor)
  const i = Number.isFinite(n) ? Math.max(0, Math.min(s.length, n)) : s.length
  const before = s.slice(0, i)
  const after = s.slice(i)
  const clean = titleOf(title)
  const m = before.match(IN_AT_CARET)
  if (!m) {
    const gap = s && !/\s$/.test(s) ? ' ' : ''
    const inserted = `${gap}in: ${clean} `
    return { text: s + inserted, cursor: s.length + inserted.length }
  }
  const start = before.length - m[2].length
  const gap = s[start - 1] === ':' ? ' ' : ''
  const inserted = `${gap}${clean} `
  return { text: s.slice(0, start) + inserted + after, cursor: start + inserted.length }
}

function earlier(a, b) {
  const c = String(a.ts || a.first_ts || '').localeCompare(String(b.ts || b.first_ts || ''))
  if (c !== 0) return c < 0
  return String(a.msg_id || '').localeCompare(String(b.msg_id || '')) <= 0
}

/**
 * One row per topic the dropdown and the send resolver share.
 * Viewer subjects win, so a loaded topic list is not renamed by a feed row.
 * Feed messages contribute only their starter: the earliest row of a task
 * with no parent_task_id. A reply is not its own title.
 * @returns {{ taskId: string, title: string, channel: string }[]}
 */
export function topicChoices({ topics = [], messages = [] } = {}) {
  const by = new Map()
  for (const row of topics || []) {
    if (!row) continue
    const id = String(row.task_id || row.taskId || '')
    const title = titleOf(row.subject || row.title || '')
    if (!id || !title || by.has(id)) continue
    by.set(id, { taskId: id, title, channel: String(row.channel || '') })
  }
  const earliest = new Map()
  for (const m of messages || []) {
    if (!m || m.parent_task_id || !m.task_id) continue
    const prev = earliest.get(m.task_id)
    if (!prev || earlier(m, prev)) earliest.set(m.task_id, m)
  }
  for (const m of earliest.values()) {
    const id = String(m.task_id)
    if (by.has(id)) continue
    const title = titleOf(m.body)
    if (!title) continue
    by.set(id, { taskId: id, title, channel: String(m.channel || '') })
  }
  return [...by.values()]
}

/**
 * Consume one exact `in: <title>` clause. Longest catalogue title wins.
 * A prefix of a title is not consumed. `in:` inside a code fence is literal.
 * @returns {{ taskId: string, channel: string, title: string, body: string }}
 */
export function resolveInClause(text, choices) {
  const s = String(text || '')
  const list = Array.isArray(choices) ? choices : []
  const re = /(^|\s)in:\s*/gi
  let best = null
  for (let m = re.exec(s); m; m = re.exec(s)) {
    const clauseStart = m.index + m[1].length
    if (fenceStateAt(s, clauseStart).inCode) continue
    const contentStart = m.index + m[0].length
    const rest = s.slice(contentStart)
    for (const c of list) {
      const title = String((c && c.title) || '')
      if (!title || rest.length < title.length) continue
      if (rest.slice(0, title.length).toLowerCase() !== title.toLowerCase()) continue
      const next = rest[title.length]
      if (next !== undefined && !/\s/.test(next)) continue
      if (!best || title.length > best.len) {
        best = { choice: c, len: title.length, clauseStart, contentStart }
      }
    }
    if (m.index === re.lastIndex) re.lastIndex++
  }
  if (!best) return { taskId: '', channel: '', title: '', body: s.trim() }
  let end = best.contentStart + best.len
  if (s[end] === ' ' || s[end] === '\t') end += 1
  let start = best.clauseStart
  if (start > 0 && /\s/.test(s[start - 1])) start -= 1
  const body = (s.slice(0, start) + s.slice(end)).replace(/[ \t]{2,}/g, ' ').trim()
  return {
    taskId: String(best.choice.taskId || ''),
    channel: String(best.choice.channel || ''),
    title: String(best.choice.title || ''),
    body,
  }
}
