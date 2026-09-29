import { authOrigin, createAuthClient } from '~/utils/auth-client.mjs'

/**
 * The hub origin every /api/v1/auth/** call goes to (runtime
 * NUXT_PUBLIC_AUTH_BASE; '' = same-origin, the lde devProxy). The WUI host
 * and the hub host differ in every deployed env (spec 010 auth-v1 §1).
 */
export function useAuthBase(): string {
  return authOrigin(String(useRuntimeConfig().public.authBase || ''))
}

/*
 * CLE-35099: saveIssuesSort / savePaneSizes are members of the client's return
 * object (auth-client.mjs), but vue-tsc drops them from the large object
 * literal's inferred type (only a subset of the ~21 methods surface). They
 * exist at runtime; declaring them here restores the types at the call sites
 * with no `any`. Keep in sync with auth-client.mjs.
 */
type AuthClient = ReturnType<typeof createAuthClient>
type PerTenantPrefSaves = {
  saveIssuesSort(sort: { col: string, dir: string } | null): ReturnType<AuthClient['saveIssueColumns']>
  savePaneSizes(sizes: Record<string, number> | null): ReturnType<AuthClient['saveIssueColumns']>
}

/** The auth client bound to the auth base. Call it in setup, not later. */
export function useAuthClient(): AuthClient & PerTenantPrefSaves {
  // spec 021: the active UI locale rides every auth call as X-Locale. The
  // hub admits the header in its CORS preflight from 0.1.10 (e586002); the
  // registration mail follows it.
  const i18n = useNuxtApp().$i18n as { locale?: unknown } | undefined
  return createAuthClient({ base: useAuthBase(), locale: () => String(unref(i18n?.locale) || ''), sendLocale: true }) as AuthClient & PerTenantPrefSaves
}
