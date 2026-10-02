// P3-14: the router starts with the default locale and the URL's locale only
// (app/router.options.ts). This adds the other locales' records:
//   - at idle after mount, so hreflang and every later link resolve;
//   - when a navigation matches nothing (a back/forward or a typed link into
//     a locale not added yet): add them and resolve the same URL again.
// A locale switch adds them first itself (composables/useLocaleSwitch.ts,
// plugins/preferred-locale.client.ts), so switchLocalePath knows the route.
import { registerLocaleRoutes } from '~/utils/locale-routes.mjs'

export default defineNuxtPlugin((nuxtApp) => {
  const router = useRouter()
  router.beforeEach((to) => {
    if (!to.matched.length && registerLocaleRoutes(router)) return to.fullPath
    return undefined
  })
  nuxtApp.hook('app:mounted', () => {
    const add = () => registerLocaleRoutes(router)
    if (typeof requestIdleCallback === 'function') requestIdleCallback(add, { timeout: 3000 })
    else setTimeout(add, 1000)
  })
})
