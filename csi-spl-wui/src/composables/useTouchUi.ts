/*
 * SPL-991: the phone half of the message area (rules: utils/touch-ui.mjs).
 *
 * usePhone()          - true at or below 820 px: useMobileStack().isMobile (SPL-989).
 * useKeyboardInset()  - keeps `--kb-inset` on <html> equal to the on-screen
 *                       keyboard's height (visualViewport), so anything docked
 *                       at the bottom (the composer, a bottom sheet, the send
 *                       error) sits ABOVE the keyboard. It subscribes to the
 *                       tab's one passive, rAF-coalesced viewport source
 *                       (utils/viewport-resize.mjs, perf round 4 W5), so it
 *                       runs at most once per frame and never during mount.
 */
import { keyboardInset } from '~/utils/touch-ui.mjs'
import { useMobileStack } from '~/composables/useMobileStack'
import { onViewportResize } from '~/utils/viewport-resize.mjs'

/** SPL-989's one breakpoint (layouts/default.vue installs the stack) */
export function usePhone() {
  return useMobileStack().isMobile
}

const kbInset = ref(0)
let insetWired = false

export function useKeyboardInset() {
  if (!insetWired && typeof window !== 'undefined') {
    insetWired = true
    const vv = window.visualViewport
    const apply = () => {
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
