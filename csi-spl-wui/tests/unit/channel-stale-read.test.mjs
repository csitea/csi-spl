/**
 * SPL-5250: the channel store's refresh() (readFirstPage) and its older-page
 * and catch-up reads answer for the feed they were asked for. Steps: open feed
 * A, switch to feed B before A's read returns, let B's read return, then A's.
 * Before the guard A's rows replaced B's, and A's `loading = false` landed while
 * B's read was still in flight.
 */
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { openFeed, readFirstPage, sameFeed } from '../../src/utils/feed-read.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const ref = (value) => ({ value })

function store() {
  return {
    active: ref(null), peer: ref(null), messages: ref([]), loading: ref(false), error: ref(null),
    totals: ref({}), olderCursor: ref(null), offlineAt: ref(null),
  }
}

/** A hub whose reads return only when the test says so. */
function slowHub() {
  const calls = []
  const read = (where) => new Promise((resolve, reject) => calls.push({ where, resolve, reject }))
  return { calls, read }
}

function steps(hub, log) {
  return {
    read: hub.read,
    withHeld: (rows) => rows,
    keep: (where) => log.push(['keep', where]),
    showKept: async (_e, where) => { log.push(['showKept', where]); return false },
    follow: () => log.push(['follow']),
    failed: (e) => e.message,
  }
}

const page = (id) => ({ messages: [{ msg_id: id }], totals: { [id]: { count: 1, last_ts: 't' } }, next: `next-${id}` })
const tick = () => new Promise((r) => setImmediate(r))

/** Open A, switch to B; return the store, the two pending reads and the log. */
async function aThenB(feedB = { active: 'b', peer: null }) {
  const s = store()
  const hub = slowHub()
  const log = []
  s.active.value = 'a'
  const ra = readFirstPage(s, steps(hub, log))
  s.active.value = feedB.active
  s.peer.value = feedB.peer
  const rb = readFirstPage(s, steps(hub, log))
  assert.equal(hub.calls.length, 2)
  return { s, hub, log, ra, rb }
}

describe('SPL-5250 readFirstPage: a late read of the feed left behind changes nothing', () => {
  it('A returns after B: B rows, totals and cursor stay (n=1, deterministic)', async () => {
    const { s, hub, log, ra, rb } = await aThenB()
    hub.calls[1].resolve(page('b1'))
    await rb
    hub.calls[0].resolve(page('a1'))
    await ra
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['b1'])
    assert.deepEqual(Object.keys(s.totals.value), ['b1'])
    assert.equal(s.olderCursor.value, 'next-b1')
    assert.deepEqual(log.filter(([k]) => k === 'keep').map(([, w]) => w), [{ channel: 'b', peer: undefined }], 'A is not kept as the offline copy')
  })
  it('A returns while B is in flight: loading stays true, no A rows, then B lands', async () => {
    const { s, hub, ra, rb } = await aThenB()
    hub.calls[0].resolve(page('a1'))
    await ra
    assert.equal(s.loading.value, true, 'B is still loading')
    assert.deepEqual(s.messages.value, [])
    hub.calls[1].resolve(page('b1'))
    await rb
    assert.equal(s.loading.value, false)
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['b1'])
  })
  it('A fails late: no error line, no kept copy of A, loading untouched', async () => {
    const { s, hub, log, ra, rb } = await aThenB()
    hub.calls[0].reject(new Error('A failed'))
    await ra
    assert.equal(s.error.value, null)
    assert.equal(s.loading.value, true)
    assert.equal(log.some(([k]) => k === 'showKept'), false)
    hub.calls[1].resolve(page('b1'))
    await rb
  })
  it('channel A to a DM with peer p: the channel read changes nothing', async () => {
    const { s, hub, ra, rb } = await aThenB({ active: null, peer: 'p' })
    assert.deepEqual(hub.calls[1].where, { channel: undefined, peer: 'p' })
    hub.calls[1].resolve(page('d1'))
    await rb
    hub.calls[0].resolve(page('a1'))
    await ra
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['d1'])
  })
  it('the feed still open: the read lands, a failure shows its error', async () => {
    const s = store()
    const hub = slowHub()
    s.active.value = 'a'
    const r = readFirstPage(s, steps(hub, []))
    assert.equal(s.loading.value, true)
    hub.calls[0].resolve(page('a1'))
    await r
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a1'])
    assert.equal(s.loading.value, false)
    const r2 = readFirstPage(s, steps(hub, []))
    hub.calls[1].reject(new Error('down'))
    await r2
    assert.equal(s.error.value, 'down')
    assert.equal(s.loading.value, false)
  })
  it('background (the mock poll) never touches loading', async () => {
    const s = store()
    const hub = slowHub()
    s.active.value = 'a'
    const r = readFirstPage(s, steps(hub, []), { background: true })
    assert.equal(s.loading.value, false)
    hub.calls[0].resolve(page('a1'))
    await r
    await tick()
    assert.equal(s.loading.value, false)
  })
})

describe('SPL-5250 sameFeed / openFeed', () => {
  it('null and undefined are the same; channel and DM never match', () => {
    const s = store()
    s.active.value = 'a'
    assert.deepEqual(openFeed(s), { channel: 'a', peer: undefined })
    assert.equal(sameFeed({ channel: 'a', peer: null }, s), true)
    assert.equal(sameFeed({ channel: 'b' }, s), false)
    s.active.value = null
    s.peer.value = 'a'
    assert.equal(sameFeed({ channel: 'a' }, s), false)
    assert.equal(sameFeed({ peer: 'a' }, s), true)
  })
})

describe('SPL-5250 wiring in stores/channel.ts', () => {
  const st = readFileSync(join(SRC, 'stores/channel.ts'), 'utf8')
  const body = (name) => {
    const i = st.indexOf(`async function ${name}(`)
    assert.ok(i > 0, name)
    return st.slice(i, st.indexOf('\n  }\n', i))
  }
  it('refresh() reads through readFirstPage', () => {
    assert.match(body('refresh'), /await readFirstPage\(s, \{/)
  })
  it('loadOlder() and catchUp() check sameFeed after the read and in the catch', () => {
    for (const name of ['loadOlder', 'catchUp']) {
      const b = body(name)
      assert.equal((b.match(/if \(!sameFeed\(where, s\)\) return/g) || []).length, 2, name)
    }
  })
})
