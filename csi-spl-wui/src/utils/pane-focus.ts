/**
 * Which pane the reader selected last: the middle list or the right topic
 * pane (owner rule 2026-09-25).
 *
 * SPL-996, owner answer B (topic e0b12a2c, 2026-09-27) retired that rule for
 * the Omnibox: an open topic takes every line until it is closed, whatever
 * was clicked last (paneTakesLine ignores lastPane). The store still records
 * the reader's pane - opening a topic, a click or a keyboard move into a pane
 * - but nothing routes a send on it any more.
 */

export const MIDDLE = 'middle' as const
export const RIGHT = 'right' as const

type Closest = { closest?: (s: string) => unknown } | null

/** The pane an event target sits in, or '' for anywhere that does not choose. */
export function paneOfTarget(el: unknown): '' | 'middle' | 'right' {
  const e = el as Closest
  if (!e || typeof e.closest !== 'function') return ''
  if (e.closest('.pane-divider')) return ''
  /* topic c6994436: the bottom Omnibox dock sits INSIDE .spool-main, but
     typing there is not choosing the middle pane (the top bar never was) */
  if (e.closest('.omnibox-dock')) return ''
  if (e.closest('aside.live-pane')) return RIGHT
  if (e.closest('.spool-main')) return MIDDLE
  return ''
}

/** A focusin this soon after a navigation key counts as the reader's own move. */
export const KEY_NAV_MS: number = 1000

/**
 * SPL-996: only the READER chooses a pane. Measured on prd t1 (2026-09-27,
 * #spool-hub-mobile, n=4): four follow-ups typed while a topic was open each
 * became a new topic, because something the reader did not mean as "go back
 * to the middle" had set it:
 *   - a pointerdown on a pane's SCROLLBAR (dragging the middle list to read)
 *   - a focusin the app made itself: a card focused on mount for a #hash, a
 *     row focused after an edit, a restore after `/`. Those are not a choice.
 * So a pointerdown counts unless it lands on the target's scrollbar, and a
 * focusin counts only right after a navigation key (Tab, arrows ...) pressed
 * outside a text field - typing and sending in the composer is not one.
 */
export function eventChoosesPane({ type = '', onScrollbar = false, keyNavAt = 0, now = 0 }: { type?: string, onScrollbar?: boolean, keyNavAt?: number, now?: number } = {}): boolean {
  if (type === 'pointerdown') return !onScrollbar
  if (type === 'focusin') return keyNavAt > 0 && now - keyNavAt >= 0 && now - keyNavAt <= KEY_NAV_MS
  return false
}

/**
 * Is a keydown a navigation key pressed outside a text field? Typing (and the
 * Enter that sends) in the composer is not; Tab / arrows / Home / End / F6 on
 * a row or a button are.
 */
export function isKeyNav(ev: { key?: string, target?: unknown }): boolean {
  const key = String((ev && ev.key) || '')
  if (!/^(Tab|Arrow(Up|Down|Left|Right)|Home|End|PageUp|PageDown|F6)$/.test(key)) return false
  const t = ((ev && ev.target) || null) as Closest
  if (key !== 'Tab' && key !== 'F6' && t && typeof t.closest === 'function' && t.closest('textarea, input, [contenteditable="true"]')) return false
  return true
}

/**
 * A pointerdown on the element's own scrollbar: past its client box, while it
 * scrolls. offsetX/offsetY are relative to the padding edge, clientWidth /
 * clientHeight exclude the bar.
 */
export function onScrollbar(ev: { target?: unknown, offsetX?: number, offsetY?: number }): boolean {
  const el = ((ev && ev.target) || null) as { clientWidth?: number, clientHeight?: number, scrollWidth?: number, scrollHeight?: number } | null
  if (!el || typeof el.clientWidth !== 'number' || !el.clientWidth) return false
  const x = Number(ev.offsetX), y = Number(ev.offsetY)
  const vbar = (el.scrollHeight || 0) > (el.clientHeight || 0) && x >= el.clientWidth
  const hbar = (el.scrollWidth || 0) > el.clientWidth && y >= (el.clientHeight || 0)
  return Boolean(vbar || hbar)
}

/**
 * Does the open right pane take the next Omnibox line? Whenever it is open
 * (SPL-996 B). `lastPane` is accepted for the old callers and ignored.
 */
export function paneTakesLine({ paneOpen = false }: { paneOpen?: boolean, lastPane?: string } = {}): boolean {
  /* SPL-996, owner answer B (2026-09-27): the open pane takes every line
     until it is closed; the pane clicked last no longer decides */
  return Boolean(paneOpen)
}

/*
 * 081 T006 (FR-006, FR-007, FR-009): the F6 cycle, the skip link and the
 * focus after a route change. paneOfTarget above stays as it is (the left
 * pane and the Omnibox choose no level); paneAt below names every F6 stop.
 */
export const LEFT = 'left' as const
export const OMNIBOX = 'omnibox' as const

export type F6Pane = 'left' | 'middle' | 'right' | 'omnibox'

/** The F6 order, left to right; Shift + F6 walks it back. */
export const F6_ORDER: readonly F6Pane[] = Object.freeze([LEFT, MIDDLE, RIGHT, OMNIBOX])

/** Each pane's root in the shell. The docked Omnibox sits inside .spool-main, so paneAt tests it first. */
export const PANE_ROOTS: Readonly<Record<F6Pane, string>> = Object.freeze({
  [OMNIBOX]: '.top-bar__omnibox',
  [RIGHT]: 'aside.live-pane, aside.operator-pane',
  [MIDDLE]: '.spool-main',
  [LEFT]: 'nav.sidebar',
})

/**
 * Where the focus lands in a pane: its selected row, else its first row
 * (F6 only, spec 3.2), else its heading (spec 3.3).
 */
const PANE_TARGETS: Readonly<Record<F6Pane, { selected: string, first: string, heading: string }>> = Object.freeze({
  [LEFT]: { selected: '[aria-current="true"], [aria-current="page"], .sidebar-tab[aria-selected="true"]', first: 'a[href]:not([tabindex="-1"]), button:not([tabindex="-1"]):not([disabled])', heading: 'h1, h2, h3' },
  [MIDDLE]: { selected: '[data-selected="true"], [aria-current="true"]', first: '.msg[tabindex="0"], [role="row"], [role="option"]', heading: 'h1, h2' },
  [RIGHT]: { selected: '[data-selected="true"], [aria-current="true"]', first: '.msg[tabindex="0"]', heading: 'h1, h2, h3' },
  [OMNIBOX]: { selected: 'textarea', first: 'textarea, input', heading: '' },
})

/**
 * The F6 pane an element sits in, or '' for none (a dialog, the top bar
 * outside the Omnibox, the body).
 */
export function paneAt(el: unknown): '' | F6Pane {
  const e = el as Closest
  if (!e || typeof e.closest !== 'function') return ''
  for (const pane of [OMNIBOX, RIGHT, MIDDLE, LEFT] as const) {
    if (e.closest(PANE_ROOTS[pane])) return pane
  }
  return ''
}

/**
 * F6 forwards, Shift + F6 back; with Ctrl, Alt or Meta it is the browser's.
 */
export function paneKey(ev: { key?: string, shiftKey?: boolean, ctrlKey?: boolean, altKey?: boolean, metaKey?: boolean } | null): '' | 'next' | 'prev' {
  if (!ev || ev.key !== 'F6' || ev.ctrlKey || ev.altKey || ev.metaKey) return ''
  return ev.shiftKey ? 'prev' : 'next'
}

/**
 * The next pane in the F6 cycle from `from`, skipping the panes not there
 * (the right pane while no topic is open). From nowhere F6 starts at the
 * left pane and Shift + F6 at the Omnibox; '' when there is nowhere to go.
 */
export function nextPane(from: string, { back = false, has = () => true }: { back?: boolean, has?: (pane: F6Pane) => boolean } = {}): '' | F6Pane {
  const there = F6_ORDER.filter((p) => has(p))
  if (!there.length) return ''
  const i = F6_ORDER.indexOf(from as F6Pane)
  if (i < 0) return back ? there[there.length - 1] : there[0]
  const n = F6_ORDER.length
  for (let k = 1; k < n; k++) {
    const p = F6_ORDER[(i + (back ? -k : k) + n * k) % n]
    if (has(p)) return p
  }
  return ''
}

/**
 * The element to focus in a pane root: the selected row, else the first
 * row (unless `firstRow` is false), else the heading, else the root.
 * `visible` drops what a collapsed panel or a closed list hides.
 */
export function paneTarget(root: ParentNode | null, pane: string, { firstRow = true, visible = () => true }: { firstRow?: boolean, visible?: (el: Element) => boolean } = {}): Element | null {
  if (!root || typeof root.querySelectorAll !== 'function') return null
  const q = (sel: string): ArrayLike<Element> => root.querySelectorAll(sel)
  const t = (PANE_TARGETS as Readonly<Record<string, { selected: string, first: string, heading: string }>>)[pane]
  if (!t) return root as Element
  const pick = (sel: string) => (sel ? Array.from(q(sel)).find((el) => visible(el)) : undefined)
  return pick(t.selected) || (firstRow ? pick(t.first) : undefined) || pick(t.heading) || (root as Element)
}

/**
 * Does a finished navigation move the focus into the middle pane (FR-009)?
 * Not on the first load (the skip link is the first stop), not on Back or
 * Forward, not when only the query changed (a topic opening on the right),
 * not on a phone, and never out of a text field or an open dialog.
 * HUM-10 (t1 7d9e1681): nor out of the Channels list (`channelList`, the focus
 * on a channel row): a click there, or its arrow keys, opens the channel and
 * the next ArrowDown / ArrowUp walks on to the next channel.
 */
export function routeTakesFocus({ initial = false, popstate = false, failed = false, mobile = false, fromPath = '', toPath = '', typing = false, dialog = false, channelList = false }: { initial?: boolean, popstate?: boolean, failed?: boolean, mobile?: boolean, fromPath?: string, toPath?: string, typing?: boolean, dialog?: boolean, channelList?: boolean } = {}): boolean {
  if (initial || popstate || failed || mobile || typing || dialog || channelList) return false
  return fromPath !== toPath
}
