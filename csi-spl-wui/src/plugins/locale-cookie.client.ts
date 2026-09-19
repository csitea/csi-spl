// spec 021 (copied from the donor WUI) — persist the visitor's locale in the
// `i18n_redirected` cookie (strictly necessary: it only remembers a choice).
//
// @nuxtjs/i18n only writes this cookie while `detectBrowserLanguage` is on,
// and that feature is OFF here: on the prerendered `/` it swapped the locale
// in place before the first client render, which is exactly the hydration
// mismatch T017 removes. The root redirect script (utils/rootLocaleRedirect)
// reads this cookie first, so a returning visitor lands on the locale they
// last used rather than on Accept-Language. The URL prefix stays the single
// source of truth for the locale; this plugin only mirrors it.
export default defineNuxtPlugin((nuxtApp) => {
  if (!import.meta.client) return

  const cookieKey = String(useRuntimeConfig().public.localeCookie || '')
  if (!cookieKey) return

  const i18n = nuxtApp.$i18n as { locale?: unknown } | undefined
  const write = () => {
    const code = String(unref(i18n?.locale) || '')
    if (!code) return
    try {
      document.cookie = `${cookieKey}=${encodeURIComponent(code)}; Path=/; Max-Age=31536000; SameSite=Lax`
    } catch {
      /* cookies disabled — Accept-Language still resolves the root */
    }
  }

  // After hydration (never during it — the cookie is not part of the DOM,
  // but keep the first render free of side effects), then on every switch.
  nuxtApp.hook('app:suspense:resolve', write)
  watch(() => unref(i18n?.locale), write)
})
