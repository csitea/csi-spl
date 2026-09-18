import { cloneMock } from './mock-data.mjs'
import { parseMention } from './channel-feed.mjs'
import {
  channelsFromView,
  normalizeThreadRow,
  normalizeViewMessage,
  rosterFromView,
  threadMessages,
  threadsFromMessages,
} from './view-api.mjs'

function uuid() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

/** Thrown for live calls the read-only viewer does not have (spec 005 §0). */
export class ReadOnlyError extends Error {
  constructor(what) {
    super(`${what} is not available: the hub WUI API is read-only (spec 005 §0)`)
    this.status = 501
  }
}

/**
 * Live mode reads only the 003 viewer API (contracts/view-v1.md): /v1/view/*,
 * GET /v1/files/{file_id}, /v1/health (003 FR-023: Cloud Run shadows /healthz). The view token rides in Authorization;
 * no cookies (view-v1 §3), so fetch runs with credentials: 'omit'.
 */
export function createSpoolClient({ base = '', fetchFn = globalThis.fetch, mock = true, token = '' } = {}) {
  const state = mock ? cloneMock() : null
  const root = String(base || '').replace(/\/+$/, '')
  let viewToken = String(token || '')

  async function live(path, opts) {
    const fn = fetchFn
    if (typeof fn !== 'function') throw new Error('no fetch')
    const headers = { accept: 'application/json', ...(opts && opts.headers) }
    if (viewToken) headers.authorization = `Bearer ${viewToken}`
    const res = await fn(`${root}${path}`, { credentials: 'omit', ...opts, headers })
    if (!res.ok) {
      let token = ''
      try {
        const body = await res.json()
        token = (body && body.error) || ''
      } catch {
        /* not json */
      }
      const err = new Error(`spool ${res.status} ${token || path}`)
      err.status = res.status
      err.token = token
      throw err
    }
    if (res.status === 204) return null
    const ct = res.headers.get('content-type') || ''
    if (ct.includes('application/json')) return res.json()
    return res.arrayBuffer()
  }

  return {
    mock: Boolean(mock),
    setToken(t) {
      viewToken = String(t || '')
    },
    hasToken() {
      return Boolean(viewToken)
    },
    async healthz() {
      if (mock) return { ok: true, mock: true }
      return live('/v1/health')
    },
    async listThreads({ limit = 50, before } = {}) {
      if (mock) return { threads: threadsFromMessages(state.messages).slice(0, limit), next: null }
      const q = new URLSearchParams()
      if (limit) q.set('limit', String(limit))
      if (before) q.set('before', before)
      const data = await live(`/v1/view/threads?${q}`)
      const rows = (data && data.threads) || []
      return { threads: rows.map(normalizeThreadRow), next: (data && data.next) || null }
    },
    async getThread(taskId, { limit = 200, after } = {}) {
      const id = String(taskId || '')
      if (!id) throw new Error('task_id required')
      if (mock) return { task_id: id, messages: threadMessages(state.messages, id), next: null }
      const q = new URLSearchParams()
      if (limit) q.set('limit', String(limit))
      if (after) q.set('after', after)
      const data = await live(`/v1/view/threads/${encodeURIComponent(id)}?${q}`)
      const rows = (data && data.messages) || []
      return { task_id: id, messages: rows.map(normalizeViewMessage), next: (data && data.next) || null }
    },
    async listChannels() {
      if (mock) return state.channels.slice()
      return channelsFromView(await live('/v1/view/channels'))
    },
    async listMessages({ channel, peer, limit = 50, since } = {}) {
      if (!mock) throw new ReadOnlyError('a channel / DM feed')
      let rows = state.messages.slice()
      if (channel) rows = rows.filter((m) => m.channel === channel)
      else if (peer) {
        const [id] = String(peer).split('@')
        rows = rows.filter((m) => !m.channel && (m.from === id || m.to === id))
      }
      if (since) rows = rows.filter((m) => m.ts > since)
      return rows.slice(-limit)
    },
    async listRoster() {
      if (mock) return { roster: state.roster, online: state.online, me: state.me }
      return rosterFromView(await live('/v1/view/roster'))
    },
    async sendMessage({ channel, peer, text, parent_task_id, files }) {
      if (!mock) throw new ReadOnlyError('send')
      const parsed = parseMention(text)
      const body = {
        v: 1,
        msg_id: uuid(),
        task_id: uuid(),
        ts: new Date().toISOString(),
        from: state.me.id,
        from_box: state.me.box,
        to: peer ? String(peer).split('@')[0] : parsed.to,
        to_box: peer && String(peer).includes('@') ? String(peer).split('@')[1] : undefined,
        kind: peer ? 'note' : parsed.kind,
        body: peer ? String(text || '') : parsed.body,
        files: files || [],
        channel: channel || null,
        parent_task_id: parent_task_id || null,
      }
      state.messages.push(body)
      return body
    },
    async createChannel({ channel_id, name }) {
      if (!mock) throw new ReadOnlyError('channel creation')
      const slug = String(channel_id || name || '')
        .toLowerCase()
        .replace(/[^a-z0-9-]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 64)
      if (!slug) throw new Error('channel id required')
      const row = { channel_id: slug, name: name || slug, created_by: state.me.id }
      if (!state.channels.some((c) => c.channel_id === slug)) state.channels.push(row)
      return row
    },
    fileUrl(fileId) {
      return `${root}/v1/files/${encodeURIComponent(String(fileId || ''))}`
    },
  }
}
