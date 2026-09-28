// csi-spl-wui/src/utils/issue-columns-pref.mjs
//
// SPL-1132 (owner, prd t1 topic beb4024f: "the columns of the issues grid
// should be resizable"): a person's Issues sheet column widths, kept on the
// account (humans.issues_columns, rdb 0076) and answered as the
// `issues_columns` session claim - one object of column -> px, null when
// never sized (the sheet then keeps its automatic layout).
//
// The hub admits exactly what parseIssueColumns keeps (auth.IsIssueColumns):
// the sheet columns, whole px ISSUE_COLUMN_MIN..ISSUE_COLUMN_MAX. The unit
// test tests/unit/issue-columns-pref.test.mjs pins the two sides equal.
import { SHEET_COLUMNS } from './issues-view.mjs'

export const ISSUE_COLUMNS = SHEET_COLUMNS
export const ISSUE_COLUMN_MIN = 24
export const ISSUE_COLUMN_MAX = 2000

/**
 * The widths the hub would store: known columns only, each rounded to whole
 * px inside [MIN, MAX]; junk entries are dropped. Never null (empty = none).
 * @param {unknown} raw
 * @returns {Record<string, number>}
 */
export function parseIssueColumns(raw) {
  const out = {}
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out
  for (const col of ISSUE_COLUMNS) {
    const v = /** @type {Record<string, unknown>} */ (raw)[col]
    if (v == null || v === '') continue
    const n = Number(v)
    if (!Number.isFinite(n)) continue
    out[col] = Math.min(ISSUE_COLUMN_MAX, Math.max(ISSUE_COLUMN_MIN, Math.round(n)))
  }
  return out
}

/** Two width maps hold the same widths. */
export function sameIssueColumns(a, b) {
  const x = parseIssueColumns(a)
  const y = parseIssueColumns(b)
  const kx = Object.keys(x)
  return kx.length === Object.keys(y).length && kx.every((k) => x[k] === y[k])
}

/**
 * The save, optimistic like the other Behaviour settings: mirror the claim
 * at once (every view of the sheet follows), store it, and put the old
 * widths back on a refusal. An empty map is stored as null.
 * @param {unknown} want
 * @param {{ current: unknown, apply: (v: Record<string, number> | null) => void,
 *           save: (v: Record<string, number> | null) => Promise<{ ok: boolean }> }} io
 * @returns {Promise<{ ok: boolean, value: Record<string, number>, out?: unknown }>}
 */
export async function applyIssueColumns(want, { current, apply, save }) {
  const prev = parseIssueColumns(current)
  const next = parseIssueColumns(want)
  if (sameIssueColumns(prev, next)) return { ok: true, value: prev }
  const asClaim = (m) => (Object.keys(m).length ? m : null)
  apply(asClaim(next))
  let out
  try {
    out = await save(asClaim(next))
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (out && out.ok) return { ok: true, value: next }
  apply(asClaim(prev))
  return { ok: false, value: prev, out }
}
