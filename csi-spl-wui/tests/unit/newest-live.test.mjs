// 013 US7 (CLE-3412): newest on top everywhere, pushed live — ordering,
// dedupe of our optimistic send, scroll anchoring, reconnect catch-up, and
// the WS follows for DMs and the topic list (wui-live-ws v0.5).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { mergeById, newestFirst, pendingRow, withoutMsg } from '../../src/utils/feed.mjs'
import { channelView, dmFollow, feedRow, mergeLive, mergePage, rowFromAck } from '../../src/utils/channel-feed.mjs'
import { anchorAfterPrepend, layoutTop, NEAR_TOP_PX, prependedCount, scrollerOf } from '../../src/utils/scroll-anchor.mjs'
import { bumpTopic, mergeTopicPage } from '../../src/utils/topic-list.mjs'
import { createLiveClient } from '../../src/utils/live-ws.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')
const ids = (rows) => rows.map((m) => m.msg_id)

function msg(n, extra = {}) {
  const hh = String(n).padStart(2, '0')
  return { msg_id: `m${hh}`, task_id: `t${hh}`, ts: `2026-09-19T10:${hh}:00Z`, from: 'HUM-2', kind: 'note', body: `msg ${n}`, channel: 'lobby', parent_task_id: null, ...extra }
}

describe('ordering: newest on top, prepend', () => {
  it('a live row lands on top of the rendered feed; older pages go to the bottom', () => {
    let rows = mergeById([msg(2), msg(3)], [msg(4)]).rows
    rows = mergeById(rows, [msg(1)]).rows
    assert.deepEqual(ids(newestFirst(rows)), ['m04', 'm03', 'm02', 'm01'])
  })

  it('our pending send renders on top at once', () => {
    const own = pendingRow({ msg_id: 'own', task_id: 't9', from: 'HUM-1', body: 'hi', now: new Date('2026-09-19T11:00:00Z') })
    assert.equal(own.pending, true)
    assert.deepEqual(ids(newestFirst(mergeById([msg(1), msg(2)], [own]).rows)), ['own', 'm02', 'm01'])
  })
})

describe('dedupe: optimistic send confirmed by the pushed echo (FR-013)', () => {
  it('the echo with the same msg_id replaces the pending row — one row, not two', () => {
    const own = pendingRow({ msg_id: 'own', task_id: 't9', body: 'hi' })
    const echo = { ...msg(9), msg_id: 'own', task_id: 't9', body: 'hi', cursor: 'c9' }
    const r = mergeById([msg(1), own], [echo])
    assert.equal(r.rows.length, 2)
    assert.equal(r.added.length, 0)
    assert.equal(r.confirmed, 1)
    const row = r.rows.find((m) => m.msg_id === 'own')
    assert.equal(row.pending, undefined)
    assert.equal(row.cursor, 'c9')
  })

  it('a second copy of a confirmed row (echo then ack, or a catch-up read) is dropped', () => {
    const r = mergeById([msg(1), msg(2)], [msg(2), msg(2)])
    assert.deepEqual(ids(r.rows), ['m01', 'm02'])
    assert.equal(r.confirmed, 0)
  })

  it('a pending copy never overwrites a confirmed row', () => {
    const r = mergeById([msg(2)], [{ ...msg(2), body: 'stale', pending: true }])
    assert.equal(r.rows[0].body, 'msg 2')
  })

  it('a failed send removes the pending row', () => {
    const own = pendingRow({ msg_id: 'own', task_id: 't9' })
    assert.deepEqual(ids(withoutMsg([msg(1), own], 'own')), ['m01'])
  })

  it('channel feed: echo (ingestLive) then ack (rowFromAck) leave one card on top', () => {
    const own = pendingRow({ msg_id: 'own', task_id: 'tn', from: 'HUM-1', body: 'new root', channel: 'lobby', now: new Date('2026-09-19T11:00:00Z') })
    let rows = mergeLive([msg(1), msg(2)], own)
    const echo = { ...own, pending: undefined, cursor: 'c', received_at: '2026-09-19T11:00:01Z' }
    rows = mergeLive(rows, echo)
    rows = mergeLive(rows, rowFromAck({ msg_id: 'own', task_id: 'tn', received_at: '2026-09-19T11:00:01Z' }, { task_id: 'tn', body: 'new root' }, { from: 'HUM-1', channel: 'lobby' }))
    assert.equal(rows.filter((m) => m.msg_id === 'own').length, 1)
    assert.equal(rows.find((m) => m.msg_id === 'own').pending, undefined)
    assert.deepEqual(ids(channelView(rows).rows), ['own', 'm02', 'm01'])
  })

  it('channel feed: the ack row replaces the pending card when the echo is late', () => {
    const own = pendingRow({ msg_id: 'own', task_id: 'tn', channel: 'lobby' })
    const rows = mergeLive([own], rowFromAck({ msg_id: 'own', task_id: 'tn', cursor: 'c1' }, { task_id: 'tn' }, { channel: 'lobby' }))
    assert.equal(rows.length, 1)
    assert.equal(rows[0].cursor, 'c1')
    assert.equal(rows[0].pending, undefined)
  })
})

describe('scroll anchoring (FR-012)', () => {
  it('counts only rows that arrived above the previous first row', () => {
    assert.equal(prependedCount(['a', 'b'], ['x', 'y', 'a', 'b']), 2)
    assert.equal(prependedCount(['a', 'b'], ['a', 'b', 'c']), 0, 'an older page at the bottom is not a prepend')
    assert.equal(prependedCount(['a'], ['q', 'r']), 0, 'a new filter is not a prepend')
    assert.equal(prependedCount([], ['a']), 0, 'first paint')
  })

  it('at the top: new rows just enter, no pill, no scroll move', () => {
    assert.deepEqual(anchorAfterPrepend({ top: 0, prevHeight: 1000, nextHeight: 1120, added: 1 }), { top: 0, pill: 0, moved: false })
    assert.deepEqual(anchorAfterPrepend({ top: NEAR_TOP_PX, prevHeight: 1000, nextHeight: 1120, added: 1, pill: 3 }), { top: NEAR_TOP_PX, pill: 0, moved: false })
  })

  it('scrolled down: the offset grows by the inserted height and the pill counts', () => {
    assert.deepEqual(anchorAfterPrepend({ top: 600, prevHeight: 3000, nextHeight: 3240, added: 2, pill: 1 }), { top: 840, pill: 3, moved: true })
  })

  it('the feed list is the scroller, and the document is not', () => {
    const node = (oy, sh, ch, parent = null) => ({ oy, scrollHeight: sh, clientHeight: ch, parentElement: parent })
    const html = { tag: 'html' }
    const doc = { scrollingElement: html, defaultView: { getComputedStyle: (n) => ({ overflowY: n.oy }) } }
    const body = node('auto', 3000, 600)
    const feed = node('visible', 3000, 3000, body)
    assert.equal(scrollerOf(feed, doc), body)
    assert.equal(scrollerOf(body, doc), body, 'the element itself may be the scroller')
    const short = node('auto', 500, 600)
    const list = node('visible', 500, 500, short)
    assert.equal(scrollerOf(list, doc), short, 'a feed list that does not overflow is still the scroller; the document is not')
    assert.notEqual(scrollerOf(list, doc), html)
  })

  it('with an anchor row: moves by how far that row was pushed, even when the window dropped a row at the bottom', () => {
    /* measured on dev 783a137: +112 px row on top, 52 px row dropped at the bottom -> height +60, anchor +112 */
    assert.deepEqual(anchorAfterPrepend({ top: 300, prevHeight: 3000, nextHeight: 3060, anchorBefore: 64, anchorAfter: 176, added: 1 }), { top: 412, pill: 1, moved: true })
  })

  it('layoutTop sums offsetTop up the chain (transforms never enter it)', () => {
    const page = { offsetTop: 0, offsetParent: null }
    const feed = { offsetTop: 120, offsetParent: page }
    assert.equal(layoutTop({ offsetTop: 300, offsetParent: feed }), 420)
  })

  it('nothing prepended: nothing moves', () => {
    assert.deepEqual(anchorAfterPrepend({ top: 600, prevHeight: 3000, nextHeight: 3500, added: 0, pill: 2 }), { top: 600, pill: 2, moved: false })
  })
})

describe('reconnect catch-up (FR-015)', () => {
  it('channel: a fresh first page merges by msg_id; older pages and pending sends stay; topic counts move on', () => {
    const older = feedRow({ task_id: 'old', first_ts: '2026-09-18T10:00:00Z', last_ts: '2026-09-18T10:00:00Z', count: 1, participants: ['HUM-2@box-wui'], subject: 'old' })
    const known = feedRow({ task_id: 'k', first_ts: '2026-09-19T10:00:00Z', last_ts: '2026-09-19T10:00:00Z', count: 1, participants: ['HUM-2@box-wui'], subject: 'k' })
    const own = pendingRow({ msg_id: 'own', task_id: 'o', channel: 'lobby' })
    const fresh = [
      feedRow({ task_id: 'k', first_ts: '2026-09-19T10:00:00Z', last_ts: '2026-09-19T10:05:00Z', count: 3, participants: ['HUM-2@box-wui'], subject: 'k' }),
      feedRow({ task_id: 'missed', first_ts: '2026-09-19T10:04:00Z', last_ts: '2026-09-19T10:04:00Z', count: 1, participants: ['CLE-07@box-a'], subject: 'while away' }),
    ]
    const rows = mergePage([older, known, own], fresh)
    assert.deepEqual(rows.map((r) => r.msg_id).sort(), ['k', 'missed', 'old', 'own'])
    assert.equal(rows.find((r) => r.msg_id === 'k').count, 2)
  })

  it('topic list: a fresh first page replaces rows by task_id, keeps older pages, newest first', () => {
    const t = (id, last) => ({ task_id: id, last_ts: last, count: 1, kinds: {}, participants: [], subject: id })
    const merged = mergeTopicPage([t('a', '2026-09-19T10:00:00Z'), t('z', '2026-09-01T10:00:00Z')], [{ ...t('a', '2026-09-19T10:09:00Z'), count: 4 }, t('b', '2026-09-19T10:05:00Z')])
    assert.deepEqual(merged.map((r) => r.task_id), ['a', 'b', 'z'])
    assert.equal(merged[0].count, 4)
  })
})

describe('topic list live (FR-011)', () => {
  const rows = [
    { task_id: 'a', last_ts: '2026-09-19T10:02:00Z', count: 2, kinds: { note: 2 }, participants: ['HUM-2@box-wui'], subject: 'a' },
    { task_id: 'b', last_ts: '2026-09-19T10:01:00Z', count: 1, kinds: { note: 1 }, participants: ['HUM-3@box-wui'], subject: 'b' },
  ]

  it('a reply in an older topic moves it to the top with its count bumped', () => {
    const next = bumpTopic(rows, { msg_id: 'r', task_id: 'b', from: 'CLE-07', from_box: 'box-a', to: 'ALL-0', kind: 'result', received_at: '2026-09-19T10:03:00Z' })
    assert.deepEqual(next.map((r) => r.task_id), ['b', 'a'])
    assert.equal(next[0].count, 2)
    assert.deepEqual(next[0].kinds, { note: 1, result: 1 })
    assert.deepEqual(next[0].participants, ['HUM-3@box-wui', 'CLE-07@box-a'])
  })

  it('a new root starts a row on top; a child topic does not', () => {
    const next = bumpTopic(rows, { msg_id: 'n', task_id: 'c', from: 'HUM-1', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: 'hello\nworld', channel: 'lobby', received_at: '2026-09-19T10:04:00Z' })
    assert.equal(next[0].task_id, 'c')
    assert.equal(next[0].subject, 'hello')
    assert.equal(next[0].count, 1)
    assert.equal(bumpTopic(rows, { msg_id: 'x', task_id: 'kid', parent_task_id: 'a', received_at: '2026-09-19T10:05:00Z' }), rows)
    assert.equal(bumpTopic(rows, { msg_id: 'z', task_id: 'new', is_parent: 0, body: 'reply', received_at: '2026-09-19T10:06:00Z' }), rows)
    /* the send and its echo are one message */
    const again = bumpTopic(next, { msg_id: 'n', task_id: 'c', body: 'hello', received_at: '2026-09-19T10:04:00Z' })
    assert.equal(again[0].count, 1)
  })
})

describe('WS follows: DM peer and topic list (wui-live-ws v0.5)', () => {
  function fakeWs() {
    const sockets = []
    class FakeWS {
      constructor() { this.sent = []; sockets.push(this) }
      send(s) { this.sent.push(JSON.parse(s)) }
      close() { this.onclose && this.onclose() }
    }
    return { FakeWS, sockets }
  }

  it('subscribes a peer and all once, re-sends both after a reconnect, then catch-up fires', () => {
    const { FakeWS, sockets } = fakeWs()
    const timers = []
    let reconnected = 0
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: (fn) => { timers.push(fn); return fn }, onReconnected: () => { reconnected++ } })
    c.connect(); sockets[0].onopen(); sockets[0].onmessage({ data: JSON.stringify({ type: 'welcome' }) })
    c.subscribePeer('HUM-2'); c.subscribePeer('HUM-2'); c.subscribeAll(); c.subscribeAll()
    assert.deepEqual(sockets[0].sent.slice(1), [{ type: 'subscribe', peer: 'HUM-2' }, { type: 'subscribe', all: true }])
    sockets[0].onclose()
    timers[0]()
    sockets[1].onopen(); sockets[1].onmessage({ data: JSON.stringify({ type: 'welcome' }) })
    assert.deepEqual(sockets[1].sent.slice(1), [{ type: 'subscribe', peer: 'HUM-2' }, { type: 'subscribe', all: true }])
    assert.equal(reconnected, 1)
    /* CLE-3425: `all` is ref-counted - two holders (the topic list on `/` and
       the tab-wide shell follow), so the FIRST unsubscribe must not drop it. */
    c.unsubscribePeer('HUM-2'); c.unsubscribeAll()
    assert.deepEqual(sockets[1].sent.slice(3), [{ type: 'unsubscribe', peer: 'HUM-2' }],
      'one of the two `all` holders left: the follow stays')
    c.unsubscribeAll()
    assert.deepEqual(sockets[1].sent.slice(3), [{ type: 'unsubscribe', peer: 'HUM-2' }, { type: 'unsubscribe', all: true }])
    c.unsubscribeAll()
    assert.deepEqual(sockets[1].sent.slice(5), [], 'CONTROL: an extra unsubscribe sends nothing')
  })

  it('dmFollow moves the peer subscription with the open DM', () => {
    assert.deepEqual(dmFollow('', { peer: 'HUM-2' }), { sub: 'HUM-2', unsub: '', next: 'HUM-2' })
    assert.deepEqual(dmFollow('HUM-2', { peer: 'CLE-07@box-a' }), { sub: 'CLE-07@box-a', unsub: 'HUM-2', next: 'CLE-07@box-a' })
    assert.deepEqual(dmFollow('HUM-2', { peer: null }), { sub: '', unsub: 'HUM-2', next: '' })
  })
})

describe('wiring (no view polls in live mode)', () => {
  it('LiveFeed and the topic list anchor the scroll and show the pill', () => {
    for (const f of ['components/LiveFeed.vue', 'pages/index.vue']) {
      assert.match(read(f), /useScrollAnchor\(/, f)
      assert.match(read(f), /new-pill/, f)
    }
  })

  it('the channel store follows the open DM peer and catches up by merge', () => {
    const s = read('stores/channel.ts')
    assert.match(s, /subscribePeer\(/)
    assert.match(s, /mergePage\(/)
    assert.match(read('composables/useSpoolEvents.ts'), /channel\.catchUp\(\)/)
  })

  it('the topic list follows the tenant and bumps rows live', () => {
    const s = read('stores/viewer.ts')
    assert.match(s, /subscribeAll\(\)/)
    assert.match(s, /bumpTopic\(/)
    assert.doesNotMatch(s, /setInterval/)
  })

  it('every store send is optimistic under the msg_id it sends', () => {
    assert.match(read('stores/live.ts'), /msg_id: msgId/)
    assert.match(read('stores/channel.ts'), /frame\.msg_id = newId\(\)/)
    assert.match(read('components/TopicPane.vue'), /rowsForRightPane/)
  })
})
