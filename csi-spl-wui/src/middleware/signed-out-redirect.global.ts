// One door for every product screen. A settled 'out' goes to /login;
// 'loading' and 'unknown' stay, and the mock tenant is never signed out.
// Prerender runs this on the server, where the cookie cannot be read, so the
// server never bakes a redirect into the HTML.
//
// The first document is the prerendered product shell (default layout, the
// "Loading Spool…" fallback, height 100dvh). Nuxt pins that layout for the
// whole hydration, so a client navigateTo(/login) paints the login page
// under the shell and the shell never leaves — a reload is the only way
// off it, because a reload fetches the prerendered login document. While
// hydrating, load that document with a real navigation. A later sign-out
// stays a client navigation so the in-memory "password changed" flag still
// arrives on the login page.
import { isProductScreen, signedOutLoginHref, signedOutLoginTarget } from '~/utils/signed-out-redirect.mjs'
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
  if (nuxtApp.isHydrating) {
    // Hold the in-app redirect. A subscriber that runs as the probe settles
    // must not also client-navigate under the shell we are about to leave.
    suppress = true
    const href = signedOutLoginHref(localePath('/login'), dest.query.redirect)
    return nuxtApp.runWithContext(() => navigateTo(href, { external: true, replace: true }))
  }
  return nuxtApp.runWithContext(() =>
    navigateTo({ path: localePath('/login'), query: dest.query }, { replace: true }),
  )
})
