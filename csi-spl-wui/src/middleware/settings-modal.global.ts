// CLE-77853 (bug 49568e8b): Settings is a modal over the current view, keyed
// by ?settings=<section> (utils/settings-nav.mjs). An old address - the user
// menu's /settings, a /settings/notifications link, a cold /fi/settings/keys
// deep link - becomes that modal over the view the person came from, or over
// the lobby when there is none. A redirect inside a push stays a push, so
// Back from the modal returns to that view. A cold deep link lands on the
// lobby first and opens the modal as a second entry, so Back closes it there
// too instead of leaving the app. The settings routes boot from the 200.html
// SPA fallback (never prerendered), so this is client-only.
import { isSettingsPath, settingsModalTarget, withoutSettings } from '~/utils/settings-nav.mjs'

export default defineNuxtRouteMiddleware((to, from) => {
  if (import.meta.server || !isSettingsPath(to.path)) return
  /* cold: no view of ours to come back to - the app's first navigation (on
     which Nuxt hands over the requested /settings route itself as `from`) */
  const cold = from.matched.length === 0 || isSettingsPath(from.path)
  const target = settingsModalTarget(to.path, {
    path: from.path,
    query: from.query as Record<string, unknown>,
    matched: from.matched.length,
  })
  if (!cold) return navigateTo(target)
  const router = useRouter()
  /* once the lobby has landed, and a macrotask later: a push still inside the
     app's FIRST navigation is written as a replace, which would leave nothing
     under the modal for Back to land on */
  const off = router.afterEach((landed, _from, failure) => {
    if (failure || isSettingsPath(landed.path)) return
    off()
    setTimeout(() => { void router.push(target) }, 0)
  })
  return navigateTo({ path: target.path, query: withoutSettings(target.query) }, { replace: true })
})
