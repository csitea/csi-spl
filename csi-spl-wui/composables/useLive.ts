import { createLiveClient, wsUrl } from '~/utils/live-ws.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { MOCK_LOBBY_TASK_ID } from '~/utils/mock-data.mjs'

/** Display name for 2-session interop: ?as=<name>, remembered for the tab. */
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
  const clean = (s: string) => s.trim().replace(/[^A-Za-z0-9._-]/g, '').slice(0, 32)
  let name = clean(q) || clean(stored)
  if (!name) name = `guest-${Math.random().toString(16).slice(2, 6)}`
  try {
    sessionStorage.setItem(AS_KEY, name)
  } catch {
    /* memory only */
  }
  return name
}

type Listener = (m: Record<string, unknown>) => void

let live: ReturnType<typeof createLiveClient> | null = null
const listeners = new Set<Listener>()
const state = ref('idle')
const identity = ref('')
const uploadToken = ref('')
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
      state.value = 'mock'
      return null
    }
    if (live) return live
    if (!api.base) {
      state.value = api.configError || 'no_base'
      return null
    }
    live = createLiveClient({
      url: wsUrl(api.base),
      token: api.token || '',
      as: identity.value,
      onState: (s: string) => { state.value = s },
      onWelcome: (w: Record<string, unknown>) => {
        if (typeof w.upload_token === 'string') uploadToken.value = w.upload_token
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

  function onMessage(fn: Listener) {
    listeners.add(fn)
    return () => listeners.delete(fn)
  }

  return { ensure, onMessage, state, identity, uploadToken, lobbyTaskId }
}
