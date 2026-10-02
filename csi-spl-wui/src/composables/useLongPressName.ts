/**
 * Long-press to read a thing's name on touch (no hover there).
 *
 * Lifted out of EmojiPicker.vue: the press names the glyph after `holdMs`;
 * the ensuing click still picks it, so reading a name and picking it are the
 * same gesture held a little longer. The hold timer is cleared on unmount;
 * the short linger after the finger lifts is left to run, as before.
 */
import { onBeforeUnmount, ref } from 'vue'

export function useLongPressName<T>(nameOf: (item: T) => string, { holdMs = 350, lingerMs = 900 } = {}) {
  /** the name shown while a press is held, or '' */
  const held = ref('')
  let holdTimer: ReturnType<typeof setTimeout> | null = null
  function clearHold() {
    if (holdTimer) { clearTimeout(holdTimer); holdTimer = null }
  }
  function onHoldStart(item: T) {
    clearHold()
    holdTimer = setTimeout(() => { held.value = nameOf(item) }, holdMs)
  }
  function onHoldEnd() {
    clearHold()
    /* keep the name up a breath after the finger lifts, then clear it */
    if (held.value) setTimeout(() => { held.value = '' }, lingerMs)
  }
  function onHoldCancel() {
    clearHold()
    held.value = ''
  }

  onBeforeUnmount(clearHold)
  return { held, onHoldStart, onHoldEnd, onHoldCancel }
}
