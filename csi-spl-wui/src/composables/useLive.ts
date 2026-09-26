import { cleanAs, createLiveClient, tokenStale, wsUrl } from '~/utils/live-ws.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { MOCK_LOBBY_TASK_ID } from '~/utils/mock-data.mjs'

/**
 * Identity for 2-session interop: ?as=HUM-2 (a v:1 agent id, wui-live-ws §2),
 * remembered for the tab. Absent/invalid → the hub assigns a guest GST-<n>; welcome.as wins.
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
/** CLE-3425 `channel` frames ({ channel, name, created_at }): a channel created in the tenant. */
const channelListeners = new Set<Listener>()
/** CLE-3445 `message_edited` frames: a REPLACEMENT for a row the screen already holds. */
const editedListeners = new Set<Listener>()
/** `message_deleted` frames: drop a row the screen is showing. */
const deletedListeners = new Set<Listener>()
/** SPL-983 `topic_archived` / `topic_deleted` frames. */
const topicListeners = new Set<Listener>()
/** `message_reaction` frames: replace the emoji list on a row already held. */
const reactionListeners = new Set<Listener>()
/** issues-v1 §5: an issue was created or updated in this tenant. */
const issueListeners = new Set<Listener>()
/** issues-v1 §5: a label was added to the tenant catalogue. */
const issueLabelListeners = new Set<Listener>()
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
    live = createLiveClient({
      url: wsUrl(api.base),
      token: api.token || '',
      as: identity.value,
      onState: (s: string) => { state.value = s },
      // live-ws fires this after the re-subscribes (subscribe first, then read)
      onReconnected: () => {
        for (const fn of reconnectListeners) fn()
      },
      onPresence: (f) => {
        for (const fn of presenceListeners) fn(f as unknown as Record<string, unknown>)
      },
      onChannel: (f) => {
        for (const fn of channelListeners) fn(f as unknown as Record<string, unknown>)
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
      onEdited: (m: Record<string, unknown>) => {
        for (const fn of editedListeners) fn(m)
      },
      onDeleted: (m: Record<string, unknown>) => {
        for (const fn of deletedListeners) fn(m)
      },
      onTopic: (f: Record<string, unknown>) => {
        for (const fn of topicListeners) fn(f)
      },
      onReaction: (m: Record<string, unknown>) => {
        for (const fn of reactionListeners) fn(m)
      },
      onIssue: (f: Record<string, unknown>) => {
        for (const fn of issueListeners) fn(f)
      },
      onIssueLabel: (f: Record<string, unknown>) => {
        for (const fn of issueLabelListeners) fn(f)
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

  /** CLE-3425: a channel created anywhere in the tenant, for the sidebar. */
  function onChannel(fn: Listener) {
    channelListeners.add(fn)
    return () => channelListeners.delete(fn)
  }

  /**
   * CLE-3445: another session edited a message this one is showing. Kept
   * apart from onMessage because an edit is a replacement and every
   * onMessage listener merges by appending — see applyEdit in msg-edit.mjs.
   */
  function onEdited(fn: Listener) {
    editedListeners.add(fn)
    return () => editedListeners.delete(fn)
  }

  function onDeleted(fn: Listener) {
    deletedListeners.add(fn)
    return () => deletedListeners.delete(fn)
  }
  function onTopic(fn: Listener) {
    topicListeners.add(fn)
    return () => topicListeners.delete(fn)
  }

  function onReaction(fn: Listener) {
    reactionListeners.add(fn)
    return () => reactionListeners.delete(fn)
  }

  function onIssue(fn: Listener) {
    issueListeners.add(fn)
    return () => issueListeners.delete(fn)
  }

  function onIssueLabel(fn: Listener) {
    issueLabelListeners.add(fn)
    return () => issueLabelListeners.delete(fn)
  }

  return { ensure, onMessage, onEdited, onDeleted, onTopic, onReaction, onIssue, onIssueLabel, onReconnected, onPresence, onChannel, freshUploadToken, state, identity, uploadToken, lobbyTaskId }
}
