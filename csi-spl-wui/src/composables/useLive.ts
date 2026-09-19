import { cleanAs, createLiveClient, tokenStale, wsUrl } from '~/utils/live-ws.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { MOCK_LOBBY_TASK_ID } from '~/utils/mock-data.mjs'
import { reconnectDetector } from '~/utils/live-follow.mjs'

/**
 * Identity for 2-session interop: ?as=HUM-2 (a v:1 agent id, wui-live-ws §2),
 * remembered for the tab. Absent/invalid → the hub assigns HUM-<n>; welcome.as wins.
 */
export const AS_KEY = 'spool.as'

function readAs(): string {
  if (!import.meta.client) return ''
  let q = ''
  let stored = ''
  try {
    q = new URLSearchParams(window.location.search).get('as') || ''
    stored = sessionStorage.getItem(AS_KEY) || ''
  } catch {
    /* memory only */
  }
  const name = cleanAs(q) || cleanAs(stored)
  try {
    if (name) sessionStorage.setItem(AS_KEY, name)
  } catch {
    /* memory only */
  }
  return name
}

type Listener = (m: Record<string, unknown>) => void

let live: ReturnType<typeof createLiveClient> | null = null
const listeners = new Set<Listener>()
/** wui-live-ws §7: fired once per reconnect (an open after a drop), after the re-subscribes. */
const reconnectListeners = new Set<() => void>()
/** wui-live-ws §3 `presence` frames ({ peer, status }). */
const presenceListeners = new Set<Listener>()
const state = ref('idle')
const identity = ref('')
const uploadToken = ref('')
const uploadTokenExpiresAt = ref('')
const lobbyFromHub = ref('')

/**
 * One hub WUI socket per tab (003 wui-live-ws.md) on the TENANT host.
 * Mock mode has no socket: sends are applied locally by the live store.
 */
export function useLive() {
  const api = useSpoolApi()
  const config = useRuntimeConfig()
  const lobbyTaskId = computed(() => lobbyFromHub.value || String(config.public.lobbyTaskId || '')
    || (api.mock ? MOCK_LOBBY_TASK_ID : ''))

  function ensure() {
    if (!import.meta.client) return null
    if (!identity.value) identity.value = readAs()
    if (api.mock) {
      if (!identity.value) identity.value = 'HUM-1'
      state.value = 'mock'
      return null
    }
    if (live) return live
    if (!api.base) {
      state.value = api.configError || 'no_base'
      return null
    }
    // live-ws calls onState('open') before it re-subscribes: defer, so the
    // catch-up read goes out after the subscribes (subscribe first, then read).
    const reconnected = reconnectDetector(() => queueMicrotask(() => {
      for (const fn of reconnectListeners) fn()
    }))
    live = createLiveClient({
      url: wsUrl(api.base),
      token: api.token || '',
      as: identity.value,
      onState: (s: string) => {
        state.value = s
        reconnected(s)
      },
      onToken: (f: Record<string, unknown>) => {
        if (typeof f.upload_token === 'string') uploadToken.value = f.upload_token
        if (typeof f.upload_token_expires_at === 'string') uploadTokenExpiresAt.value = f.upload_token_expires_at
      },
      onWelcome: (w: Record<string, unknown>) => {
        if (typeof w.as === 'string' && w.as) {
          identity.value = w.as
          try { sessionStorage.setItem(AS_KEY, w.as) } catch { /* memory only */ }
        }
        if (typeof w.upload_token === 'string') uploadToken.value = w.upload_token
        if (typeof w.upload_token_expires_at === 'string') uploadTokenExpiresAt.value = w.upload_token_expires_at
        if (typeof w.lobby_task_id === 'string') lobbyFromHub.value = w.lobby_task_id
        if (typeof w.as === 'string' && w.as) identity.value = w.as
      },
      onMessage: (m: Record<string, unknown>) => {
        for (const fn of listeners) fn(m)
      },
    })
    live.connect()
    return live
  }

  /** Upload token for POST /v1/files, refreshed via {type:"token"} when stale (5 min TTL). */
  async function freshUploadToken(): Promise<string> {
    const client = ensure()
    if (!client) return ''
    if (uploadToken.value && !tokenStale(uploadTokenExpiresAt.value)) return uploadToken.value
    const f = await client.requestToken() as Record<string, unknown>
    return typeof f.upload_token === 'string' ? f.upload_token : uploadToken.value
  }

  function onMessage(fn: Listener) {
    listeners.add(fn)
    return () => listeners.delete(fn)
  }

  function onReconnected(fn: () => void) {
    reconnectListeners.add(fn)
    return () => reconnectListeners.delete(fn)
  }

  function onPresence(fn: Listener) {
    presenceListeners.add(fn)
    return () => presenceListeners.delete(fn)
  }

  return { ensure, onMessage, onReconnected, onPresence, freshUploadToken, state, identity, uploadToken, lobbyTaskId }
}
