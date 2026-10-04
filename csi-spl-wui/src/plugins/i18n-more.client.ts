// Perf round 3, P3-06: the second catalogue of each locale - every message
// the first screen cannot show (src/node/i18n/split-catalogue.mjs, wired in
// nuxt.config.ts). It is merged into vue-i18n
//   - before any route that is not a first-screen page, and before the
//     ?settings= modal (src/utils/i18n-first-screen.mjs names both), so such
//     a view never renders a key instead of its text - on a cold boot onto
//     such a route already during this plugin, so the boot's own navigations
//     (Nuxt's initial replace, a replayed notification tap's push) find it
//     loaded instead of racing each other while it downloads;
//   - when the browser is idle after the first screen, so a later click
//     finds it in place;
//   - for the new locale on a switch, once it was wanted for the old one.
// The files are modules of compiled messages, made at build time as the
// i18n module makes the core ones (runtime-only vue-i18n cannot compile). lde (`nuxt dev`) ships whole
// catalogues and has nothing to load.
import { isFirstScreenRoute } from '~/utils/i18n-first-screen.mjs'
import { settingsQuerySection } from '~/utils/settings-nav.mjs'

type Catalogue = Record<string, unknown>
const MORE = import.meta.glob<{ default: Catalogue }>('../../i18n/.split/more/*.mjs')

/** The second catalogue's loader for a locale code, or undefined (lde, or none). */
function moreLoader(code: string) {
  return MORE[`../../i18n/.split/more/${code}.mjs`]
}

/** True when the route shows something whose strings may be in the second catalogue. */
function needsMore(to: { name?: unknown, query?: Record<string, unknown> }): boolean {
  if (!isFirstScreenRoute(to)) return true
  // ON_DEMAND_COMPONENTS: app.vue mounts the Settings modal on ?settings=
  return settingsQuerySection(to.query) !== null
}

export default defineNuxtPlugin({
  name: 'spool:i18n-more',
  dependsOn: ['i18n:plugin'],
  async setup(nuxtApp) {
    if (import.meta.dev) return
    const i18n = nuxtApp.$i18n as {
      locale: { value: string }
      mergeLocaleMessage: (locale: string, messages: Catalogue) => void
    }
    const loads = new Map<string, Promise<void>>()
    let wanted = false

    function load(code: string): Promise<void> {
      wanted = true
      const known = loads.get(code)
      if (known) return known
      const loader = moreLoader(code)
      const p = loader
        ? (async () => {
            try {
              const m = await loader()
              // a failed chunk can come back as undefined (Vite's preload wrapper)
              if (!m?.default) throw new Error('no module')
              i18n.mergeLocaleMessage(code, m.default)
            } catch (e) {
              // a failed chunk is retried on the next need; keys show meanwhile
              loads.delete(code)
              console.error('[i18n-more] load failed', code, e)
            }
          })()
        : Promise.resolve()
      loads.set(code, p)
      return p
    }

    /** The locale a route renders in: its `___<code>` name suffix, else the current one. */
    function routeLocale(to: { name?: unknown }): string {
      const suffix = typeof to.name === 'string' ? to.name.split('___')[1] : ''
      return suffix || i18n.locale.value
    }

    const router = useRouter()
    router.beforeResolve(async (to) => {
      if (needsMore(to)) await load(routeLocale(to))
    })
    const boot = router.currentRoute.value
    if (needsMore(boot)) await load(routeLocale(boot))

    nuxtApp.hook('i18n:localeSwitched', ({ newLocale }: { newLocale: string }) => {
      if (wanted) void load(newLocale)
    })

    nuxtApp.hook('app:suspense:resolve', () => {
      const run = () => { void load(i18n.locale.value) }
      if (typeof window.requestIdleCallback === 'function') window.requestIdleCallback(run, { timeout: 3000 })
      else setTimeout(run, 1500)
    })
  },
})
