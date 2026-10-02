// useLocaleSwitch — "show me this page in that language", for every surface
// that offers the choice (the header LanguageSwitcher, Settings → Language).
//
// The URL prefix stays the single source of truth for the active locale
// (`prefix_except_default`), so switching IS a navigation: same page, same
// query, same hash, different locale segment. Both callers used to inline
// that, and both inlined the same silent failure — see the header of
// utils/localeTargetPath.mjs for the measurement.
//
// The localStorage mirror (`csi-spl-lang`) is written here so the two
// surfaces cannot drift apart on which key they use; the cookie
// (`i18n_redirected`) is written by plugins/locale-cookie.client.ts, which
// watches the locale and therefore also covers a switch made from Settings.
import { localeTargetPath, isPathInLocale } from '@/utils/localeTargetPath.mjs'
import { registerLocaleRoutes } from '@/utils/locale-routes.mjs'

/** localStorage mirror of the visitor's choice (see LanguageSwitcher.vue). */
export const LOCALE_LS_KEY = 'csi-spl-lang'

export function useLocaleSwitch() {
  const { locale, localeCodes } = useI18n({ useScope: 'global' })
  const switchLocalePath = useSwitchLocalePath()
  const router = useRouter()
  const defaultLocale = String(useRuntimeConfig().public.defaultLocale || '')

  function persist(code: string) {
    // SSR-safe: only touch localStorage on the client.
    if (!import.meta.client) return
    try {
      localStorage.setItem(LOCALE_LS_KEY, code)
    } catch {
      // private mode / quota — the cookie path still works
    }
  }

  /**
   * Navigate to the current page in `code`.
   *
   * @param code    target locale
   * @param replace true to replace the history entry instead of pushing one
   * @returns the path navigated to, or '' when nothing was to be done
   */
  async function switchTo(code: string, replace = false): Promise<string> {
    const codes = (unref(localeCodes) as string[] | undefined) || []
    if (!code || !codes.includes(code) || code === String(unref(locale) || '')) return ''
    persist(code)

    // P3-14: the target locale's routes may not be in the router yet.
    registerLocaleRoutes(router)
    const route = router.currentRoute.value
    // Prefer the module's answer — it carries route params a path rewrite
    // cannot know — but only when it actually lands in the target locale.
    const offered = String(switchLocalePath(code as never) || '').split(/[?#]/)[0]
    const target = offered && isPathInLocale(offered, code, codes, defaultLocale)
      ? offered
      : localeTargetPath(route.path, code, codes, defaultLocale)

    // ALWAYS re-apply the current query/hash: a verify/reset token or a topic
    // deep link must survive a language switch. switchLocalePath usually
    // returns fullPath, but path-only and empty results have dropped it.
    await navigateTo(
      { path: target, query: { ...route.query }, hash: route.hash || undefined },
      replace ? { replace: true } : undefined,
    )
    return target
  }

  return { switchTo, persist }
}
