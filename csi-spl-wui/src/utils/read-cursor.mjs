/**
 * Local per-client read cursors (005 contracts/verbosity-notify-v1.md §3).
 * Hub-synced cursors are OQ-W5 (b). A cursor is { ts, id } plus, for a live
 * channel, `hub`: the opaque view-v1 cursor the hub counts `unread` against
 * (channels-v1 §5.2, `read=<channel>~<cursor>`).
 */

import { storageGetJson, storageSetJson } from './prefs.mjs'

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
