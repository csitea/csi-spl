// spec 021 — a signed-in human's stored language wins over the URL's once.
//
// The donor stores users.preferred_locale for mail and does not switch the
// UI from it; the spool owner asked for the preference to be "the WUI default
// after sign-in" as well. So: the first time a session answers 'in' carrying
// a preferred_locale that differs from the active locale, navigate to the same
// page in that locale (the URL prefix stays the single source of truth, the
// locale-cookie plugin then remembers it). Once per signed-in human per tab
// (sessionStorage marker): after that the header switcher is free to change
// the language, as in the donor, and a reload does not undo that choice.
import { useSessionStore } from '~/stores/session'
import { registerLocaleRoutes } from '~/utils/locale-routes.mjs'

export default defineNuxtPlugin((nuxtApp) => {
  if (!import.meta.client) return
  const i18n = nuxtApp.$i18n as { locale?: unknown, localeCodes?: unknown } | undefined
  let applied = false
  const MARK = 'csi-spl-pref-locale-applied'
  const read = () => { try { return sessionStorage.getItem(MARK) || '' } catch { return '' } }
  const mark = (v: string) => { try { sessionStorage.setItem(MARK, v) } catch { /* private mode */ } }

  nuxtApp.hook('app:suspense:resolve', () => {
    const session = useSessionStore()
    watch(
      () => [session.state, session.claims?.preferred_locale] as const,
      ([state, pref]) => {
        if (applied || state !== 'in') return
        applied = true
        const who = String(session.claims?.hum || session.claims?.email || 'in')
        if (read() === who) return
        mark(who)
        const want = String(pref || '')
        const codes = (unref(i18n?.localeCodes) as string[] | undefined) || []
        if (!want || !codes.includes(want) || want === String(unref(i18n?.locale) || '')) return
        registerLocaleRoutes(useRouter()) // P3-14: before switchLocalePath
        const route = useRoute()
        const switched = useSwitchLocalePath()(want as never)
        const path = (switched || route.path).split(/[?#]/)[0] || '/'
        void navigateTo({ path, query: { ...route.query }, hash: route.hash || undefined }, { replace: true })
      },
      { immediate: true },
    )
  })
})
