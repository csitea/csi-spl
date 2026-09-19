/**
 * Local per-client read cursors (005 contracts/verbosity-notify-v1.md §3).
 * Hub-synced cursors are OQ-W5 (b).
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

export function advanceCursor(cursor, msg) {
  const ts = when(msg)
  const id = String((msg && msg.msg_id) || '')
  if (!ts) return cursor || null
  if (!cursor || !cursor.ts || ts > cursor.ts) return { ts, id }
  if (ts === cursor.ts && id) return { ts, id }
  return cursor
}

export function markReadAt(cursors, key, msg) {
  const next = { ...(cursors || {}) }
  if (msg) next[key] = advanceCursor(next[key], msg)
  else next[key] = { ts: new Date().toISOString(), id: '' }
  return next
}
