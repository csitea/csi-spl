/**
 * Pure helpers for the 003 read-only viewer API (specs/003 contracts/view-v1.md):
 * topic titles and the mock's grouping, and the rest from view-api-core.mjs.
 * Node tests import this file; the client and stores wrap it.
 */

import { plainText } from './plain-text.mjs'
import { viewPeerLabel as label, subjectOf } from './view-api-core.mjs'

export {
  BROWSER_BOX,
  DEFAULT_DELIVERY,
  channelReadQuery,
  channelsFromView,
  copyEditFields,
  copyMoveFields,
  hubField,
  normalizeTopicRow,
  normalizeViewMessage,
  rosterFromView,
  subjectOf,
} from './view-api-core.mjs'

/** How much of the first message the topics list shows after "Topic:". */
export const TOPIC_TITLE_CHARS = 100

/**
 * The title of an open topic: the pinned root when the click was one
 * message, otherwise the oldest row (the starter). Empty when there is
 * no text yet.
 */
export function topicTitleFromRows(rows, pinnedRoot) {
  const pinned = pinnedRoot && String(pinnedRoot.body || '').trim()
  if (pinned) return topicOpening(pinnedRoot.body)
  const list = Array.isArray(rows) ? rows : []
  let root = null
  for (const m of list) {
    if (!m) continue
    if (!root || String(m.ts || '') < String(root.ts || '')) root = m
  }
  return topicOpening(root && root.body)
}

/** First 100 characters of a topic's first message, whitespace collapsed.
 *  A longer message keeps those 100 and ends with "...". */
export function topicOpening(text) {
  const flat = String(text || '').replace(/\s+/g, ' ').trim()
  const chars = Array.from(flat)
  if (chars.length <= TOPIC_TITLE_CHARS) return flat
  return chars.slice(0, TOPIC_TITLE_CHARS).join('') + '...'
}

/**
 * A Topics list row title (spec 082 FR-001, FR-004): the topic's gist (034)
 * when it has one, else its opening as plain text, cut at 100 characters.
 * No "Topic:" label: the list already says what its rows are.
 */
export function rowTitle(subject, gist) {
  const short = plainText(gist)
  return short || plainText(subject, TOPIC_TITLE_CHARS)
}

/** Group flat v:1 messages into view-v1 §4.3 rows, newest activity first. */
export function topicsFromMessages(messages) {
  const by = new Map()
  const sorted = messages.slice().sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
  for (const m of sorted) {
    const key = m.parent_task_id || m.task_id
    if (!key) continue
    let row = by.get(key)
    if (!row) {
      row = {
        task_id: key, first_ts: m.ts, last_ts: m.ts, count: 0,
        kinds: {}, participants: [], subject: subjectOf(m.body),
        /* view-v1 §4.3 names the topic's channel (null = a DM); the move picker reads it */
        channel: m.channel || null,
      }
      by.set(key, row)
    }
    row.count += 1
    row.last_ts = m.ts
    row.kinds[m.kind] = (row.kinds[m.kind] || 0) + 1
    for (const p of [label(m.from, m.from_box), label(m.to, m.to_box)]) {
      if (p && !p.startsWith('@') && !row.participants.includes(p)) row.participants.push(p)
    }
  }
  return [...by.values()].sort((a, b) => String(b.last_ts).localeCompare(String(a.last_ts)))
}

/** All messages of one topic, oldest first (mock side of view-v1 §4.4). */
export function topicMessages(messages, taskId) {
  return messages
    .filter((m) => (m.parent_task_id || m.task_id) === taskId)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

/** Only a blob attachment has bytes on the hub (msg.go Attachment, mode "blob"). */
export function isDownloadable(file) {
  const f = file || {}
  if (f.mode === 'path') return false
  return Boolean(f.file_id || f.sha256)
}
