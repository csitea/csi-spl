import { defineStore } from 'pinia'
import { createAuthClient } from '~/utils/auth-client.mjs'

export type SessionState = 'in' | 'out' | 'unknown' | 'loading'

export interface SessionClaims {
  p?: string
  email?: string
  name?: string
  hum?: string
  t?: string
  exp?: number
}

/** Human sign-in state (spec 010 auth-v1 §3–§4). The cookie is HttpOnly; we only probe. */
export const useSessionStore = defineStore('session', () => {
  const auth = createAuthClient()
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

  async function logout() {
    await auth.logout()
    state.value = 'out'
    claims.value = null
    await navigateTo('/login')
  }

  return { state, claims, label, probe, logout }
})
