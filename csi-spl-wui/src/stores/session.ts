import { defineStore } from 'pinia'
import { useAuthClient } from '~/composables/useAuthClient'

export type SessionState = 'in' | 'out' | 'unknown' | 'loading'

export interface SessionClaims {
  p?: string
  email?: string
  name?: string
  hum?: string
  t?: string
  iat?: number
  exp?: number
  /**
   * The human's own "Debug pane" setting (CLE-34963), which shows the
   * diagnostics panel (005 T035): the hub answers it from the store on every
   * session read, and only the literal `true` admits (debugAudience.mjs).
   * The WUI writes it only through setDiagnosticsEnabled, mirroring the
   * checkbox while its save is in flight; the next probe is the authority.
   */
  diagnostics_enabled?: boolean
  /** spec 021: the human's stored UI + mail language; null/absent = none. */
  preferred_locale?: string | null
}

/** Human sign-in state (spec 010 auth-v1 §3–§4, 015 native). The cookie is HttpOnly; we only probe. */
export const useSessionStore = defineStore('session', () => {
  const auth = useAuthClient()
  const state = ref<SessionState>('loading')
  const claims = ref<SessionClaims | null>(null)

  const label = computed(() => claims.value?.hum || claims.value?.name || claims.value?.email || '')

  async function probe() {
    const out = await auth.session()
    // 'unknown' keeps what we had (auth-v1 §4: the csi-rel 052 incident case)
    if (out.state === 'unknown') {
      if (state.value === 'loading') state.value = 'unknown'
      return
    }
    state.value = out.state
    claims.value = (out.claims as SessionClaims | null) || null
  }

  /** Native login (015 native-auth-v1 §2) answers 200 with the claims: adopt them, no second probe. */
  function adopt(c: SessionClaims | null) {
    state.value = c ? 'in' : 'out'
    claims.value = c
  }

  /** A native password change clears the cookie (§2 `password/change` 204). */
  function signedOut() {
    state.value = 'out'
    claims.value = null
  }

  /** spec 021: mirror a saved preference without another probe. */
  function setPreferredLocale(code: string) {
    if (claims.value) claims.value = { ...claims.value, preferred_locale: code }
  }

  /** CLE-34963: mirror the "Debug pane" checkbox (optimistic; reverted on a failed save). */
  function setDiagnosticsEnabled(on: boolean) {
    if (claims.value) claims.value = { ...claims.value, diagnostics_enabled: on === true }
  }

  async function logout() {
    await auth.logout()
    state.value = 'out'
    claims.value = null
    await navigateTo(useNuxtApp().$localePath('/login'))
  }

  return { state, claims, label, probe, adopt, signedOut, setPreferredLocale, setDiagnosticsEnabled, logout }
})
