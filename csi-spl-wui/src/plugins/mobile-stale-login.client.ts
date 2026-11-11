/**
 * 087 T003 (FR-001): on every document, whatever its layout, a history step
 * back onto /login with a signed-in session goes on past it instead of
 * painting the sign-in page (composables/useMobileStack.ts guardStaleLogin).
 * A plugin, because the /login document uses the login layout, which never
 * calls the stack's install(). Loaded lazily: a static import put the whole
 * stack into the initial chunk (+2.7 kB gzip, over the 027 budget), and the
 * guard only has to be armed before the next Back.
 * SPL-5319: the popstate listener is added here, synchronously, before
 * nuxt:router (enforce 'pre', -20) creates the history and adds its own:
 * window runs popstate listeners in the order they were added, so only a
 * listener added first can stop the router seeing the stale /login.
 */
export default defineNuxtPlugin({
  name: 'spool:mobile-stale-login',
  order: -30,
  setup(nuxtApp) {
    let pop: ((e: PopStateEvent) => void) | undefined
    window.addEventListener('popstate', (e) => pop?.(e))
    /* the guard reads the session store: arm it once every plugin (pinia) ran */
    nuxtApp.hook('app:created', () => {
      void import('~/composables/useMobileStack').then((m) => { pop = m.useMobileStack().guardStaleLogin() })
    })
  },
})
