// 013 on /channel and /dm (X3): newest first under the Omnibox, the same
// LiveFeed / Omnibox as /lobby, and the channel ThreadPane reversed too.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { channelView, feedRow, mergeLive, rowFromAck } from '../../src/utils/channel-feed.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')
const ids = (v) => v.rows.map((m) => m.msg_id)

function msg(n, extra = {}) {
  const hh = String(n).padStart(2, '0')
  return { msg_id: `m${hh}`, task_id: `t${hh}`, ts: `2026-09-19T10:${hh}:00Z`, from: 'HUM-2', kind: 'note', body: `root ${n}`, channel: 'lobby', parent_task_id: null, ...extra }
}

describe('channelView (X3 ordering)', () => {
  it('renders roots newest first although the store holds them oldest first', () => {
    assert.deepEqual(ids(channelView([msg(1), msg(2), msg(3)])), ['m03', 'm02', 'm01'])
  })

  it('a live append of a new root lands on top', () => {
    const rows = mergeLive([msg(1), msg(2)], msg(3))
    assert.deepEqual(ids(channelView(rows)), ['m03', 'm02', 'm01'])
  })

  it('our own send (rowFromAck) lands on top', () => {
    const ack = { msg_id: 'mine', task_id: 'tm', received_at: '2026-09-19T11:00:00Z' }
    const own = rowFromAck(ack, { task_id: 'tm', kind: 'note', body: 'hi' }, { from: 'HUM-2', channel: 'lobby' })
    assert.deepEqual(ids(channelView(mergeLive([msg(1), msg(2)], own))), ['mine', 'm02', 'm01'])
  })

  it('a live in-thread reply bumps no card and keeps the order (one card per task_id)', () => {
    const reply = { ...msg(9), msg_id: 'r1', task_id: 't01' }
    assert.deepEqual(ids(channelView(mergeLive([msg(1), msg(2)], reply))), ['m02', 'm01'])
  })

  it('after a load of older pages the older rows go to the bottom, newest stays on top', () => {
    const newer = [msg(40), msg(41), msg(42)]
    const older = [msg(10), msg(11)]
    const merged = older.reduce((rows, m) => mergeLive(rows, m), newer)
    assert.deepEqual(ids(channelView(merged)), ['m42', 'm41', 'm40', 'm11', 'm10'])
  })

  it('windows: the first `visible` rows, hasOlder until the sentinel reveals the rest', () => {
    const rows = Array.from({ length: 60 }, (_, i) => msg(i))
    const first = channelView(rows, { visible: 50 })
    assert.equal(first.rows.length, 50)
    assert.equal(first.hasOlder, true)
    assert.equal(first.rows[0].msg_id, 'm59')
    const all = channelView(rows, { visible: 100 })
    assert.equal(all.hasOlder, false)
    assert.equal(all.rows[59].msg_id, 'm00')
  })

  it('view-v1 §4.3 thread rows (live) sort by their first_ts, newest first', () => {
    const a = feedRow({ task_id: 'ta', first_ts: '2026-09-19T09:00:00Z', count: 3, participants: ['HUM-2@box-wui'] })
    const b = feedRow({ task_id: 'tb', first_ts: '2026-09-19T09:05:00Z', count: 1, participants: ['CLE-7@box-a'] })
    assert.deepEqual(ids(channelView([a, b])), ['tb', 'ta'])
  })

  it('/search filters without reordering', () => {
    const v = channelView([msg(1), msg(2, { body: 'deploy done' }), msg(3, { body: 'deploy started' })], { search: 'deploy' })
    assert.deepEqual(ids(v), ['m03', 'm02'])
  })
})

describe('X3 wiring: the lobby pattern on /channel, /dm and the channel ThreadPane', () => {
  for (const page of ['pages/channel/[name].vue', 'pages/dm/[peer].vue']) {
    it(`${page}: Omnibox above the feed`, () => {
      const s = read(page)
      const omni = s.indexOf('<MessageComposer')
      assert.ok(omni > 0 && s.slice(omni, s.indexOf('/>', omni)).includes('omnibox'))
      assert.ok(omni < s.indexOf('<MessageFeed'), 'composer before the feed')
      assert.match(s, /@search="channel\.setSearch"/)
    })
  }

  it('MessageFeed renders LiveFeed (no second feed implementation)', () => {
    const s = read('components/MessageFeed.vue')
    assert.match(s, /<LiveFeed/)
    assert.match(s, /channel\.newestFirst/)
    assert.doesNotMatch(s, /v-for=/)
  })

  it('ThreadPane: pinned root, reply Omnibox, newest-first replies via LiveFeed', () => {
    const s = read('components/ThreadPane.vue')
    const root = s.indexOf('pinned-root')
    const omni = s.indexOf('<MessageComposer')
    const feed = s.indexOf('<LiveFeed')
    assert.ok(root > 0 && root < omni && omni < feed)
    assert.match(s, /rootAndReplies/)
  })
})
