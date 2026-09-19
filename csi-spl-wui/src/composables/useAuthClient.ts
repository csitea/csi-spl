import { authOrigin, createAuthClient } from '~/utils/auth-client.mjs'

/**
 * The hub origin every /api/v1/auth/** call goes to (runtime
 * NUXT_PUBLIC_AUTH_BASE; '' = same-origin, the lde devProxy). The WUI host
 * and the hub host differ in every deployed env (spec 010 auth-v1 §1).
 */
export function useAuthBase(): string {
  return authOrigin(String(useRuntimeConfig().public.authBase || ''))
}

/** The auth client bound to the auth base. Call it in setup, not later. */
export function useAuthClient() {
  return createAuthClient({ base: useAuthBase() })
}
