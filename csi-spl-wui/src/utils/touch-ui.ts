/**
 * SPL-991 (epic SPL-988, the mobile revamp): the message area on a phone.
 *
 * Three rules, each unit-tested without a browser:
 *   - at or below 820 px (SPL-989's MOBILE_STACK_QUERY, read through
 *     useMobileStack().isMobile) the menus, the emoji picker and the @ list
 *     open as bottom sheets, and the composer docks at the bottom. The
 *     desktop layout above it is not touched.
 *   - keyboardInset: how much of the layout viewport the on-screen keyboard
 *     covers, from the visualViewport API (iOS Safari and Android Chrome both
 *     shrink the VISUAL viewport and leave `position: fixed; bottom: 0` under
 *     the keyboard).
 *   - createLongPress: a touch held still for LONG_PRESS_MS opens the message
 *     menu (a phone has no hover and no right-click).
 */

export const LONG_PRESS_MS = 500
/** a finger that moved more than this is scrolling, not pressing */
export const LONG_PRESS_SLOP_PX = 10
/** below this the "keyboard" is the browser's own toolbar sliding, not a keyboard */
const KEYBOARD_MIN_PX = 60

/**
 * The keyboard's height over the layout viewport, px (0 = no keyboard).
 * `innerHeight` is window.innerHeight (the layout viewport), `vv`
 * window.visualViewport.
 */
export function keyboardInset(innerHeight: number, vv: { height?: number, offsetTop?: number, scale?: number } | null | undefined): number {
  const ih = Number(innerHeight)
  if (!vv || !Number.isFinite(ih) || ih <= 0) return 0
  const h = Number(vv.height)
  const top = Number(vv.offsetTop) || 0
  if (!Number.isFinite(h) || h <= 0) return 0
  const inset = Math.round(ih - h - top)
  /* SPL-2829 (owner, t1 d8ede89a): a page zoomed in (a forced zoom, the
     viewport meta refuses a pinch) shows only part of the layout viewport,
     and a fixed `bottom` is the LAYOUT bottom: at x1.07 the 50-odd px under
     the screen read as "no keyboard" and the dock sat under the nav bar. So
     zoomed, every px under the visual viewport counts */
  if (Number(vv.scale) > 1.001) return Math.max(0, inset)
  return inset >= KEYBOARD_MIN_PX ? inset : 0
}

/** a field the on-screen keyboard types into (not a button, a checkbox, ...) */
export function isTextEntry(el: { tagName?: string, type?: string, isContentEditable?: boolean, readOnly?: boolean } | null | undefined): boolean {
  if (!el) return false
  if (el.isContentEditable) return true
  const tag = String(el.tagName || '').toUpperCase()
  if (tag === 'TEXTAREA') return !el.readOnly
  if (tag !== 'INPUT') return false
  return !el.readOnly && /^(|text|search|email|url|tel|password|number)$/.test(String(el.type || '').toLowerCase())
}

export type LayoutKeyboard = { base: number, width: number, open: boolean }

/**
 * SPL-3785 (owner, t1 c3e53990 msg d4459f4c: on his Android phone the strip
 * did not fold for the keyboard): the viewport meta asks for
 * interactive-widget=resizes-content, so Android Chrome shrinks the LAYOUT
 * viewport for the keyboard - innerHeight and visualViewport.height drop
 * together and keyboardInset (the iOS shape) reads 0. There the keyboard is
 * the drop of innerHeight below its height while no field had the focus, at
 * the same width (a turned phone is a new base, not a keyboard). One step per
 * viewport frame; `prev` is the last step's state.
 */
export function layoutKeyboardStep(prev: LayoutKeyboard | null, innerHeight: number, innerWidth: number, editing: boolean): LayoutKeyboard {
  const h = Number(innerHeight)
  const w = Number(innerWidth)
  if (!Number.isFinite(h) || h <= 0) return { base: prev?.base ?? 0, width: prev?.width ?? 0, open: false }
  if (!prev || prev.width !== w || !editing) return { base: h, width: w, open: false }
  const base = Math.max(prev.base, h)
  return { base, width: w, open: base - h >= KEYBOARD_MIN_PX }
}

/** Only a finger (or a pen) long-presses. A mouse has its right-click. */
export function isTouchPointer(pointerType: string | undefined): boolean {
  return pointerType === 'touch' || pointerType === 'pen'
}

type LongPressOpts = {
  onPress: (x: number, y: number) => void
  delay?: number
  slop?: number
  setTimer?: (fn: () => void, ms: number) => unknown
  clearTimer?: (id: unknown) => void
}

/**
 * The long-press state machine. The host feeds it pointer events; `onPress`
 * runs once when a touch stayed within LONG_PRESS_SLOP_PX for LONG_PRESS_MS.
 * `takeClick()` is true exactly once after a press fired, so the click the
 * browser sends when that finger lifts does not also open the topic.
 */
export function createLongPress(opts: LongPressOpts) {
  const delay = opts.delay ?? LONG_PRESS_MS
  const slop = opts.slop ?? LONG_PRESS_SLOP_PX
  const setTimer = opts.setTimer ?? ((fn: () => void, ms: number) => setTimeout(fn, ms))
  const clearTimer = opts.clearTimer ?? ((id: unknown) => clearTimeout(id as ReturnType<typeof setTimeout>))
  let timer: unknown = null
  let start = { x: 0, y: 0 }
  let fired = false

  function stop() {
    if (timer !== null) clearTimer(timer)
    timer = null
  }

  return {
    down(ev: { pointerType?: string, clientX: number, clientY: number, isPrimary?: boolean }): void {
      stop()
      fired = false
      if (!isTouchPointer(ev.pointerType) || ev.isPrimary === false) return
      start = { x: ev.clientX, y: ev.clientY }
      timer = setTimer(() => {
        timer = null
        fired = true
        opts.onPress(start.x, start.y)
      }, delay)
    },
    move(ev: { clientX: number, clientY: number }): void {
      if (timer === null) return
      if (Math.hypot(ev.clientX - start.x, ev.clientY - start.y) > slop) stop()
    },
    up(): void { stop() },
    cancel(): void { stop() },
    /** true once after a press fired: the host swallows that click */
    takeClick(): boolean {
      const was = fired
      fired = false
      return was
    },
    get pending(): boolean { return timer !== null },
  }
}

/**
 * The window event that puts the caret in the docked composer (the sheet's
 * Reply). MessageComposer listens; MessageCard dispatches.
 */
export const COMPOSER_FOCUS_EVENT = 'spool:composer-focus'
