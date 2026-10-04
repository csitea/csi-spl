import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  channelsFromView,
  isDownloadable,
  normalizeTopicRow,
  normalizeViewMessage,
  DEFAULT_DELIVERY,
  rowTitle,
  rosterFromView,
  topicMessages,
  topicOpening,
  topicTitleFromRows,
  topicsFromMessages,
} from '../../src/utils/view-api.mjs'
import { createSpoolClient, sha256Hex } from '../../src/utils/spool-client.mjs'
// channel-feed's renderBody was bodyToHtml(src) and had no app caller; it went
// (027 perf budget) so channel-feed no longer pulls the renderer into first paint
import { bodyToHtml as renderBody } from '../../src/utils/code-blocks.mjs'
import { MOCK_MESSAGES } from '../../src/utils/mock-data.mjs'

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
  it('groups mock messages into topics, newest activity first', () => {
    const rows = topicsFromMessages(MOCK_MESSAGES)
    const t = rows.find((r) => r.task_id === 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
    assert.equal(t.count, 4)
    assert.deepEqual(t.kinds, { task: 1, note: 2, result: 1 })
    assert.equal(rows[0].last_ts >= rows[rows.length - 1].last_ts, true)
    assert.equal(t.participants.includes('HUM-1@box-wui'), true)
  })

  it('topic messages are oldest first', () => {
    const ms = topicMessages(MOCK_MESSAGES, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
    assert.deepEqual(ms.map((m) => m.kind), ['task', 'note', 'note', 'result'])
  })

  it('normalises a view-v1 §4.3 row and the flat branch row', () => {
    const v = normalizeTopicRow({ task_id: T, first_ts: 'a', last_ts: 'b', count: 2, kinds: { task: 1 }, participants: ['X@b'], subject: 's' })
    assert.equal(v.last_ts, 'b')
    const f = normalizeTopicRow({ task_id: T, ts: 'a', updated_at: 'c', from: 'GRK-03', from_box: 'box-a', to: 'CLE-07', to_box: 'box-b', kind: 'task', body: 'line1\nline2', count: 3 })
    assert.deepEqual(f.participants, ['GRK-03@box-a', 'CLE-07@box-b'])
    assert.equal(f.last_ts, 'c')
    assert.equal(f.subject, 'line1')
  })

  it('a Topics row title is the gist, else the plain opening (082 FR-001)', () => {
    assert.equal(rowTitle('Welcome to **#lobby**.'), 'Welcome to #lobby.')
    assert.equal(rowTitle('Welcome to **#lobby**.', ''), 'Welcome to #lobby.')
    assert.equal(rowTitle('Welcome to **#lobby**.', '  '), 'Welcome to #lobby.')
    assert.equal(rowTitle('long opening', 'the **gist**'), 'the gist')
    assert.equal(rowTitle('a'.repeat(120)), 'a'.repeat(100) + '…')
    assert.equal(rowTitle(''), '')
    assert.ok(!rowTitle('hello').startsWith('Topic:'))
  })

  it('a topic title is the first 100 characters of the first message', () => {
    assert.equal(topicOpening(''), '')
    assert.equal(topicOpening('  hello\nworld  '), 'hello world')
    assert.equal(topicOpening('ä'.repeat(101)), 'ä'.repeat(100) + '...')
    assert.equal(topicOpening('a'.repeat(100)), 'a'.repeat(100))
    assert.equal(topicOpening('a'.repeat(101)), 'a'.repeat(100) + '...')
    assert.equal(topicTitleFromRows([], null), '')
    assert.equal(topicTitleFromRows([{ ts: '2', body: 'later' }, { ts: '1', body: 'starter' }], null), 'starter')
    assert.equal(topicTitleFromRows([{ ts: '1', body: 'starter' }], { body: 'the pinned root' }), 'the pinned root')
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
    assert.deepEqual(r, { roster: { 'box-a': ['CLE-07'] }, online: ['CLE-07@box-a'], owners: [] })
    assert.deepEqual(channelsFromView({ channels: [{ channel: 'alerts', count: 1 }] }), [{ channel_id: 'alerts', name: 'alerts', count: 1 }])
  })

  it('renders a body as text, never as markup', () => {
    const html = renderBody('<script>alert(1)</script> <img src=x onerror=alert(1)>')
    assert.equal(html.includes('<script'), false)
    assert.equal(html.includes('<img'), false)
    assert.equal(html.includes('&lt;script&gt;'), true)
  })
})

describe('spool-client live (view-v1)', () => {
  it('lists topics from /v1/view/topics with a bearer token and no cookies', async () => {
    const { fn, calls } = stubFetch({ '/v1/view/topics?': [200, { topics: [{ task_id: T, first_ts: 'a', last_ts: 'b', count: 1, kinds: {}, participants: [], subject: 'hi' }], next: 'n1' }] })
    const c = createSpoolClient({ base: 'http://t1.localhost:58080/', fetchFn: fn, mock: false, token: 'tok' })
    const out = await c.listTopics({ limit: 10 })
    assert.equal(out.topics[0].subject, 'hi')
    assert.equal(out.next, 'n1')
    assert.equal(calls[0].url, 'http://t1.localhost:58080/v1/view/topics?limit=10')
    assert.equal(calls[0].opts.headers.authorization, 'Bearer tok')
    assert.equal(calls[0].opts.credentials, 'omit')
  })

  it('reads one topic from /v1/view/topics/{task_id}', async () => {
    const { fn, calls } = stubFetch({ [`/v1/view/topics/${T}`]: [200, { task_id: T, messages: [{ cursor: 'c', env: { from_box: 'a', to_box: 'b', msg: { v: 1, msg_id: 'm', task_id: T } } }], next: null }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const out = await c.getTopic(T)
    assert.equal(out.messages[0].from_box, 'a')
    assert.equal(calls[0].url.startsWith(`/v1/view/topics/${T}?`), true)
    assert.equal('authorization' in calls[0].opts.headers, false)
  })

  it('polls one topic with after=<cursor>', async () => {
    const { fn, calls } = stubFetch({ [`/v1/view/topics/${T}`]: [200, { task_id: T, messages: [], next: null }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await c.getTopic(T, { after: 'c 9' })
    assert.equal(new URL(calls[0].url, 'http://x').searchParams.get('after'), 'c 9')
  })

  it('asks view-v1 §4.4 for newest-first windows with order=desc and before=', async () => {
    const { fn, calls } = stubFetch({ [`/v1/view/topics/${T}`]: [200, { task_id: T, messages: [], next: 'c-old' }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const out = await c.getTopic(T, { order: 'desc', limit: 50, before: 'c9' })
    const q = new URL(calls[0].url, 'http://x').searchParams
    assert.equal(q.get('order'), 'desc')
    assert.equal(q.get('limit'), '50')
    assert.equal(q.get('before'), 'c9')
    assert.equal(q.get('after'), null)
    assert.equal(out.next, 'c-old')
  })

  it('mock desc windows page newest to oldest until next is null', async () => {
    const c = createSpoolClient({ mock: true })
    const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    const seen = []
    let before
    for (let i = 0; i < 10; i++) {
      const page = await c.getTopic(id, { order: 'desc', limit: 2, before })
      seen.push(...page.messages.map((m) => m.ts))
      if (!page.next) break
      before = page.next
    }
    assert.equal(seen.length, 4)
    assert.deepEqual(seen, seen.slice().sort().reverse())
  })

  it('surfaces the error token and status', async () => {
    const { fn } = stubFetch({ '/v1/view/topics': [401, { error: 'view_door' }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.listTopics(), (e) => e.status === 401 && e.token === 'view_door')
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
    await assert.rejects(c.listTopics(), (e) => e.status === 0 && e.token === 'api_host')
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
    assert.equal(calls[1].opts.credentials, 'omit')
  })

  it('downloads with the member session cookie in the session door (017 FR-SEC-002)', async () => {
    const calls = []
    const fn = async (url, opts) => {
      calls.push({ url, opts })
      return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([7]).buffer }
    }
    const c = createSpoolClient({ base: 'http://t1.localhost:58080', fetchFn: fn, mock: false, door: 'session' })
    await c.downloadFile('f1')
    assert.equal(calls[0].opts.credentials, 'include')
    c.setDoor('token')
    await c.downloadFile('f1')
    assert.equal(calls[1].opts.credentials, 'omit')
  })

  it('mock upload is content-addressed and downloads identical bytes', async () => {
    const c = createSpoolClient({ mock: true })
    const bytes = new TextEncoder().encode('hello spool')
    const up = await c.uploadFile(new Blob([bytes]))
    assert.equal(up.file_id, await sha256Hex(bytes.buffer))
    assert.equal(up.bytes, bytes.byteLength)
    assert.deepEqual(new Uint8Array(await c.downloadFile(up.file_id)), bytes)
  })

  it('mock mode serves topics without a hub', async () => {
    const c = createSpoolClient({ mock: true })
    const { topics } = await c.listTopics()
    assert.ok(topics.length >= 1)
    const one = await c.getTopic(topics[0].task_id)
    assert.ok(one.messages.length >= 1)
  })
})

// view-v1 §4.1 (#feedback, owner 2026-09-25): owner:true humans become roster.owners.
describe('rosterFromView owners', () => {
  it('lists only owner:true HUM-n ids', () => {
    const r = rosterFromView({ boxes: [], humans: [
      { human_id: 'HUM-10', owner: true },
      { human_id: 'HUM-3' },
      { human_id: 'HUM-4', owner: 'yes' },
    ] })
    assert.deepEqual(r.owners, ['HUM-10'])
    assert.ok(r.roster['box-wui'].includes('HUM-3'))
  })
  it('CONTROL: no humans, no owners', () => {
    assert.deepEqual(rosterFromView({}).owners, [])
  })
})

/* DB payload cut 4 (hub view.go viewMsgsIn): a list element leaves out
   env.sig, an empty msg.files, empty reactions, the default [box-wui sent]
   and a msg.task_id equal to the topic's. Each test fails without its
   default in normalizeViewMessage. */
describe('view list element defaults (DB payload cut 4)', () => {
  const trimmed = () => ({ cursor: 'c', received_at: 'r', is_parent: 1,
    env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: 'm', from: 'HUM-1', to: '@lobby', kind: 'msg', body: 'hi' } } })

  it('files default to []', () => {
    assert.deepEqual(normalizeViewMessage(trimmed(), T).files, [])
  })
  it('reactions default to []', () => {
    assert.deepEqual(normalizeViewMessage(trimmed(), T).reactions, [])
  })
  it('deliveries default to [box-wui sent]', () => {
    assert.deepEqual(normalizeViewMessage(trimmed(), T).deliveries, [{ to_box: 'box-wui', state: 'sent' }])
    assert.deepEqual(DEFAULT_DELIVERY, { to_box: 'box-wui', state: 'sent' })
  })
  it('task_id defaults to the topic it was read under', () => {
    assert.equal(normalizeViewMessage(trimmed(), T).task_id, T)
  })
  it('CONTROL: what the hub did send wins over every default', () => {
    const el = trimmed()
    el.env.msg.task_id = 'other'
    el.env.msg.files = [{ file_id: 'f' }]
    el.deliveries = []
    el.reactions = [{ emoji: '👍', actors: ['HUM-2'] }]
    const m = normalizeViewMessage(el, T)
    assert.equal(m.task_id, 'other')
    assert.deepEqual(m.files, [{ file_id: 'f' }])
    assert.deepEqual(m.deliveries, [])
    assert.equal(m.reactions.length, 1)
  })
  it('CONTROL: a moved row keeps its place, not the topic default', () => {
    const el = trimmed()
    el.task_id = 'moved-here'
    assert.equal(normalizeViewMessage(el, T).task_id, 'moved-here')
  })
  it('archive cards (topic "") default the arrays but never a task_id', () => {
    const m = normalizeViewMessage(trimmed(), '')
    assert.deepEqual(m.files, [])
    assert.equal('task_id' in m, false)
  })
  it('CONTROL: an edit answer (no topic) gets no default, so applyEdit keeps the held reactions', () => {
    const m = normalizeViewMessage({ ...trimmed(), deliveries: [{ to_box: 'box-b', state: 'queued' }] })
    assert.equal('reactions' in m, false)
    assert.equal('files' in m, false)
  })
  it('getTopic defaults every element under its topic id', async () => {
    const { fn } = stubFetch({ [`/v1/view/topics/${T}`]: [200, { task_id: T, messages: [trimmed(), trimmed()], next: null }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const out = await c.getTopic(T)
    for (const m of out.messages) {
      assert.equal(m.task_id, T)
      assert.deepEqual(m.reactions, [])
      assert.deepEqual(m.deliveries, [{ to_box: 'box-wui', state: 'sent' }])
    }
  })
  it('per_topic inline messages default under their own topic id', async () => {
    const row = { task_id: T, first_ts: 'a', last_ts: 'b', count: 2, kinds: {}, participants: [], subject: 'hi', messages: [trimmed(), trimmed()] }
    const { fn } = stubFetch({ '/v1/view/topics?': [200, { topics: [row], next: null }] })
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const out = await c.listTopics({ perTopic: 2 })
    for (const m of out.topics[0].inline.messages) {
      assert.equal(m.task_id, T)
      assert.deepEqual(m.files, [])
    }
  })
})
