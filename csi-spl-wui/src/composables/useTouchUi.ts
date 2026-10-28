/*
 * SPL-991: the phone half of the message area (rules: utils/touch-ui.ts).
 *
 * usePhone()          - true at or below 820 px: useMobileStack().isMobile (SPL-989).
 * useKeyboardInset()  - keeps `--kb-inset` on <html> equal to the on-screen
 *                       keyboard's height (visualViewport), so anything docked
 *                       at the bottom (the composer, a bottom sheet, the send
 *                       error) sits ABOVE the keyboard. It subscribes to the
 *                       tab's one passive, rAF-coalesced viewport source
 *                       (utils/viewport-resize.ts, perf round 4 W5), so it
 *                       runs at most once per frame and never during mount.
 */
import { isTextEntry, keyboardInset, layoutKeyboardStep, type LayoutKeyboard } from '~/utils/touch-ui'
import { useMobileStack } from '~/composables/useMobileStack'
import { onViewportResize } from '~/utils/viewport-resize'

/** SPL-989's one breakpoint (layouts/default.vue installs the stack) */
export function usePhone() {
  return useMobileStack().isMobile
}

const kbInset = ref(0)
/* SPL-3785: the Android shape (utils/touch-ui layoutKeyboardStep), kept by the same frame */
const kbLayoutOpen = ref(false)
let layoutKb: LayoutKeyboard | null = null
let insetWired = false

export function useKeyboardInset() {
  if (!insetWired && typeof window !== 'undefined') {
    insetWired = true
    const vv = window.visualViewport
    const apply = () => {
      layoutKb = layoutKeyboardStep(layoutKb, window.innerHeight, window.innerWidth, isTextEntry(document.activeElement as HTMLInputElement | null))
      kbLayoutOpen.value = layoutKb.open
      const px = keyboardInset(window.innerHeight, vv)
      if (px === kbInset.value) return
      kbInset.value = px
      document.documentElement.style.setProperty('--kb-inset', `${px}px`)
    }
    document.documentElement.style.setProperty('--kb-inset', '0px')
    /* the first innerHeight read waits for the first frame too */
    onViewportResize(apply, { visual: true, initial: true })
  }
  return kbInset
}

/**
 * true while the on-screen keyboard is up, on iOS (--kb-inset > 0) AND on
 * Android, where interactive-widget=resizes-content shrinks the page itself
 * and --kb-inset stays 0 (the page already ends at the keyboard, so nothing
 * docked needs lifting: --kb-inset is left as it is).
 */
export function useKeyboardOpen() {
  const inset = useKeyboardInset()
  return computed(() => inset.value > 0 || kbLayoutOpen.value)
}
