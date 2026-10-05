/**
 * Topic verbosity inferred from v:1 `kind` (005 contracts/verbosity-notify-v1.md).
 * No envelope field. Node tests import this file; Vue stores wrap it.
 */

import { storageGet, storageSet } from './prefs.mjs'

export const LEVELS = ['minimal', 'normal', 'verbose']
export const DEFAULT_LEVEL = 'normal'
/**
 * localStorage key `spool.verbosity`. The only storage-key constant in
 * src/utils whose name is not <FEATURE>_KEY. A rename touches the shim,
 * so the name stays.
 */
export const STORAGE_KEY = 'spool.verbosity'

/** Frozen inner kinds (`internal/msg/msg.go` validKinds; inner of wire.Envelope.Msg). */
export const V1_KINDS = ['task', 'result', 'note', 'reject', 'blocker', 'msg']

const KIND_LEVEL = {
  task: 'minimal',
  result: 'minimal',
  reject: 'minimal',
  // SPL-952: a blocker waits on a reader, so even minimal shows it
  blocker: 'minimal',
  note: 'normal',
  msg: 'normal',
}

const RANK = { minimal: 0, normal: 1, verbose: 2 }

/** Verbosity a v:1 kind is shown at. An unknown or empty kind is verbose. */
export function verbosityOf(kind) {
  return KIND_LEVEL[String(kind || '')] || 'verbose'
}

/** One of LEVELS, or DEFAULT_LEVEL when the value is not one of them. */
export function parseLevel(v) {
  return LEVELS.includes(v) ? v : DEFAULT_LEVEL
}

/**
 * Whether a message's kind is visible at the reader's level.
 * A quieter kind stays visible when the reader asks for more.
 */
export function messageVisible(msg, level) {
  const have = RANK[verbosityOf(msg && msg.kind)] ?? RANK.verbose
  const want = RANK[parseLevel(level)] ?? RANK.normal
  return have <= want
}

/**
 * The rows the reader sees at this level. Returns a copy;
 * verbose returns every row.
 */
export function applyVerbosity(messages, level) {
  const rows = Array.isArray(messages) ? messages : []
  if (parseLevel(level) === 'verbose') return rows.slice()
  return rows.filter((m) => messageVisible(m, level))
}

/** The saved level, or DEFAULT_LEVEL when nothing usable is stored. */
export function loadVerbosity(store) {
  return parseLevel(storageGet(STORAGE_KEY, DEFAULT_LEVEL, store))
}

/** Persist a level under STORAGE_KEY and return the level written. */
export function saveVerbosity(level, store) {
  const v = parseLevel(level)
  storageSet(STORAGE_KEY, v, store)
  return v
}
