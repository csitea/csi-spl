import type { Directive } from 'vue'
import { playTapAnim } from '~/composables/useTapAnim'

/**
 * Row 05 of ui-animations-panel-plan.md (SPL-2792, epic SPL-2403): the
 * connection dot (desktop sidebar foot, phone status strip) plays the
 * `ripple` tap animation once when the socket comes back: its health
 * (connectionHealth: ok / warn / down) turns `ok` again after it was `ok`
 * before. The first connect after a page load and a steady connection play
 * nothing; playTapAnim does nothing under reduced motion.
 *
 * `v-reconnect-ripple="health"` on the dot.
 */
const WAS_OK = Symbol('wasOk')
type DotEl = HTMLElement & { [WAS_OK]?: boolean }

export const vReconnectRipple: Directive<DotEl, string> = {
  mounted(el, { value }) {
    el[WAS_OK] = value === 'ok'
  },
  updated(el, { value, oldValue }) {
    if (value !== 'ok' || oldValue === 'ok') return
    if (el[WAS_OK]) playTapAnim(el, 'ripple')
    el[WAS_OK] = true
  },
  getSSRProps() {
    return {}
  },
}
