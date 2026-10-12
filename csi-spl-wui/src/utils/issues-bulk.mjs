/**
 * Gmail-style selection on the /issues list (owner HUM-10, t1 53ab04e7, msg
 * 14b0e604: "the issues listing should have checkboxes to perform multiple
 * actions the same way as in gmail").
 *
 * The selection is a list of issue keys, kept in the order they were checked.
 * Everything here is pure: the page holds the ref, these functions return the
 * next value. A shift-click checks (or unchecks) the whole run between the
 * last row clicked (the anchor) and this one, the way Gmail does.
 *
 * The hub has no bulk route (measured 2026-10-12 on dev, n=6 status PATCHes,
 * ~0.3..0.6 s each at the hub), so a bulk action is one call per issue, a few
 * at a time (BULK_PARALLEL), and one summary naming the rows that failed.
 */

/** how many per-issue calls run at once */
export const BULK_PARALLEL = 4

/** `key` checked or unchecked: `on` true / false, or the opposite of now. */
export function toggleKey(sel, key, on) {
  const list = Array.isArray(sel) ? sel : []
  if (!key) return list
  const has = list.includes(key)
  const want = typeof on === 'boolean' ? on : !has
  if (want === has) return list
  return want ? [...list, key] : list.filter((k) => k !== key)
}

/**
 * Shift-click: every key in `order` between `anchor` and `key` (both
 * included) takes the state `on`. No anchor, or an anchor no longer in the
 * list, behaves as a plain click on `key`.
 */
export function rangeSelect(sel, order, anchor, key, on) {
  const keys = Array.isArray(order) ? order : []
  const a = anchor ? keys.indexOf(anchor) : -1
  const b = keys.indexOf(key)
  if (b < 0) return Array.isArray(sel) ? sel : []
  if (a < 0) return toggleKey(sel, key, on)
  const [lo, hi] = a <= b ? [a, b] : [b, a]
  let out = Array.isArray(sel) ? sel : []
  for (const k of keys.slice(lo, hi + 1)) out = toggleKey(out, k, on)
  return out
}

/** The header box's state for the rows shown: 'none', 'some' or 'all'. */
export function pageState(sel, shown) {
  const keys = Array.isArray(shown) ? shown : []
  const set = new Set(Array.isArray(sel) ? sel : [])
  const n = keys.filter((k) => set.has(k)).length
  if (!n) return 'none'
  return n === keys.length ? 'all' : 'some'
}

/** The header box clicked: every shown row checked, or (all already were) none. */
export function toggleAll(sel, shown) {
  const keys = Array.isArray(shown) ? shown : []
  const list = Array.isArray(sel) ? sel : []
  if (pageState(list, keys) === 'all') {
    const drop = new Set(keys)
    return list.filter((k) => !drop.has(k))
  }
  const have = new Set(list)
  return [...list, ...keys.filter((k) => !have.has(k))]
}

/** Only the keys still on the list (a row deleted, archived or filtered away leaves the selection). */
export function keepShown(sel, keys) {
  const list = Array.isArray(sel) ? sel : []
  const set = new Set(Array.isArray(keys) ? keys : [])
  const out = list.filter((k) => set.has(k))
  return out.length === list.length ? list : out
}

/**
 * Run `fn(key)` for every key, at most `parallel` at once. Never throws:
 * `{ done: [keys], failed: [{ key, error }] }`, in the keys' order.
 * `onProgress(finished, total)` after each call.
 */
export async function runBulk(keys, fn, { parallel = BULK_PARALLEL, onProgress } = {}) {
  const list = Array.isArray(keys) ? [...keys] : []
  const outcome = new Array(list.length)
  let next = 0
  let finished = 0
  const worker = async () => {
    while (next < list.length) {
      const i = next++
      try {
        await fn(list[i])
        outcome[i] = { ok: true }
      } catch (error) {
        outcome[i] = { ok: false, error }
      }
      finished++
      if (typeof onProgress === 'function') onProgress(finished, list.length)
    }
  }
  const n = Math.max(1, Math.min(Number(parallel) || 1, list.length))
  await Promise.all(Array.from({ length: list.length ? n : 0 }, worker))
  const done = []
  const failed = []
  list.forEach((key, i) => {
    if (outcome[i].ok) done.push(key)
    else failed.push({ key, error: outcome[i].error })
  })
  return { done, failed }
}
