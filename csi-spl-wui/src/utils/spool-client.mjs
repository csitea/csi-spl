import { noteError } from '../composables/errorJournal.mjs'
import { isAbortError } from '../composables/apiHealth.mjs'
import { cloneMock } from './mock-data.mjs'
import { belongsTo, channelSlug, parseMention } from './channel-feed.mjs'
import {
  channelReadQuery,
  channelsFromView,
  normalizeTopicRow,
  normalizeViewMessage,
  rosterFromView,
  topicMessages,
  topicsFromMessages,
} from './view-api.mjs'
import { storageGetJson, storageSetJson } from './prefs.mjs'
import { CHANNEL_ORDER_MAX, MOCK_CHANNEL_ORDER_KEY, normalizeChannelOrder } from './channel-order.mjs'
/* issues-v1 §4 query - the same as issues.mjs issueQuery (kept here so the
   Issues code stays off the initial script; tests/unit/issues.test.mjs
   checks the two agree). */
function issueQuery(filter = {}, sort = '') {
  const q = new URLSearchParams()
  if (filter.kind) q.set('kind', filter.kind)
  for (const k of ['epic', 'parent', 'status', 'priority', 'level', 'assignee', 'label']) {
    const v = filter[k]
    if (Array.isArray(v) && v.length) q.set(k, v.join(','))
  }
  if (filter.deadlineBefore) q.set('deadline_before', filter.deadlineBefore)
  if (filter.deadlineAfter) q.set('deadline_after', filter.deadlineAfter)
  if (sort && sort !== 'priority') q.set('sort', sort)
  return q.toString()
}

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

const CHANNEL_ERRORS = {
  channel_exists: (slug) => `#${slug} already exists`,
  channel_archived: (slug) => `#${slug} is reserved: an archived channel has this name`,
  bad_channel: (slug) => `"${slug}" is not a valid channel name (a-z, 0-9, "-", max 64)`,
}

/**
 * store.ChannelPublic: the default channels, and `issues` - the reserved id
 * every issue's discussion is stored under (spec 039 §3.4), which no channel
 * list shows. `general` is the lobby alias. #tasks is gone (SPL-68).
 */
const PUBLIC_CHANNELS = new Set(['lobby', 'alerts', 'feedback', 'issues'])
const HUMAN_ID_RE = /^HUM-[0-9]+$/

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
 * CLE-77819 test hook (mock only): the workspace "Who can archive topics" an
 * e2e opts into with localStorage `spool.mock.archive_policy`; '' = off.
 */
function mockArchivePolicy() {
  try {
    const v = typeof localStorage !== 'undefined' ? String(localStorage.getItem('spool.mock.archive_policy') || '') : ''
    return ['everyone', 'admins', 'starter'].includes(v) ? v : ''
  } catch { return '' }
}

/**
 * CLE-77891 test hook (mock only), next to the archive policy: the mock
 * member's role ('admin' | 'developer', default developer) an e2e opts into
 * with localStorage `spool.mock.role`. Read only when the policy hook is on.
 */
function mockRole() {
  try {
    const v = typeof localStorage !== 'undefined' ? String(localStorage.getItem('spool.mock.role') || '') : ''
    return ['admin', 'developer'].includes(v) ? v : 'developer'
  } catch { return 'developer' }
}

function parseMemberList(data, channel) {
  const members = Array.isArray(data && data.members) ? data.members.map((id) => String(id)) : []
  const agents = Array.isArray(data && data.agents)
    ? data.agents.map((a) => {
      const row = { id: String((a && a.id) || ''), box: String((a && a.box) || '') }
      if (a && typeof a.online === 'boolean') row.online = a.online
      if (a && typeof a.seated === 'boolean') row.seated = a.seated
      return row
    }).filter((a) => a.id)
    : []
  const responders = Array.isArray(data && data.responders)
    ? data.responders.map((id) => String(id)).filter(Boolean)
    : []
  return {
    channel: String((data && data.channel) || channel || ''),
    default: Boolean(data && data.default),
    members,
    members_open_invite: Boolean(data && data.members_open_invite),
    created_by: String((data && data.created_by) || ''),
    agents,
    responders,
  }
}

function memberError(status, token, detail) {
  return Object.assign(new Error(detail || token), { status, token, detail: detail || '' })
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
} = {}) {
  const state = mock ? cloneMock() : null
  if (state) {
    state.memberships = Object.create(null)
    state.openInvite = Object.create(null)
    state.agentMembers = Object.create(null)
  }
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
  /** GET reads in flight, by what makes them identical (see live). */
  const inflight = new Map()

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
   */
  function live(path, opts) {
    const method = String((opts && opts.method) || 'GET').toUpperCase()
    if (method !== 'GET' || (opts && opts.signal)) return liveOnce(path, opts)
    const key = [viewDoor, viewToken, path, JSON.stringify((opts && opts.headers) || {})].join('\n')
    const hit = inflight.get(key)
    if (hit) return hit.then(cloneBody)
    const run = liveOnce(path, opts)
    inflight.set(key, run)
    const done = () => { if (inflight.get(key) === run) inflight.delete(key) }
    run.then(done, done)
    return run
  }

  async function liveOnce(path, opts) {
    const fn = fetchFn
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
      let pos
      let bad = ''
      try {
        const body = await res.json()
        token = (body && body.error) || ''
        detail = (body && body.detail) || ''
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

  function mockMemberList(channel) {
    const id = normalizeChannelId(channel)
    const known = id && state.channels.some((c) => c.channel_id === id)
    if (!known) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    if (isPublicChannel(id)) {
      return {
        channel: id,
        default: true,
        members: [],
        members_open_invite: false,
        created_by: 'hub',
        agents: (state.agentMembers[id] || []).slice(),
      }
    }
    const row = state.channels.find((c) => c.channel_id === id)
    const members = (state.memberships[id] || []).slice()
    if (!members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    return {
      channel: id,
      default: false,
      members,
      members_open_invite: state.openInvite[id] === true,
      created_by: String((row && row.created_by) || ''),
      agents: (state.agentMembers[id] || []).slice(),
    }
  }

  function mockMayInvite(row) {
    if (!row) return false
    if (row.created_by === state.me.id) return true
    if (state.openInvite[row.channel_id] === true) return true
    return Boolean(row.created_by) && !HUMAN_ID_RE.test(row.created_by)
  }

  function mockAddMember(channel, humanId) {
    const id = normalizeChannelId(channel)
    const hid = String(humanId || '')
    if (!hid) throw memberError(400, 'bad_json', 'body must be {human_id}')
    const row = state.channels.find((c) => c.channel_id === id)
    if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    if (isPublicChannel(id)) {
      throw memberError(409, 'channel_public', `#${id} is a default channel: every member of the tenant already reads it`)
    }
    const members = state.memberships[id]
    if (!members || !members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    if (!mockMayInvite(row)) throw memberError(403, 'forbidden', 'forbidden')
    if (!HUMAN_ID_RE.test(hid) || !rosterHumanIds(state.roster).includes(hid)) {
      throw memberError(404, 'not_a_member', `${hid} is not a member of this tenant`)
    }
    if (!members.includes(hid)) members.push(hid)
    return { channel: id, human_id: hid, added_by: state.me.id }
  }

  function mockAddAgent(channel, agentId, box) {
    const id = normalizeChannelId(channel)
    const agent = String(agentId || '')
    const boxId = String(box || '')
    if (!agent || !boxId) throw memberError(400, 'bad_json', 'body must be {id, box}')
    const row = state.channels.find((c) => c.channel_id === id)
    if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    // A default channel takes agents too; any member picks them (created_by hub).
    if (!isPublicChannel(id)) {
      const members = state.memberships[id]
      if (!members || !members.includes(state.me.id)) {
        throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
      }
      if (!mockMayInvite(row)) throw memberError(403, 'forbidden', 'forbidden')
    }
    const announced = (state.roster && state.roster[boxId]) || []
    if (!announced.includes(agent)) {
      throw memberError(404, 'not_a_member', `${agent} is not announced on ${boxId}`)
    }
    const list = state.agentMembers[id] || (state.agentMembers[id] = [])
    if (!list.some((a) => a.id === agent && a.box === boxId)) list.push({ id: agent, box: boxId })
    return { channel: id, id: agent, box: boxId }
  }

  function mockRemoveMember(channel, humanId) {
    const id = normalizeChannelId(channel)
    const hid = String(humanId || '')
    const row = state.channels.find((c) => c.channel_id === id)
    if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    if (isPublicChannel(id)) throw memberError(409, 'channel_public', `#${id} has no membership to remove`)
    const members = state.memberships[id]
    if (!members || !members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    if (hid !== state.me.id && !mockMayInvite(row)) throw memberError(403, 'forbidden', 'forbidden')
    state.memberships[id] = members.filter((m) => m !== hid)
    return null
  }

  function mockRemoveAgent(channel, agentId, box) {
    const id = normalizeChannelId(channel)
    const agent = String(agentId || '')
    const boxId = String(box || '')
    const row = state.channels.find((c) => c.channel_id === id)
    if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    if (!isPublicChannel(id)) {
      const members = state.memberships[id]
      if (!members || !members.includes(state.me.id)) {
        throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
      }
      if (!mockMayInvite(row)) throw memberError(403, 'forbidden', 'forbidden')
    }
    const list = state.agentMembers[id] || []
    state.agentMembers[id] = list.filter((a) => !(a.id === agent && a.box === boxId))
    return null
  }

  function mockDeleteChannel(channel) {
    const id = normalizeChannelId(channel)
    const row = state.channels.find((c) => c.channel_id === id)
    if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    const members = state.memberships[id] || []
    if (!isPublicChannel(id) && !members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    if (isPublicChannel(id)) throw memberError(409, 'channel_public', `#${id} is a default channel: it cannot be deleted`)
    if (row.created_by !== state.me.id) throw memberError(403, 'forbidden', 'forbidden')
    state.channels = state.channels.filter((c) => c.channel_id !== id)
    delete state.memberships[id]
    if (state.archivedChannels) delete state.archivedChannels[id]
    return null
  }

  function mockArchiveChannel(channel) {
    const id = normalizeChannelId(channel)
    const row = state.channels.find((c) => c.channel_id === id)
    if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    const members = state.memberships[id] || []
    if (!isPublicChannel(id) && !members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    if (isPublicChannel(id)) throw memberError(409, 'channel_public', `#${id} is a default channel: it cannot be archived`)
    if (row.created_by !== state.me.id) throw memberError(403, 'forbidden', 'forbidden')
    state.archivedChannels = state.archivedChannels || {}
    state.archivedChannels[id] = { ...row, members: [...members] }
    state.channels = state.channels.filter((c) => c.channel_id !== id)
    return null
  }

  function mockUnarchiveChannel(channel) {
    const id = normalizeChannelId(channel)
    const kept = state.archivedChannels && state.archivedChannels[id]
    if (!kept) throw memberError(404, 'unknown_channel', `no archived channel ${channel} in this tenant`)
    const { members, ...row } = kept
    if (!state.channels.some((c) => c.channel_id === id)) state.channels.push(row)
    state.memberships[id] = members || [state.me.id]
    delete state.archivedChannels[id]
    return row
  }

  function mockSetOpen(channel, flag) {
    const id = normalizeChannelId(channel)
    const row = state.channels.find((c) => c.channel_id === id)
    if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    if (isPublicChannel(id)) {
      throw memberError(409, 'channel_public', `#${id} is a default channel: every member of the tenant already reads it`)
    }
    const members = state.memberships[id] || []
    if (!members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    if (row.created_by !== state.me.id) throw memberError(403, 'forbidden', 'forbidden')
    state.openInvite[id] = flag === true
    return { channel: id, members_open_invite: state.openInvite[id] === true }
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
        const all = topicMessages(state.messages, id)
        if (order !== 'desc') return { task_id: id, messages: all, next: null }
        const desc = all.slice().reverse()
        const start = before ? desc.findIndex((m) => m.msg_id === before) + 1 : 0
        const page = desc.slice(start, start + limit)
        const more = start + limit < desc.length
        return { task_id: id, messages: page, next: more && page.length ? page[page.length - 1].msg_id : null }
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
      return { task_id: id, messages: rows.map((m) => normalizeViewMessage(m, id)), next: (data && data.next) || null }
    },
    /**
     * specs/025 FR-006: the caller's role and permissions in the active
     * tenant. Mock / a hub without the route (404): null = unrestricted.
     */
    async me() {
      if (mock) {
        // specs/054: the OPT-IN act-as mock. Absent by default (the other e2e
        // specs see null = unrestricted admin, unchanged). When present, report
        // act_as as the hub would, with the target's name from the directory.
        const { mockActAsGet } = await import('./act-as-mock.mjs')
        const a = mockActAsGet()
        /* CLE-77819: the OPT-IN archive-policy mock. Absent by default (null =
           unrestricted, as before); when set, the mock member is a plain
           developer in a workspace with that "Who can archive topics". */
        const policy = mockArchivePolicy()
        if (policy && (!a || !a.target_hum)) return { role: mockRole(), tenant_owner: false, topic_archive_policy: policy }
        if (!a || !a.target_hum) return null
        let name = a.target_hum
        try {
          const m = (await dir()).list().members.find((x) => x.human_id === a.target_hum)
          if (m && m.display_name) name = m.display_name
        } catch { /* keep the id */ }
        return { act_as: { target_hum: a.target_hum, target_name: name, expires_at: a.expires_at || '' } }
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
     * PUT /v1/me/channel-order (contracts/move-v1.md §7): the whole list;
     * answers the stored one, normalized ([] clears it -> null).
     */
    async setChannelOrder(ids) {
      if (!Array.isArray(ids) || ids.some((v) => typeof v !== 'string')) {
        throw Object.assign(new Error('channel_order must be a list'), { status: 400, token: 'bad_json' })
      }
      if (mock) {
        const list = normalizeChannelOrder(ids)
        if (list.length > CHANNEL_ORDER_MAX) throw Object.assign(new Error('too many ids'), { status: 400, token: 'bad_json' })
        storageSetJson(MOCK_CHANNEL_ORDER_KEY, list.length ? list : null)
        return { channel_order: list.length ? list : null }
      }
      return live('/v1/me/channel-order', {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ channel_order: ids }),
      })
    },
    /**
     * DELETE /v1/members/{human_id} (025 FR-007). Humans only; the hub
     * answers 404 for anything else. Mock has no memberships.
     */
    async removeMember(humanId) {
      const id = String(humanId || '')
      if (!/^HUM-\d+$/.test(id)) {
        const err = new Error('not a member')
        err.status = 404
        err.token = 'not_found'
        throw err
      }
      if (mock) return null
      return live(`/v1/members/${encodeURIComponent(id)}`, { method: 'DELETE' })
    },
    /**
     * GET /v1/members: the tenant's members, pending invites and
     * the roles the caller may grant. members.invite (admin) only.
     */
    async listTenantUsers() {
      if (mock) return (await dir()).list()
      return live('/v1/members')
    },
    /**
     * POST /v1/members/invites: store the invite, and mail it unless noMail
     * (CLE-77780: no mail without an explicit click). `locale` rides as
     * X-Locale for the mail.
     */
    async inviteTenantUser({ email, role, locale, noMail } = {}) {
      const body = { email: String(email || '').trim(), ...(role ? { role: String(role) } : {}), ...(noMail ? { no_mail: true } : {}) }
      if (mock) return (await dir()).invite(body.email, body.role, { noMail: Boolean(noMail) })
      return live('/v1/members/invites', {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...(locale ? { 'x-locale': String(locale) } : {}) },
        body: JSON.stringify(body),
      })
    },
    /** PUT /v1/members/{id}/role; `fromRole` makes a stale page answer 409 role_changed. */
    async setTenantUserRole(humanId, role, fromRole = '') {
      const id = String(humanId || '')
      if (mock) return (await dir()).setRole(id, String(role || ''))
      return live(`/v1/members/${encodeURIComponent(id)}/role`, {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ role: String(role || ''), ...(fromRole ? { from_role: String(fromRole) } : {}) }),
      })
    },
    /** DELETE /v1/members/{id}: remove a member from the tenant. */
    async removeTenantUser(humanId) {
      const id = String(humanId || '')
      if (mock) return (await dir()).remove(id)
      return live(`/v1/members/${encodeURIComponent(id)}`, { method: 'DELETE' })
    },
    /**
     * GET /v1/audit/clones (specs/054 §7, CLE-77797): the tenant's act-as
     * trail, newest first. CLE-77799 reads it for the People-card Activity log
     * and filters it to one person (target_hum) client-side. audit.read only;
     * a 403 is left to the caller. The mock answers a small fixed trail.
     */
    async auditClones() {
      if (mock) {
        const { MOCK_CLONES } = await import('./mock-data.mjs')
        return MOCK_CLONES.map((c) => ({ ...c }))
      }
      return live('/v1/audit/clones')
    },
    /**
     * GET /v1/members/{id}/activity (CLE-77799): one member's audit trail —
     * membership events (role change, removal) and auth events (sign-in with
     * method, sign-out, session expiry), newest first. Readable by the tenant's
     * admins/owners (audit.read) or by the member themself; the hub is the
     * authority. The act-as trail rides GET /v1/audit/clones and is merged by
     * the caller. The mock records no server events, so it answers [].
     */
    async memberActivity(humanId) {
      if (mock) return []
      return live(`/v1/members/${encodeURIComponent(String(humanId || ''))}/activity`)
    },
    /** DELETE /v1/members/invites?email=: revoke a pending invite. */
    async revokeTenantInvite(email) {
      const e = String(email || '').trim()
      if (mock) return (await dir()).revoke(e)
      return live(`/v1/members/invites?email=${encodeURIComponent(e)}`, { method: 'DELETE' })
    },
    /**
     * PATCH /v1/members/{id} (specs/046): { display_name?, locale?, disabled? }.
     * disabled suspends the member in THIS tenant only.
     */
    async patchTenantUser(humanId, patch = {}) {
      const id = String(humanId || '')
      if (mock) return (await dir()).patch(id, patch)
      return live(`/v1/members/${encodeURIComponent(id)}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(patch),
      })
    },
    /** GET /v1/tenant/settings (specs/046, tenant.settings): name, default locale, responders. */
    async getTenantSettings() {
      if (mock) return (await tenantMock()).settings()
      return live('/v1/tenant/settings')
    },
    /** PATCH /v1/tenant/settings { display_name?, default_locale?, responders? } → the new settings. */
    async patchTenantSettings(patch = {}) {
      if (mock) return (await tenantMock()).patch(patch)
      return live('/v1/tenant/settings', {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(patch),
      })
    },
    /** GET /v1/tenant/channels: every channel of the tenant (private ones too), admin view. */
    async listTenantChannels() {
      if (mock) return (await tenantMock()).channels()
      return live('/v1/tenant/channels')
    },
    /** PATCH /v1/tenant/channels/{ch} { no_fallback }. */
    async setTenantChannelNoFallback(channel, off) {
      const ch = String(channel || '')
      if (mock) return (await tenantMock()).setNoFallback(ch, off)
      return live(`/v1/tenant/channels/${encodeURIComponent(ch)}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ no_fallback: Boolean(off) }),
      })
    },
    /** DELETE /v1/tenant/channels/{ch}: archive a channel without being its creator. */
    async archiveTenantChannel(channel) {
      const ch = String(channel || '')
      if (mock) return (await tenantMock()).archive(ch)
      return live(`/v1/tenant/channels/${encodeURIComponent(ch)}`, { method: 'DELETE' })
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
        let rows = state.messages.slice()
        if (channel) rows = rows.filter((m) => m.channel === channel)
        /* specs/058: a DM is per <ID>@<box>, as the hub's peer filter is */
        else if (peer) rows = rows.filter((m) => belongsTo(m, { peer: String(peer) }))
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
      for (const page of pages) {
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
      if (mock) return normalizeSearchResponse(mockSearch(state.messages, q))
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
        const row = {
          v: 1,
          msg_id: uuid(),
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
     * message-edit-v1 §1 — PATCH /v1/messages/{msg_id}, body { body }.
     *
     * The prefix is `/v1/`, NOT `/api/v1/`: the latter is the auth handler's
     * mount, the view / channels surface is `/v1/`. `content-type` is the
     * only header, and it is one the channels POST already sends, so this
     * adds no new CORS preflight — a new request header has broken sign-in
     * in this repo before.
     *
     * The tenant is the member session's (spec 026) and is never in the body.
     * Refusals arrive as { error, detail } and `live()` already lifts `error`
     * onto err.token, which is what utils/msg-edit.mjs switches on.
     */
    async editMessage(msgId, body) {
      const id = String(msgId || '')
      const text = String(body == null ? '' : body)
      if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
      if (mock) {
        /* The lde mock is a real edit against the in-memory store, including
           the two refusals the hub makes, so the browser e2e exercises the
           whole path (open, type, commit, marker, rollback) without a hub. */
        const row = state.messages.find((m) => m.msg_id === id)
        if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
        if (!text.trim()) throw Object.assign(new Error('body must not be empty'), { status: 400, token: 'empty_body' })
        if (row.from !== state.me.id) throw Object.assign(new Error('only the author may edit this message'), { status: 403, token: 'not_author' })
        if (row.from_box !== state.me.box) throw Object.assign(new Error('box-signed envelope'), { status: 409, token: 'not_editable' })
        row.body = text
        /* §FR-ED-009: an edit does NOT move the message — ts, received_at and
           cursor are deliberately left exactly as they were. */
        row.edited_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
        row.edited_by = state.me.id
        row.revision = (Number(row.revision) || 1) + 1
        return { ...row }
      }
      const data = await live(`/v1/messages/${encodeURIComponent(id)}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ body: text }),
      })
      return normalizeViewMessage(data)
    },
    /**
     * DELETE /v1/messages/{msg_id}. 204 on success. The same refusals as an
     * edit: not_author, not_editable, not_found. The mock removes the row
     * from its store so a later read does not bring it back.
     */
    async deleteMessage(msgId) {
      const id = String(msgId || '')
      if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
      if (mock) {
        const at = state.messages.findIndex((m) => m.msg_id === id)
        if (at < 0) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
        const row = state.messages[at]
        if (row.from !== state.me.id) throw Object.assign(new Error('only the author may delete this message'), { status: 403, token: 'not_author' })
        if (row.from_box !== state.me.box) throw Object.assign(new Error('box-signed envelope'), { status: 409, token: 'not_editable' })
        state.messages.splice(at, 1)
        return null
      }
      await live(`/v1/messages/${encodeURIComponent(id)}`, { method: 'DELETE' })
      return null
    },
    /**
     * POST /v1/messages/{msg_id}/merge {into}. {msg_id} is the
     * source, the row that goes away; `into` keeps both bodies, older first.
     * ONE request: the hub edits `into` and deletes the source in one
     * transaction, so a merge can no longer leave the source behind (the old
     * PATCH-then-DELETE lost its DELETE on prd). Resolves with the kept row
     * (plus merged_from); rejects with the hub token on err.token
     * (not_same_thread, not_same_author, not_allowed, not_editable, is_card,
     * has_replies, not_found, too_large). The mock applies the same rules
     * against its store.
     */
    async mergeMessage(msgId, intoId) {
      const src = String(msgId || '')
      const into = String(intoId || '')
      if (!src || !into || src === into) throw Object.assign(new Error('two message ids required'), { status: 400, token: 'bad_json' })
      /* the mock's rules load on use: they are not first-paint code (specs/027) */
      if (mock) return (await import('./mock-merge.mjs')).mockMerge(state, src, into)
      const data = await live(`/v1/messages/${encodeURIComponent(src)}/merge`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ into }),
      })
      const row = normalizeViewMessage(data)
      row.merged_from = src
      return row
    },
    /**
     * SPL-983, specs/041 topic-archive-v1 §2: archive (PUT) or unarchive
     * (DELETE) a topic card. The hub lets the card's author, the tenant owner
     * or an admin (403 not_allowed otherwise); a reply is 409 not_a_card.
     * Returns { msg_id, task_id, archived, archived_at?, archived_by? }.
     */
    async archiveTopic(msgId, archived = true) {
      const id = String(msgId || '')
      if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
      if (mock) {
        state.archived = state.archived || []
        if (archived) {
          const at = state.messages.findIndex((m) => m.msg_id === id)
          if (at < 0) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
          const row = { ...state.messages[at], archived_at: new Date().toISOString(), archived_by: state.me.id }
          state.messages.splice(at, 1)
          state.archived.unshift(row)
          return { msg_id: id, task_id: row.task_id, archived: true, archived_at: row.archived_at, archived_by: row.archived_by }
        }
        const at = state.archived.findIndex((m) => m.msg_id === id)
        if (at >= 0) {
          const [row] = state.archived.splice(at, 1)
          state.messages.push({ ...row, archived_at: undefined, archived_by: undefined })
        }
        return { msg_id: id, task_id: '', archived: false }
      }
      return live(`/v1/messages/${encodeURIComponent(id)}/archive`, { method: archived ? 'PUT' : 'DELETE' })
    },
    /** topic-archive-v1 §3: { replies, task_ids, can_delete, ... } for the confirm dialog. */
    async topicSize(msgId) {
      const id = String(msgId || '')
      if (mock) {
        /* test hook (mock only): a confirm dialog reads the reply count from
           the hub, and on prd that round-trip takes real time. e2e sets
           `spool-mock-topic-size-delay-ms` to replay that latency window so a
           test can prove the Delete button stays keyboard-usable while it
           loads (TopicDeleteDialog, owner topic b6a7db19). Off by default. */
        const delay = typeof localStorage !== 'undefined' ? Number(localStorage.getItem('spool-mock-topic-size-delay-ms') || 0) : 0
        if (delay > 0) await new Promise((r) => setTimeout(r, delay))
        const all = [...state.messages, ...(state.archived || [])]
        const row = all.find((m) => m.msg_id === id)
        const replies = row ? all.filter((m) => m.msg_id !== id && (m.task_id === row.task_id || m.task_id === id)).length : 0
        /* CLE-77819: with the opt-in policy, the mock answers can_archive the
           way the hub's resolveCard does for a plain developer. */
        const policy = mockArchivePolicy()
        const canArchive = !policy || policy === 'everyone' || (policy === 'starter' && Boolean(row) && row.from === state.me.id)
        return { msg_id: id, task_id: row ? row.task_id : '', replies, task_ids: row ? [row.task_id] : [], can_delete: true, can_archive: canArchive }
      }
      return live(`/v1/view/messages/${encodeURIComponent(id)}/topic`)
    },
    /**
     * topic-archive-v1 §4: DELETE the card and every child, one transaction.
     * Returns { deleted, msg_ids, task_ids }.
     */
    async deleteTopic(msgId) {
      const id = String(msgId || '')
      if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
      if (mock) {
        const pool = [...state.messages, ...(state.archived || [])]
        const row = pool.find((m) => m.msg_id === id)
        if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
        const gone = (m) => m.msg_id === id || m.task_id === row.task_id || m.task_id === id
        const ids = pool.filter(gone).map((m) => m.msg_id)
        state.messages = state.messages.filter((m) => !gone(m))
        state.archived = (state.archived || []).filter((m) => !gone(m))
        return { msg_id: id, task_id: row.task_id, deleted: ids.length, msg_ids: ids, task_ids: [row.task_id, id] }
      }
      return live(`/v1/messages/${encodeURIComponent(id)}/topic`, { method: 'DELETE' })
    },
    /**
     * SPL-1024 move-v1 §2: POST /v1/messages/{msg_id}/move {to_channel} moves
     * a topic's card and every row under it to another channel. The answer
     * carries `undo` ({ to_channel }). Refusals keep the hub token (409
     * lobby / same_place / not_in_channel / issue_topic / not_a_card, 404
     * unknown_channel, 403 not_allowed).
     */
    async moveTopic(msgId, toChannel) {
      const id = String(msgId || '')
      const to = String(toChannel || '').trim().replace(/^#/, '').toLowerCase()
      if (!id || !to) throw Object.assign(new Error('msg_id and channel required'), { status: 400, token: 'bad_json' })
      if (mock) return (await import('./move-mock.mjs')).mockMove(state, id, { to_channel: to })
      return live(`/v1/messages/${encodeURIComponent(id)}/move`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ to_channel: to }),
      })
    },
    /**
     * move-v1 §3: {to_task} moves a reply (and its own thread) into another
     * topic. The answer carries `undo` ({ to_task: <home task> }).
     */
    async moveMessage(msgId, toTask) {
      const id = String(msgId || '')
      const to = String(toTask || '')
      if (!id || !to) throw Object.assign(new Error('msg_id and task required'), { status: 400, token: 'bad_json' })
      if (mock) return (await import('./move-mock.mjs')).mockMove(state, id, { to_task: to })
      return live(`/v1/messages/${encodeURIComponent(id)}/move`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ to_task: to }),
      })
    },
    /**
     * 714c7028: {to_task} merges a whole topic (this card's topic) into another
     * topic, ordered by the original timestamps; the source opener becomes a
     * reply. The answer carries `undo` ({ from_task, msg_ids }). Refusals keep
     * the hub token (409 same_place / lobby / not_in_channel / issue_topic /
     * not_a_card / cycle, 404 not_found, 403 not_allowed).
     */
    async mergeTopic(msgId, toTask) {
      const id = String(msgId || '')
      const to = String(toTask || '')
      if (!id || !to) throw Object.assign(new Error('msg_id and task required'), { status: 400, token: 'bad_json' })
      if (mock) return (await import('./move-mock.mjs')).mockMergeTopic(state, id, { to_task: to })
      return live(`/v1/messages/${encodeURIComponent(id)}/merge-topic`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ to_task: to }),
      })
    },
    /** 714c7028: the undo of a merge - {undo:{from_task,msg_ids}} puts the topic back. */
    async mergeUndo(msgId, fromTask, msgIds) {
      const id = String(msgId || '')
      const undo = { from_task: String(fromTask || ''), msg_ids: (Array.isArray(msgIds) ? msgIds : []).map(String) }
      if (!id || !undo.from_task) throw Object.assign(new Error('msg_id and from_task required'), { status: 400, token: 'bad_json' })
      if (mock) return (await import('./move-mock.mjs')).mockMergeTopic(state, id, { undo })
      return live(`/v1/messages/${encodeURIComponent(id)}/merge-topic`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ undo }),
      })
    },
    /**
     * 8f588edd: POST /v1/messages/{msg_id}/promote-topic {} splits a reply out
     * of its topic into a NEW topic of its own (the hub mints the task_id, in
     * the message's own channel). The answer carries the new `task_id` and
     * `undo` ({ from_task: <new topic>, msg_ids }). Refusals keep the hub token
     * (409 is_card / lobby / not_in_channel / issue_topic / cycle, 403
     * not_allowed).
     */
    async promoteTopic(msgId) {
      const id = String(msgId || '')
      if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
      if (mock) return (await import('./move-mock.mjs')).mockPromoteTopic(state, id, {})
      return live(`/v1/messages/${encodeURIComponent(id)}/promote-topic`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({}),
      })
    },
    /** 8f588edd: the undo of a promote - {undo:{from_task,msg_ids}} re-seats the reply. */
    async promoteUndo(msgId, fromTask, msgIds) {
      const id = String(msgId || '')
      const undo = { from_task: String(fromTask || ''), msg_ids: (Array.isArray(msgIds) ? msgIds : []).map(String) }
      if (!id || !undo.from_task) throw Object.assign(new Error('msg_id and from_task required'), { status: 400, token: 'bad_json' })
      if (mock) return (await import('./move-mock.mjs')).mockPromoteTopic(state, id, { undo })
      return live(`/v1/messages/${encodeURIComponent(id)}/promote-topic`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ undo }),
      })
    },
    /** move-v1 §4: { msg_id, task_id, channel, is_card, can_move, moved_from_channel?, moved_from_task? }. */
    async moveInfo(msgId) {
      const id = String(msgId || '')
      if (mock) {
        const row = state.messages.find((m) => m.msg_id === id)
        if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
        /* parent_task_id: mock only. The hub reads a topic by task_id, so a
           reply is found in getTopic(task_id); the mock reads it by
           parent_task_id || task_id and loses it (open-message.mjs). */
        return { msg_id: id, task_id: row.task_id, parent_task_id: row.parent_task_id || undefined, channel: row.channel || null, is_card: row.is_parent !== 0, can_move: row.from === state.me.id }
      }
      return live(`/v1/view/messages/${encodeURIComponent(id)}/move`)
    },
    /**
     * topic-archive-v1 §5: the archived cards this member may read, newest
     * archived first. { cards: [{ message, msg_id, task_id, channel,
     * archived_at, archived_by, replies, can_delete }], next }.
     */
    async listArchived({ before } = {}) {
      if (mock) {
        return {
          cards: (state.archived || []).map((m) => ({ message: m, msg_id: m.msg_id, task_id: m.task_id, channel: m.channel || null,
            archived_at: m.archived_at, archived_by: m.archived_by, replies: 0, can_delete: true })),
          next: null,
        }
      }
      const q = before ? `?before=${encodeURIComponent(before)}` : ''
      const body = await live(`/v1/view/archived${q}`)
      const cards = Array.isArray(body && body.cards) ? body.cards : []
      return {
        cards: cards.map((c) => ({ ...c, message: normalizeViewMessage(c.message || {}, '') })),
        next: (body && body.next) || null,
      }
    },
    /**
     * PUT adds the viewer's emoji; DELETE removes it. Body is {emoji} either
     * way. The same call for an opening message and a reply — the hub does
     * not look at is_parent. Returns { msg_id, task_id, reactions }.
     */
    /**
     * SPL-952 — PATCH /v1/messages/{msg_id}/kind, body { kind }. The hub lets
     * the author, a biz_owner or an admin set it (403 not_allowed otherwise)
     * and answers the view element with the kind override beside the envelope.
     */
    async setMessageKind(msgId, kind) {
      const id = String(msgId || '')
      const k = String(kind || '')
      if (!id || !k) throw Object.assign(new Error('kind required'), { status: 400, token: 'bad_json' })
      if (mock) {
        /* the lde mock member sets any kind, as a biz_owner would */
        const row = state.messages.find((m) => m.msg_id === id)
        if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
        row.kind = k
        row.kind_set_by = state.me.id
        row.kind_set_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
        return { ...row }
      }
      const data = await live(`/v1/messages/${encodeURIComponent(id)}/kind`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ kind: k }),
      })
      return normalizeViewMessage(data)
    },
    async setReaction(msgId, emoji, op, current) {
      const id = String(msgId || '')
      const glyph = String(emoji || '')
      if (!id || !glyph) throw Object.assign(new Error('emoji required'), { status: 400, token: 'bad_json' })
      if (mock) {
        /* A mock send from the live store keeps the row in that store and
           does not push it here. The card still has the message, so the
           first emoji on it starts the row from the list the card holds. */
        let row = state.messages.find((m) => m.msg_id === id)
        if (!row) {
          row = { msg_id: id, task_id: '', reactions: Array.isArray(current) ? current.map((r) => ({ emoji: r.emoji, actors: Array.isArray(r.actors) ? r.actors.slice() : [] })) : [] }
          state.messages.push(row)
        }
        const me = state.me.id
        const list = Array.isArray(row.reactions)
          ? row.reactions.map((r) => ({ emoji: r.emoji, actors: Array.isArray(r.actors) ? r.actors.slice() : [] }))
          : []
        const at = list.findIndex((r) => r.emoji === glyph)
        if (op === 'remove') {
          if (at >= 0) {
            list[at].actors = list[at].actors.filter((a) => a !== me)
            if (!list[at].actors.length) list.splice(at, 1)
          }
        } else if (at < 0) {
          list.push({ emoji: glyph, actors: [me] })
        } else if (!list[at].actors.includes(me)) {
          list[at].actors.push(me)
        }
        row.reactions = list.map((r) => ({ emoji: r.emoji, actors: r.actors.slice() }))
        return { msg_id: id, task_id: row.task_id, reactions: row.reactions.map((r) => ({ emoji: r.emoji, actors: r.actors.slice() })) }
      }
      return live(`/v1/messages/${encodeURIComponent(id)}/reactions`, {
        method: op === 'remove' ? 'DELETE' : 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ emoji: glyph }),
      })
    },
    /**
     * channels-v1 §5.1: POST /v1/channels; 409 channel_exists / 400 bad_channel
     * keep their token. `description` (§5.1, 1.2.0) is what the new-channel
     * dialog collected next to the title, and is sent ONLY when there is one:
     * the hub rejects unknown fields, so a no-description create still works
     * against a hub that predates rdb 0027.
     */
    async createChannel({ channel_id, name, description } = {}) {
      const slug = channelSlug(channel_id || name)
      if (!slug) throw Object.assign(new Error('channel id required'), { status: 400, token: 'bad_channel' })
      const about = String(description || '').trim().slice(0, 500)
      if (mock) {
        if (state.archivedChannels && state.archivedChannels[slug]) {
          throw memberError(409, 'channel_archived', 'reserved: an archived channel has this name')
        }
        const row = { channel_id: slug, name: name || slug, created_by: state.me.id }
        if (about) row.description = about
        if (!state.channels.some((c) => c.channel_id === slug)) {
          state.channels.push(row)
          // channels-v1 §7.4: creating a channel puts its creator in it.
          if (!isPublicChannel(slug)) {
            state.memberships[slug] = [state.me.id]
            state.openInvite[slug] = false
          }
        }
        return row
      }
      let data
      try {
        data = await live('/v1/channels', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            channel: slug,
            name: String(name || slug).slice(0, 80),
            ...(about ? { description: about } : {}),
          }),
        })
      } catch (e) {
        const msg = CHANNEL_ERRORS[e && e.token]
        if (msg) e.message = msg(slug)
        throw e
      }
      const [row] = channelsFromView({ channels: [data || { channel: slug }] })
      return row
    },
    /**
     * channels-v1 §7.4. A default channel answers `default: true`,
     * `members: []` (people: everyone) and the agents someone added. A caller who is not in the channel gets the same 404
     * as a missing channel (`unknown_channel`).
     */
    async listChannelMembers(channel) {
      if (mock) return mockMemberList(channel)
      const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/members`)
      return parseMemberList(data, channel)
    },
    /**
     * channels-v1 §7.4: POST `{human_id}`. 201 on success. The caller must
     * already be in the channel and hold `channels.manage`; the target must
     * already be in the tenant. Mock records the id on that channel.
     */
    async addChannelMember(channel, humanId) {
      const id = String(humanId || '')
      if (mock) return mockAddMember(channel, id)
      const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/members`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ human_id: id }),
      })
      return data || { channel: String(channel || ''), human_id: id }
    },
    /**
     * Invite one announced agent into the channel. The row survives the
     * box's next announce. 201 {channel, id, box}.
     */
    async addChannelAgent(channel, agentId, box) {
      const id = String(agentId || '')
      const boxId = String(box || '')
      if (mock) return mockAddAgent(channel, id, boxId)
      const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/agents`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ id, box: boxId }),
      })
      return data || { channel: String(channel || ''), id, box: boxId }
    },
    /** Take one human out of the channel. Leaving yourself needs no extra permission. */
    async removeChannelMember(channel, humanId) {
      const id = String(humanId || '')
      if (mock) return mockRemoveMember(channel, id)
      await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/members/${encodeURIComponent(id)}`, {
        method: 'DELETE',
      })
      return null
    },
    /** Take one agent out. A later announce does not put that agent back. */
    async removeChannelAgent(channel, agentId, box) {
      const id = String(agentId || '')
      const boxId = String(box || '')
      if (mock) return mockRemoveAgent(channel, id, boxId)
      await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/agents/${encodeURIComponent(boxId)}/${encodeURIComponent(id)}`, {
        method: 'DELETE',
      })
      return null
    },
    /**
     * channels-v1 membership flag. Only the channel owner may change it.
     * Absent on a read means false. 403 forbidden, 409 channel_public,
     * 404 unknown_channel.
     */
    async setMembersOpenInvite(channel, open) {
      const flag = open === true
      if (mock) return mockSetOpen(channel, flag)
      const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ members_open_invite: flag }),
      })
      const returned = data && typeof data.members_open_invite === 'boolean' ? data.members_open_invite : flag
      return {
        channel: String((data && (data.channel || data.channel_id)) || channel || ''),
        members_open_invite: returned,
      }
    },
    /**
     * SPL-72, channels-v1 §5.4: the creator HARD-deletes a channel (rdb 0092),
     * so the name is free again. 204. 404 unknown_channel (not a member),
     * 409 channel_public, 403 forbidden.
     */
    async deleteChannel(channel) {
      if (mock) return mockDeleteChannel(channel)
      await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}`, { method: 'DELETE' })
      return null
    },
    /**
     * rdb 0092: the creator archives a channel - it is hidden, its slug stays
     * reserved, and its topics move to the Archive view. PUT .../archive, 204.
     * 404 unknown_channel, 409 channel_public, 403 forbidden. Reversible by
     * unarchiveChannel.
     */
    async archiveChannel(channel) {
      if (mock) return mockArchiveChannel(channel)
      await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/archive`, { method: 'PUT' })
      return null
    },
    /**
     * rdb 0092: bring an archived channel back (channels.manage). PUT
     * .../unarchive, 200 {channel,...}. 404 when no archived channel by that
     * name.
     */
    async unarchiveChannel(channel) {
      if (mock) return mockUnarchiveChannel(channel)
      const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/unarchive`, { method: 'PUT' })
      const [row] = channelsFromView({ channels: [data || { channel: normalizeChannelId(channel) }] })
      return row
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
      const res = await fetchFn(`${root}/v1/files`, { method: 'POST', credentials: 'omit', headers, body: buf })
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
      const res = await fetchFn(`${root}/v1/files/${encodeURIComponent(id)}`, { credentials: credentialsFor(viewDoor) })
      if (!res.ok) throw Object.assign(new Error(`spool ${res.status} /v1/files`), { status: res.status })
      return res.arrayBuffer()
    },
    fileUrl(fileId) {
      return `${root}/v1/files/${encodeURIComponent(String(fileId || ''))}`
    },
    /**
     * specs/039 issues-v1 §1: the tenant's issues with the filters and sort
     * of §4 applied by the hub. `{ prefix, statuses, counts, issues, labels, channel }`.
     */
    bindIssuesMock(factory) { mockFactory = factory },
    async listIssues({ filter = {}, sort = '' } = {}) {
      const q = issueQuery(filter, sort)
      if (mock) return issuesMock().list(q)
      return live(`/v1/view/issues${q ? `?${q}` : ''}`)
    },
    /** issues-v1 §1: one issue by key (SPL-12) → `{ issue }`; 404 not_found. */
    async getIssue(ref) {
      if (mock) return issuesMock().get(ref)
      return live(`/v1/view/issues/${encodeURIComponent(String(ref || ''))}`)
    },
    /** issues-v1 §3: create → `{ issue }`. Refusals keep their token (bad_issue, unknown_label, bad_assignee, unknown_parent). */
    async createIssue(body = {}) {
      if (mock) return issuesMock().create(body)
      return live('/v1/issues', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      })
    },
    /** issues-v1 §3: a partial update; only the fields given change, '' clears → `{ issue }`. */
    async updateIssue(ref, patch = {}) {
      if (mock) return issuesMock().update(ref, patch)
      return live(`/v1/issues/${encodeURIComponent(String(ref || ''))}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(patch),
      })
    },
    /** issues-v1 §1 (SPL-1027 / SPL-1226): the soft delete → `{ issue, descendants }`
     *  as it was; 403 forbidden, 409 issue_has_children. With `{ cascade: true }`
     *  a whole epic or feature and all of its descendants go in one call. */
    async deleteIssue(ref, { cascade = false } = {}) {
      if (mock) return issuesMock().remove(ref, cascade)
      const q = cascade ? '?cascade=1' : ''
      return live(`/v1/issues/${encodeURIComponent(String(ref || ''))}${q}`, { method: 'DELETE' })
    },
    /** SPL-1226: soft-archive an issue → `{ issue, descendants }`; with
     *  `{ cascade: true }` the whole epic / feature and its descendants. */
    async archiveIssue(ref, { cascade = false } = {}) {
      if (mock) return issuesMock().archive(ref, cascade)
      const q = cascade ? '?cascade=1' : ''
      return live(`/v1/issues/${encodeURIComponent(String(ref || ''))}/archive${q}`, { method: 'POST' })
    },
    /** issues-v1 §1: a new label in the tenant's catalogue → `{ label }`; 409 label_exists. */
    async createIssueLabel({ name = '', color = '' } = {}) {
      if (mock) return issuesMock().label({ name, color })
      return live('/v1/issue-labels', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(color ? { name, color } : { name }),
      })
    },
  }
  return api
}
