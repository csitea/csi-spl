import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  channelsFromView,
  isDownloadable,
  normalizeThreadRow,
  normalizeViewMessage,
  rosterFromView,
  threadMessages,
  threadsFromMessages,
} from '../../utils/view-api.mjs'
import { createSpoolClient, sha256Hex } from '../../utils/spool-client.mjs'
import { renderBody } from '../../utils/channel-feed.mjs'
import { MOCK_MESSAGES } from '../../utils/mock-data.mjs'

const T = '33330000-0000-4000-8000-000000009001'

function stubFetch(routes) {
  const calls = []
  const fn = async (url, opts) => {
    calls.push({ url, opts })
    const path = url.replace(/^https?:\/\/[^/]+/, '')
    const hit = Object.keys(routes).find((k) => path.startsWith(k))
    const [status, body] = hit ? routes[hit] : [404, { error: 'not_found' }]
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => 'application/json' },
      json: async () => body,
    }
  }
  return { fn, calls }
}

describe('view-api helpers', () => {
  it('groups mock messages into threads, newest activity first', () => {
    const rows = threadsFromMessages(MOCK_MESSAGES)
    const t = rows.find((r) => r.task_id === 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
    assert.equal(t.count, 4)
    assert.deepEqual(t.kinds, { task: 1, note: 2, result: 1 })
    assert.equal(rows[0].last_ts >= rows[rows.length - 1].last_ts, true)
    assert.equal(t.participants.includes('HUM-1@box-wui'), true)
  })

  it('thread messages are oldest first', () => {
    const ms = threadMessages(MOCK_MESSAGES, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
    assert.deepEqual(ms.map((m) => m.kind), ['task', 'note', 'note', 'result'])
  })

  it('normalises a view-v1 §4.3 row and the flat branch row', () => {
    const v = normalizeThreadRow({ task_id: T, first_ts: 'a', last_ts: 'b', count: 2, kinds: { task: 1 }, participants: ['X@b'], subject: 's' })
    assert.equal(v.last_ts, 'b')
    const f = normalizeThreadRow({ task_id: T, ts: 'a', updated_at: 'c', from: 'GRK-03', from_box: 'box-a', to: 'CLE-07', to_box: 'box-b', kind: 'task', body: 'line1\nline2', count: 3 })
    assert.deepEqual(f.participants, ['GRK-03@box-a', 'CLE-07@box-b'])
    assert.equal(f.last_ts, 'c')
    assert.equal(f.subject, 'line1')
  })

  it('flattens a §4.4 envelope and drops sig', () => {
    const m = normalizeViewMessage({
      cursor: 'c1', received_at: 'r',
      env: { from_box: 'box-a', to_box: 'box-b', sig: 'S', msg: { v: 1, msg_id: 'm', task_id: T, kind: 'task', sig: 'x' } },
      deliveries: [{ to_box: 'box-b', state: 'sent' }],
    })
    assert.equal(m.from_box, 'box-a')
    assert.equal(m.kind, 'task')
    assert.equal(m.cursor, 'c1')
    assert.equal('sig' in m, false)
  })

  it('only blob attachments are downloadable', () => {
    assert.equal(isDownloadable({ mode: 'blob', file_id: 'ab' }), true)
    assert.equal(isDownloadable({ mode: 'path', path: '/x', sha256: 'ab' }), false)
    assert.equal(isDownloadable({ file_id: 'ab' }), true)
  })

  it('maps roster and channels, skipping revoked boxes', () => {
    const r = rosterFromView({ boxes: [
      { box_id: 'box-a', agents: ['CLE-07'], online: true },
      { box_id: 'box-z', agents: ['GRK-01'], online: false, revoked: true },
    ] })
    assert.deepEqual(r, { roster: { 'box-a': ['CLE-07'] }, online: ['CLE-07@box-a'] })
    assert.deepEqual(channelsFromView({ channels: [{ channel: 'alerts', count: 1 }] }), [{ channel_id: 'alerts', name: 'alerts' }])
  })

  it('renders a body as text, never as markup', () => {
    const html = renderBody('<script>alert(1)</script> <img src=x onerror=alert(1)>')
    assert.equal(html.includes('<script'), false)
    assert.equal(html.includes('<img'), false)
    assert.equal(html.includes('&lt;script&gt;'), true)
  })
})

describe('spool-client live (view-v1)', () => {
  it('lists threads from /v1/view/threads with a bearer token and no cookies', async () => {
    const { fn, calls } = stubFetch({ '/v1/view/threads?': [200, { threads: [{ task_id: T, first_ts: 'a', last_ts: 'b', count: 1, kinds: {}, participants: [], subject: 'hi' }], next: 'n1' }] })
    const c = createSpoolClient({ base: 'http://t1.localhost:58080/', fetchFn: fn, mock: false, token: 'tok' })
    const out = await c.listThreads({ limit: 10 })
    assert.equal(out.threads[0].subject, 'hi')
    assert.equal(out.next, 'n1')
    assert.equal(calls[0].url, 'http://t1.localhost:58080/v1/view/threads?limit=10')
    assert.equal(calls[0].opts.headers.authorization, 'Bearer tok')
    assert.equal(calls[0].opts.credentials, 'omit')
  })

  it('reads one thread from /v1/view/threads/{task_id}', async () => {
    const { fn, calls } = stubFetch({ [`/v1/view/threads/${T}`]: [200, { task_id: T, messages: [{ cursor: 'c', env: { from_box: 'a', to_box: 'b', msg: { v: 1, msg_id: 'm', task_id: T } } }], next: null }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const out = await c.getThread(T)
    assert.equal(out.messages[0].from_box, 'a')
    assert.equal(calls[0].url.startsWith(`/v1/view/threads/${T}?`), true)
    assert.equal('authorization' in calls[0].opts.headers, false)
  })

  it('polls one thread with after=<cursor>', async () => {
    const { fn, calls } = stubFetch({ [`/v1/view/threads/${T}`]: [200, { task_id: T, messages: [], next: null }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await c.getThread(T, { after: 'c 9' })
    assert.equal(new URL(calls[0].url, 'http://x').searchParams.get('after'), 'c 9')
  })

  it('surfaces the error token and status', async () => {
    const { fn } = stubFetch({ '/v1/view/threads': [401, { error: 'view_door' }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.listThreads(), (e) => e.status === 401 && e.token === 'view_door')
  })

  it('refuses live send, channel creation and channel feeds (read-only)', async () => {
    const { fn, calls } = stubFetch({})
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.sendMessage({ text: 'x' }), (e) => e.status === 501)
    await assert.rejects(c.createChannel({ name: 'x' }), (e) => e.status === 501)
    await assert.rejects(c.listMessages({ channel: 'lobby' }), (e) => e.status === 501)
    assert.equal(calls.length, 0)
  })

  it('probes /v1/health, not the Cloud Run-shadowed /healthz', async () => {
    const { fn, calls } = stubFetch({ '/v1/health': [200, { status: 'ok' }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    assert.deepEqual(await c.healthz(), { status: 'ok' })
    assert.equal(calls[0].url, '/v1/health')
  })

  it('a config error (no tenant / API host) fails before any request', async () => {
    const { fn, calls } = stubFetch({})
    const c = createSpoolClient({ fetchFn: fn, mock: false, configError: 'api_host' })
    await assert.rejects(c.listThreads(), (e) => e.status === 0 && e.token === 'api_host')
    assert.equal(calls.length, 0)
  })

  it('uploads raw bytes with the Bearer upload token and downloads them back', async () => {
    const calls = []
    const fn = async (url, opts) => {
      calls.push({ url, opts })
      if (opts.method === 'POST') return { ok: true, status: 201, json: async () => ({ file_id: 'f1', sha256: 'f1', bytes: 3 }) }
      return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer }
    }
    const c = createSpoolClient({ base: 'http://t1.localhost:58080', fetchFn: fn, mock: false })
    const up = await c.uploadFile(new Blob([new Uint8Array([1, 2, 3])]), 'up-tok')
    assert.equal(up.file_id, 'f1')
    assert.equal(calls[0].url, 'http://t1.localhost:58080/v1/files')
    assert.equal(calls[0].opts.headers.authorization, 'Bearer up-tok')
    assert.equal(calls[0].opts.headers['content-type'], 'application/octet-stream')
    assert.equal(calls[0].opts.body.byteLength, 3)
    const buf = await c.downloadFile('f1')
    assert.deepEqual([...new Uint8Array(buf)], [1, 2, 3])
    assert.equal(calls[1].url, 'http://t1.localhost:58080/v1/files/f1')
  })

  it('mock upload is content-addressed and downloads identical bytes', async () => {
    const c = createSpoolClient({ mock: true })
    const bytes = new TextEncoder().encode('hello spool')
    const up = await c.uploadFile(new Blob([bytes]))
    assert.equal(up.file_id, await sha256Hex(bytes.buffer))
    assert.equal(up.bytes, bytes.byteLength)
    assert.deepEqual(new Uint8Array(await c.downloadFile(up.file_id)), bytes)
  })

  it('mock mode serves threads without a hub', async () => {
    const c = createSpoolClient({ mock: true })
    const { threads } = await c.listThreads()
    assert.ok(threads.length >= 1)
    const one = await c.getThread(threads[0].task_id)
    assert.ok(one.messages.length >= 1)
  })
})
