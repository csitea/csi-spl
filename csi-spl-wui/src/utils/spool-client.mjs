import { noteError } from '../composables/errorJournal.mjs'
import { isAbortError } from '../composables/apiHealth.mjs'
import { belongsTo, parseMention } from './channel-feed.mjs'
import { dmPointerRows, mockDmPointers } from './dm-pointer.mjs'
import { isAgentId } from './agent-id.mjs'
import {
  channelReadQuery,
  channelsFromView,
  normalizeTopicRow,
  normalizeViewMessage,
  rosterFromView,
  topicMessages,
  topicsFromMessages,
} from './view-api.mjs'
import { storageGetJson } from './prefs.mjs'
import { MOCK_CHANNEL_ORDER_KEY, normalizeChannelOrder } from './channel-order.mjs'
import { noteLastData } from './last-data.mjs'

/**
 * P3-30: the client methods that live in spool-client-lazy.mjs (writers,
 * admin, issues - no first screen calls one). Each is a stub here that loads
 * that chunk on its first call; the names match that module's one export.
 */
const LAZY_METHODS = [
  'lookupIds',
  'previewLinks',
  'setChannelOrder',
  'removeMember',
  'listTenantUsers',
  'inviteTenantUser',
  'setTenantUserRole',
  'removeTenantUser',
  'resetTenantUserPassword',
  'auditClones',
  'memberActivity',
  'revokeTenantInvite',
  'patchTenantUser',
  'getTenantSettings',
  'patchTenantSettings',
  'getMarketingSwitch',
  'patchMarketingSwitch',
  'mintJoinToken',
  'listJoinTokens',
  'revokeJoinToken',
  'revokeSeat',
  'listTenantChannels',
  'setTenantChannelNoFallback',
  'archiveTenantChannel',
  'getPerfSummary',
  'boxStats',
  'getFleetLoad',
  'patchFleetLoad',
  'listOperatorWorkspaces',
  'createOperatorWorkspace',
  'patchOperatorWorkspace',
  'archiveOperatorWorkspace',
  'editMessage',
  'deleteMessage',
  'mergeMessage',
  'archiveTopic',
  'topicSize',
  'deleteTopic',
  'moveTopic',
  'moveMessage',
  'mergeTopic',
  'mergeUndo',
  'promoteTopic',
  'promoteUndo',
  'moveInfo',
  'listArchived',
  'setMessageKind',
  'setReaction',
  'createChannel',
  'listChannelMembers',
  'addChannelMember',
  'addChannelAgent',
  'removeChannelMember',
  'removeChannelAgent',
  'setMembersOpenInvite',
  'deleteChannel',
  'archiveChannel',
  'unarchiveChannel',
  'listIssues',
  'getIssue',
  'createIssue',
  'updateIssue',
  'deleteIssue',
  'archiveIssue',
  'createIssueLabel',
  'listFlow',
  'markFlow',
]

function uuid() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

export async function sha256Hex(buf) {
  const d = await globalThis.crypto.subtle.digest('SHA-256', buf)
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/**
 * fetch credentials for a view door (view-v1 §2, 010 FR-009): the `session`
 * door rides the sign-in cookie, so it needs 'include' (credentialed CORS,
 * OQ-A1); `off` / `token` send no cookies (the token is a header).
 */
export function credentialsFor(door) {
  return door === 'session' ? 'include' : 'omit'
}

/**
 * Per-topic reads listMessages keeps in flight. The api host speaks HTTP/2,
 * so this is the client's own cap, not the browser's: at 6 a 20-topic page
 * went out in four serial waves (~70-100 ms each on dev).
 */
export const TOPIC_READS_IN_FLIGHT = 10

/** view-v1 §4.3 v0.6.1: the largest `per_topic` the hub accepts (hub/view.go perTopicMax). */
export const PER_TOPIC_MAX = 50

/**
 * spec 109 T004: how long after the client is made a settled roster or
 * topic-list read is reused (live). The prd first screen (W1) is ~5 s.
 */
export const FIRST_SCREEN_MS = 10000

/** The reads kept for the first screen: the roster and the topic list (not one topic). */
const FIRST_SCREEN_READ = /^\/v1\/view\/(roster$|topics\?)/

/** A joiner's copy of a shared read (live): JSON-shaped bodies are cloned, the rest passed as is. */
function cloneBody(v) {
  if (v === null || typeof v !== 'object' || v instanceof ArrayBuffer) return v
  return typeof structuredClone === 'function' ? structuredClone(v) : JSON.parse(JSON.stringify(v))
}

/** Up to `n` async jobs at a time, results in input order. */
async function pool(items, n, job) {
  const out = new Array(items.length)
  let next = 0
  async function worker() {
    while (next < items.length) {
      const i = next++
      out[i] = await job(items[i])
    }
  }
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker))
  return out
}

/**
 * store.ChannelPublic: the default channels, and `issues` - the reserved id
 * every issue's discussion is stored under (spec 039 §3.4), which no channel
 * list shows. `general` is the lobby alias. #tasks is gone (SPL-68).
 */
const PUBLIC_CHANNELS = new Set(['lobby', 'alerts', 'feedback', 'issues'])

export function normalizeChannelId(channel) {
  const id = String(channel || '').replace(/^#/, '').trim().toLowerCase()
  return id === 'general' ? 'lobby' : id
}

export function isPublicChannel(channel) {
  return PUBLIC_CHANNELS.has(normalizeChannelId(channel))
}

/** Every id on the tenant roster, boxes in object order. */
export function rosterHumanIds(roster) {
  const out = []
  if (!roster || typeof roster !== 'object') return out
  for (const bag of Object.values(roster)) {
    if (!Array.isArray(bag)) continue
    for (const id of bag) out.push(String(id || ''))
  }
  return out
}

/**
 * Live mode talks to the tenant hub: the 003 viewer API (contracts/view-v1.md:
 * /v1/view/*, GET /v1/files/{file_id}, /v1/health — FR-023: Cloud Run shadows
 * /healthz), POST /v1/channels (channels-v1 §5.1), and sends over the WUI
 * socket (wui-live-ws §4) through an injected `sender` (live-ws `send`).
 * The view token rides in Authorization; cookies only for the `session`
 * door (credentialsFor).
 */
export function createSpoolClient({
  base = '',
  fetchFn = globalThis.fetch,
  mock = true,
  token = '',
  tenant = '',
  configError = '',
  door = '',
  sender = null,
  firstScreenMs = FIRST_SCREEN_MS,
  now = Date.now,
} = {}) {
  /* P3-15: the mock tenant's data loads with the first mock call, not in
     every live first load; each async method waits for it (gateMock).
     Member access only (data.<name>): a bare mock-data export name here
     makes Nuxt's utils/ auto-import add a STATIC import of mock-data.mjs
     (tests/unit/initial-js-trims.test.mjs). */
  let state = null
  const mockReady = mock
    ? import('./mock-data.mjs').then((data) => {
      state = data.cloneMock()
      /* test hook (mock only): an e2e adds lines to the mock feed with
         localStorage `spool.mock.extra-messages` (a JSON array of rows) */
      const extra = storageGetJson('spool.mock.extra-messages', [])
      if (Array.isArray(extra)) state.messages.push(...extra.filter((m) => m && m.msg_id))
      state.memberships = Object.create(null)
      state.openInvite = Object.create(null)
      state.agentMembers = Object.create(null)
    })
    : null
  const mockBlobs = new Map()
  let mockIssues = null
  let mockFactory = null
  const issuesMock = () => {
    if (!mockIssues) {
      if (typeof mockFactory !== 'function') throw Object.assign(new Error('issues mock is not bound'), { status: 500, token: 'no_mock' })
      mockIssues = mockFactory((state && state.me && state.me.id) || 'HUM-1')
    }
    return mockIssues
  }
  let mockDir = null
  const dir = async () => (mockDir ||= (await import('./tenant-users-mock.mjs')).createMockDirectory())
  let mockTenant = null
  const tenantMock = async () => (mockTenant ||= (await import('./tenant-settings-mock.mjs')).createMockTenant())
  const root = String(base || '').replace(/\/+$/, '')
  let viewToken = String(token || '')
  let viewDoor = String(door || '')
  /* a door set from a signed-in session probe, not yet proven by a
     read. withSessionRetry takes it back if the hub refuses credentials. */
  let doorGuessed = false
  let send = sender
  const rawFetch = fetchFn
  async function hubFetch(url, init) {
    if (typeof rawFetch !== 'function') throw new Error('no fetch')
    const res = await rawFetch(url, init)
    // One number per hub 2xx. Callers do not stamp themselves.
    if (res && res.ok) noteLastData()
    return res
  }
  /** GET reads in flight, by what makes them identical (see live). */
  const inflight = new Map()
  /** First-screen reads that have settled, by the same key (see live). */
  const settled = new Map()
  const bornAt = now()

  /* Owner, 2026-09-25, prd v0.5.5: four "Failed to fetch" in the diagnostics
     (routes /dm/CLE-001, /dm/CLE-100, /channel/spool-hub-devel) and not one
     matching failure in the hub request log - every /v1/view read at those
     seconds answered 200. The browser's TypeError names no request, so the
     report could not be matched to anything. Now a transport failure is
     journaled with its method and path (errorJournal redacts both), and an
     idempotent GET gets ONE retry after a short pause: a dropped connection
     on a read never reaches the reader. A write is never retried - it may
     have landed. An abort is not a failure and is rethrown untouched. */
  async function fetchOnce(fn, url, init) {
    const method = String((init && init.method) || 'GET').toUpperCase()
    try {
      return await fn(url, init)
    } catch (err) {
      if (isAbortError(err)) throw err
      if (method === 'GET') {
        await new Promise((r) => setTimeout(r, 400))
        try {
          return await fn(url, init)
        } catch (again) {
          if (isAbortError(again)) throw again
          noteError({ source: 'api', method, url, error: again })
          throw again
        }
      }
      noteError({ source: 'api', method, url, error: err })
      throw err
    }
  }

  /*
   * (perf P1, measured on dev 947635e7): one cold /lobby asked for
   * /v1/view/roster six times and channels / me / operators / the DM list
   * twice each, because the shell, the plugins and the page each read what
   * they need at the same moment. A GET that is identical to one already in
   * flight (same path, headers, door and token) now joins it instead of going
   * out again. The first caller gets the parsed body; every joiner gets its
   * own structured clone, so no caller can mutate another one's rows. A read
   * with an AbortSignal, and every write, always goes out on its own.
   *
   * (spec 109 T004, D7/D8): prd still read the roster twice per load and the
   * topic list twice per first screen, because the second caller started
   * after the first read had settled, so it had nothing to join. During the
   * first screen (firstScreenMs after the client is made) a settled roster or
   * topic-list read is kept and handed out as a clone. Any write drops it,
   * and after the first screen every read goes out as before.
   */
  function live(path, opts) {
    const method = String((opts && opts.method) || 'GET').toUpperCase()
    if (method !== 'GET' || (opts && opts.signal)) {
      settled.clear()
      return liveOnce(path, opts)
    }
    const key = [viewDoor, viewToken, path, JSON.stringify((opts && opts.headers) || {})].join('\n')
    const hit = inflight.get(key) || keptRead(key)
    if (hit) return hit.then(cloneBody)
    const run = liveOnce(path, opts)
    inflight.set(key, run)
    const done = () => { if (inflight.get(key) === run) inflight.delete(key) }
    run.then(done, done)
    if (FIRST_SCREEN_READ.test(path) && inFirstScreen()) {
      run.then((body) => { if (inFirstScreen()) settled.set(key, cloneBody(body)) }, () => {})
    }
    return run
  }

  function inFirstScreen() {
    if (now() - bornAt < firstScreenMs) return true
    settled.clear()
    return false
  }

  /** A settled first-screen read as a promise, or null. */
  function keptRead(key) {
    return settled.has(key) && inFirstScreen() ? Promise.resolve(settled.get(key)) : null
  }

  async function liveOnce(path, opts) {
    const fn = hubFetch
    if (typeof fn !== 'function') throw new Error('no fetch')
    if (configError) {
      const err = new Error(`spool config ${configError}`)
      err.status = 0
      err.token = configError
      throw err
    }
    const headers = { accept: 'application/json', ...(opts && opts.headers) }
    if (viewToken) headers.authorization = `Bearer ${viewToken}`
    const res = await fetchOnce(fn, `${root}${path}`, { credentials: credentialsFor(viewDoor), ...opts, headers })
    if (!res.ok) {
      let token = ''
      let detail = ''
      let permission = ''
      let pos
      let bad = ''
      try {
        const body = await res.json()
        token = (body && body.error) || ''
        detail = (body && body.detail) || ''
        if (body && typeof body.permission === 'string') permission = body.permission
        // search-v1 §5.1: bad_query points at the offending token
        if (body && Number.isInteger(body.pos)) pos = body.pos
        if (body && typeof body.token === 'string') bad = body.token
      } catch {
        /* not json */
      }
      const err = new Error(`spool ${res.status} ${token || path}`)
      err.status = res.status
      err.token = token
      err.detail = detail
      if (permission) err.permission = permission
      if (pos !== undefined) err.pos = pos
      if (bad) err.badToken = bad
      if (res.status === 429) err.retryAfter = Number(res.headers.get('retry-after')) || 0
      throw err
    }
    if (res.status === 204) return null
    const ct = res.headers.get('content-type') || ''
    if (ct.includes('application/json')) return res.json()
    return res.arrayBuffer()
  }

  const api = {
    mock: Boolean(mock),
    tenant: String(tenant || ''),
    base: root,
    get token() {
      return viewToken
    },
    configError: String(configError || ''),
    setToken(t) {
      viewToken = String(t || '')
    },
    get door() {
      return viewDoor
    },
    /** view door (`off` | `token` | `session`); `session` → credentials 'include'. */
    setDoor(d) {
      viewDoor = String(d || '')
      doorGuessed = false
    },
    /**
     * set the door BEFORE the first read, from a signed-in session
     * probe, so a cold load does not spend one 401 per shell read discovering
     * it. Only an unset door is guessed; withSessionRetry takes the guess back
     * when a read under it fails without an HTTP status (a token door's CORS
     * refusing credentials) and falls back to discovering the door.
     */
    guessDoor(d) {
      if (viewDoor) return
      viewDoor = String(d || '')
      doorGuessed = Boolean(viewDoor)
    },
    get doorGuessed() {
      return doorGuessed
    },
    get credentials() {
      return credentialsFor(viewDoor)
    },
    /** fn(frame) → ack: the live-ws client's `send` (wui-live-ws §4). */
    setSender(fn) {
      send = typeof fn === 'function' ? fn : null
    },
    hasToken() {
      return Boolean(viewToken)
    },
    async healthz() {
      if (mock) return { ok: true, mock: true }
      return live('/v1/health')
    },
    /**
     * view-v1 §4.3. `perTopic` (1..PER_TOPIC_MAX) asks the hub to inline each
     * topic's newest N messages (v0.6.1); a row then carries `inline` =
     * { messages, next }, exactly what getTopic(id, { order: 'desc', limit: N })
     * returns. A hub without it ignores the parameter and rows carry no
     * `inline` (callers read those topics one by one, as before).
     */
    async listTopics({ limit = 50, before, channel, dm, peer, agent, roots, perTopic = 0, dmCounts = false, dmRead = [], since, rx = [] } = {}) {
      if (mock) {
        let rows = state.messages.slice()
        if (channel) rows = rows.filter((m) => m.channel === channel)
        else if (dm) rows = rows.filter((m) => !m.channel)
        if (peer) {
          const [id] = String(peer).split('@')
          rows = rows.filter((m) => m.from === id || m.to === id)
        }
        return { topics: topicsFromMessages(rows).slice(0, limit), next: null }
      }
      const q = new URLSearchParams()
      if (limit) q.set('limit', String(limit))
      if (before) q.set('before', before)
      if (channel) q.set('channel', channel)
      if (dm) q.set('dm', 'true')
      if (peer) q.set('peer', peer)
      if (agent) q.set('agent', agent)
      if (roots === false) q.set('roots', 'false')
      const inlineN = Number(perTopic) || 0
      if (inlineN >= 1 && inlineN <= PER_TOPIC_MAX) q.set('per_topic', String(inlineN))
      /* DB payload cut 1: the hub counts the per-peer DM unread/total against our dm_read= cursors */
      if (dmCounts) {
        q.set('dm_counts', 'true')
        for (const mark of dmRead || []) q.append('dm_read', String(mark))
      }
      /* R2-2: a reconnect asks for the topics changed after its newest cursor */
      if (since) {
        q.set('since', String(since))
        for (const r of rx || []) q.append('rx', String(r))
      }
      const data = await live(`/v1/view/topics?${q}`)
      const rows = (data && data.topics) || []
      return {
        topics: rows.map((raw) => {
          const row = normalizeTopicRow(raw)
          if (raw && raw.dm && typeof raw.dm === 'object') row.dm = raw.dm
          if (inlineN && raw && Array.isArray(raw.messages)) {
            row.inline = { task_id: row.task_id, messages: raw.messages.map((m) => normalizeViewMessage(m, row.task_id)), next: raw.messages_next || null }
          }
          return row
        }),
        next: (data && data.next) || null,
        /* R2-2: true = only the changed topics; false / absent = the full page */
        delta: !!(data && data.delta === true),
        goneTasks: (data && Array.isArray(data.gone_tasks) && data.gone_tasks) || [],
        goneMsgs: (data && Array.isArray(data.gone_msgs) && data.gone_msgs) || [],
        sync: (data && typeof data.sync === 'string' && data.sync) || '',
        /* dc6d5e3f: ?dm=true&peer= only - the channel lines between the reader and that agent */
        pointers: (data && Array.isArray(data.pointers) ? data.pointers : []).map((m) => normalizeViewMessage(m, '')),
      }
    },
    /**
     * view-v1 §4.4. Default: oldest first, `after=` for catch-up. With
     * `order: 'desc'`: the newest `limit` newest-first; `next` → pass as `before`
     * for the next older window (013 reverse prepend; hub 1dca945).
     */
    async getTopic(taskId, { limit = 200, after, order, before } = {}) {
      const id = String(taskId || '')
      if (!id) throw new Error('task_id required')
      if (mock) {
        /* t1 404cd808: the hub's topic read keeps the topic's own archived
           card (only the lobby feed hides archived rows), so the mock does too */
        const all = topicMessages([...state.messages, ...(state.archived || [])], id)
        /* t1 8fb802cd: the hub's archive stamp, as its own rule reads it */
        const arch = (state.archived || []).find((m) => m.archived_at && (m.msg_id === id || m.task_id === id))
        const stamp = arch && !after ? { archived_at: arch.archived_at, archived_by: arch.archived_by } : {}
        if (order !== 'desc') return { task_id: id, messages: all, next: null, ...stamp }
        const desc = all.slice().reverse()
        const start = before ? desc.findIndex((m) => m.msg_id === before) + 1 : 0
        const page = desc.slice(start, start + limit)
        const more = start + limit < desc.length
        return { task_id: id, messages: page, next: more && page.length ? page[page.length - 1].msg_id : null, ...stamp }
      }
      const q = new URLSearchParams()
      if (order === 'desc') q.set('order', 'desc')
      if (limit) q.set('limit', String(limit))
      if (after) q.set('after', after)
      if (before) q.set('before', before)
      let data
      try {
        data = await live(`/v1/view/topics/${encodeURIComponent(id)}?${q}`)
      } catch (e) {
        // rdb 0028: a topic you may not read answers 404, exactly as one
        // that does not exist does - the hub will not tell a non-member
        // which of the two it is. An empty topic is the honest rendering;
        // an error toast would leak that something IS there.
        if (e && e.status === 404) return { task_id: id, messages: [], next: null }
        throw e
      }
      const rows = (data && data.messages) || []
      const out = { task_id: id, messages: rows.map((m) => normalizeViewMessage(m, id)), next: (data && data.next) || null }
      /* t1 8fb802cd: a topic read by its id answers while archived; the stamp marks it */
      if (data && data.archived_at) Object.assign(out, { archived_at: String(data.archived_at), archived_by: String(data.archived_by || '') })
      return out
    },
    /**
     * specs/025 FR-006: the caller's role and permissions in the active
     * tenant. Mock / a hub without the route (404): null = unrestricted.
     */
    async me() {
      if (mock) {
        /* the mock answer (act-as, role + permissions, archive policy) lives
           in the lazy act-as-mock.mjs: none of it rides the initial JS */
        const { mockMe } = await import('./act-as-mock.mjs')
        return mockMe(dir)
      }
      try {
        return await live('/v1/view/me')
      } catch (e) {
        if (e && e.status === 404) return null
        throw e
      }
    },
    /**
     * SPL-1034: the lde mock's stored channel order (the live one rides
     * /v1/view/me `channel_order`). null = never set.
     */
    mockChannelOrder() {
      if (!mock) return null
      const raw = storageGetJson(MOCK_CHANNEL_ORDER_KEY, null)
      return Array.isArray(raw) ? normalizeChannelOrder(raw) : null
    },
    /**
     * channels-v1 §5.2. `read` = { channel: last-read cursor } (client-held,
     * OQ-CH2) → repeated `read=<ch>~<cursor>`; rows keep unread / last_cursor /
     * retention_days.
     */
    async listChannels({ read } = {}) {
      if (mock) return state.channels.slice()
      const q = new URLSearchParams()
      for (const r of channelReadQuery(read)) q.append('read', r)
      const qs = q.toString()
      return channelsFromView(await live(`/v1/view/channels${qs ? `?${qs}` : ''}`))
    },
    /**
     * Flat messages of a channel (`?channel=`) or a DM peer (`?dm=true&peer=`),
     * oldest first, at most `limit`: one page of `topics` topics from the
     * view list (view-v1 §4.3), each read newest-first (§4.4) and merged.
     * `next` is the §4.3 cursor — pass it as `before` for the next older
     * window of topics, until `next` is null. Mock has no server pages.
     * `changedSince` + `rx` (R2-2, channel-feed catchUpQuery): only the topics
     * changed after that cursor; `delta` says whether the hub answered so.
     */
    async listMessages({ channel, peer, limit = 50, since, topics = 20, before, changedSince, rx } = {}) {
      if (mock) {
        /* the same test hook, read again: a line an e2e adds after boot is
           held as the hub would hold a reply its socket just delivered */
        const extra = storageGetJson('spool.mock.extra-messages', [])
        if (Array.isArray(extra)) {
          const held = new Set(state.messages.map((m) => m.msg_id))
          state.messages.push(...extra.filter((m) => m && m.msg_id && !held.has(m.msg_id)))
        }
        let rows = state.messages.slice()
        if (channel) rows = rows.filter((m) => m.channel === channel)
        /* specs/058: a DM is per <ID>@<box>, as the hub's peer filter is */
        /* dc6d5e3f: plus the channel lines between me and that agent, as pointers */
        else if (peer) rows = [...rows.filter((m) => belongsTo(m, { peer: String(peer) })), ...mockDmPointers(rows, state.me && state.me.id, String(peer))]
        if (since) rows = rows.filter((m) => m.ts > since)
        return { messages: rows.slice(-limit), next: null }
      }
      const filter = channel ? { channel } : peer ? { dm: true, peer: String(peer) } : {}
      /* CLE-34984 / T122: one request for the whole page where the hub
         inlines each topic's newest `limit` messages; a topic the answer
         carries no messages for is read on its own, as before. */
      const delta = changedSince && !before ? { since: changedSince, rx } : {}
      const list = await api.listTopics({ limit: topics, before, perTopic: limit <= PER_TOPIC_MAX ? limit : 0, ...filter, ...delta })
      /* A topic is read newest first, so one with more messages than `limit`
         loses its opening line - and with it the middle card, because every
         later line may be is_parent 0. The oldest message is read on its own
         then. A page that already holds the whole topic costs nothing more. */
      const pages = await pool(list.topics, TOPIC_READS_IN_FLIGHT, async (t) => {
        const page = t.inline || await api.getTopic(t.task_id, { order: 'desc', limit })
        if (!(Number(t.count) > page.messages.length)) return page
        const first = await api.getTopic(t.task_id, { limit: 1 })
        return { ...page, messages: [...page.messages, ...first.messages] }
      })
      const seen = new Set()
      const out = []
      /* dc6d5e3f: a DM view's pointers - the channel lines between the reader
         and the agent - each a card of its own topic, never a copy */
      const pointed = peer ? [{ messages: dmPointerRows(list.pointers) }] : []
      for (const page of [...pages, ...pointed]) {
        for (const m of page.messages) {
          if (m.msg_id && seen.has(m.msg_id)) continue
          if (m.msg_id) seen.add(m.msg_id)
          if (since && !(String(m.ts) > since)) continue
          out.push(m)
        }
      }
      out.sort((a, b) => String(a.received_at || a.ts).localeCompare(String(b.received_at || b.ts)))
      /* The cap keeps the newest `limit` lines, but never drops a topic's
         opening line: that line is the topic's middle card. */
      const opener = new Set()
      const seenTask = new Set()
      for (const m of out) {
        if (!m.task_id || seenTask.has(m.task_id)) continue
        seenTask.add(m.task_id)
        opener.add(m)
      }
      const cut = out.length - limit
      /* SPL-1008: the cut drops an older topic's middle replies, so the card
         count comes from the hub's row (topicReplies), not from held lines. */
      const totals = {}
      for (const t of list.topics) if (t.task_id) totals[t.task_id] = { count: Number(t.count) || 0, last_ts: String(t.last_ts || '') }
      return { messages: out.filter((m, i) => i >= cut || opener.has(m)), next: list.next || null, totals,
        delta: list.delta, goneTasks: list.goneTasks, goneMsgs: list.goneMsgs, sync: list.sync }
    },
    /**
     * 022 global search: `GET /v1/view/search?q=<raw>` (search-v1.md, the hub
     * parses the grammar). → normalizeSearchResponse. Mock: the lde matcher.
     */
    async search({ q = '', cursor = '', limit = 0, sort = '' } = {}) {
      // The result half loads on the first search, never on the first paint (027 budget).
      const { mockSearch, normalizeSearchResponse } = await import('./search-results.mjs')
      if (mock) return normalizeSearchResponse(mockSearch(state.messages, q, state.channels))
      // 027 budget: the search grammar (search.mjs + its mention autocomplete)
      // rides the first search, not the initial chunk.
      const { searchApiQuery } = await import('./search.mjs')
      return normalizeSearchResponse(await live(`/v1/view/search?${searchApiQuery({ q, cursor, limit, sort })}`))
    },
    /** search-v1 §6 grammar-as-data → the autocomplete catalogue. */
    async searchOperators() {
      if (mock) {
        const { SEARCH_OPERATORS } = await import('./search.mjs')
        return SEARCH_OPERATORS
      }
      const { normalizeOperators } = await import('./search-results.mjs')
      return normalizeOperators(await live('/v1/view/search/operators'))
    },
    async listRoster() {
      // CLE-77794: the People/Agents sections read the per-member detail
      // (interests, last_seen, owner) and the per-box detail (online,
      // last_hello_at) alongside the mapped roster. rosterFromView stays the
      // pure mapper; the raw humans[]/boxes[] ride along unchanged.
      if (mock) return { roster: state.roster, online: state.online, me: state.me, humans: state.humans || [], boxes: state.boxes || [] }
      const body = await live('/v1/view/roster')
      return {
        ...rosterFromView(body),
        humans: Array.isArray(body && body.humans) ? body.humans : [],
        boxes: Array.isArray(body && body.boxes) ? body.boxes : [],
      }
    },
    /**
     * The view-v1 §4.1 roster body as the hub sent it (`humans` included):
     * what the avatars and display names read. Same request as listRoster,
     * so the two join one read when they overlap (live).
     */
    async rosterView() {
      if (mock) return null
      return live('/v1/view/roster')
    },
    /**
     * Post into a channel (`channel`), a DM (`peer`, no channel) or an existing
     * topic (`task_id`); a new post starts a new task. `parent_task_id` links a
     * CHILD task (channels-v1 §0), it does not topic a reply. Live: one
     * wui-live-ws §4 `send` frame via the injected sender; resolves with the
     * flat message plus the ack's cursor / received_at.
     */
    async sendMessage({ channel, peer, text, task_id, parent_task_id, is_parent, files, from, msg_id } = {}) {
      const parsed = parseMention(text)
      const peerId = peer ? String(peer).split('@')[0] : ''
      const to = peer ? peerId : parsed.to
      /* specs/058: the DM peer's box, or the one a leading @ID@box named */
      const toBox = peer ? (String(peer).includes('@') ? String(peer).split('@')[1] : undefined) : parsed.toBox
      const kind = 'note' /* owner 2026-09-26 (topic 1a9a8a84): a person's post is a note; re-type it from the card's kind badge */
      const body = peer ? String(text || '') : parsed.body
      if (mock) {
        /* 080 T006: the hub de-dupes by msg_id, so a resend of a held send
           (same msg_id) stores nothing new - the mock does the same */
        const dup = msg_id ? state.messages.find((m) => m.msg_id === msg_id) : null
        if (dup) return dup
        /* spec 068: what the hub's insert stores - <to>@<to_box> for a
           message to one agent; the mock reads a bare peer's box off the roster */
        const seatBox = toBox || Object.keys(state.roster || {}).find((b) => (state.roster[b] || []).includes(to))
        const row = {
          v: 1,
          msg_id: msg_id || uuid(),
          task_id: task_id || uuid(),
          ts: new Date().toISOString(),
          from: state.me.id,
          from_box: state.me.box,
          to,
          to_box: toBox,
          kind,
          body,
          files: files || [],
          channel: channel || null,
          parent_task_id: parent_task_id || null,
          ...(is_parent === 0 || is_parent === 1 ? { is_parent } : {}),
          ...(isAgentId(to) && seatBox ? { responsible: `${to}@${seatBox}` } : {}),
        }
        state.messages.push(row)
        return row
      }
      if (typeof send !== 'function') {
        throw Object.assign(new Error('live send needs the WUI socket (setSender)'), { status: 0, token: 'no_socket' })
      }
      const frame = { task_id: task_id || uuid(), kind, body, files: files || [] }
      if (msg_id) frame.msg_id = msg_id
      if (to && to !== '@channel') frame.to = to
      // specs/058: a DM peer is <ID>@<box>; the box pins the route, because the
      // reserved ids CLE-001..003 run on every box (a bare id would be ambiguous_to_box).
      if (frame.to && toBox) frame.to_box = toBox
      if (channel) frame.channel = String(channel)
      if (parent_task_id) frame.parent_task_id = String(parent_task_id)
      if (is_parent === 0 || is_parent === 1) frame.is_parent = is_parent
      const ack = (await send(frame)) || {}
      return {
        v: 1,
        msg_id: ack.msg_id || msg_id || '',
        task_id: ack.task_id || frame.task_id,
        ts: ack.received_at || new Date().toISOString(),
        from: from || '',
        from_box: 'box-wui',
        to: frame.to || 'ALL-0',
        to_box: 'box-wui',
        kind,
        body,
        files: frame.files,
        channel: frame.channel || null,
        parent_task_id: frame.parent_task_id || null,
        ...(frame.is_parent === 0 || frame.is_parent === 1 ? { is_parent: frame.is_parent } : {}),
        cursor: ack.cursor,
        received_at: ack.received_at,
      }
    },
    /**
     * Upload one browser File / Blob (003 http-v1 §3: raw bytes, Bearer upload
     * token) → { file_id, sha256, bytes }. Mock keeps the bytes in memory.
     */
    async uploadFile(file, uploadToken = '') {
      const buf = await file.arrayBuffer()
      if (mock) {
        const hex = await sha256Hex(buf)
        mockBlobs.set(hex, new Blob([buf]))
        return { file_id: hex, sha256: hex, bytes: buf.byteLength }
      }
      if (configError) {
        throw Object.assign(new Error(`spool config ${configError}`), { status: 0, token: configError })
      }
      const headers = { accept: 'application/json', 'content-type': 'application/octet-stream' }
      if (uploadToken) headers.authorization = `Bearer ${uploadToken}`
      const res = await hubFetch(`${root}/v1/files`, { method: 'POST', credentials: 'omit', headers, body: buf })
      if (!res.ok) {
        let tok = ''
        try { tok = (await res.json()).error || '' } catch { /* not json */ }
        throw Object.assign(new Error(`spool ${res.status} ${tok || '/v1/files'}`), { status: res.status, token: tok })
      }
      return res.json()
    },
    /**
     * Download bytes for a blob file_id (mock: the in-memory copy). The hub
     * wants a caller credential (017 FR-SEC-002): the member session cookie,
     * so the view door's credentials ('include' in the `session` door).
     */
    async downloadFile(fileId) {
      const id = String(fileId || '')
      if (mock) {
        const b = mockBlobs.get(id)
        if (!b) throw Object.assign(new Error('not in mock store'), { status: 404 })
        return b.arrayBuffer()
      }
      const res = await hubFetch(`${root}/v1/files/${encodeURIComponent(id)}`, { credentials: credentialsFor(viewDoor) })
      if (!res.ok) throw Object.assign(new Error(`spool ${res.status} /v1/files`), { status: res.status })
      return res.arrayBuffer()
    },
    fileUrl(fileId) {
      return `${root}/v1/files/${encodeURIComponent(String(fileId || ''))}`
    },
    bindIssuesMock(factory) { mockFactory = factory },
  }
  /* P3-30: the stubs of the lazy half. Read as a member: a bare name from a
     utils/ module here makes Nuxt's auto-import add a STATIC import of it. */
  const ctx = { live, mock, get state() { return state }, dir, tenantMock, issuesMock }
  let lazy = null
  const loadLazy = () => (lazy ||= import('./spool-client-lazy.mjs').then(
    (m) => m.lazySpoolMethods,
    (err) => { lazy = null; throw err },
  ))
  for (const name of LAZY_METHODS) api[name] = async (...args) => (await loadLazy())[name](ctx, ...args)
  if (mockReady) gateMock(api, mockReady)
  return api
}

/** P3-15: every async method of a mock client first awaits the mock tenant's data. */
function gateMock(api, ready) {
  for (const [key, d] of Object.entries(Object.getOwnPropertyDescriptors(api))) {
    const fn = d.value
    if (typeof fn !== 'function' || fn[Symbol.toStringTag] !== 'AsyncFunction') continue
    api[key] = async function (...args) {
      await ready
      const out = await fn.apply(this, args)
      // Mock has no HTTP: a method that returns is the response the clock counts.
      noteLastData()
      return out
    }
  }
}
