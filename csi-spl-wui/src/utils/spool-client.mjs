import { noteError } from '../composables/errorJournal.mjs'
import { isAbortError } from '../composables/apiHealth.mjs'
import { cloneMock } from './mock-data.mjs'
import { createMockDirectory } from './tenant-users.mjs'
import { channelSlug, parseMention } from './channel-feed.mjs'
import {
  channelReadQuery,
  channelsFromView,
  normalizeTopicRow,
  normalizeViewMessage,
  rosterFromView,
  topicMessages,
  topicsFromMessages,
} from './view-api.mjs'
import { SEARCH_OPERATORS, mockSearch, normalizeOperators, normalizeSearchResponse, searchApiQuery } from './search.mjs'
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
 * went out in four serial waves (~70-100 ms each on dev, CLE-34984).
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
 * Who the invite picker offers: HUM-* already in the tenant, not already
 * in the channel. Agents, guests and current members are left out.
 */
export function channelInviteCandidates(rosterIds, memberIds) {
  const members = new Set((memberIds || []).map((id) => String(id)))
  const seen = new Set()
  const out = []
  for (const raw of rosterIds || []) {
    const id = String(raw || '')
    if (!HUMAN_ID_RE.test(id) || members.has(id) || seen.has(id)) continue
    seen.add(id)
    out.push(id)
  }
  return out
}

/**
 * People the dropdown offers for the text typed so far. Empty text keeps
 * every id. Any other text matches when the id contains it, ignoring case,
 * so "17" finds HUM-17.
 */
export function filterPeopleContains(ids, query, names = null) {
  const q = String(query || '').trim().toLowerCase()
  const nameOf = (id) => (names && typeof names === 'object' && Object.prototype.hasOwnProperty.call(names, id) ? String(names[id] || '') : '')
  const out = []
  for (const raw of ids || []) {
    const id = String(raw || '')
    if (!id) continue
    // the member id, or the display name they chose (owner, 2026-09-26)
    if (!q || id.toLowerCase().includes(q) || nameOf(id).toLowerCase().includes(q)) out.push(id)
  }
  return out
}

/**
 * Agents the dropdown offers for the text typed so far. Empty text keeps
 * every row. Any other text matches when the id or the box contains it,
 * ignoring case, so "desk" finds an agent on box-desk.
 */
export function filterAgentsContains(rows, query) {
  const q = String(query || '').trim().toLowerCase()
  const out = []
  for (const row of rows || []) {
    if (!row || !row.id) continue
    const id = String(row.id)
    const box = String(row.box || '')
    if (!q || `${id} ${box}`.toLowerCase().includes(q)) out.push({ id, box })
  }
  return out
}

/** Hub error token (`not_a_member`, `channel_public`, `forbidden`, `unknown_channel`). */
export function inviteErrorToken(err) {
  if (err && typeof err === 'object' && err.token) return String(err.token)
  if (err instanceof Error && err.message) return err.message
  return ''
}

/** Signed-in HUM-* . Live uses /v1/view/me. The mock has no me() and uses the roster. */
export function signedInHuman(me, opts = {}) {
  const id = me && typeof me.humanId === 'string' ? me.humanId : ''
  if (HUMAN_ID_RE.test(id)) return id
  if (opts && opts.mock) {
    const rosterMe = String(opts.rosterMe || '')
    return HUMAN_ID_RE.test(rosterMe) ? rosterMe : ''
  }
  return ''
}

/**
 * Who this browser is. /v1/view/me wins. The socket welcome is the same HUM-*
 * when that read has not landed yet (a 401 before the session door is armed
 * used to leave the invite plus disabled for the channel owner).
 */
export function viewerHumanId(me, socketId, opts = {}) {
  const fromMe = signedInHuman(me, opts)
  if (fromMe) return fromMe
  const socket = String(socketId || '')
  return HUMAN_ID_RE.test(socket) ? socket : ''
}

/**
 * Owner, or any current member when members_open_invite is on.
 * A channel recorded as hub or wui has no human owner, so a signed-in
 * member may invite. An empty created_by is not that case.
 * An unknown caller may try; the hub still refuses a non-owner.
 */
export function canAddChannelMember({ selfId, createdBy, membersOpenInvite } = {}) {
  const self = String(selfId || '')
  const by = String(createdBy || '')
  if (!HUMAN_ID_RE.test(self)) return true
  if (self === by) return true
  if (membersOpenInvite === true) return true
  return by !== '' && !HUMAN_ID_RE.test(by)
}

const AGENT_ID_RE = /^[A-Z]{2,4}-[0-9]+$/

/**
 * Announced agents the channel can still invite. Humans and the browser
 * box are not agents. An agent already in the channel is left out.
 */
export function channelAgentCandidates(roster, current) {
  const have = new Set((current || []).map((row) => String(row && row.id) + '\0' + String(row && row.box)))
  const out = []
  const seen = new Set()
  const boxes = roster && typeof roster === 'object' ? Object.keys(roster) : []
  boxes.sort()
  for (const box of boxes) {
    if (box === 'box-wui') continue
    const ids = Array.isArray(roster[box]) ? roster[box] : []
    for (const raw of ids) {
      const id = String(raw || '')
      if (!AGENT_ID_RE.test(id) || id.startsWith('HUM-')) continue
      const key = id + '\0' + box
      if (have.has(key) || seen.has(key)) continue
      seen.add(key)
      out.push({ id, box })
    }
  }
  out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : a.box < b.box ? -1 : a.box > b.box ? 1 : 0))
  return out
}

/** The Settings checkbox is enabled only for the channel owner. */
export function canEditOpenInvite({ selfId, createdBy } = {}) {
  const self = String(selfId || '')
  return HUMAN_ID_RE.test(self) && self === String(createdBy || '')
}

/**
 * SPL-72: Delete is offered on a created channel to the member who created
 * it, and to nobody else - no role widens it (channels-v1 §5.4). A default
 * channel never. The hub refuses anyone else anyway; this only hides it.
 */
export function canDeleteChannel({ selfId, row } = {}) {
  const r = row || {}
  if (r.default === true || isPublicChannel(normalizeChannelId(String(r.channel_id || '')))) return false
  return canEditOpenInvite({ selfId, createdBy: r.created_by })
}

/** Agents that receive the channel. People and the browser box are not agents. */
export function channelAgentRows(agents) {
  const rows = []
  const seen = new Set()
  for (const raw of agents || []) {
    const id = String((raw && raw.id) || '')
    const box = String((raw && raw.box) || '')
    if (!id || /^HUM-/.test(id) || box === 'box-wui') continue
    const key = id + '\0' + box
    if (seen.has(key)) continue
    seen.add(key)
    rows.push({ id, box })
  }
  rows.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : a.box < b.box ? -1 : a.box > b.box ? 1 : 0))
  return rows
}

/**
 * Who a default channel (lobby, alerts, feedback) lists: every person of the
 * tenant, read-only, and only the agents someone added (owner decision
 * 2026-09-25). An announced agent is NOT in it until a member picks it.
 */
export function defaultChannelRows(roster, subscribed) {
  const people = channelInviteCandidates(rosterHumanIds(roster), [])
  const agents = channelAgentRows(subscribed || [])
  return { people, agents }
}

export function aboutChannelName(row) {
  const name = String((row && row.name) || '').trim()
  if (name) return name
  return String((row && (row.channel_id || row.channel)) || '')
}

export function aboutChannelDescription(row) {
  return String((row && row.description) || '').trim()
}

function parseMemberList(data, channel) {
  const members = Array.isArray(data && data.members) ? data.members.map((id) => String(id)) : []
  const agents = Array.isArray(data && data.agents)
    ? data.agents.map((a) => ({ id: String((a && a.id) || ''), box: String((a && a.box) || '') })).filter((a) => a.id)
    : []
  return {
    channel: String((data && data.channel) || channel || ''),
    default: Boolean(data && data.default),
    members,
    members_open_invite: Boolean(data && data.members_open_invite),
    created_by: String((data && data.created_by) || ''),
    agents,
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
  const dir = () => (mockDir ||= createMockDirectory())
  const root = String(base || '').replace(/\/+$/, '')
  let viewToken = String(token || '')
  let viewDoor = String(door || '')
  /* CLE-34984: a door set from a signed-in session probe, not yet proven by a
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
   * CLE-34984 (perf P1, measured on dev 947635e7): one cold /lobby asked for
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
    return null
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
     * CLE-34984: set the door BEFORE the first read, from a signed-in session
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
    async listTopics({ limit = 50, before, channel, dm, peer, agent, roots, perTopic = 0 } = {}) {
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
      const data = await live(`/v1/view/topics?${q}`)
      const rows = (data && data.topics) || []
      return {
        topics: rows.map((raw) => {
          const row = normalizeTopicRow(raw)
          if (inlineN && raw && Array.isArray(raw.messages)) {
            row.inline = { task_id: row.task_id, messages: raw.messages.map(normalizeViewMessage), next: raw.messages_next || null }
          }
          return row
        }),
        next: (data && data.next) || null,
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
      return { task_id: id, messages: rows.map(normalizeViewMessage), next: (data && data.next) || null }
    },
    /**
     * specs/025 FR-006: the caller's role and permissions in the active
     * tenant. Mock / a hub without the route (404): null = unrestricted.
     */
    async me() {
      if (mock) return null
      try {
        return await live('/v1/view/me')
      } catch (e) {
        if (e && e.status === 404) return null
        throw e
      }
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
     * GET /v1/members (CLE-34969): the tenant's members, pending invites and
     * the roles the caller may grant. members.invite (admin) only.
     */
    async listTenantUsers() {
      if (mock) return dir().list()
      return live('/v1/members')
    },
    /** POST /v1/members/invites: invite + invitation mail. `locale` rides as X-Locale for the mail. */
    async inviteTenantUser({ email, role, locale } = {}) {
      const body = { email: String(email || '').trim(), ...(role ? { role: String(role) } : {}) }
      if (mock) return dir().invite(body.email, body.role)
      return live('/v1/members/invites', {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...(locale ? { 'x-locale': String(locale) } : {}) },
        body: JSON.stringify(body),
      })
    },
    /** PUT /v1/members/{id}/role; `fromRole` makes a stale page answer 409 role_changed. */
    async setTenantUserRole(humanId, role, fromRole = '') {
      const id = String(humanId || '')
      if (mock) return dir().setRole(id, String(role || ''))
      return live(`/v1/members/${encodeURIComponent(id)}/role`, {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ role: String(role || ''), ...(fromRole ? { from_role: String(fromRole) } : {}) }),
      })
    },
    /** DELETE /v1/members/{id}: remove a member from the tenant. */
    async removeTenantUser(humanId) {
      const id = String(humanId || '')
      if (mock) return dir().remove(id)
      return live(`/v1/members/${encodeURIComponent(id)}`, { method: 'DELETE' })
    },
    /** DELETE /v1/members/invites?email=: revoke a pending invite. */
    async revokeTenantInvite(email) {
      const e = String(email || '').trim()
      if (mock) return dir().revoke(e)
      return live(`/v1/members/invites?email=${encodeURIComponent(e)}`, { method: 'DELETE' })
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
     */
    async listMessages({ channel, peer, limit = 50, since, topics = 20, before } = {}) {
      if (mock) {
        let rows = state.messages.slice()
        if (channel) rows = rows.filter((m) => m.channel === channel)
        else if (peer) {
          const [id] = String(peer).split('@')
          rows = rows.filter((m) => !m.channel && (m.from === id || m.to === id))
        }
        if (since) rows = rows.filter((m) => m.ts > since)
        return { messages: rows.slice(-limit), next: null }
      }
      const filter = channel ? { channel } : peer ? { dm: true, peer: String(peer) } : {}
      /* CLE-34984 / T122: one request for the whole page where the hub
         inlines each topic's newest `limit` messages; a topic the answer
         carries no messages for is read on its own, as before. */
      const list = await api.listTopics({ limit: topics, before, perTopic: limit <= PER_TOPIC_MAX ? limit : 0, ...filter })
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
      return { messages: out.filter((m, i) => i >= cut || opener.has(m)), next: list.next || null }
    },
    /**
     * 022 global search: `GET /v1/view/search?q=<raw>` (search-v1.md, the hub
     * parses the grammar). → normalizeSearchResponse. Mock: the lde matcher.
     */
    async search({ q = '', cursor = '', limit = 0, sort = '' } = {}) {
      if (mock) return normalizeSearchResponse(mockSearch(state.messages, q))
      return normalizeSearchResponse(await live(`/v1/view/search?${searchApiQuery({ q, cursor, limit, sort })}`))
    },
    /** search-v1 §6 grammar-as-data → the autocomplete catalogue. */
    async searchOperators() {
      if (mock) return SEARCH_OPERATORS
      return normalizeOperators(await live('/v1/view/search/operators'))
    },
    async listRoster() {
      if (mock) return { roster: state.roster, online: state.online, me: state.me }
      return rosterFromView(await live('/v1/view/roster'))
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
      const kind = peer ? 'note' : parsed.kind
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
          to_box: peer && String(peer).includes('@') ? String(peer).split('@')[1] : undefined,
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
     * PUT adds the viewer's emoji; DELETE removes it. Body is {emoji} either
     * way. The same call for an opening message and a reply — the hub does
     * not look at is_parent. Returns { msg_id, task_id, reactions }.
     */
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
     * SPL-72, channels-v1 §5.4: the creator soft-deletes a channel. 204.
     * 404 unknown_channel (not a member), 409 channel_public, 403 forbidden.
     */
    async deleteChannel(channel) {
      if (mock) return mockDeleteChannel(channel)
      await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}`, { method: 'DELETE' })
      return null
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
