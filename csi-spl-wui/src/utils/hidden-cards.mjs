// HUM-10 (owner, t1 topic 6fc56905, 2026-10-03): "On mobile in the
// reply/thread messages view, it should be possible to hide a message/card by
// just swiping to the left. That would be just hide, not archive, not delete.
// Just hide that card there and indicate that there is a card by having a
// thicker line between the start and stop messages before and after that
// message." And (t1 topic 3e073a95): "when one clicks on that thicker line,
// the hidden message/card should reappear once again."
//
// Hide is this viewer's, on this device: a list of msg ids in localStorage.
// Nothing goes to the hub (a cross-device hide would need a hub change).
// Every storage touch is wrapped: without storage the page still works, the
// hide just lasts until the reload. Pure, so tests/unit/hidden-cards.test.mjs
// pins it.

/** localStorage key (per device). */
export const HIDDEN_CARDS_KEY = 'spool.hidden-cards'
/** the newest this many hides are kept; the oldest fall off */
export const HIDDEN_CARDS_MAX = 1000

/** A clean, de-duplicated list of non-empty id strings, at most MAX long. */
export function normalizeHiddenIds(raw) {
  if (!Array.isArray(raw)) return []
  const out = []
  const seen = new Set()
  for (const v of raw) {
    if (typeof v !== 'string' || !v || seen.has(v)) continue
    seen.add(v)
    out.push(v)
  }
  return out.slice(-HIDDEN_CARDS_MAX)
}

function storage(store) {
  if (store !== undefined) return store
  try {
    return typeof window !== 'undefined' ? window.localStorage : null
  } catch {
    return null
  }
}

/** The hidden ids on this device ([] when storage is missing or broken). */
export function readHiddenCards(store) {
  try {
    const s = storage(store)
    const raw = s ? s.getItem(HIDDEN_CARDS_KEY) : null
    return raw ? normalizeHiddenIds(JSON.parse(raw)) : []
  } catch {
    return []
  }
}

/** Keep `ids` on this device; an empty list removes the key. Never throws. */
export function writeHiddenCards(ids, store) {
  try {
    const s = storage(store)
    if (!s) return
    const list = normalizeHiddenIds(ids)
    if (list.length) s.setItem(HIDDEN_CARDS_KEY, JSON.stringify(list))
    else s.removeItem(HIDDEN_CARDS_KEY)
  } catch { /* private mode, quota: the hide lasts until the reload */ }
}

/** `ids` with `add` appended (the newest last). */
export function withHiddenIds(ids, add) {
  const drop = new Set(normalizeHiddenIds(add))
  return normalizeHiddenIds([...normalizeHiddenIds(ids).filter((id) => !drop.has(id)), ...drop])
}

/** `ids` without `drop`. */
export function withoutHiddenIds(ids, drop) {
  const d = new Set(normalizeHiddenIds(drop))
  return normalizeHiddenIds(ids).filter((id) => !d.has(id))
}

/**
 * The feed's items with each run of consecutive hidden cards folded into ONE
 * `{ key, hidden: [ids], i: -1 }` item: the thicker line that stands where
 * they were. Other items (dividers, shown cards) pass through in order.
 */
export function collapseHiddenRuns(items, isHidden) {
  const out = []
  let run = null
  for (const it of items) {
    const id = it && it.msg && it.msg.msg_id ? String(it.msg.msg_id) : ''
    if (id && isHidden(id)) {
      if (run) run.hidden.push(id)
      else {
        run = { key: `__hidden__${id}`, hidden: [id], i: -1 }
        out.push(run)
      }
      continue
    }
    run = null
    out.push(it)
  }
  return out
}
