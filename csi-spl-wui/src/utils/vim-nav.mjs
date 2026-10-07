// csi-spl-wui/src/utils/vim-nav.mjs
//
// Spec 103 T002 (t1 7d9e1681): the pure key matcher behind vim-style
// navigation across the four panels (0 = icon rail, 1 = left list,
// 2 = centre list, 3 = topic pane). One keydown in, one action out; no DOM,
// no store, no timers, so node can test every rule. The listener that acts on
// the action is composables/useVimNavigation.ts (T005).
//
//   h / l           panel left / right
//   j / k           next / previous item      (ArrowDown / ArrowUp mirror)
//   g g             first item, the 2nd g within 500 ms   (Home mirrors)
//   Shift + G       last item                 (End mirrors)
//   Enter           open the selected item
//   Esc             back one panel
//
// The gates are msg-shortcuts.mjs's own: nothing while the caret is in a text
// field or a menu / dialog is open (inTypingOrOverlay - an overlay keeps its
// own Esc), nothing with Ctrl / Cmd / Alt held (browser and OS chords),
// nothing on a phone width (usePhone) or with the Keyboard shortcuts setting
// off (shortcutsOn; vimNavOn below). Shift + a lower-case key stays the
// message actions' (Shift + H, Shift + K, Shift + L ...), so h j k l match
// only without Shift. ArrowLeft / ArrowRight are not mapped: they step table
// columns and resize dividers today (spec 103 section 5).
import { inTypingOrOverlay, shortcutsOn } from './msg-shortcuts.mjs'

/** How long the first `g` of `g g` waits for the second, in ms. */
export const VIM_GG_MS = 500

/** The sequence state before any key: no `g` pending. */
export const VIM_SEQ_IDLE = Object.freeze({ g: null })

/** Every action vimNavMatch can return. */
export const VIM_ACTIONS = Object.freeze(['left', 'right', 'down', 'up', 'first', 'last', 'open', 'back'])

const KEYS = Object.freeze({
  h: 'left',
  l: 'right',
  j: 'down',
  k: 'up',
  ArrowDown: 'down',
  ArrowUp: 'up',
  Home: 'first',
  End: 'last',
  Enter: 'open',
  Escape: 'back',
  Esc: 'back',
})

/** Are vim keys on at all: the `keyboard_shortcuts` claim (shortcutsOn) and not a phone width (usePhone). */
export function vimNavOn({ claim, phone = false } = {}) {
  return shortcutsOn(claim) && !phone
}

/** When the key happened: ctx.now, else the event's own timeStamp, else the clock. */
function whenOf(ev, now) {
  if (Number.isFinite(now)) return now
  if (Number.isFinite(ev.timeStamp)) return ev.timeStamp
  return Date.now()
}

/** Is a `g` from `seq` still waiting at time `t`? */
function gPending(seq, t) {
  const at = seq && Number.isFinite(seq.g) ? seq.g : null
  return at !== null && t >= at && t - at <= VIM_GG_MS
}

/**
 * What one keydown means for vim navigation, and the sequence state after it.
 * Pure: `seqState` is never changed; keep the returned `seq` for the next key.
 * Any key other than the 2nd `g` drops a pending `g`.
 *
 * @param {{ key?: string, shiftKey?: boolean, ctrlKey?: boolean, metaKey?: boolean, altKey?: boolean,
 *           isComposing?: boolean, repeat?: boolean, defaultPrevented?: boolean, timeStamp?: number,
 *           target?: unknown } | null | undefined} ev
 * @param {{ g: number | null } | null | undefined} [seqState]
 * @param {{ enabled?: boolean, phone?: boolean, overlayOpen?: boolean, now?: number }} [ctx]
 * @returns {{ action: 'left' | 'right' | 'down' | 'up' | 'first' | 'last' | 'open' | 'back' | null,
 *             seq: { g: number | null } }}
 */
export function vimNavMatch(ev, seqState, { enabled = true, phone = false, overlayOpen = false, now } = {}) {
  const none = { action: null, seq: VIM_SEQ_IDLE }
  if (!ev || !enabled || phone || overlayOpen) return none
  if (ev.isComposing || ev.defaultPrevented) return none
  if (ev.ctrlKey || ev.metaKey || ev.altKey) return none
  if (inTypingOrOverlay(ev.target)) return none
  const key = String(ev.key || '')
  if (key === 'g' && !ev.shiftKey) {
    if (ev.repeat) return none
    const t = whenOf(ev, now)
    return gPending(seqState, t) ? { action: 'first', seq: VIM_SEQ_IDLE } : { action: null, seq: Object.freeze({ g: t }) }
  }
  if (key === 'G') return ev.shiftKey && !ev.repeat ? { action: 'last', seq: VIM_SEQ_IDLE } : none
  const action = Object.hasOwn(KEYS, key) ? KEYS[key] : null
  if (!action) return none
  /* Shift + a letter is a message action; Enter and Esc fire once per press, without Shift */
  const once = action === 'open' || action === 'back'
  if (ev.shiftKey && (once || /^[a-z]$/.test(key))) return none
  if (ev.repeat && once) return none
  return { action, seq: VIM_SEQ_IDLE }
}
