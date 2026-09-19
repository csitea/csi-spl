// useSettledQuery — read a URL query parameter that survives SSG hydration.
//
// WHY THIS EXISTS
//
// The WUI is prerendered (`nuxt generate`). When a prerendered page is
// cold-loaded with a query string, Nuxt 3 deliberately renders the FIRST pass
// against the query-less prerendered route so the markup matches, and only
// restores the real URL afterwards — see
// node_modules/nuxt/dist/pages/runtime/plugins/router.js:
//
//     const hasDeferredRoute = nuxtApp.isHydrating && payload.prerenderedAt
//       && payload.path && initialURL !== payload.path && …
//     if (hasDeferredRoute) {
//       await router.replace({ ...router.resolve(payload.path), force: true })
//       nuxtApp.hooks.hookOnce('app:suspense:resolve', async () => {
//         await router.replace({ ...resolvedInitialRoute, force: true })
//       })
//     }
//
// So inside `setup()` AND inside `onMounted()` of a cold-loaded prerendered
// page, `route.query` is EMPTY. `window.location.search` is empty too, because
// that first `router.replace` has already rewritten history — which is why
// reading `location` instead of the route is NOT a workaround.
//
// The damage is silent: a prerendered page (here `/login`, `/`) that reads
// `?auth_error=` / `?redirect=` / `?tenant=` in setup or onMounted sees
// nothing on a cold load. Static-marker unit tests cannot see this; only a
// real `nuxt generate` + cold load reproduces it.
//
// This composable is the `watch(() => route.query.x, …)` idiom, once, with
// the "has it settled yet?" half that a bare watcher does not give you
// (ported from the donor WUI).

import { computed, ref, watch, type ComputedRef, type Ref } from 'vue'

/** First value of a query entry that vue-router may hand over as an array. */
export function firstQueryValue(raw: unknown): string {
  if (typeof raw === 'string') return raw
  if (Array.isArray(raw)) {
    const first = raw.find((v) => typeof v === 'string')
    return typeof first === 'string' ? first : ''
  }
  return ''
}

export interface SettledQuery {
  /**
   * The parameter's value. Empty until the real route is in place; once the
   * deferred replace lands it flips to the value from the URL and stays there.
   */
  value: Ref<string>
  /**
   * False only while a cold load is still rendering against the prerendered
   * route. Gate "the link had no token" messaging on this, or the page will
   * accuse the user of a bad link during the hydration window.
   */
  settled: Ref<boolean>
  /**
   * The parameter is genuinely absent. FALSE during SSR/prerender and during
   * the hydration window, so a page can bind "this link carries no token"
   * straight to it: the prerendered markup and the hydrating client agree on
   * the neutral state (no hydration mismatch), and the message appears only
   * once the real URL is in place.
   */
  missing: ComputedRef<boolean>
}

/**
 * Track one query parameter across the SSG hydration window.
 *
 * On a client-side navigation the value is available immediately and `settled`
 * starts true, so callers need no branch for the two cases.
 *
 * @param key query parameter name, e.g. `'token'`
 */
export function useSettledQuery(key: string): SettledQuery {
  const route = useRoute()
  const nuxtApp = useNuxtApp()

  const value = ref(firstQueryValue(route.query[key]))
  // A hydrating client render is the only case that can still be lying to us.
  // SSR and in-app navigations already hold the real route.
  const hydrating = Boolean(import.meta.client && nuxtApp.isHydrating)
  const settled = ref(!hydrating || value.value !== '')

  if (hydrating) {
    // The restore is an ordinary router navigation, so a watcher sees it
    // without depending on hook ordering.
    watch(
      () => route.query[key],
      (next) => {
        const v = firstQueryValue(next)
        if (v) value.value = v
        settled.value = true
      },
    )
    // Nothing to restore (the URL really had no query): Nuxt never fires the
    // deferred replace, so settle on the same hook it would have used.
    nuxtApp.hooks.hookOnce('app:suspense:resolve', () => {
      settled.value = true
    })
  }

  const missing = computed(
    () => Boolean(import.meta.client) && settled.value && value.value === '',
  )
  return { value, settled, missing }
}
