/**
 * SPL-5250: the channel store's refresh() (readFirstPage) and its older-page
 * and catch-up reads answer for the feed they were asked for. Steps: open feed
 * A, switch to feed B before A's read returns, let B's read return, then A's.
 * Before the guard A's rows replaced B's, and A's `loading = false` landed while
 * B's read was still in flight. R7 (c-544, msg 819963d6): A -> B -> A let the
 * first A read land again, as the feed matched; each opening is now a new
 * generation. readMore is the older-page (loadOlder) and catch-up (catchUp)
 * read: the same cases with land/fail steps shaped like the store's.
 */
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { openFeed, readFirstPage, readMore, sameFeed } from '../../src/utils/feed-read.mjs'

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

/** Open A, then B, then A again: three first-page reads in flight. */
function aba() {
  const s = store()
  const hub = slowHub()
  const log = []
  s.active.value = 'a'
  const a1 = readFirstPage(s, steps(hub, log))
  s.active.value = 'b'
  const b = readFirstPage(s, steps(hub, log))
  s.active.value = 'a'
  const a2 = readFirstPage(s, steps(hub, log))
  return { s, hub, log, a1, b, a2 }
}

describe('SPL-5250 R7: A -> B -> A, only the newest opening of A lands', () => {
  it('A1 returns while A2 is in flight: no A1 rows, loading stays true', async () => {
    const { s, hub, log, a1, b, a2 } = aba()
    hub.calls[0].resolve(page('a-old'))
    await a1
    assert.equal(s.loading.value, true, 'A2 is still loading')
    assert.deepEqual(s.messages.value, [])
    assert.equal(log.some(([k]) => k === 'keep'), false, 'A1 is not kept as the offline copy')
    hub.calls[1].resolve(page('b1'))
    await b
    assert.deepEqual(s.messages.value, [])
    hub.calls[2].resolve(page('a-new'))
    await a2
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a-new'])
    assert.equal(s.loading.value, false)
  })
  it('A1 returns after A2: A2 rows, cursor and offline copy stay', async () => {
    const { s, hub, log, a1, b, a2 } = aba()
    hub.calls[2].resolve(page('a-new'))
    await a2
    hub.calls[0].resolve(page('a-old'))
    await a1
    hub.calls[1].resolve(page('b1'))
    await b
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a-new'])
    assert.equal(s.olderCursor.value, 'next-a-new')
    assert.equal(log.filter(([k]) => k === 'keep').length, 1)
  })
  it('A1 fails after A2 landed: no error line', async () => {
    const { s, hub, a1, b, a2 } = aba()
    hub.calls[2].resolve(page('a-new'))
    await a2
    hub.calls[0].reject(new Error('A1 failed'))
    await a1
    hub.calls[1].resolve(page('b1'))
    await b
    assert.equal(s.error.value, null)
  })
  it('a background poll of A started before A was opened again changes nothing', async () => {
    const s = store()
    const hub = slowHub()
    s.active.value = 'a'
    const poll = readFirstPage(s, steps(hub, []), { background: true })
    s.active.value = 'b'
    const b = readFirstPage(s, steps(hub, []))
    s.active.value = 'a'
    const a2 = readFirstPage(s, steps(hub, []))
    hub.calls[2].resolve(page('a-new'))
    await a2
    hub.calls[0].resolve(page('a-poll-old'))
    await poll
    hub.calls[1].resolve(page('b1'))
    await b
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a-new'])
  })
  it('a background poll started after the opening lands (same generation)', async () => {
    const s = store()
    const hub = slowHub()
    s.active.value = 'a'
    const a = readFirstPage(s, steps(hub, []))
    hub.calls[0].resolve(page('a1'))
    await a
    const poll = readFirstPage(s, steps(hub, []), { background: true })
    hub.calls[1].resolve(page('a2'))
    await poll
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a2'])
  })
})

/** land/fail steps shaped like loadOlder's (append, cursor) and catchUp's (sync cursor). */
function moreSteps(hub, s, log) {
  return {
    read: hub.read,
    land: (pg, where) => {
      log.push(['land', where])
      s.messages.value = [...s.messages.value, ...pg.messages]
      s.olderCursor.value = pg.next || null
    },
    fail: (e) => { log.push(['fail']); s.error.value = e.message },
  }
}

/** Feed A open with page a1, a follow-up read of A started, then `moves` run. */
async function moreOnA(moves) {
  const s = store()
  const hub = slowHub()
  const log = []
  s.active.value = 'a'
  const first = readFirstPage(s, steps(hub, []))
  hub.calls[0].resolve(page('a1'))
  await first
  const more = readMore(s, moreSteps(hub, s, log))
  const opened = moves(s, hub)
  return { s, hub, log, more, opened }
}

describe('SPL-5250 readMore (loadOlder, catchUp): a stale follow-up read changes nothing', () => {
  it('A -> B: A\'s older page returns on B: no rows appended, cursor kept', async () => {
    const { s, hub, log, more, opened } = await moreOnA((s, hub) => {
      s.active.value = 'b'
      return readFirstPage(s, steps(hub, []))
    })
    hub.calls[2].resolve(page('b1'))
    await opened
    hub.calls[1].resolve(page('a-older'))
    await more
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['b1'])
    assert.equal(s.olderCursor.value, 'next-b1')
    assert.deepEqual(log, [])
  })
  it('A -> B -> A: the read of the first A opening never lands on the second', async () => {
    const { s, hub, log, more, opened } = await moreOnA((s, hub) => {
      s.active.value = 'b'
      const b = readFirstPage(s, steps(hub, []))
      s.active.value = 'a'
      return Promise.all([b, readFirstPage(s, steps(hub, []))])
    })
    hub.calls[2].resolve(page('b1'))
    hub.calls[3].resolve(page('a2'))
    await opened
    hub.calls[1].resolve(page('a-older'))
    await more
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a2'])
    assert.equal(s.olderCursor.value, 'next-a2')
    assert.deepEqual(log, [], 'no land: catchUp would set its sync cursor from the old read')
  })
  it('A -> B -> A: its failure shows no error', async () => {
    const { s, hub, log, more, opened } = await moreOnA((s, hub) => {
      s.active.value = 'b'
      const b = readFirstPage(s, steps(hub, []))
      s.active.value = 'a'
      return Promise.all([b, readFirstPage(s, steps(hub, []))])
    })
    hub.calls[2].resolve(page('b1'))
    hub.calls[3].resolve(page('a2'))
    await opened
    hub.calls[1].reject(new Error('older failed'))
    await more
    assert.equal(s.error.value, null)
    assert.deepEqual(log, [])
  })
  it('A still open (a background poll in between): the read lands; a failure shows', async () => {
    const { s, hub, log, more, opened } = await moreOnA((s, hub) => readFirstPage(s, steps(hub, []), { background: true }))
    hub.calls[2].resolve(page('a1'))
    await opened
    hub.calls[1].resolve(page('a-older'))
    await more
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a1', 'a-older'])
    assert.deepEqual(log, [['land', { channel: 'a', peer: undefined }]])
    const again = readMore(s, moreSteps(hub, s, log))
    hub.calls[3].reject(new Error('older failed'))
    await again
    assert.equal(s.error.value, 'older failed')
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
  it('loadOlder() and catchUp() read through readMore, with no store write outside its steps', () => {
    for (const name of ['loadOlder', 'catchUp']) {
      const b = body(name)
      assert.match(b, /await readMore\(s, \{/, name)
      assert.doesNotMatch(b.slice(0, b.indexOf('await readMore(')), /await /, `${name}: nothing awaited before readMore`)
    }
  })
})
