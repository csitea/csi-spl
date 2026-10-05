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
// hide the chord. T006 adds F6 here.
import { usePhone } from '~/composables/useTouchUi'

/** The command palette (CommandPalette.vue, mounted by the layout while true). */
const paletteOpen = ref(false)
let installed = 0
let listener: ((ev: KeyboardEvent) => void) | null = null

/** A menu, a dialog or a sheet is open: the palette does not open over it. */
const OVERLAY_OPEN = '.point-menu, [role="dialog"][aria-modal="true"], dialog[open]'

/** Ctrl + K, or Cmd + K: no Alt, no Shift; the K by its key or its place (non-Latin layouts). */
function isPaletteChord(ev: KeyboardEvent): boolean {
  if (!(ev.ctrlKey || ev.metaKey) || ev.altKey || ev.shiftKey) return false
  return ev.key === 'k' || ev.key === 'K' || ev.code === 'KeyK'
}

export function usePaletteOpen() {
  return paletteOpen
}

export function useGlobalKeys() {
  const phone = usePhone()
  onMounted(() => {
    installed += 1
    if (listener) return
    listener = (ev: KeyboardEvent) => {
      if (ev.defaultPrevented || ev.isComposing || !isPaletteChord(ev)) return
      if (phone.value) return
      if (paletteOpen.value) {
        ev.preventDefault()
        paletteOpen.value = false
        return
      }
      if (document.querySelector(OVERLAY_OPEN)) return
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
