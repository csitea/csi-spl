// csi-spl-wui/src/utils/rail-order.ts
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

import type { UiIconName } from '~/utils/uiIcons'

export type RailId = 'dm' | 'channels' | 'issues' | 'flow' | 'events' | 'archive' | 'people' | 'calendar' | 'monitoring' | 'reporting'
type RailTab = { readonly id: RailId, readonly icon: UiIconName, readonly labelKey: string, readonly phoneLabelKey?: string }

/** The tabs in the default order, with their icon and catalogue key. */
export const RAIL_TABS: readonly RailTab[] = Object.freeze([
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
  /* owner HUM-10 (t1 e4bfddb1, msg a78e06c8): no Topics tab any more; the
     hub still stores its id (RAIL_RETIRED) */
  Object.freeze({ id: 'flow', icon: 'waves', labelKey: 'sidebar.flow' }),
  /* SPL-983: Archive (owner, topic 8f58f802); the page is CLE-35018's. */
  Object.freeze({ id: 'archive', icon: 'archive', labelKey: 'sidebar.archive' }),
  /* the personal Event log (owner, topic 4335f075); last by default
     since 2026-09-27 (topic 116646c8 left it out of the named order). */
  Object.freeze({ id: 'events', icon: 'history', labelKey: 'sidebar.events' }),
  /* CLE-77794 (owner 2026-09-30, topic 1fc29f99): People lists every member
     with their interests on the right. Reorders and collapses like the rest;
     a stored order from before it is drawn with it appended (parseRailOrder),
     and the hub's IsRailOrder + rdb 0087 admit it. The Agents and Boxes tabs
     beside it (CLE-77794, CLE-77799) went into Monitoring (SPL-2075,
     RAIL_RETIRED). */
  Object.freeze({ id: 'people', icon: 'users', labelKey: 'sidebar.people' }),
  /* spec 089 T007 (owner HUM-10, 2026-10-05): Calendar opens /calendar, a
     single sheet like Issues (the year strip and the main view). Reorders and
     collapses like the rest; a stored order from before it is drawn with
     Calendar appended (parseRailOrder), and the hub's IsRailOrder + rdb 0133
     admit the eleven. */
  Object.freeze({ id: 'calendar', icon: 'calendar', labelKey: 'sidebar.calendar' }),
  /* SPL-1991 (owner HUM-10, t1 dbf2f39b, msg 94283d6b, A on Q1-Q4):
     Monitoring opens /monitoring, its tabs Agents and Boxes. Since SPL-2075
     (t1 dbf2f39b, msg fd5a2bf4) it holds the Agents and Boxes sections too:
     their own tabs are gone (RAIL_RETIRED). Reorders and collapses like the rest; a
     stored order from before it is drawn with Monitoring appended
     (parseRailOrder). The hub admits it since SPL-1990 (rdb 0198). */
  Object.freeze({ id: 'monitoring', icon: 'activity', labelKey: 'sidebar.monitoring' }),
  /* spec 143 1.1 (SPL-2324, SPL-2351): Reporting opens /reporting, beside
     Monitoring. Reorders and collapses like the rest; a stored order from
     before it is drawn with Reporting appended (parseRailOrder). The hub
     admits it since SPL-2587 (rdb 0209). */
  Object.freeze({ id: 'reporting', icon: 'chart-column', labelKey: 'sidebar.reporting' }),
])

/** Every drawn rail id - a set, not the drawn order. */
export const RAIL_IDS: readonly RailId[] = Object.freeze(RAIL_TABS.map((t) => t.id))

/**
 * Owner HUM-10 (t1 e4bfddb1, msg a78e06c8: "Remove the whole topics view"):
 * ids the hub's list (auth.RailTabs, the humans.rail_order CHECK) still
 * holds but the rail no longer draws. A stored order loses them when it is
 * read (parseRailOrder) and gets them back when it is saved (wireRailOrder),
 * so the hub keeps admitting it.
 * SPL-2075 (owner HUM-10, t1 dbf2f39b, msg fd5a2bf4: "remove the Agents and
 * the Boxes icons both from mobile and on desktop"): agents and boxes too;
 * their pages are Monitoring -> Agents / Boxes.
 */
export const RAIL_RETIRED: readonly string[] = Object.freeze(['topics', 'agents', 'boxes'])

/**
 * SPL-1991: ids the rail draws before the hub admits them (auth.RailTabs and
 * the humans.rail_order CHECK lag the WUI by one lane). A saved order leaves
 * them out, so the hub keeps admitting it, and parseRailOrder appends them
 * when it is read back. Empty this list in the commit after the hub lands
 * the id: until then a dragged tab is drawn back before Archive.
 * SPL-1990: the hub admits monitoring (auth.RailTabs, rdb 0198), so none.
 * SPL-2351 (spec 143 1.1): reporting waited here until SPL-2587 (auth.RailTabs,
 * rdb 0209) admitted it, so none.
 */
export const RAIL_HUB_PENDING: readonly string[] = Object.freeze([])

/**
 * A drawn order as the hub stores it: the retired ids added, the ids the hub
 * does not admit yet left out, Archive last.
 */
export function wireRailOrder(order: readonly string[]): string[] {
  const drop = (id: string) => RAIL_RETIRED.includes(id) || RAIL_HUB_PENDING.includes(id)
  return pinRailOrder([...order.filter((id) => !drop(id)), ...RAIL_RETIRED])
}

/**
 * CLE-77916 (owner, t1 topic 5463df22, 2026-10-01: "its place should be
 * ALWAYS at the bottom and it must be the only one which is NOT draggable"):
 * Archive ends every drawn and every saved order, whatever was stored.
 */
export const RAIL_PINNED_LAST = 'archive' as const

/** `order` with the pinned tab moved to the end (a copy; absent stays absent). */
export function pinRailOrder<T extends string>(order: readonly T[]): T[] {
  const out = order.filter((id) => id !== RAIL_PINNED_LAST)
  if (out.length !== order.length) out.push(RAIL_PINNED_LAST as T)
  return out
}

/**
 * The order a never-reordered person sees: RAIL_IDS with Calendar moved up
 * after Flow, with the other talk tabs, and Archive last. Owner HUM-10 (t1
 * 2b61230c, msg a351c864, "A"): in RAIL_IDS order Calendar sat between Boxes
 * and Archive, so the desktop rail drew 3 talk/workspace lines (spec 109
 * T015); grouped, it draws 1. A stored order is drawn as stored.
 */
export const DEFAULT_RAIL_ORDER: readonly RailId[] = Object.freeze(pinRailOrder(moveTo([...RAIL_IDS], 'calendar', RAIL_IDS.indexOf('flow') + 1)))

/** Can this rail tab be dragged / stepped? Archive cannot. */
export function isRailMovable(id: string): boolean {
  return id !== RAIL_PINNED_LAST
}

/**
 * The catalogue key that names a rail tab: its phone name at <= 820 px
 * (useMobileStack().isMobile) when it has one, else its label.
 */
export function railLabelKey(tab: { labelKey: string, phoneLabelKey?: string }, phone: boolean): string {
  return (phone && tab.phoneLabelKey) || tab.labelKey
}

/** A pointer must travel this far before a press becomes a drag: a click never reorders. */
export const DRAG_THRESHOLD_PX: number = 6

/** true when `raw` holds every rail id exactly once (the hub's IsRailOrder). */
export function isRailOrder(raw: unknown): boolean {
  if (!Array.isArray(raw) || raw.length !== RAIL_IDS.length) return false
  const seen = new Set<unknown>(raw)
  return seen.size === RAIL_IDS.length && RAIL_IDS.every((id) => seen.has(id))
}

/**
 * The order to draw: the stored one, tolerant of a tab added since it was
 * stored (SPL-983 Archive: an order saved with six ids keeps them in place
 * and gets the new tab appended). Unknown and repeated ids are dropped; no
 * stored order at all is the default order. Archive is always last
 * (CLE-77916), so an order stored with it elsewhere is drawn repaired.
 */
export function parseRailOrder(raw: unknown): RailId[] {
  if (!Array.isArray(raw)) return [...DEFAULT_RAIL_ORDER]
  const out: RailId[] = []
  for (const id of raw) if (RAIL_IDS.includes(id) && !out.includes(id)) out.push(id)
  if (out.length === 0) return [...DEFAULT_RAIL_ORDER]
  for (const id of RAIL_IDS) if (!out.includes(id)) out.push(id)
  return pinRailOrder(out)
}

export function sameOrder(a: unknown, b: unknown): boolean {
  return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => x === b[i])
}

/** `order` with `id` moved to index `to` (clamped). Unknown id: a copy. */
export function moveTo<T extends string>(order: readonly T[], id: T, to: number): T[] {
  const out = [...order]
  const from = out.indexOf(id)
  if (from < 0) return out
  const at = Math.max(0, Math.min(out.length - 1, Math.trunc(to)))
  out.splice(from, 1)
  out.splice(at, 0, id)
  return out
}

/** One step up (-1) or down (+1); stops at either end. */
export function moveBy<T extends string>(order: readonly T[], id: T, delta: number): T[] {
  const from = order.indexOf(id)
  return from < 0 ? [...order] : moveTo(order, id, from + delta)
}

/**
 * The index a dragged item lands on: the number of OTHER items whose middle
 * lies before the pointer. `mids` are the items' middles in their current
 * order, `from` the dragged item's index there, both on the list's own axis
 * (dragAxis).
 */
export function dropIndex(mids: readonly number[], from: number, pos: number): number {
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
 */
export function dragAxis(rects: readonly { left: number, top: number, width: number, height: number }[]): { axis: 'x' | 'y', sign: 1 | -1 } {
  if (!Array.isArray(rects) || rects.length < 2) return { axis: 'y', sign: 1 }
  const a = rects[0]
  const b = rects[rects.length - 1]
  const dx = (b.left + b.width / 2) - (a.left + a.width / 2)
  const dy = (b.top + b.height / 2) - (a.top + a.height / 2)
  if (Math.abs(dx) > Math.abs(dy)) return { axis: 'x', sign: dx < 0 ? -1 : 1 }
  return { axis: 'y', sign: 1 }
}

/** Past the click-versus-drag threshold? */
export function isDrag(dx: number, dy: number, threshold: number = DRAG_THRESHOLD_PX): boolean {
  return Math.hypot(Number(dx) || 0, Number(dy) || 0) >= threshold
}

/**
 * Save a new order, optimistic like the other Behaviour setting: mirror the
 * claim at once (the rail and the Settings list both redraw), save it, put
 * the old one back on a refusal. `want` null = back to the default (clears).
 */
export async function applyRailOrder(
  want: string[] | null,
  { current, apply, save }: { current: unknown, apply: (o: string[] | null) => void, save: (o: string[] | null) => Promise<{ ok: boolean }> },
): Promise<{ ok: boolean, value: string[] | null, out?: unknown }> {
  /* a legacy (shorter) stored order is kept as it was on a revert */
  const prev: string[] | null = Array.isArray(current) && current.length > 0 ? [...current] : null
  if (want !== null && !isRailOrder(want)) return { ok: false, value: prev }
  /* CLE-77916: whatever the caller built, Archive is saved last; the hub
     still wants the retired ids (RAIL_RETIRED) */
  if (want !== null) want = wireRailOrder(want)
  if (want === null ? prev === null : (prev !== null && sameOrder(want, prev))) return { ok: true, value: prev }
  const next = want === null ? null : [...want]
  apply(next)
  let out: { ok: boolean, error?: unknown }
  try {
    out = await save(next)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (out && out.ok) return { ok: true, value: next }
  apply(prev)
  return { ok: false, value: prev, out }
}
