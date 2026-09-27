// Topic c6994436 lane B: is the one Omnibox in the bottom dock (under the
// middle pane) right now? Read by TopBar (the Teleport) and the layout (the
// dock itself), so both agree on every render. Rules: utils/omnibox-dock.mjs.
import { useViewPrefs } from '~/composables/useViewPrefs'
import { usePhone } from '~/composables/useTouchUi'
import { omniboxAtBottom } from '~/utils/omnibox-dock.mjs'

export function useOmniboxDock() {
  const prefs = useViewPrefs()
  const phone = usePhone()
  return computed(() => omniboxAtBottom({ position: prefs.composerPosition.value, phone: phone.value }))
}
