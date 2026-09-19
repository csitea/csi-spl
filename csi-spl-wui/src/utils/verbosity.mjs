/**
 * Thread verbosity inferred from v:1 `kind` (005 contracts/verbosity-notify-v1.md).
 * No envelope field. Node tests import this file; Vue stores wrap it.
 */

import { storageGet, storageSet } from './prefs.mjs'

export const LEVELS = ['minimal', 'normal', 'verbose']
export const DEFAULT_LEVEL = 'normal'
export const STORAGE_KEY = 'spool.verbosity'

/** Frozen inner kinds (`internal/msg/msg.go` validKinds; inner of wire.Envelope.Msg). */
export const V1_KINDS = ['task', 'result', 'note', 'reject']

const KIND_LEVEL = {
  task: 'minimal',
  result: 'minimal',
  reject: 'minimal',
  note: 'normal',
}

const RANK = { minimal: 0, normal: 1, verbose: 2 }

export function verbosityOf(kind) {
  return KIND_LEVEL[String(kind || '')] || 'verbose'
}

export function parseLevel(v) {
  return LEVELS.includes(v) ? v : DEFAULT_LEVEL
}

export function messageVisible(msg, level) {
  const have = RANK[verbosityOf(msg && msg.kind)] ?? RANK.verbose
  const want = RANK[parseLevel(level)] ?? RANK.normal
  return have <= want
}

export function applyVerbosity(messages, level) {
  const rows = Array.isArray(messages) ? messages : []
  if (parseLevel(level) === 'verbose') return rows.slice()
  return rows.filter((m) => messageVisible(m, level))
}

export function loadVerbosity(store) {
  return parseLevel(storageGet(STORAGE_KEY, DEFAULT_LEVEL, store))
}

export function saveVerbosity(level, store) {
  const v = parseLevel(level)
  storageSet(STORAGE_KEY, v, store)
  return v
}
