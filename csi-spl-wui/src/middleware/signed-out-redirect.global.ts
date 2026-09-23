// One door for every product screen. A settled 'out' replaces the route with
// /login before the shell paints; 'loading' and 'unknown' stay, and the mock
// tenant is never signed out. Prerender runs this on the server, where the
// cookie cannot be read, so the server never bakes a redirect into the HTML.
import { isProductScreen, signedOutLoginTarget } from '~/utils/signed-out-redirect.mjs'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'

let armed = false
let suppress = false

function armSignedOutRedirect(): void {
  if (armed) return
  armed = true
  const session = useSessionStore()
  const api = useSpoolApi()
  const router = useRouter()
  const localePath = useLocalePath()
  const nuxtApp = useNuxtApp()
  // Detached from the navigation that installed it: a later sign-out (password
  // change) has no new route, so the middleware does not run again on its own.
  session.$subscribe(() => {
    if (suppress || api.mock) return
    const dest = signedOutLoginTarget(router.currentRoute.value.fullPath, session.state, api.mock)
    if (!dest) return
    void nuxtApp.runWithContext(() =>
      navigateTo({ path: localePath('/login'), query: dest.query }, { replace: true }),
    )
  })
}

export default defineNuxtRouteMiddleware(async (to) => {
  if (import.meta.server) return
  const api = useSpoolApi()
  if (api.mock) return
  const localePath = useLocalePath()
  const nuxtApp = useNuxtApp()
  armSignedOutRedirect()
  const session = useSessionStore()
  if (session.state === 'loading' && isProductScreen(to.fullPath)) {
    suppress = true
    try {
      await session.probe()
    } finally {
      suppress = false
    }
  }
  const dest = signedOutLoginTarget(to.fullPath, session.state, api.mock)
  if (!dest) return
  return nuxtApp.runWithContext(() =>
    navigateTo({ path: localePath('/login'), query: dest.query }, { replace: true }),
  )
})
