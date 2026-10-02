// Owner, t1 (2026-10-02): the phone omnibox's place - bottom (the default),
// top or the right corner - chosen with its grip and kept per browser (the
// Flow's Mine / All is kept the same way). One ref for the whole tab, so the
// composer and the layout read the same value. Rules: utils/omnibox-dock.mjs.
// Owner, t1 21:53Z: "it should be possible to resize it" - a size per place
// is kept next to it (spool.omnibox-phone-size).
import { PHONE_POSITION_KEY, PHONE_SIZE_KEY, parsePhonePosition, parsePhoneSize } from '~/utils/omnibox-dock.mjs'
import { storageGet, storageSet } from '~/utils/prefs.mjs'

type PhonePosition = 'bottom' | 'top' | 'right'
type PhoneSize = { bottom?: number, top?: number, right?: number }

let shared: Ref<PhonePosition> | null = null
let sharedSize: Ref<PhoneSize> | null = null

export function useOmniboxPhonePos() {
  if (!shared) {
    shared = ref<PhonePosition>(parsePhonePosition(import.meta.client ? storageGet(PHONE_POSITION_KEY) : ''))
  }
  if (!sharedSize) {
    sharedSize = ref<PhoneSize>(parsePhoneSize(import.meta.client ? storageGet(PHONE_SIZE_KEY) : ''))
  }
  const pos = shared
  const size = sharedSize
  function set(next: PhonePosition) {
    pos.value = parsePhonePosition(next)
    storageSet(PHONE_POSITION_KEY, pos.value)
  }
  /** The current place's size (null = its default); keep false while a finger still drags. */
  function setSize(share: number | null, keep = true) {
    const next: PhoneSize = { ...size.value }
    if (share == null) delete next[pos.value]
    else next[pos.value] = share
    size.value = parsePhoneSize(JSON.stringify(next))
    if (keep) storageSet(PHONE_SIZE_KEY, JSON.stringify(size.value))
  }
  return { pos: readonly(pos), size: readonly(size), set, setSize }
}
