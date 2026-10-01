/**
 * Local per-client read cursors (005 contracts/verbosity-notify-v1.md §3).
 * Hub-synced cursors are OQ-W5 (b). A cursor is { ts, id } plus, for a live
 * channel, `hub`: the opaque view-v1 cursor the hub counts `unread` against
 * (channels-v1 §5.2, `read=<channel>~<cursor>`).
 */

import { storageGetJson, storageSetJson } from './prefs.mjs'
import { isViewersOwn } from './typed-by.mjs'

export const CURSOR_KEY = 'spool.read-cursors'

export function when(msg) {
  return String((msg && (msg.received_at || msg.ts)) || '')
}

export function loadCursors(store) {
  const v = storageGetJson(CURSOR_KEY, {}, store)
  return v && typeof v === 'object' && !Array.isArray(v) ? { ...v } : {}
}

export function saveCursors(cursors, store) {
  const v = cursors && typeof cursors === 'object' && !Array.isArray(cursors) ? cursors : {}
  return storageSetJson(CURSOR_KEY, v, store)
}

export function isUnread(msg, cursor) {
  if (!cursor || !cursor.ts) return true
  const ts = when(msg)
  if (ts > cursor.ts) return true
  if (ts < cursor.ts) return false
  return String((msg && msg.msg_id) || '') !== String(cursor.id || '')
}

function withHub(c, msg) {
  return msg && msg.cursor ? { ...c, hub: String(msg.cursor) } : c
}

export function advanceCursor(cursor, msg) {
  const ts = when(msg)
  const id = String((msg && msg.msg_id) || '')
  if (!ts) return cursor || null
  if (!cursor || !cursor.ts || ts > cursor.ts) return withHub({ ts, id }, msg)
  if (ts === cursor.ts && id) return withHub({ ts, id }, msg)
  return cursor
}

export function markReadAt(cursors, key, msg) {
  const next = { ...(cursors || {}) }
  if (msg) next[key] = advanceCursor(next[key], msg)
  else next[key] = { ts: new Date().toISOString(), id: '' }
  return next
}

/** The per-topic read-cursor key (CLE-77804 topic 35053f95): one per topic the reader has opened. */
export function topicKey(taskId) {
  return taskId ? `t:${taskId}` : ''
}

/**
 * CLE-77804 (topic 35053f95): mark a topic read at its current reply total.
 * The cursor carries `count` — the total the reader had seen — so the card can
 * show unread = currentTotal - count as "<unread>/<total> >>", per reader, with
 * no hub round-trip. Opening the thread (or the reader's own reply) sets it to
 * the current total, clearing the unread part to a plain "<total>".
 */
export function markTopicReadAt(cursors, taskId, count, ownMsgId = '') {
  const key = topicKey(taskId)
  if (!key) return { ...(cursors || {}) }
  const next = { ...(cursors || {}) }
  const was = next[key]
  const c = { ts: new Date().toISOString(), id: '', count: Math.max(0, Number(count) || 0) }
  const own = withOwn(was && Array.isArray(was.own) ? was.own : [], ownMsgId)
  next[key] = own.length ? { ...c, own } : c
  return next
}

/** How many own msg_ids a topic cursor remembers (enough for a burst from another device). */
export const OWN_KEEP = 50

function withOwn(list, id) {
  const out = list.map(String).filter(Boolean)
  if (id && !out.includes(String(id))) out.push(String(id))
  return out.slice(-OWN_KEEP)
}

/**
 * CLE-77889 (owner, t1 99905c80): the reader's OWN reply - sent from another
 * tab or device, or typed at an agent's terminal - raises the topic's reply
 * total, and the card read it as "1/N" new. It now moves the reader's seen
 * count with it: each own reply of a topic the reader has a cursor for, newer
 * than that cursor, counts as seen ONCE (its msg_id is kept in `own`, so the
 * echo of a reply this tab already counted when sending, a reload, and the
 * same row read twice never count it again). The cursor's ts stays put, so
 * own replies still on their way are counted when they land.
 *
 * @param {Record<string, any>} cursors
 * @param {string} taskId the topic the reply counts under
 * @param {{ msg_id?: string, received_at?: string, ts?: string }} msg an own reply
 * @returns {Record<string, any>} the same object when nothing moved
 */
export function ownReplyReadAt(cursors, taskId, msg) {
  const key = topicKey(taskId)
  const c = key && cursors ? cursors[key] : null
  const id = String((msg && msg.msg_id) || '')
  if (!c || !Number.isFinite(c.count) || !id) return cursors
  const own = Array.isArray(c.own) ? c.own.map(String) : []
  if (own.includes(id)) return cursors
  if (c.ts && when(msg) && when(msg) <= c.ts) return cursors
  return { ...cursors, [key]: { ...c, count: Number(c.count) + 1, own: withOwn(own, id) } }
}

/** The topics a message counts as a reply under: its own task (when it is not the root) and its parent. */
export function replyTopicsOf(msg) {
  const m = msg || {}
  const out = []
  if (m.task_id && !m.topic_row) out.push(String(m.task_id))
  if (m.parent_task_id && String(m.parent_task_id) !== String(m.task_id || '')) out.push(String(m.parent_task_id))
  return out
}

/**
 * The unread reply count for a topic: how many replies arrived since the reader
 * last read it. `total` is the hub's current reply count; `cursor` the t:<id>
 * cursor. No cursor (never opened) -> 0, so an untouched topic shows a plain
 * total, not every reply flagged.
 */
export function topicUnread(total, cursor) {
  const n = Number(total) || 0
  if (!cursor || !Number.isFinite(cursor.count)) return 0
  return Math.max(0, n - Number(cursor.count))
}

/**
 * CLE-77804 (topic 1e7d56b8): the "New messages" divider. Given the read
 * cursor as it was when the feed was opened (the frozen boundary) and the
 * feed's messages, the msg_id of the chronologically-FIRST message the reader
 * has not seen — where the divider goes — or '' when there is nothing new or
 * the channel was never read (no boundary: we do not flag a whole fresh feed).
 */
export function firstUnreadId(messages, cursor, selfId = '') {
  if (!cursor || !cursor.ts) return ''
  let best = null
  for (const m of messages || []) {
    /* CLE-77804 (HUM-24, topic 311427c6): the reader's own message is never new,
       nor one they typed at an agent's terminal (CLE-77889) */
    if (isViewersOwn(m, selfId)) continue
    if (!isUnread(m, cursor)) continue
    const ts = when(m)
    const id = String((m && m.msg_id) || '')
    if (!best || ts < best.ts || (ts === best.ts && id < best.id)) best = { ts, id }
  }
  return best ? best.id : ''
}

/** How many of `messages` are unread vs the frozen boundary (the "N new" count). Own messages never count (HUM-24). */
export function countUnread(messages, cursor, selfId = '') {
  if (!cursor || !cursor.ts) return 0
  let n = 0
  for (const m of messages || []) {
    if (isViewersOwn(m, selfId)) continue
    if (isUnread(m, cursor)) n++
  }
  return n
}

/** Cursor at a hub channel row's newest message (view-v1 §4.2 last_ts / last_cursor). */
export function cursorFromChannel(row) {
  if (!row || !row.last_ts) return null
  const c = { ts: String(row.last_ts), id: '' }
  return row.last_cursor ? { ...c, hub: String(row.last_cursor) } : c
}

/** Unread per key from the stored cursors, so badges survive a reload. */
export function unreadFromCursors(messages, cursors, keyOf) {
  const out = {}
  const cs = cursors || {}
  for (const m of messages || []) {
    const key = m && keyOf(m)
    if (key && isUnread(m, cs[key])) out[key] = (out[key] || 0) + 1
  }
  return out
}

/** channels-v1 §5.2: one `<channel>~<cursor>` per channel that has a hub cursor. */
export function readParams(cursors) {
  return Object.entries(cursors || {})
    .filter(([k, c]) => k.startsWith('ch:') && c && c.hub)
    .map(([k, c]) => `${k.slice(3)}~${c.hub}`)
}

/** Hub channel rows → `ch:<id>` unread counts (rows without a numeric unread are skipped). */
export function unreadFromChannels(rows) {
  const out = {}
  for (const r of rows || []) {
    const id = r && (r.channel_id || r.channel)
    if (id && Number.isFinite(r.unread)) out[`ch:${id}`] = r.unread
  }
  return out
}

/** The same cursors as spool-client listChannels({ read }) wants them: { <channel>: <hub cursor> }. */
export function readMap(cursors) {
  const out = {}
  for (const [k, c] of Object.entries(cursors || {})) {
    if (k.startsWith('ch:') && c && c.hub) out[k.slice(3)] = String(c.hub)
  }
  return out
}
