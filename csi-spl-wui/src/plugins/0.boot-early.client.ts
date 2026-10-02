// work that only needs the entry chunk starts before the other
// plugins run - the i18n plugin awaits the locale catalogue, and everything
// after it (the route middleware's session probe, the frame's chunks) used to
// wait for that download too.
//   1. the session probe (utils/early-session.mjs; the session store takes it).
//      P3-03: the document's head script already sent it; adopt that fetch.
//   2. on a product screen, the default layout and the top bar's language
//      switcher, which the frame imports as soon as it renders
import { useAuthBase, useAuthClient } from '~/composables/useAuthClient'
import { sessionProbeUrl } from '~/utils/auth-client.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { startEarlySession, takeParkedSession } from '~/utils/early-session.mjs'
import { isProductScreen } from '~/utils/signed-out-redirect.mjs'

export default defineNuxtPlugin({
  name: 'spool:boot-early',
  enforce: 'pre',
  setup() {
    if (!import.meta.client) return
    if (useSpoolApi().mock) return
    const auth = useAuthClient()
    const parked = takeParkedSession(window, sessionProbeUrl(useAuthBase()))
    startEarlySession(() => auth.session(parked))
    if (isProductScreen(window.location.pathname + window.location.search)) {
      void import('~/layouts/default.vue').catch(() => {})
      void import('~/components/LanguageSwitcher.vue').catch(() => {})
    }
  },
})
