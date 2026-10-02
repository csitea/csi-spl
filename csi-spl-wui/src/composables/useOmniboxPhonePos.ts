// Owner, t1 (2026-10-02): the phone omnibox's place - bottom (the default),
// top or the right corner - chosen with its grip and kept per browser (the
// Flow's Mine / All is kept the same way). One ref for the whole tab, so the
// composer and the layout read the same value. Rules: utils/omnibox-dock.mjs.
import { PHONE_POSITION_KEY, parsePhonePosition } from '~/utils/omnibox-dock.mjs'
import { storageGet, storageSet } from '~/utils/prefs.mjs'

type PhonePosition = 'bottom' | 'top' | 'right'

let shared: Ref<PhonePosition> | null = null

export function useOmniboxPhonePos() {
  if (!shared) {
    shared = ref<PhonePosition>(parsePhonePosition(import.meta.client ? storageGet(PHONE_POSITION_KEY) : ''))
  }
  const pos = shared
  function set(next: PhonePosition) {
    pos.value = parsePhonePosition(next)
    storageSet(PHONE_POSITION_KEY, pos.value)
  }
  return { pos: readonly(pos), set }
}
