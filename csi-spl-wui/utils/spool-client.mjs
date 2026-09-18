import { cloneMock } from './mock-data.mjs'
import { parseMention } from './channel-feed.mjs'

function uuid() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

export function createSpoolClient({ base = '', fetchFn = globalThis.fetch, mock = true } = {}) {
  const state = mock ? cloneMock() : null
  const root = String(base || '').replace(/\/+$/, '')

  async function live(path, opts) {
    const fn = fetchFn
    if (typeof fn !== 'function') throw new Error('no fetch')
    const res = await fn(`${root}${path}`, {
      credentials: 'include',
      ...opts,
      headers: { accept: 'application/json', ...(opts && opts.headers) },
    })
    if (!res.ok) {
      const err = new Error(`spool ${res.status} ${path}`)
      err.status = res.status
      throw err
    }
    if (res.status === 204) return null
    const ct = res.headers.get('content-type') || ''
    if (ct.includes('application/json')) return res.json()
    return res.arrayBuffer()
  }

  return {
    mock: Boolean(mock),
    async healthz() {
      if (mock) return { ok: true, mock: true }
      return live('/healthz')
    },
    async listChannels() {
      if (mock) return state.channels.slice()
      const data = await live('/v1/channels')
      return Array.isArray(data) ? data : (data && data.channels) || []
    },
    async listMessages({ channel, peer, limit = 50, since } = {}) {
      if (mock) {
        let rows = state.messages.slice()
        if (channel) rows = rows.filter((m) => m.channel === channel)
        else if (peer) {
          const [id] = String(peer).split('@')
          rows = rows.filter((m) => !m.channel && (m.from === id || m.to === id))
        }
        if (since) rows = rows.filter((m) => m.ts > since)
        return rows.slice(-limit)
      }
      const q = new URLSearchParams()
      if (channel) q.set('channel', channel)
      if (peer) q.set('peer', peer)
      if (limit) q.set('limit', String(limit))
      if (since) q.set('since', since)
      const data = await live(`/v1/messages?${q}`)
      return Array.isArray(data) ? data : (data && data.messages) || []
    },
    async listRoster() {
      if (mock) return { roster: state.roster, online: state.online, me: state.me }
      return live('/v1/pins')
    },
    async sendMessage({ channel, peer, text, parent_task_id, files }) {
      const parsed = parseMention(text)
      const now = new Date().toISOString()
      const task_id = uuid()
      const body = {
        v: 1,
        msg_id: uuid(),
        task_id,
        ts: now,
        from: mock ? state.me.id : 'HUM-1',
        from_box: mock ? state.me.box : 'box-wui',
        to: peer ? String(peer).split('@')[0] : parsed.to,
        to_box: peer && String(peer).includes('@') ? String(peer).split('@')[1] : undefined,
        kind: peer ? 'note' : parsed.kind,
        body: peer ? String(text || '') : parsed.body,
        files: files || [],
        channel: channel || null,
        parent_task_id: parent_task_id || null,
      }
      if (mock) {
        state.messages.push(body)
        return body
      }
      return live('/v1/messages', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      })
    },
    async createChannel({ channel_id, name }) {
      const slug = String(channel_id || name || '')
        .toLowerCase()
        .replace(/[^a-z0-9-]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 64)
      if (!slug) throw new Error('channel id required')
      const row = { channel_id: slug, name: name || slug, created_by: mock ? state.me.id : 'HUM-1' }
      if (mock) {
        if (state.channels.some((c) => c.channel_id === slug)) return row
        state.channels.push(row)
        return row
      }
      return live('/v1/channels', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(row),
      })
    },
    fileUrl(fileId) {
      return `${root}/v1/files/${fileId}`
    },
  }
}
