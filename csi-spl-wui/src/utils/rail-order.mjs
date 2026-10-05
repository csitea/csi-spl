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
// CLE-77916 (owner, t1 topic 5463df22): Archive is ALWAYS the last section and
// the one that cannot be dragged (RAIL_PINNED_LAST, pinRailOrder).

/** The six tabs in the default order, with their icon and catalogue key. */
export const RAIL_TABS = Object.freeze([
  /* Owner 2026-09-27 (topic 116646c8): new members start with Channels,
     Direct messages, Issues, Topics, Flow, Archive; the Event log, which the
     owner did not name, goes last. A stored order (humans.rail_order) is kept
     as it is; only never-reordered people follow this one. */
  Object.freeze({ id: 'channels', icon: 'hash', labelKey: 'sidebar.channels' }),
  /* CLE-77904 (owner, t1 topic cb12574f): on a phone the section reads
     "Messages"; desktop keeps "Direct messages" (railLabelKey) */
  Object.freeze({ id: 'dm', icon: 'messages', labelKey: 'sidebar.direct_messages', phoneLabelKey: 'sidebar.messages' }),
  /* Owner 2026-09-26: Issues is the third tab. */
  Object.freeze({ id: 'issues', icon: 'issues', labelKey: 'sidebar.issues' }),
  Object.freeze({ id: 'topics', icon: 'list', labelKey: 'nav.topics' }),
  Object.freeze({ id: 'flow', icon: 'waves', labelKey: 'sidebar.flow' }),
  /* SPL-983: Archive (owner, topic 8f58f802); the page is CLE-35018's. */
  Object.freeze({ id: 'archive', icon: 'archive', labelKey: 'sidebar.archive' }),
  /* the personal Event log (owner, topic 4335f075); last by default
     since 2026-09-27 (topic 116646c8 left it out of the named order). */
  Object.freeze({ id: 'events', icon: 'history', labelKey: 'sidebar.events' }),
  /* CLE-77794 (owner 2026-09-30, topic 1fc29f99): People lists every member
     with their interests on the right; Agents lists the tenant's agents with
     their kind (Claude / Antigravity / Grok / Qwen). Both reorder and collapse
     like the rest; a stored order from before them is drawn with the two
     appended (parseRailOrder), and the hub's IsRailOrder + rdb 0087 admit the
     nine. */
  Object.freeze({ id: 'people', icon: 'users', labelKey: 'sidebar.people' }),
  Object.freeze({ id: 'agents', icon: 'bot', labelKey: 'sidebar.agents' }),
  /* CLE-77799 (owner 2026-09-30, topic 1fc29f99: "we should have a boxes
     section as well ... and later on we will have more boxes than the current
     one box"): Boxes lists the tenant's boxes (machines and the browser box),
     their liveness and who is seated on each — the people AND the agents that
     use it, each linked to their People / Agents card. Reorders and collapses
     like the rest; a stored order from before it is drawn with Boxes appended
     (parseRailOrder), and the hub's IsRailOrder + rdb 0089 admit the ten. */
  Object.freeze({ id: 'boxes', icon: 'server', labelKey: 'sidebar.boxes' }),
  /* spec 089 T007 (owner HUM-10, 2026-10-05): Calendar opens /calendar, a
     single sheet like Issues (the year strip and the main view). Reorders and
     collapses like the rest; a stored order from before it is drawn with
     Calendar appended (parseRailOrder), and the hub's IsRailOrder + rdb 0133
     admit the eleven. */
  Object.freeze({ id: 'calendar', icon: 'calendar', labelKey: 'sidebar.calendar' }),
])

/** Every rail id, in the hub's list (auth.RailTabs) - a set, not the drawn order. */
export const RAIL_IDS = Object.freeze(RAIL_TABS.map((t) => t.id))

/**
 * CLE-77916 (owner, t1 topic 5463df22, 2026-10-01: "its place should be
 * ALWAYS at the bottom and it must be the only one which is NOT draggable"):
 * Archive ends every drawn and every saved order, whatever was stored.
 */
export const RAIL_PINNED_LAST = 'archive'

/** `order` with the pinned tab moved to the end (a copy; absent stays absent). */
export function pinRailOrder(order) {
  const out = order.filter((id) => id !== RAIL_PINNED_LAST)
  if (out.length !== order.length) out.push(RAIL_PINNED_LAST)
  return out
}

/** The order a never-reordered person sees: RAIL_IDS with Archive last. */
export const DEFAULT_RAIL_ORDER = Object.freeze(pinRailOrder([...RAIL_IDS]))

/** Can this rail tab be dragged / stepped? Archive cannot. */
export function isRailMovable(id) {
  return id !== RAIL_PINNED_LAST
}

/**
 * The catalogue key that names a rail tab: its phone name at <= 820 px
 * (useMobileStack().isMobile) when it has one, else its label.
 * @param {{ labelKey: string, phoneLabelKey?: string }} tab
 * @param {boolean} phone
 */
export function railLabelKey(tab, phone) {
  return (phone && tab.phoneLabelKey) || tab.labelKey
}

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
 * stored order at all is the default order. Archive is always last
 * (CLE-77916), so an order stored with it elsewhere is drawn repaired.
 */
export function parseRailOrder(raw) {
  if (!Array.isArray(raw)) return [...DEFAULT_RAIL_ORDER]
  const out = []
  for (const id of raw) if (RAIL_IDS.includes(id) && !out.includes(id)) out.push(id)
  if (out.length === 0) return [...DEFAULT_RAIL_ORDER]
  for (const id of RAIL_IDS) if (!out.includes(id)) out.push(id)
  return pinRailOrder(out)
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
 * order, `from` the dragged item's index there, both on the list's own axis
 * (dragAxis).
 */
export function dropIndex(mids, from, pos) {
  let n = 0
  for (let i = 0; i < mids.length; i++) {
    if (i !== from && pos > mids[i]) n++
  }
  return n
}

/**
 * CLE-77916: the axis a list runs along, from its items' boxes in order: 'x'
 * when it is laid out in a row (the phone strip), 'y' otherwise (the desktop
 * rail, the Settings list). `sign` is -1 when the row runs right to left, so
 * `sign * clientX` grows along the list. Measuring the strip on clientY made
 * every sideways press-and-move a "drop" at the first or the last index - the
 * tab under the finger jumped to an end and the order was saved.
 * @param {{ left: number, top: number, width: number, height: number }[]} rects
 */
export function dragAxis(rects) {
  if (!Array.isArray(rects) || rects.length < 2) return { axis: 'y', sign: 1 }
  const a = rects[0]
  const b = rects[rects.length - 1]
  const dx = (b.left + b.width / 2) - (a.left + a.width / 2)
  const dy = (b.top + b.height / 2) - (a.top + a.height / 2)
  if (Math.abs(dx) > Math.abs(dy)) return { axis: 'x', sign: dx < 0 ? -1 : 1 }
  return { axis: 'y', sign: 1 }
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
  /* CLE-77916: whatever the caller built, Archive is saved last */
  if (want !== null) want = pinRailOrder(want)
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
