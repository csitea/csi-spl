// 013 on /channel and /dm (X3): newest first under the Omnibox, the same
// LiveFeed / Omnibox as /lobby, and the channel TopicPane reversed too.
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

  /*
   * Owner, 2026-09-23: pane 2 is the starter again. A reply still makes that
   * topic the newest thing in the channel (CLE-3425), and the row that moves
   * is the starter — its author and its body — not the reply.
   */
  it('a live in-topic reply lifts the starter, and the row stays the starter', () => {
    const reply = { ...msg(9), msg_id: 'r1', task_id: 't01', from: 'CLE-07', body: 'pong' }
    const v = channelView(mergeLive([msg(1), msg(2)], reply))
    assert.deepEqual(ids(v), ['m01', 'm02'])
    assert.equal(v.rows[0].from, 'HUM-2', 'the row is the starter, not the replier')
    assert.equal(v.rows[0].body, 'root 1')
    assert.equal(v.rows[0].msg_id, 'm01')
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

  it('view-v1 §4.3 topic rows (live) sort by their LAST activity, newest first', () => {
    const a = feedRow({ task_id: 'ta', first_ts: '2026-09-19T09:00:00Z', count: 3, participants: ['HUM-2@box-wui'] })
    const b = feedRow({ task_id: 'tb', first_ts: '2026-09-19T09:05:00Z', count: 1, participants: ['CLE-7@box-a'] })
    assert.deepEqual(ids(channelView([a, b])), ['tb', 'ta'])
    /* CLE-3425: the same two rows, but `ta` was replied to after `tb` started —
       the busy topic is on top. The pre-2026-09-20 code sorted on first_ts and
       left it buried, which is the defect the owner reported. */
    const busy = feedRow({ task_id: 'ta', first_ts: '2026-09-19T09:00:00Z', last_ts: '2026-09-19T09:10:00Z', count: 4, participants: ['HUM-2@box-wui'] })
    assert.deepEqual(ids(channelView([busy, b])), ['ta', 'tb'])
  })

  it('/search filters without reordering', () => {
    const v = channelView([msg(1), msg(2, { body: 'deploy done' }), msg(3, { body: 'deploy started' })], { search: 'deploy' })
    assert.deepEqual(ids(v), ['m03', 'm02'])
  })
})

describe('X3 wiring: the lobby pattern on /channel, /dm and the channel TopicPane', () => {
  // 022: the page Omnibox moved into the top bar; the page registers its send target
  for (const page of ['pages/channel/[name].vue', 'pages/dm/[peer].vue', 'pages/lobby.vue']) {
    it(`${page}: sends through the top-bar Omnibox, no inline one`, () => {
      const s = read(page)
      assert.match(s, /useOmniboxTarget\(\{/)
      assert.match(s, /send: /)
      assert.doesNotMatch(s, /<MessageComposer/, 'CONTROL: no second Omnibox in the page body')
    })
  }

  it('the top bar hosts the one global Omnibox (same composer, code blocks included)', () => {
    const bar = read('components/TopBar.vue')
    const omni = bar.indexOf('<MessageComposer')
    assert.ok(omni > 0)
    const tag = bar.slice(omni, bar.indexOf('/>', omni))
    for (const attr of ['omnibox', 'global', '@send="onSend"', '@search="onSearch"']) assert.ok(tag.includes(attr), attr)
    assert.match(read('layouts/default.vue'), /<TopBar \/>/)
  })

  it('MessageFeed renders LiveFeed (no second feed implementation)', () => {
    const s = read('components/MessageFeed.vue')
    assert.match(s, /<LiveFeed/)
    assert.match(s, /channel\.newestFirst/)
    assert.doesNotMatch(s, /v-for=/)
  })

  it('TopicPane: pinned root, then the replies, with no reply field of its own', () => {
    const s = read('components/TopicPane.vue')
    const root = s.indexOf('pinned-root')
    const feed = s.indexOf('<LiveFeed')
    assert.ok(root > 0 && root < feed)
    assert.doesNotMatch(s, /<MessageComposer/)
    assert.match(s, /rootAndReplies/)
  })
})
