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
import { wasSignedIn } from '~/utils/session-recover.mjs'

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
    const dest = signedOutLoginTarget(router.currentRoute.value.fullPath, session.state, api.mock, wasSignedIn())
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
    /* the route resolves only after the probe, so its page chunks
       used to start downloading only then (after ~1-2 s of session probe on
       dev). Fetch them alongside the probe; a signed-out visitor who is
       redirected just leaves them in the cache. */
    void preloadRouteComponents(to.fullPath).catch(() => {})
    /* the frame's own chunks are started even earlier, by
       plugins/0.boot-early, before the i18n plugin awaits its catalogue */
    try {
      await session.probe()
    } finally {
      suppress = false
    }
  }
  const dest = signedOutLoginTarget(to.fullPath, session.state, api.mock, wasSignedIn())
  if (!dest) return
  if (nuxtApp.isHydrating) {
    // Hold the in-app redirect. A subscriber that runs as the probe settles
    // must not also client-navigate under the shell we are about to leave.
    suppress = true
    const href = signedOutLoginHref(localePath('/login'), dest.query.redirect, dest.query.ended === '1')
    return nuxtApp.runWithContext(() => navigateTo(href, { external: true, replace: true }))
  }
  return nuxtApp.runWithContext(() =>
    navigateTo({ path: localePath('/login'), query: dest.query }, { replace: true }),
  )
})
