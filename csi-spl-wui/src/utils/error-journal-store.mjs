// csi-spl-wui/src/utils/error-journal-store.mjs
//
// The in-memory journal of composables/errorJournal.mjs: one ring buffer per
// tab, and its subscribers. It holds records that were ALREADY built and
// redacted; it never sees raw input. Pure ES module, nothing here throws on
// the capture path.

/** Ring-buffer cap. 50 × ≤2 KB ≈ 100 KB worst case, and it dies with the tab. */
export const ERROR_JOURNAL_LIMIT = 50

/** @type {object[]} */
let records = []
/** @type {Set<(r: object[]) => void>} */
const listeners = new Set()

function emit() {
  const snapshot = records.slice()
  for (const fn of listeners) {
    try { fn(snapshot) } catch { /* a bad subscriber must not break capture */ }
  }
}

/**
 * Append one built record, drop the oldest past the cap, tell subscribers.
 * @param {object} rec
 */
export function pushRecord(rec) {
  records.push(rec)
  if (records.length > ERROR_JOURNAL_LIMIT) {
    records.splice(0, records.length - ERROR_JOURNAL_LIMIT)
  }
  emit()
}

/** @returns {object[]} newest LAST (insertion order) */
export function getErrors() {
  return records.slice()
}

/**
 * @param {(records: object[]) => void} fn
 * @returns {() => void} unsubscribe
 */
export function subscribeErrors(fn) {
  listeners.add(fn)
  return () => { listeners.delete(fn) }
}

/** Empty the buffer for this tab (the panel's Clear control). */
export function clearErrors() {
  if (!records.length) return
  records = []
  emit()
}

/** Test helper — the production UI never calls this. */
export function resetErrorJournal() {
  records = []
  emit()
}
