import { cloneMock } from './mock-data.mjs'
import { channelSlug, parseMention } from './channel-feed.mjs'
import {
  channelReadQuery,
  channelsFromView,
  normalizeThreadRow,
  normalizeViewMessage,
  rosterFromView,
  threadMessages,
  threadsFromMessages,
} from './view-api.mjs'
import { SEARCH_OPERATORS, mockSearch, normalizeOperators, normalizeSearchResponse, searchApiQuery } from './search.mjs'

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
  const mockBlobs = new Map()
  const root = String(base || '').replace(/\/+$/, '')
  let viewToken = String(token || '')
  let viewDoor = String(door || '')
  let send = sender

  async function live(path, opts) {
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
    const res = await fn(`${root}${path}`, { credentials: credentialsFor(viewDoor), ...opts, headers })
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
    async listThreads({ limit = 50, before, channel, dm, peer, agent, roots } = {}) {
      if (mock) {
        let rows = state.messages.slice()
        if (channel) rows = rows.filter((m) => m.channel === channel)
        else if (dm) rows = rows.filter((m) => !m.channel)
        if (peer) {
          const [id] = String(peer).split('@')
          rows = rows.filter((m) => m.from === id || m.to === id)
        }
        return { threads: threadsFromMessages(rows).slice(0, limit), next: null }
      }
      const q = new URLSearchParams()
      if (limit) q.set('limit', String(limit))
      if (before) q.set('before', before)
      if (channel) q.set('channel', channel)
      if (dm) q.set('dm', 'true')
      if (peer) q.set('peer', peer)
      if (agent) q.set('agent', agent)
      if (roots === false) q.set('roots', 'false')
      const data = await live(`/v1/view/threads?${q}`)
      const rows = (data && data.threads) || []
      return { threads: rows.map(normalizeThreadRow), next: (data && data.next) || null }
    },
    /**
     * view-v1 §4.4. Default: oldest first, `after=` for catch-up. With
     * `order: 'desc'`: the newest `limit` newest-first; `next` → pass as `before`
     * for the next older window (013 reverse prepend; hub 1dca945).
     */
    async getThread(taskId, { limit = 200, after, order, before } = {}) {
      const id = String(taskId || '')
      if (!id) throw new Error('task_id required')
      if (mock) {
        const all = threadMessages(state.messages, id)
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
      const data = await live(`/v1/view/threads/${encodeURIComponent(id)}?${q}`)
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
     * oldest first, at most `limit`: one page of `threads` threads from the
     * view list (view-v1 §4.3), each read newest-first (§4.4) and merged.
     * `next` is the §4.3 cursor — pass it as `before` for the next older
     * window of threads, until `next` is null. Mock has no server pages.
     */
    async listMessages({ channel, peer, limit = 50, since, threads = 20, before } = {}) {
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
      const list = await api.listThreads({ limit: threads, before, ...filter })
      const pages = await pool(list.threads, 6, (t) => api.getThread(t.task_id, { order: 'desc', limit }))
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
      return { messages: out.slice(-limit), next: list.next || null }
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
     * Post into a channel (`channel`), a DM (`peer`, no channel) or an existing
     * thread (`task_id`); a new post starts a new task. `parent_task_id` links a
     * CHILD task (channels-v1 §0), it does not thread a reply. Live: one
     * wui-live-ws §4 `send` frame via the injected sender; resolves with the
     * flat message plus the ack's cursor / received_at.
     */
    async sendMessage({ channel, peer, text, task_id, parent_task_id, files, from, msg_id } = {}) {
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
    /** channels-v1 §5.1: POST /v1/channels; 409 channel_exists / 400 bad_channel keep their token. */
    async createChannel({ channel_id, name } = {}) {
      const slug = channelSlug(channel_id || name)
      if (!slug) throw Object.assign(new Error('channel id required'), { status: 400, token: 'bad_channel' })
      if (mock) {
        const row = { channel_id: slug, name: name || slug, created_by: state.me.id }
        if (!state.channels.some((c) => c.channel_id === slug)) state.channels.push(row)
        return row
      }
      let data
      try {
        data = await live('/v1/channels', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ channel: slug, name: String(name || slug).slice(0, 80) }),
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
  }
  return api
}
