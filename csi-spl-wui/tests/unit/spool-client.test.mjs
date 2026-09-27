import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createSpoolClient, credentialsFor } from '../../src/utils/spool-client.mjs'

describe('spool-client mock', () => {
  it('lists default channels and catch-up of 50', async () => {
    const c = createSpoolClient({ mock: true })
    const channels = await c.listChannels()
    assert.deepEqual(channels.map((x) => x.channel_id), ['lobby', 'alerts', 'feedback'])
    const { messages: feed, next } = await c.listMessages({ channel: 'lobby', limit: 50 })
    assert.ok(feed.length >= 1)
    assert.equal(feed.every((m) => m.channel === 'lobby'), true)
    assert.equal(next, null)
  })

  it('a person\'s post is a note, an @mention included, and appends it', async () => {
    const c = createSpoolClient({ mock: true })
    const sent = await c.sendMessage({ channel: 'dev', text: '@GRK-03 ship it' })
    assert.equal(sent.kind, 'note', 'owner 2026-09-26: human posts are notes; the card badge re-types them')
    assert.equal(sent.to, 'GRK-03')
    assert.equal(sent.channel, 'dev')
    const { messages: feed } = await c.listMessages({ channel: 'dev' })
    assert.equal(feed.some((m) => m.msg_id === sent.msg_id), true)
  })

  it('creates a channel slug and lists it', async () => {
    const c = createSpoolClient({ mock: true })
    const row = await c.createChannel({ name: 'Feature Auth' })
    assert.equal(row.channel_id, 'feature-auth')
    const channels = await c.listChannels()
    assert.equal(channels.some((x) => x.channel_id === 'feature-auth'), true)
  })

  it('DM list is channel-null messages for that peer', async () => {
    const c = createSpoolClient({ mock: true })
    const { messages: dms } = await c.listMessages({ peer: 'GRK-03@box-a' })
    assert.ok(dms.length >= 1)
    assert.equal(dms.every((m) => !m.channel), true)
  })
})

const T1 = '33330000-0000-4000-8000-00000000a001'
const T2 = '33330000-0000-4000-8000-00000000a002'

/** routes: [predicate(url, opts), [status, body]] in order; first match wins. */
function stubFetch(routes) {
  const calls = []
  const fn = async (url, opts = {}) => {
    calls.push({ url, opts })
    const hit = routes.find(([p]) => p(url, opts))
    const [status, body] = hit ? hit[1] : [404, { error: 'not_found' }]
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => 'application/json' },
      json: async () => body,
    }
  }
  return { fn, calls }
}

const el = (cursor, received_at, msg, extra = {}) => ({ cursor, received_at, env: { from_box: 'box-a', to_box: 'box-wui', ...extra, msg: { v: 1, ...msg }, sig: 's' } })

describe('spool-client live A1 (005 FR-005, channels-v1 §5, 010 FR-009)', () => {
  it('channel feed hits /v1/view/topics?channel= and merges each topic oldest-first', async () => {
    const { fn, calls } = stubFetch([
      [(u) => u.startsWith('/v1/view/topics?'), [200, { topics: [{ task_id: T2, channel: 'lobby', first_ts: 'b', last_ts: 'b', subject: 'b' }, { task_id: T1, channel: 'lobby', first_ts: 'a', last_ts: 'a', subject: 'a' }], next: null }]],
      [(u) => u.startsWith(`/v1/view/topics/${T1}?`), [200, { task_id: T1, messages: [el('c2', '2026-09-19T00:00:02Z', { msg_id: 'm2', task_id: T1 }, { channel: 'lobby' }), el('c1', '2026-09-19T00:00:01Z', { msg_id: 'm1', task_id: T1 }, { channel: 'lobby' })], next: null }]],
      [(u) => u.startsWith(`/v1/view/topics/${T2}?`), [200, { task_id: T2, messages: [el('c3', '2026-09-19T00:00:03Z', { msg_id: 'm3', task_id: T2 }, { channel: 'lobby', parent_task_id: T1 })], next: null }]],
    ])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const { messages: feed, next } = await c.listMessages({ channel: 'lobby', limit: 50 })
    const q = new URL(calls[0].url, 'http://x').searchParams
    assert.equal(q.get('channel'), 'lobby')
    assert.equal(new URL(calls[1].url, 'http://x').searchParams.get('order'), 'desc')
    assert.deepEqual(feed.map((m) => m.msg_id), ['m1', 'm2', 'm3'])
    assert.equal(feed.every((m) => m.channel === 'lobby'), true)
    assert.equal(feed[2].parent_task_id, T1)
    assert.equal(next, null)
  })

  it('DM feed asks dm=true&peer=', async () => {
    const { fn, calls } = stubFetch([[(u) => u.startsWith('/v1/view/topics?'), [200, { topics: [], next: null }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    assert.deepEqual(await c.listMessages({ peer: 'CLE-07@box-a' }), { messages: [], next: null, totals: {} })
    const q = new URL(calls[0].url, 'http://x').searchParams
    assert.equal(q.get('dm'), 'true')
    assert.equal(q.get('peer'), 'CLE-07@box-a')
    assert.equal(q.get('channel'), null)
  })

  it('topic rows keep channel / parent_task_id', async () => {
    const { fn } = stubFetch([[(u) => u.startsWith('/v1/view/topics?'), [200, { topics: [{ task_id: T2, parent_task_id: T1, channel: 'tasks', first_ts: 'a', subject: 's' }], next: null }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const { topics } = await c.listTopics({ channel: 'tasks', roots: false })
    assert.equal(topics[0].channel, 'tasks')
    assert.equal(topics[0].parent_task_id, T1)
  })

  it('listChannels sends read=<ch>~<cursor> and keeps unread / last_cursor / retention_days', async () => {
    const { fn, calls } = stubFetch([[(u) => u.startsWith('/v1/view/channels'), [200, { channels: [{ channel: 'alerts', name: 'alerts', default: true, retention_days: 7, count: 4, unread: 2, last_ts: 't', last_cursor: 'c9', members: { agents: 3, boxes: 2, posters: 1 } }] }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const [row] = await c.listChannels({ read: { alerts: 'c5', lobby: 'c1', tasks: '' } })
    assert.deepEqual(new URL(calls[0].url, 'http://x').searchParams.getAll('read'), ['alerts~c5', 'lobby~c1'])
    assert.equal(row.unread, 2)
    assert.equal(row.last_cursor, 'c9')
    assert.equal(row.retention_days, 7)
    assert.deepEqual(row.members, { agents: 3, boxes: 2, posters: 1 })
  })

  it('createChannel POSTs JSON to /v1/channels', async () => {
    const { fn, calls } = stubFetch([[(u, o) => u === '/v1/channels' && o.method === 'POST', [201, { channel: 'feature-auth', name: 'Feature Auth', created_by: 'wui', created_at: 't', default: false }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const row = await c.createChannel({ name: 'Feature Auth' })
    assert.equal(calls[0].opts.headers['content-type'], 'application/json')
    assert.deepEqual(JSON.parse(calls[0].opts.body), { channel: 'feature-auth', name: 'Feature Auth' })
    assert.deepEqual(row, { channel_id: 'feature-auth', name: 'Feature Auth', created_by: 'wui', created_at: 't', default: false })
  })

  it('createChannel maps 409 channel_exists and 400 bad_channel', async () => {
    const { fn } = stubFetch([
      [(u, o) => o.body && JSON.parse(o.body).channel === 'lobby', [409, { error: 'channel_exists' }]],
      [(u) => u === '/v1/channels', [400, { error: 'bad_channel', detail: 'slug' }]],
    ])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.createChannel({ name: 'lobby' }), (e) => e.status === 409 && e.token === 'channel_exists' && /already exists/.test(e.message))
    await assert.rejects(c.createChannel({ name: 'x' }), (e) => e.status === 400 && e.token === 'bad_channel' && e.detail === 'slug')
  })

  it('live send goes through the injected socket sender with channel / parent_task_id', async () => {
    const frames = []
    const sender = async (f) => { frames.push(f); return { msg_id: 'm1', task_id: f.task_id, cursor: 'c1', received_at: 'r1' } }
    const { fn, calls } = stubFetch([])
    const c = createSpoolClient({ fetchFn: fn, mock: false, sender })
    const out = await c.sendMessage({ channel: 'tasks', text: '@GRK-03 ship it', parent_task_id: T1, from: 'HUM-1' })
    assert.equal(calls.length, 0)
    assert.equal(frames[0].channel, 'tasks')
    assert.equal(frames[0].parent_task_id, T1)
    assert.equal(frames[0].to, 'GRK-03')
    assert.equal(frames[0].kind, 'note')
    assert.equal(out.channel, 'tasks')
    assert.equal(out.cursor, 'c1')
    const dm = await c.sendMessage({ peer: 'CLE-07@box-a', text: 'hi', task_id: T2 })
    assert.equal('channel' in frames[1], false)
    assert.equal(frames[1].to, 'CLE-07')
    assert.equal(frames[1].task_id, T2)
    assert.equal(dm.channel, null)
    await c.sendMessage({ channel: 'lobby', text: 'ambient' })
    assert.equal('to' in frames[2], false)
  })

  it('live send without a socket fails with no_socket, not a fetch', async () => {
    const { fn, calls } = stubFetch([])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.sendMessage({ channel: 'lobby', text: 'x' }), (e) => e.token === 'no_socket')
    assert.equal(calls.length, 0)
  })

  it('credentials: omit by default, include for the session door', async () => {
    assert.equal(credentialsFor('off'), 'omit')
    assert.equal(credentialsFor('token'), 'omit')
    assert.equal(credentialsFor('session'), 'include')
    const { fn, calls } = stubFetch([[() => true, [200, { topics: [], next: null }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await c.listTopics()
    assert.equal(calls[0].opts.credentials, 'omit')
    c.setDoor('session')
    assert.equal(c.credentials, 'include')
    await c.listTopics()
    assert.equal(calls[1].opts.credentials, 'include')
    const s = createSpoolClient({ fetchFn: fn, mock: false, door: 'session' })
    await s.listRoster()
    assert.equal(calls[2].opts.credentials, 'include')
  })

  it('a 401 keeps the hub error detail (door prompt, A3)', async () => {
    const { fn } = stubFetch([[() => true, [401, { error: 'view_door', detail: 'session required' }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.listTopics(), (e) => e.token === 'view_door' && e.detail === 'session required')
  })
})
