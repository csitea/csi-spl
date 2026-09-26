// csi-spl-wui/src/utils/rail-order.mjs
//
// Settings -> Behaviour -> "Left panel order" (SPL-979, spec 023 3.8): the
// order of the six left-rail icons. The person drags the icons in the rail
// itself, or reorders the list in Settings (drag, or up/down for the
// keyboard); both write one value on the hub (humans.rail_order, rdb 0063),
// answered as the `rail_order` session claim, null when never reordered.
// The admin-only Users tab is not one of them: it always stays last. Since
// SPL-983 there are seven (Archive); an order stored before that holds six
// and is drawn with the missing tab appended (parseRailOrder).

/** The six tabs in the default order, with their icon and catalogue key. */
export const RAIL_TABS = Object.freeze([
  Object.freeze({ id: 'dm', icon: 'messages', labelKey: 'sidebar.direct_messages' }),
  Object.freeze({ id: 'channels', icon: 'hash', labelKey: 'sidebar.channels' }),
  /* Owner 2026-09-26: Issues is the third tab, directly after Channels. */
  Object.freeze({ id: 'issues', icon: 'issues', labelKey: 'sidebar.issues' }),
  Object.freeze({ id: 'topics', icon: 'list', labelKey: 'nav.topics' }),
  Object.freeze({ id: 'flow', icon: 'waves', labelKey: 'sidebar.flow' }),
  /* CLE-34990: the personal Event log, directly after flow (owner, topic 4335f075). */
  Object.freeze({ id: 'events', icon: 'history', labelKey: 'sidebar.events' }),
  /* SPL-983: Archive (owner, topic 8f58f802), last by default; the page is CLE-35018's. */
  Object.freeze({ id: 'archive', icon: 'archive', labelKey: 'sidebar.archive' }),
])

export const RAIL_IDS = Object.freeze(RAIL_TABS.map((t) => t.id))

/** A pointer must travel this far before a press becomes a drag: a click never reorders. */
export const DRAG_THRESHOLD_PX = 6

/** true when `raw` holds every rail id exactly once (the hub's IsRailOrder). */
export function isRailOrder(raw) {
  if (!Array.isArray(raw) || raw.length !== RAIL_IDS.length) return false
  const seen = new Set(raw)
  return seen.size === RAIL_IDS.length && RAIL_IDS.every((id) => seen.has(id))
}

/**
 * The order to draw: the stored one, tolerant of a tab added since it was
 * stored (SPL-983 Archive: an order saved with six ids keeps them in place
 * and gets the new tab appended). Unknown and repeated ids are dropped; no
 * stored order at all is the default order.
 */
export function parseRailOrder(raw) {
  if (!Array.isArray(raw)) return [...RAIL_IDS]
  const out = []
  for (const id of raw) if (RAIL_IDS.includes(id) && !out.includes(id)) out.push(id)
  if (out.length === 0) return [...RAIL_IDS]
  for (const id of RAIL_IDS) if (!out.includes(id)) out.push(id)
  return out
}

export function sameOrder(a, b) {
  return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => x === b[i])
}

/** `order` with `id` moved to index `to` (clamped). Unknown id: a copy. */
export function moveTo(order, id, to) {
  const out = [...order]
  const from = out.indexOf(id)
  if (from < 0) return out
  const at = Math.max(0, Math.min(out.length - 1, Math.trunc(to)))
  out.splice(from, 1)
  out.splice(at, 0, id)
  return out
}

/** One step up (-1) or down (+1); stops at either end. */
export function moveBy(order, id, delta) {
  const from = order.indexOf(id)
  return from < 0 ? [...order] : moveTo(order, id, from + delta)
}

/**
 * The index a dragged item lands on: the number of OTHER items whose middle
 * lies before the pointer. `mids` are the items' middles in their current
 * order, `from` the dragged item's index there.
 */
export function dropIndex(mids, from, pos) {
  let n = 0
  for (let i = 0; i < mids.length; i++) {
    if (i !== from && pos > mids[i]) n++
  }
  return n
}

/** Past the click-versus-drag threshold? */
export function isDrag(dx, dy, threshold = DRAG_THRESHOLD_PX) {
  return Math.hypot(Number(dx) || 0, Number(dy) || 0) >= threshold
}

/**
 * Save a new order, optimistic like the other Behaviour setting: mirror the
 * claim at once (the rail and the Settings list both redraw), save it, put
 * the old one back on a refusal. `want` null = back to the default (clears).
 * @param {string[] | null} want
 * @param {{ current: unknown, apply: (o: string[] | null) => void,
 *           save: (o: string[] | null) => Promise<{ ok: boolean }> }} io
 */
export async function applyRailOrder(want, { current, apply, save }) {
  /* a legacy (shorter) stored order is kept as it was on a revert */
  const prev = Array.isArray(current) && current.length > 0 ? [...current] : null
  if (want !== null && !isRailOrder(want)) return { ok: false, value: prev }
  if (want === null ? prev === null : (prev !== null && sameOrder(want, prev))) return { ok: true, value: prev }
  const next = want === null ? null : [...want]
  apply(next)
  let out
  try {
    out = await save(next)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (out && out.ok) return { ok: true, value: next }
  apply(prev)
  return { ok: false, value: prev, out }
}
