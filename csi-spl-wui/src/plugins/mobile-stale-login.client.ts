import { useMobileStack } from '~/composables/useMobileStack'

/**
 * 087 T003 (FR-001): on every document, whatever its layout, a history step
 * back onto /login with a signed-in session goes on past it instead of
 * painting the sign-in page (composables/useMobileStack.ts guardStaleLogin).
 * A plugin, because the /login document uses the login layout, which never
 * calls the stack's install().
 */
export default defineNuxtPlugin(() => {
  useMobileStack().guardStaleLogin()
})
