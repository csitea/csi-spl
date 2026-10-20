import { defineStore } from 'pinia'
import { useAuthClient } from '~/composables/useAuthClient'
import { setViewToken, useSpoolApi } from '~/composables/useSpoolApi'
import { clearCursors } from '~/utils/read-cursor.mjs'
import { takeEarlySession } from '~/utils/early-session.mjs'
import { writeSignedOutHint } from '~/utils/signed-out-hint.mjs'
import { clearDrafts } from '~/utils/drafts'
import { markSignedIn } from '~/utils/session-recover.mjs'

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
   * The human's own "Debug pane" setting, which shows the
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
  /** SPL-976 Settings -> Behaviour "Text fields": 'enter' | 'ctrl-enter'; null = never picked. */
  submit_key?: string | null
  /** SPL-979 "Left panel order": the six rail ids in the person's order; null = default. */
  rail_order?: string[] | null
  /** Topic c6994436 "Message order": 'newest-first' | 'newest-last'; null = never picked (newest first). */
  message_order?: string | null
  /** Topic c6994436 "Omnibox position": 'top' | 'bottom'; null = never picked (top). */
  composer_position?: string | null
  /** SPL-1028 Issues view: 'list' | 'status'; null = never picked (the list). */
  issues_view?: string | null
  /** SPL-1133 "Close buttons": 'mac' (top left) | 'windows' (top right); null = never picked (Mac). */
  close_buttons?: string | null
  /** Topic e1f8f797 "Link previews": 'on' | 'off'; null = never picked (on). The person's own switch. */
  link_previews?: string | null
  /** SPL-1609 "Email links open in": gmail | system | outlook-web | outlook | thunderbird; null = never picked (Gmail in the browser). */
  email_client?: string | null
  /** SPL-1609 "Phone numbers open in": whatsapp | tel | viber | telegram | signal | teams; null = never picked (WhatsApp). */
  phone_app?: string | null
  /** SPL-1132 Issues sheet column widths: column -> px; null = never sized (automatic layout). */
  issues_columns?: Record<string, number> | null
  /** SPL-1181 Issues list default sort: {col, dir}; null = never picked (priority ascending). */
  issues_sort?: { col: string, dir: string } | null
  /** SPL-1182 The two vertical dividers' widths as window fractions; null = never dragged (default layout).
      Spec 078 FR-007: per view ({default: {sidebar, topic}, channel?, issues?, help?, docs?}); an old flat {sidebar, topic} reads as default. */
  pane_sizes?: Record<string, number | Record<string, number>> | null
  /** CLE-77908 The IANA zone every time prints in, per workspace; null = the browser's zone. */
  time_zone?: string | null
  /** HUM-10 ae2e5093 The message Shift+letter shortcuts, per workspace; null = never picked = on. */
  keyboard_shortcuts?: boolean | null
  /** Spec 107 1.2 "Count my reading time", per workspace; null = never picked = on. */
  hours_reading?: boolean | null
  /** SPL-2113 "Thinking animation": the ticked drawing ids, per workspace; null = never picked (the default three). */
  await_anims?: string[] | null
  /** SPL-2108 The costs' second currency (ISO 4217), per workspace; the hub answers EUR when never picked. */
  second_currency?: string | null
}

type SessionAuth = ReturnType<typeof useAuthClient>

/* P3-02: the document-head script sends a reader to /login before any JS
   loads when this browser last read 'out' (utils/signed-out-hint.mjs).
   'unknown' and 'loading' say nothing, so they leave the hint as it is. */
function watchSignedOutHint(state: Ref<SessionState>) {
  if (import.meta.client && !useSpoolApi().mock) {
    const siteUrl = String(useRuntimeConfig().public.siteUrl || '')
    watch(state, (s) => {
      if (s !== 'in' && s !== 'out') return
      writeSignedOutHint(document, s === 'out', { hostname: location.hostname, protocol: location.protocol, siteUrl })
    })
  }
}

/*
 * a member session means the view reads ride the cookie, so the
 * client's door is guessed as `session` BEFORE the state flips and every
 * watcher of 'in' fires its reads. Without it a cold load sent each shell
 * read once with no credentials, took a 401 for each (7 on dev), and only
 * then armed the door. withSessionRetry takes a wrong guess back.
 */
function signedIn() {
  const api = useSpoolApi()
  if (!api.mock) api.guessDoor('session')
}

/* Probe, adopt and drop the sign-in state. */
function probeActions(state: Ref<SessionState>, claims: Ref<SessionClaims | null>, auth: SessionAuth) {
  /* The route middleware and the shell both probe on arrival; one request serves both. */
  let probing: Promise<void> | null = null
  function probe() {
    if (!probing) {
      probing = probeOnce().finally(() => { probing = null })
    }
    return probing
  }

  async function probeOnce() {
    /* the first probe of the page was started before the plugins
       ran (plugins/0.boot-early); take its answer instead of asking again */
    const out = await (takeEarlySession() || auth.session())
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
    /* its own notice (password changed), not "your session ended" */
    if (import.meta.client) markSignedIn(false)
    state.value = 'out'
    claims.value = null
  }

  return { probe, adopt, signedOut }
}

/* Mirror a saved (or optimistic) account choice into the claims without another probe. */
function claimMirrors(claims: Ref<SessionClaims | null>) {
  function mirror(patch: Partial<SessionClaims>) {
    if (claims.value) claims.value = { ...claims.value, ...patch }
  }

  /** spec 021: mirror a saved preference without another probe. */
  function setPreferredLocale(code: string) {
    mirror({ preferred_locale: code })
  }

  /** mirror the "Debug pane" checkbox (optimistic; reverted on a failed save). */
  function setDiagnosticsEnabled(on: boolean) {
    if (claims.value) claims.value = { ...claims.value, diagnostics_enabled: on === true }
  }

  /** mirror a saved display name (the hub answers it as `name`). */
  function setName(name: string) {
    mirror({ name })
  }

  /** mirror a palette pick saved on the account. */
  function setPreferredTheme(theme: string) {
    mirror({ preferred_theme: theme })
  }

  /** SPL-976: mirror the "Text fields" choice (optimistic; reverted on a failed save). */
  function setSubmitKey(key: string) {
    mirror({ submit_key: key })
  }

  /** SPL-979: mirror the rail order (optimistic; reverted on a failed save). */
  function setRailOrder(order: string[] | null) {
    mirror({ rail_order: order })
  }

  /** Topic c6994436: mirror a layout choice (optimistic; reverted on a failed save). */
  function setViewPref(key: 'message_order' | 'composer_position' | 'issues_view' | 'close_buttons' | 'link_previews' | 'email_client' | 'phone_app', value: string) {
    mirror({ [key]: value })
  }

  /** SPL-1132: mirror the Issues sheet column widths (optimistic; reverted on a failed save). */
  function setIssuesColumns(cols: Record<string, number> | null) {
    mirror({ issues_columns: cols })
  }

  /** SPL-1181: mirror the Issues default sort (optimistic; reverted on a failed save). */
  function setIssuesSort(sort: { col: string, dir: string } | null) {
    mirror({ issues_sort: sort })
  }

  /** SPL-1182: mirror the divider widths (optimistic; reverted on a failed save). */
  function setPaneSizes(sizes: Record<string, number | Record<string, number>> | null) {
    mirror({ pane_sizes: sizes })
  }

  /** CLE-77908: mirror the time zone (optimistic; reverted on a failed save). */
  function setTimeZone(zone: string | null) {
    mirror({ time_zone: zone })
  }

  /** HUM-10 ae2e5093: mirror the shortcuts switch (optimistic; reverted on a failed save). */
  function setKeyboardShortcuts(on: boolean | null) {
    mirror({ keyboard_shortcuts: on })
  }

  /** Spec 107 1.2: mirror "Count my reading time" (optimistic; reverted on a failed save). */
  function setHoursReading(on: boolean | null) {
    mirror({ hours_reading: on })
  }

  return { setPreferredLocale, setDiagnosticsEnabled, setName, setPreferredTheme, setSubmitKey, setRailOrder, setViewPref, setIssuesColumns, setIssuesSort, setPaneSizes, setTimeZone, setKeyboardShortcuts, setHoursReading }
}

/* Sign out by hand, or stop acting as someone. */
function signOutActions(state: Ref<SessionState>, claims: Ref<SessionClaims | null>, auth: SessionAuth) {
  async function logout() {
    const hum = claims.value?.hum
    await auth.logout()
    if (import.meta.client) {
      /* HUM-10 fb8d109f: a sign-out by hand is not "your session ended" */
      markSignedIn(false)
      /* 080 FR-008: the next member on this browser never sees these drafts */
      clearDrafts(undefined, hum)
      /* SPL-2556: the view token leaves this tab with the session */
      setViewToken('')
      /* SPL-2149: the next member never reads the feeds kept for offline reading
         (utils/offline-feed.mjs OFFLINE_FEEDS_KEY, by name: no chunk to load at sign-out) */
      try { localStorage.removeItem('spool.offline-feeds') } catch { /* storage blocked: nothing kept */ }
      /* 027 budget: card-clip (and file-preview behind it) is only needed on
         sign-out here, so it is not part of the initial chunk */
      const { CARD_CLIP_KEY, CARD_CLIP_THREAD_KEY, clearCardClipSession, readCardClipDefault } = await import('~/utils/card-clip.mjs')
      clearCardClipSession()
      const msgs = readCardClipDefault(undefined, 'msgs') as 'titles' | 'rows' | 'full'
      const thread = readCardClipDefault(undefined, 'thread') as 'titles' | 'rows' | 'full'
      useState(CARD_CLIP_KEY, () => msgs).value = msgs
      useState(CARD_CLIP_THREAD_KEY, () => thread).value = thread
    }
    state.value = 'out'
    claims.value = null
    await navigateTo(useNuxtApp().$localePath('/login'))
    /* SPL-2556: the next member does not start from these read marks (the
       hub keeps them for this member). After the navigation: an open feed
       marks itself read again when the session goes out, until it is left. */
    if (import.meta.client) clearCursors()
  }

  /**
   * specs/054: "Stop acting as X" — the owner's rule is a sign-out, not a
   * silent switch back. End the clone, then clear the cookie and land on the
   * login page (logout); the admin signs in normally.
   */
  async function stopActingAs() {
    await auth.actAsExit()
    await logout()
  }

  return { logout, stopActingAs }
}

/** Human sign-in state (spec 010 auth-v1 §3–§4, 015 native). The cookie is HttpOnly; we only probe. */
export const useSessionStore = defineStore('session', () => {
  const auth = useAuthClient()
  const state = ref<SessionState>('loading')
  const claims = ref<SessionClaims | null>(null)

  const label = computed(() => claims.value?.hum || claims.value?.name || claims.value?.email || '')

  watchSignedOutHint(state)
  return { state, claims, label, ...probeActions(state, claims, auth), ...claimMirrors(claims), ...signOutActions(state, claims, auth) }
})
