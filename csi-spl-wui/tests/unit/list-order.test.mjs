// "newest first EVERYWHERE, and a new item pops to the top without
// a refresh" (the owner's order of 2026-09-20, extending 013 US7 / CLE-3412).
//
// 013 proved it for one list: the messages of the open view. This suite covers
// the lists it did not — the channel / DM topic cards ordered by their LAST
// activity, the sidebar channel list, the sidebar DM list — plus the DOM
// contract the live audit reads (`data-ts` on every row of every list, so the
// rendered order can be checked against the clock rather than against a guess).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  addChannelRow,
  channelActivity,
  channelView,
  rowsForRightPane,
  dmActivity,
  unreadFromDms,
  dmPeerOf,
  noteActivity,
  feedRow,
  mergeLive,
  orderChannels,
  orderPeers,
  topicCards,
} from '../../src/utils/channel-feed.mjs'
import { activityOf, newestActivityFirst } from '../../src/utils/feed.mjs'
import { normalizeSearchResponse, rowAt } from '../../src/utils/search-results.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')
const ids = (rows) => rows.map((r) => r.msg_id)

const msg = (task, n, extra = {}) => ({
  msg_id: `${task}-${n}`, task_id: task, ts: `2026-09-20T10:${String(n).padStart(2, '0')}:00Z`,
  from: 'HUM-4', kind: 'note', body: `${task} ${n}`, channel: 'lobby', parent_task_id: null, ...extra,
})

describe('activityOf / newestActivityFirst', () => {
  it('reads last_ts first, then received_at, then ts', () => {
    assert.equal(activityOf({ ts: 'a', received_at: 'b', last_ts: 'c' }), 'c')
    assert.equal(activityOf({ ts: 'a', received_at: 'b' }), 'b')
    assert.equal(activityOf({ ts: 'a' }), 'a')
    assert.equal(activityOf(null), '')
  })

  it('orders newest activity first and breaks ties by msg_id, stably', () => {
    const rows = [
      { msg_id: 'a', ts: '2026-09-20T10:00:00Z', last_ts: '2026-09-20T12:00:00Z' },
      { msg_id: 'b', ts: '2026-09-20T11:00:00Z' },
      { msg_id: 'c', ts: '2026-09-20T11:00:00Z' },
    ]
    assert.deepEqual(ids(newestActivityFirst(rows)), ['a', 'c', 'b'])
    assert.deepEqual(ids(newestActivityFirst(rows)), ids(newestActivityFirst(newestActivityFirst(rows))))
  })
})

describe('topicCards: one card per task, carrying the topic LAST activity', () => {
  it('keeps the root as the card and lifts the newest reply onto last_ts', () => {
    const cards = topicCards([msg('t1', 1), msg('t1', 9), msg('t2', 5)])
    assert.deepEqual(ids(cards), ['t1-1', 't2-5'])
    assert.equal(cards[0].last_ts, '2026-09-20T10:09:00Z')
    assert.equal(cards[0].count, 1)
    assert.equal(cards[1].last_ts, '2026-09-20T10:05:00Z')
  })

  it('a hub topic row keeps its own count (the hub already counted it)', () => {
    const row = feedRow({ task_id: 't3', first_ts: '2026-09-20T09:00:00Z', last_ts: '2026-09-20T09:30:00Z', count: 7, participants: ['HUM-4@box-wui'] })
    const cards = topicCards([row])
    assert.equal(cards[0].count, 6, 'feedRow already turned count into replies')
    assert.equal(cards[0].last_ts, '2026-09-20T09:30:00Z')
  })
})

describe('channelView: pane 2 is the topic starter (owner 2026-09-23)', () => {
  it('a reply is not a row; the starter stays and rises on the reply', () => {
    /* t1 started 10:01 and was replied to at 10:20; t2 started 10:10 and went
       quiet. The reply moves t1's starter to the top. The row is still t1's
       first message — not the reply. */
    const rows = [msg('t1', 1), msg('t2', 10), msg('t1', 20)]
    const v = channelView(rows).rows
    assert.deepEqual(ids(v), ['t1-1', 't2-10'])
    assert.equal(v[0].msg_id, 't1-1')
    assert.equal(v[0].body, 't1 1')
  })

  it('a live reply bumps the starter and does not add a row', () => {
    const before = [msg('t1', 1), msg('t2', 10)]
    assert.deepEqual(ids(channelView(before).rows), ['t2-10', 't1-1'])
    const after = mergeLive(before, msg('t1', 30))
    const v = channelView(after)
    assert.deepEqual(ids(v.rows), ['t1-1', 't2-10'])
    assert.equal(v.rows[0].body, 't1 1')
    assert.equal(v.rows.length, 2, 'the reply is not a pane-2 row')
  })

  it('a live root still lands on top (CLE-3412 must not regress)', () => {
    const v = channelView(mergeLive([msg('t1', 1), msg('t2', 2)], msg('t9', 40)))
    assert.deepEqual(ids(v.rows), ['t9-40', 't2-2', 't1-1'])
  })

  it('is_parent 0 never becomes a middle-pane row', () => {
    const starter = msg('t1', 1, { is_parent: 1 })
    const reply = msg('t1', 20, { is_parent: 0 })
    const alone = msg('t9', 30, { is_parent: 0 })
    const v = channelView([starter, reply, alone, msg('t2', 10)]).rows
    assert.deepEqual(ids(v), ['t1-1', 't2-10'])
    assert.equal(v.find((r) => r.task_id === 't1').body, 't1 1')
    assert.equal(v.some((r) => r.is_parent === 0), false)
  })

  it('is_parent 0 is on the right pane, including after it is no longer pending', () => {
    const root = msg('t1', 1, { is_parent: 1 })
    const reply = msg('t1', 20, { is_parent: 0, pending: false })
    const other = msg('t2', 5, { is_parent: 0 })
    const rows = rowsForRightPane([root], [reply, other], 't1')
    assert.deepEqual(ids(rows), ['t1-1', 't1-20'])
  })
})

describe('orderChannels: the sidebar channel list, newest first', () => {
  const rows = [
    { channel_id: 'alerts', last_ts: null },
    { channel_id: 'live-proof', last_ts: '2026-09-20T03:24:56Z' },
    { channel_id: 'lobby', last_ts: '2026-09-20T03:04:50Z' },
    { channel_id: 'tasks', last_ts: null },
  ]

  it('orders by last activity, idle channels in a stable a-z tail', () => {
    /* exactly the four dev t1 rows measured before the fix, where the WUI
       rendered alerts, live-proof, lobby, tasks (the hub's a-z order) */
    assert.deepEqual(orderChannels(rows).map((c) => c.channel_id), ['live-proof', 'lobby', 'alerts', 'tasks'])
  })

  it('a live message re-orders the list with no refetch', () => {
    const at = { alerts: '2026-09-20T04:00:00Z' }
    assert.deepEqual(orderChannels(rows, at).map((c) => c.channel_id), ['alerts', 'live-proof', 'lobby', 'tasks'])
  })

  it('a channel created seconds ago tops the list although it is empty', () => {
    const fresh = { channel_id: 'brand-new', last_ts: null, created_at: '2026-09-20T05:00:00Z' }
    assert.deepEqual(orderChannels([...rows, fresh]).map((c) => c.channel_id)[0], 'brand-new')
    assert.equal(channelActivity(fresh), '2026-09-20T05:00:00Z')
  })

  it('never mutates its input', () => {
    const copy = rows.map((r) => ({ ...r }))
    orderChannels(rows)
    assert.deepEqual(rows, copy)
  })
})

describe('orderPeers / dmActivity: the sidebar DM list, online first, then DM history', () => {
  const peers = [
    { id: 'EZA-1', box: 'box-e2e-a', label: 'EZA-1@box-e2e-a', online: false },
    { id: 'EZB-1', box: 'box-e2e-b', label: 'EZB-1@box-e2e-b', online: false },
    { id: 'ORC-1', box: 'box-live-probe', label: 'ORC-1@box-live-probe', online: true },
    { id: 'ORC-2', box: 'box-live-probe', label: 'ORC-2@box-live-probe', online: true },
  ]

  it('an online peer comes first even when an offline one was talked to later', () => {
    const at = { 'EZB-1@box-e2e-b': '2026-09-19T18:56:38Z' }
    assert.deepEqual(orderPeers(peers, at).map((p) => p.label),
      ['ORC-1@box-live-probe', 'ORC-2@box-live-probe', 'EZB-1@box-e2e-b', 'EZA-1@box-e2e-a'])
  })

  it('inside each group a peer with DMs beats one without, newest DM first', () => {
    const at = {
      'ORC-2@box-live-probe': '2026-09-19T10:00:00Z',
      'EZA-1@box-e2e-a': '2026-09-19T09:00:00Z',
      'EZB-1@box-e2e-b': '2026-09-19T11:00:00Z',
    }
    assert.deepEqual(orderPeers(peers, at).map((p) => p.label),
      ['ORC-2@box-live-probe', 'ORC-1@box-live-probe', 'EZB-1@box-e2e-b', 'EZA-1@box-e2e-a'])
  })

  it('with no DM at all it is online first then a-z (CONTROL)', () => {
    assert.deepEqual(orderPeers(peers).map((p) => p.label),
      ['ORC-1@box-live-probe', 'ORC-2@box-live-probe', 'EZA-1@box-e2e-a', 'EZB-1@box-e2e-b'])
  })

  it('dmActivity takes the newest moment per participant and drops our own label', () => {
    const at = dmActivity([
      { last_ts: '2026-09-19T18:56:38Z', participants: ['EZB-1@box-e2e-b', 'HUM-4@box-wui'] },
      { last_ts: '2026-09-19T17:56:38Z', participants: ['EZB-1@box-e2e-b', 'HUM-4@box-wui'] },
      { first_ts: '2026-09-19T19:00:00Z', participants: ['EZA-1@box-e2e-a', 'HUM-4@box-wui'] },
    ], 'HUM-4@box-wui')
    assert.deepEqual(at, { 'EZB-1@box-e2e-b': '2026-09-19T18:56:38Z', 'EZA-1@box-e2e-a': '2026-09-19T19:00:00Z' })
  })
})

describe('unreadFromDms: the DM rail badge on load, the twin of the hub channel unread', () => {
  const self = 'HUM-4@box-wui'
  const me = 'HUM-4'
  // Two DM topics, each with its newest messages inlined (?dm=true&per_topic=N),
  // exactly as the sidebar's loadDmActivity fetches them.
  const topics = () => [
    { task_id: 't-a', inline: { messages: [
      { msg_id: 'a1', from: 'EZB-1', from_box: 'box-e2e-b', to: me, to_box: 'box-wui', channel: null, received_at: '2026-09-19T10:00:00Z' },
      { msg_id: 'a2', from: 'EZB-1', from_box: 'box-e2e-b', to: me, to_box: 'box-wui', channel: null, received_at: '2026-09-19T11:00:00Z' },
      { msg_id: 'a3', from: me, from_box: 'box-wui', to: 'EZB-1', to_box: 'box-e2e-b', channel: null, received_at: '2026-09-19T11:05:00Z' },
    ] } },
    { task_id: 't-b', inline: { messages: [
      { msg_id: 'b1', from: 'EZA-1', from_box: 'box-e2e-a', to: me, to_box: 'box-wui', channel: null, received_at: '2026-09-19T09:00:00Z' },
    ] } },
  ]

  it('counts INCOMING DMs newer than the peer cursor, per peer, and never our own line', () => {
    // no cursor for either peer → every incoming line is unread; a3 is ours, so it never counts
    assert.deepEqual(unreadFromDms(topics(), {}, me), {
      'dm:EZB-1@box-e2e-b': 2,
      'dm:EZA-1@box-e2e-a': 1,
    })
  })

  it('a per-peer cursor clears what has been read (the DM twin of read=<channel>~<cursor>)', () => {
    const cursors = { 'dm:EZB-1@box-e2e-b': { ts: '2026-09-19T10:00:00Z', id: 'a1' } }
    assert.deepEqual(unreadFromDms(topics(), cursors, me), {
      'dm:EZB-1@box-e2e-b': 1, // only a2 is newer than the cursor at a1
      'dm:EZA-1@box-e2e-a': 1,
    })
  })

  it('a human->human DM raises the badge exactly like an agent->person one (owner, prd t1 dd88348d)', () => {
    // The only difference between the two is the sender's box: an agent sends
    // from its own box (box-desk), a human from box-wui (hub wuiEnvelope). The
    // count must not care - "the same way it works, agent to person now".
    const me2 = 'HUM-9'
    const agentDm = [{ task_id: 't-ag', inline: { messages: [
      { msg_id: 'g1', from: 'CLE-07', from_box: 'box-desk', to: me2, to_box: 'box-wui', channel: null, received_at: '2026-09-29T10:00:00Z' },
    ] } }]
    const humanDm = [{ task_id: 't-hu', inline: { messages: [
      { msg_id: 'h1', from: 'HUM-5', from_box: 'box-wui', to: me2, to_box: 'box-wui', channel: null, received_at: '2026-09-29T10:00:00Z' },
    ] } }]
    assert.deepEqual(unreadFromDms(agentDm, {}, me2), { 'dm:CLE-07@box-desk': 1 })
    assert.deepEqual(unreadFromDms(humanDm, {}, me2), { 'dm:HUM-5@box-wui': 1 },
      'a human sender must raise dm:<id>@box-wui, the label the rail gives a human peer')
  })

  it('skips channel rows and yields nothing without inline messages (CONTROL: today the rail had no DM badge on load)', () => {
    const chRow = [{ task_id: 't-c', inline: { messages: [
      { msg_id: 'c1', from: 'EZB-1', from_box: 'box-e2e-b', to: me, channel: 'lobby', received_at: 'z' },
    ] } }]
    assert.deepEqual(unreadFromDms(chRow, {}, me), {})
    assert.deepEqual(unreadFromDms([{ task_id: 't-d' }], {}, me), {})
    assert.deepEqual(unreadFromDms([], {}, me), {})
  })
})

describe('noteActivity / dmPeerOf: one live frame moves the sidebar order', () => {
  const empty = { channels: {}, peers: {} }

  it('a channel frame stamps that channel, whichever view is open', () => {
    const next = noteActivity(empty, { channel: 'alerts', received_at: '2026-09-20T04:00:00Z' }, 'HUM-4')
    assert.deepEqual(next.channels, { alerts: '2026-09-20T04:00:00Z' })
    assert.deepEqual(next.peers, {})
  })

  it('#lobby and the pre-M3 alias land under the stored channel id', () => {
    assert.deepEqual(noteActivity(empty, { channel: '#Lobby', ts: 'x' }, 'HUM-4').channels, { lobby: 'x' })
  })

  it('a DM frame stamps the OTHER end, labelled as the sidebar labels it', () => {
    const m = { from: 'EZB-1', from_box: 'box-e2e-b', to: 'HUM-4', to_box: 'box-wui', received_at: 'z' }
    assert.deepEqual(noteActivity(empty, m, 'HUM-4').peers, { 'EZB-1@box-e2e-b': 'z' })
    assert.equal(dmPeerOf(m, 'HUM-4'), 'EZB-1@box-e2e-b')
    assert.equal(dmPeerOf({ from: 'HUM-4', from_box: 'box-wui', to: 'ALL-0' }, 'HUM-4'), '', 'a broadcast has no peer')
  })

  it('an older frame changes nothing and returns the same objects (no needless re-render)', () => {
    const held = { channels: { lobby: '2026-09-20T05:00:00Z' }, peers: {} }
    const next = noteActivity(held, { channel: 'lobby', received_at: '2026-09-20T04:00:00Z' }, 'HUM-4')
    assert.equal(next.channels, held.channels)
    assert.equal(next.peers, held.peers)
  })

  it('a frame with no clock is ignored (CONTROL)', () => {
    assert.equal(noteActivity(empty, { channel: 'lobby' }, 'HUM-4').channels, empty.channels)
  })
})

describe('addChannelRow: a channel created in another session', () => {
  const rows = [{ channel_id: 'lobby', last_ts: '2026-09-20T03:04:50Z' }]

  it('adds the row and orderChannels puts it on top through created_at', () => {
    const next = addChannelRow(rows, { channel: 'brand-new', name: 'Brand New', created_at: '2026-09-20T06:00:00Z', created_by: 'HUM-4' })
    assert.equal(next.length, 2)
    assert.deepEqual(orderChannels(next).map((c) => c.channel_id), ['brand-new', 'lobby'])
  })

  it('a channel we already list is left exactly as the hub described it', () => {
    const next = addChannelRow(rows, { channel: 'lobby', name: 'somethingelse' })
    assert.equal(next, rows)
  })

  it('a frame with no channel id changes nothing (CONTROL)', () => {
    assert.equal(addChannelRow(rows, {}), rows)
  })
})

describe('the tab-wide live follow (plugins/spool-live.client.ts)', () => {
  const plugin = read('plugins/spool-live.client.ts')

  it('holds one `all` follow for the tab and feeds the sidebar order', () => {
    assert.match(plugin, /client\.subscribeAll\(\)/)
    assert.match(plugin, /live\.onMessage\(\(m\) => channel\.noteLive\(m, live\.identity\.value\)\)/)
    assert.match(plugin, /live\.onChannel\(\(f\) => channel\.addChannel\(f\)\)/)
  })

  it('catches up on reconnect, and does nothing in the socketless mock tenant', () => {
    assert.match(plugin, /onReconnected/)
    assert.match(plugin, /loadChannels\(\)/)
    assert.match(plugin, /if \(api\.mock\) return/)
  })

  /* W4 (CLE-55): signed out the hub answers 401 view_door to the DM read and the
     socket has no door either, so the whole follow waits for the session. */
  it('reads nothing until the session store says `in`, and starts once', () => {
    assert.match(plugin, /useSessionStore/)
    assert.match(plugin, /String\(state\) === 'in'/)
    assert.match(plugin, /if \(started\) return/)
    const gate = plugin.indexOf("=== 'in'")
    assert.ok(gate > plugin.indexOf('loadDmActivity'), 'the read sits inside start(), behind the gate')
  })

  it('`all` is ref-counted, so leaving `/` does not drop the tab follow', () => {
    const ws = read('utils/live-ws.mjs')
    assert.match(ws, /let allSub = 0/)
    assert.match(ws, /allSub\+\+/)
    assert.match(ws, /allSub--/)
    assert.match(ws, /if \(allSub > 0\) return/)
  })
})

describe('search rows carry the clock their group is ordered by', () => {
  it('rowAt reads the right field per group type', () => {
    assert.equal(rowAt({ received_at: 'a', last_at: 'b' }), 'a', 'a message')
    assert.equal(rowAt({ last_at: 'b' }), 'b', 'a topic')
    assert.equal(rowAt({ last_ts: 'c' }), 'c', 'a channel')
    assert.equal(rowAt({ last_hello_at: 'd' }), 'd', 'a box')
    assert.equal(rowAt({}), '')
  })

  it('the hub\'s per-group order is preserved exactly (it answers newest first)', () => {
    const r = normalizeSearchResponse({
      query: 'live',
      groups: {
        messages: { results: [
          { msg_id: 'm2', received_at: '2026-09-20T03:00:00Z' },
          { msg_id: 'm1', received_at: '2026-09-19T03:00:00Z' },
        ], next: null },
      },
    })
    const items = r.groups.find((g) => g.type === 'messages').items
    assert.deepEqual(items.map((x) => x.msg_id), ['m2', 'm1'])
    assert.deepEqual(items.map(rowAt), ['2026-09-20T03:00:00Z', '2026-09-19T03:00:00Z'])
  })

  it('the search row stamps data-key and data-ts (CLE-77884: the left panel list)', () => {
    const s = read('components/SideHitList.vue')
    assert.match(s, /:data-key="item\.key"/)
    assert.match(s, /:data-ts="item\.ts \|\| undefined"/)
    assert.match(read('components/SearchSidePanel.vue'), /ts: rowAt\(row\)/)
  })
})

describe('DOM contract: every list row carries the clock it is ordered by', () => {
  it('a message / topic card prints its ACTIVITY time, not the root ts', () => {
    const s = read('components/MessageCard.vue')
    assert.match(s, /:data-ts="at \|\| undefined"/)
    assert.match(s, /activityOf\(props\.msg\)/)
    /* the FORMATTER changed on the owner's word (real ISO 8601, with
       the T and the Z); the contract this case exists for did not — the printed
       time is still read from `at`, the clock the list is ordered by. */
    assert.match(s, /formatMsgListTs\(at\.value/)
  })

  it('the topic list row carries last_ts', () => {
    assert.match(read('pages/index.vue'), /:data-ts="t\.last_ts \|\| undefined"/)
  })

  it('the sidebar renders the ORDERED lists and stamps both', () => {
    const s = read('components/ChannelSidebar.vue')
    assert.match(s, /v-for="\(c, channelIndex\) in channelRows"/)
    assert.match(s, /:data-ts="channelActivity\(c, channel\.liveAt\) \|\| undefined"/)
    assert.match(s, /v-for="\(p, peerIndex\) in peers"/)
    /* specs/058 (CLE-77932): the roster peers plus every <ID>@<box> with a DM, still ordered */
    assert.match(s, /orderPeers\(withDmPeers\(roster\.peers, channel\.dmAt, [^)]*\), channel\.dmAt\)/)
    assert.doesNotMatch(s, /v-for="c in channel\.channels"/, 'CONTROL: the unordered hub list is not rendered')
  })
})
