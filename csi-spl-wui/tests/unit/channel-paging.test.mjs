// A6: server paging of older threads in channel and DM feeds.
// listMessages({channel|dm, before}) passes view-v1 §4.3 next as before=;
// the channel store appends the older page at the bottom, deduped by msg_id,
// and stops when next is null.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { channelView } from '../../src/utils/channel-feed.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')

const TN = '33330000-0000-4000-8000-00000000b001'
const TM = '33330000-0000-4000-8000-00000000b002'
const TO = '33330000-0000-4000-8000-00000000b003'

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

const el = (cursor, received_at, msg, extra = {}) => ({
  cursor,
  received_at,
  env: { from_box: 'box-a', to_box: 'box-wui', ...extra, msg: { v: 1, ...msg }, sig: 's' },
})

function threadListCalls(calls) {
  return calls.filter((c) => String(c.url).startsWith('/v1/view/threads?'))
}

function beforeOf(call) {
  return new URL(call.url, 'http://x').searchParams.get('before')
}

/** The store's paging loop: first page, then loadOlder while next is set. */
async function pageFeed(api, filter) {
  const held = []
  const seen = new Set()
  let next = null
  async function pull(before) {
    const page = await api.listMessages({ ...filter, before })
    for (const m of page.messages || []) {
      if (!m.msg_id || seen.has(m.msg_id)) continue
      seen.add(m.msg_id)
      held.push(m)
    }
    next = page.next || null
  }
  await pull()
  return {
    held,
    get next() { return next },
    async loadOlder() {
      if (!next) return
      await pull(next)
    },
  }
}

const page1Threads = {
  threads: [
    { task_id: TN, channel: 'lobby', first_ts: '2026-09-19T12:00:00Z', last_ts: '2026-09-19T12:00:00Z', subject: 'newest' },
    { task_id: TM, channel: 'lobby', first_ts: '2026-09-19T11:30:00Z', last_ts: '2026-09-19T11:30:00Z', subject: 'mid' },
  ],
  next: 'CUR1',
}
const page2Threads = {
  threads: [
    { task_id: TO, channel: 'lobby', first_ts: '2026-09-19T11:00:00Z', last_ts: '2026-09-19T11:00:00Z', subject: 'oldest' },
  ],
  next: null,
}

function twoPageRoutes(dupOnPage2 = false) {
  const page2Msgs = [
    el('co', '2026-09-19T11:00:00Z', { msg_id: 'old-1', task_id: TO, ts: '2026-09-19T11:00:00Z', body: 'oldest root' }, { channel: 'lobby' }),
  ]
  if (dupOnPage2) {
    page2Msgs.push(el('cn', '2026-09-19T12:00:00Z', { msg_id: 'new-1', task_id: TN, ts: '2026-09-19T12:00:00Z', body: 'newest root' }, { channel: 'lobby' }))
  }
  return [
    [(u) => u.startsWith('/v1/view/threads?') && !new URL(u, 'http://x').searchParams.get('before'), [200, page1Threads]],
    [(u) => u.startsWith('/v1/view/threads?') && new URL(u, 'http://x').searchParams.get('before') === 'CUR1', [200, page2Threads]],
    [(u) => u.startsWith(`/v1/view/threads/${TN}?`), [200, {
      task_id: TN,
      messages: [el('cn', '2026-09-19T12:00:00Z', { msg_id: 'new-1', task_id: TN, ts: '2026-09-19T12:00:00Z', body: 'newest root' }, { channel: 'lobby' })],
      next: null,
    }]],
    [(u) => u.startsWith(`/v1/view/threads/${TM}?`), [200, {
      task_id: TM,
      messages: [el('cm', '2026-09-19T11:30:00Z', { msg_id: 'mid-1', task_id: TM, ts: '2026-09-19T11:30:00Z', body: 'mid root' }, { channel: 'lobby' })],
      next: null,
    }]],
    [(u) => u.startsWith(`/v1/view/threads/${TO}?`), [200, { task_id: TO, messages: page2Msgs, next: null }]],
  ]
}

describe('listMessages paging (view-v1 §4.3 before=/next)', () => {
  it('the 2nd call sends before=<next> from the first page', async () => {
    const { fn, calls } = stubFetch(twoPageRoutes())
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const p1 = await c.listMessages({ channel: 'lobby', threads: 2 })
    assert.equal(p1.next, 'CUR1')
    assert.deepEqual(p1.messages.map((m) => m.msg_id), ['mid-1', 'new-1'])
    const lists = threadListCalls(calls)
    assert.equal(lists.length, 1)
    assert.equal(beforeOf(lists[0]), null)
    assert.equal(new URL(lists[0].url, 'http://x').searchParams.get('channel'), 'lobby')

    const p2 = await c.listMessages({ channel: 'lobby', threads: 2, before: p1.next })
    const lists2 = threadListCalls(calls)
    assert.equal(lists2.length, 2)
    assert.equal(beforeOf(lists2[1]), 'CUR1')
    assert.equal(p2.next, null)
    assert.deepEqual(p2.messages.map((m) => m.msg_id), ['old-1'])
  })

  it('DM pages pass dm=true&peer= and before=', async () => {
    const { fn, calls } = stubFetch([
      [(u) => u.startsWith('/v1/view/threads?'), [200, { threads: [], next: 'DM1' }]],
    ])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const p1 = await c.listMessages({ peer: 'CLE-07@box-a' })
    assert.equal(p1.next, 'DM1')
    const p2 = await c.listMessages({ peer: 'CLE-07@box-a', before: p1.next })
    const lists = threadListCalls(calls)
    assert.equal(lists.length, 2)
    const q1 = new URL(lists[0].url, 'http://x').searchParams
    const q2 = new URL(lists[1].url, 'http://x').searchParams
    assert.equal(q1.get('dm'), 'true')
    assert.equal(q1.get('peer'), 'CLE-07@box-a')
    assert.equal(q1.get('before'), null)
    assert.equal(q2.get('dm'), 'true')
    assert.equal(q2.get('before'), 'DM1')
    assert.equal(p2.next, 'DM1')
  })

  it('mock mode still returns a page and never a server next', async () => {
    const c = createSpoolClient({ mock: true })
    const p1 = await c.listMessages({ channel: 'lobby' })
    assert.ok(Array.isArray(p1.messages))
    assert.ok(p1.messages.length >= 1)
    assert.equal(p1.next, null)
    const p2 = await c.listMessages({ channel: 'lobby', before: 'CUR1' })
    assert.equal(p2.next, null)
    assert.deepEqual(p2.messages.map((m) => m.msg_id), p1.messages.map((m) => m.msg_id))
  })
})

describe('channel store paging action (sentinel → older page)', () => {
  it('older rows land at the bottom; newest stays on top', async () => {
    const { fn } = stubFetch(twoPageRoutes())
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const feed = await pageFeed(c, { channel: 'lobby', threads: 2 })
    await feed.loadOlder()
    const view = channelView(feed.held)
    assert.deepEqual(view.rows.map((m) => m.msg_id), ['new-1', 'mid-1', 'old-1'])
    assert.equal(view.rows[0].body, 'newest root')
    assert.equal(view.rows[view.rows.length - 1].body, 'oldest root')
  })

  it('de-duplicates by msg_id when the older page repeats a held row', async () => {
    const { fn } = stubFetch(twoPageRoutes(true))
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const feed = await pageFeed(c, { channel: 'lobby', threads: 2 })
    await feed.loadOlder()
    const ids = feed.held.map((m) => m.msg_id)
    assert.deepEqual(ids, ['mid-1', 'new-1', 'old-1'])
    assert.equal(ids.filter((id) => id === 'new-1').length, 1)
  })

  it('does not call again once next is null', async () => {
    const { fn, calls } = stubFetch(twoPageRoutes())
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const feed = await pageFeed(c, { channel: 'lobby', threads: 2 })
    await feed.loadOlder()
    assert.equal(feed.next, null)
    const n = threadListCalls(calls).length
    await feed.loadOlder()
    await feed.loadOlder()
    assert.equal(threadListCalls(calls).length, n)
    assert.equal(n, 2)
  })
})

describe('A6 wiring in channel.ts and spool-client', () => {
  it('channel store loadOlder fetches before=<next>, appends, stops at null', () => {
    const st = read('stores/channel.ts')
    assert.match(st, /before:\s*olderCursor\.value/)
    assert.match(st, /if \(!olderCursor\.value/)
    assert.match(st, /olderCursor\.value = page\.next \|\| null/)
    assert.match(st, /\[\.\.\.messages\.value, \.\.\.add\]/)
    assert.match(st, /hasOlder \|\| Boolean\(olderCursor\.value\)/)
    assert.match(st, /async function loadOlder/)
  })

  it('listMessages accepts before and returns next', () => {
    const src = read('utils/spool-client.mjs')
    assert.match(src, /async listMessages\(\{ channel, peer, limit = 50, since, threads = 20, before \}/)
    assert.match(src, /listThreads\(\{ limit: threads, before, \.\.\.filter \}\)/)
    assert.match(src, /next: list\.next \|\| null/)
    const shim = read('types/mjs-shims.d.ts')
    assert.match(shim, /before\?: string/)
    assert.match(shim, /messages: import\('\.\/spool'\)\.SpoolMessage\[\], next: string \| null/)
  })
})
