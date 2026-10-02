// The locale route copies the build leaves out (CLE-77925): see
// src/utils/locale-routes.mjs. Nuxt calls `routes` once, when the router is
// made, on the server (prerender) and in the browser, before the first route
// is resolved, so /bg/login matches exactly as it did when i18n shipped it.
import type { RouterConfig } from "@nuxt/schema"
import { defaultLocale, localeCodes } from "#build/locale-route-codes.mjs"
import { expandLocaleRoutes } from "~/utils/locale-routes.mjs"

export default <RouterConfig>{
  routes: (routes) => expandLocaleRoutes([...routes], localeCodes, defaultLocale),
}
