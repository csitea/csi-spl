// 081 T004 (FR-001): the WUI's always-on keys, desktop only. One window
// listener, installed once by layouts/default.vue (useMsgShortcuts' listener
// lives only while message cards are on screen, so it cannot carry these).
//
// Ctrl + K (Cmd + K on macOS) opens the command palette from anywhere,
// also from a text field (spec Q1: it inserts nothing, and the field keeps
// its text). It is the page's key, not the browser's (spec Q2:
// preventDefault, as GitHub and Slack do). It is off on a phone and while
// another dialog, menu or sheet is open; pressed with the palette open, it
// closes it. The capture phase, so a field that stops its own keys cannot
// hide the chord. Settings is a page that wears a dialog (UiDialog `routed`,
// the URL is /settings): the palette opens over it as over any page (owner,
// "nothing happens with Ctrl + K": over Settings the chord went to Chrome).
//
// 081 T006 (FR-006): F6 / Shift + F6 move the focus left pane -> middle ->
// right (when open) -> Omnibox, and back. The target is the pane's selected
// row, else its first row, else its heading (utils/pane-focus.mjs). Not a
// letter, so the keyboard_shortcuts setting does not turn it off (FR-012).
import { usePhone } from '~/composables/useTouchUi'
import { usePaneFocus } from '~/stores/pane-focus'
import { LEFT, MIDDLE, PANE_ROOTS, RIGHT, nextPane, paneAt, paneKey, paneTarget, type F6Pane } from '~/utils/pane-focus.mjs'

/** The command palette (CommandPalette.vue, mounted by the layout while true). */
const paletteOpen = ref(false)
let installed = 0
let listener: ((ev: KeyboardEvent) => void) | null = null

/** A menu, a dialog or a sheet is open: the palette does not open over it. */
const OVERLAY_OPEN = '.point-menu, [role="dialog"][aria-modal="true"], dialog[open]'
/** A routed dialog is a page (Settings): Ctrl + K is not off over it. */
const ROUTED_DIALOG = '.ui-dialog.routed'

/** An overlay the palette does not open over: any but a routed dialog. */
function overlayBlocksPalette(): boolean {
  return [...document.querySelectorAll(OVERLAY_OPEN)].some((el) => !el.matches(ROUTED_DIALOG))
}

/** Ctrl + K, or Cmd + K: no Alt, no Shift; the K by its key or its place (non-Latin layouts). */
function isPaletteChord(ev: KeyboardEvent): boolean {
  if (!(ev.ctrlKey || ev.metaKey) || ev.altKey || ev.shiftKey) return false
  return ev.key === 'k' || ev.key === 'K' || ev.code === 'KeyK'
}

export function usePaletteOpen() {
  return paletteOpen
}

/** On screen: a collapsed panel's hidden rows and a closed list's rows are not. */
function shown(el: Element): boolean {
  return el.getClientRects().length > 0
}

function paneRoot(pane: F6Pane): HTMLElement | null {
  return [...document.querySelectorAll<HTMLElement>(PANE_ROOTS[pane])].find(shown) || null
}

/**
 * Focus a pane (081 T006): its selected row, else its first row (unless
 * firstRow is false), else its heading, else the pane itself. A heading or a
 * pane gets tabindex -1 so it can hold the focus. False when the pane is not
 * on screen.
 */
export function focusPane(pane: F6Pane, { firstRow = true } = {}): boolean {
  const root = paneRoot(pane)
  if (!root) return false
  const el = paneTarget(root, pane, { firstRow, visible: shown }) as HTMLElement | null
  if (!el) return false
  if (!el.matches('a[href], button, input, textarea, select, [tabindex]')) el.setAttribute('tabindex', '-1')
  el.focus({ preventScroll: true })
  if (pane === LEFT || pane === MIDDLE || pane === RIGHT) usePaneFocus().set(pane)
  return root.contains(document.activeElement)
}

/** F6 / Shift + F6: the next pane on screen; true when the key was ours. */
function onPaneKey(ev: KeyboardEvent): boolean {
  const dir = paneKey(ev)
  if (!dir) return false
  const to = nextPane(paneAt(document.activeElement), { back: dir === 'prev', has: (p) => Boolean(paneRoot(p)) })
  if (!to) return false
  ev.preventDefault()
  focusPane(to as F6Pane)
  return true
}

export function useGlobalKeys() {
  const phone = usePhone()
  onMounted(() => {
    installed += 1
    if (listener) return
    listener = (ev: KeyboardEvent) => {
      if (ev.defaultPrevented || ev.isComposing) return
      if (ev.key === 'F6') {
        if (!phone.value && !paletteOpen.value && !document.querySelector(OVERLAY_OPEN)) onPaneKey(ev)
        return
      }
      if (!isPaletteChord(ev)) return
      if (phone.value) return
      if (paletteOpen.value) {
        ev.preventDefault()
        paletteOpen.value = false
        return
      }
      if (overlayBlocksPalette()) return
      ev.preventDefault()
      if (!ev.repeat) paletteOpen.value = true
    }
    window.addEventListener('keydown', listener, true)
  })
  onBeforeUnmount(() => {
    installed -= 1
    if (installed > 0 || !listener) return
    window.removeEventListener('keydown', listener, true)
    listener = null
    paletteOpen.value = false
  })
  return { paletteOpen }
}
