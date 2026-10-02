// The locale route copies the build leaves out (CLE-77925): see
// src/utils/locale-routes.mjs. Nuxt calls `routes` once, when the router is
// made, on the server (prerender) and in the browser, before the first route
// is resolved, so /bg/login matches exactly as it did when i18n shipped it.
// In the browser the router starts with the default locale and the one in
// the URL only (P3-14); plugins/locale-routes.client.ts adds the rest.
import type { RouterConfig } from "@nuxt/schema"
import { defaultLocale, localeCodes } from "#build/locale-route-codes.mjs"
import { deferLocaleRoutes, expandLocaleRoutes, splitLocaleRoutes } from "~/utils/locale-routes.mjs"
import { localePrefixOf } from "~/utils/localeTargetPath.mjs"

export default <RouterConfig>{
  routes: (routes) => {
    if (import.meta.server) return expandLocaleRoutes([...routes], localeCodes, defaultLocale)
    const active = localePrefixOf(window.location.pathname, localeCodes)
    const { now, later } = splitLocaleRoutes([...routes], localeCodes, defaultLocale, active)
    deferLocaleRoutes(later)
    return now
  },
}
