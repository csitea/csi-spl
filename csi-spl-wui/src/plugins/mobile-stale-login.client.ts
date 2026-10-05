/**
 * 087 T003 (FR-001): on every document, whatever its layout, a history step
 * back onto /login with a signed-in session goes on past it instead of
 * painting the sign-in page (composables/useMobileStack.ts guardStaleLogin).
 * A plugin, because the /login document uses the login layout, which never
 * calls the stack's install(). Loaded lazily: a static import put the whole
 * stack into the initial chunk (+2.7 kB gzip, over the 027 budget), and the
 * guard only has to be armed before the next Back.
 */
export default defineNuxtPlugin(() => {
  void import('~/composables/useMobileStack').then((m) => m.useMobileStack().guardStaleLogin())
})
