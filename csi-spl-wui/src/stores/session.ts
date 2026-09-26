import { defineStore } from 'pinia'
import { useAuthClient } from '~/composables/useAuthClient'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { CARD_CLIP_KEY, CARD_CLIP_THREAD_KEY, clearCardClipSession, readCardClipDefault } from '~/utils/card-clip.mjs'

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
  /** The human's colour theme. 'light' is the light-blue palette. null = none. */
  preferred_theme?: string | null
}

/** Human sign-in state (spec 010 auth-v1 §3–§4, 015 native). The cookie is HttpOnly; we only probe. */
export const useSessionStore = defineStore('session', () => {
  const auth = useAuthClient()
  const state = ref<SessionState>('loading')
  const claims = ref<SessionClaims | null>(null)

  const label = computed(() => claims.value?.hum || claims.value?.name || claims.value?.email || '')

  /*
   * CLE-34984: a member session means the view reads ride the cookie, so the
   * client's door is guessed as `session` BEFORE the state flips and every
   * watcher of 'in' fires its reads. Without it a cold load sent each shell
   * read once with no credentials, took a 401 for each (7 on dev), and only
   * then armed the door. withSessionRetry takes a wrong guess back.
   */
  function signedIn() {
    const api = useSpoolApi()
    if (!api.mock) api.guessDoor('session')
  }

  /* The route middleware and the shell both probe on arrival; one request serves both. */
  let probing: Promise<void> | null = null
  function probe() {
    if (!probing) {
      probing = probeOnce().finally(() => { probing = null })
    }
    return probing
  }

  async function probeOnce() {
    const out = await auth.session()
    // 'unknown' keeps what we had (auth-v1 §4: the csi-rel 052 incident case)
    if (out.state === 'unknown') {
      if (state.value === 'loading') state.value = 'unknown'
      return
    }
    if (out.state === 'in') signedIn()
    state.value = out.state
    claims.value = (out.claims as SessionClaims | null) || null
  }

  /** Native login (015 native-auth-v1 §2) answers 200 with the claims: adopt them, no second probe. */
  function adopt(c: SessionClaims | null) {
    if (c) signedIn()
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

  /** CLE-34968: mirror a saved display name (the hub answers it as `name`). */
  function setName(name: string) {
    if (claims.value) claims.value = { ...claims.value, name }
  }

  /** CLE-34994: mirror a palette pick saved on the account. */
  function setPreferredTheme(theme: string) {
    if (claims.value) claims.value = { ...claims.value, preferred_theme: theme }
  }

  async function logout() {
    await auth.logout()
    if (import.meta.client) {
      clearCardClipSession()
      const d = readCardClipDefault() as 'titles' | 'rows' | 'full'
      useState(CARD_CLIP_KEY, () => d).value = d
      useState(CARD_CLIP_THREAD_KEY, () => d).value = d
    }
    state.value = 'out'
    claims.value = null
    await navigateTo(useNuxtApp().$localePath('/login'))
  }

  return { state, claims, label, probe, adopt, signedOut, setPreferredLocale, setDiagnosticsEnabled, setName, setPreferredTheme, logout }
})
