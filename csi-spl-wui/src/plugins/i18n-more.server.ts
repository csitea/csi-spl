// SPL-2417: the second catalogue (i18n-more.client.ts) on the server too, so a
// prerendered document of a route that is not a first-screen page (/blog,
// /public-calendar) holds its text instead of its keys (`blog.lede`): with JS
// off, for a crawler, and before hydration. The client merges the same
// catalogue before such a route renders, so the hydrated text is the same.
// First-screen routes stay on the core catalogue here as there: a te() gate
// (ON_DEMAND_COMPONENTS) must read the same on both sides. Server code only:
// the client's first download does not change.
import { isFirstScreenRoute } from '~/utils/i18n-first-screen.mjs'
import { settingsQuerySection } from '~/utils/settings-nav.mjs'

type Catalogue = Record<string, unknown>
const MORE = import.meta.glob<{ default: Catalogue }>('../../i18n/.split/more/*.mjs')

export default defineNuxtPlugin({
  name: 'spool:i18n-more-server',
  dependsOn: ['i18n:plugin'],
  async setup(nuxtApp) {
    if (import.meta.dev) return
    const i18n = nuxtApp.$i18n as {
      locale: { value: string }
      mergeLocaleMessage: (locale: string, messages: Catalogue) => void
    }
    const to = useRouter().currentRoute.value
    if (isFirstScreenRoute(to) && settingsQuerySection(to.query) === null) return
    const suffix = typeof to.name === 'string' ? to.name.split('___')[1] : ''
    const code = suffix || i18n.locale.value
    const loader = MORE[`../../i18n/.split/more/${code}.mjs`]
    if (!loader) return
    const m = await loader()
    if (m?.default) i18n.mergeLocaleMessage(code, m.default)
  },
})
