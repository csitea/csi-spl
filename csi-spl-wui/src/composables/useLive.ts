import { cleanAs, createLiveClient, tokenStale, watchLive, wsUrl } from '~/utils/live-ws.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { authOrigin, createAuthClient } from '~/utils/auth-client.mjs'
import { MOCK_LOBBY_TASK_ID } from '~/utils/mock-ids.mjs'

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
/** spec 062 `flow` frames: the viewer's Flow counts (+ the new event), this member's sockets only. */
const flowListeners = new Set<Listener>()
const state = ref('idle')
const identity = ref('')
const uploadToken = ref('')
const uploadTokenExpiresAt = ref('')
const lobbyFromHub = ref('')
/* the hub's welcome frame arrived: only then does an empty lobby id mean "none" */
const welcomed = ref(false)

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
    if (live) {
      // parked after the hub refused a signed-out tab: a page asking again
      // (after a sign-in, say) dials again
      if (live.state === 'signed_out') live.connect()
      return live
    }
    if (!api.base) {
      state.value = api.configError || 'no_base'
      return null
    }
    // bound here, not via useAuthClient: ensure() also runs outside setup
    const auth = createAuthClient({ base: authOrigin(String(config.public.authBase || '')) })
    live = createLiveClient({
      url: wsUrl(api.base),
      token: api.token || '',
      as: identity.value,
      onState: (s: string) => { state.value = s },
      isSignedOut: async () => (await auth.session()).state === 'out',
      // bug B (4ecb4b0d): the revision serving NEW requests; the socket's own is in its welcome
      fetchRevision: async () => {
        const r = await fetch(`${String(api.base).replace(/\/+$/, '')}/v1/wui/revision`, { cache: 'no-store' })
        if (!r.ok) return ''
        const j = await r.json() as { revision?: unknown }
        return typeof j.revision === 'string' ? j.revision : ''
      },
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
        welcomed.value = true
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
      onFlow: (f: Record<string, unknown>) => {
        for (const fn of flowListeners) fn(f)
      },
    })
    live.connect()
    // bug B: off a retired hub revision, and awake after the tab sleeps
    watchLive(live)
    return live
  }

  /**
   * Upload token for POST /v1/files, refreshed via {type:"token"} when stale
   * (5 min TTL). `force` (CLE-77795) skips the freshness cache and redials onto
   * the live revision — the caller uses it after a 401 'door', where the token
   * looks fresh to us but the process now answering REST never minted it (a hub
   * redeploy). Returns '' when no token can be got (signed out / socket gone),
   * which the upload retry turns into the "session expired" prompt.
   */
  async function freshUploadToken(force = false): Promise<string> {
    const client = ensure()
    if (!client) return ''
    if (!force && uploadToken.value && !tokenStale(uploadTokenExpiresAt.value)) return uploadToken.value
    try {
      const f = (force ? await client.redialForToken() : await client.requestToken()) as Record<string, unknown>
      return typeof f.upload_token === 'string' ? f.upload_token : uploadToken.value
    } catch {
      return ''
    }
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

  /** a channel created anywhere in the tenant, for the sidebar. */
  function onChannel(fn: Listener) {
    channelListeners.add(fn)
    return () => channelListeners.delete(fn)
  }

  /**
   * another session edited a message this one is showing. Kept
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

  function onFlow(fn: Listener) {
    flowListeners.add(fn)
    return () => flowListeners.delete(fn)
  }

  return { ensure, onMessage, onEdited, onDeleted, onTopic, onReaction, onIssue, onIssueLabel, onFlow, onReconnected, onPresence, onChannel, freshUploadToken, state, identity, uploadToken, lobbyTaskId, welcomed }
}
