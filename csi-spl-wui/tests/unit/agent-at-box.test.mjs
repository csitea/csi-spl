// specs/058 (CLE-77932, owner 2026-10-02): an agent is <ID>@<box>. CLE-001..003
// run on every box, so the same id on two boxes is two agents: two DM rows with
// their own history, and every frame the WUI sends to one names its box
// (to_box) - a bare id announced on two boxes is refused as ambiguous_to_box.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { belongsTo, dmActivity, dmPeerOf, orderPeers, parseMention, shownPerson, personTitle } from '../../src/utils/channel-feed.mjs'
import { peopleRows, withDmPeers } from '../../src/utils/live-follow.mjs'
import { mentionBoxes, pokeTargets } from '../../src/utils/mention-poke.mjs'
import { createLiveClient } from '../../src/utils/live-ws.mjs'
import { insertMention } from '../../src/utils/mention-autocomplete.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

const ROSTER = { 'box-desk': ['CLE-001', 'CLE-002'], sat: ['CLE-001', 'CLE-002'], 'box-wui': ['HUM-10'] }

function fakeWs() {
  const sockets = []
  class FakeWS {
    constructor() {
      this.sent = []
      sockets.push(this)
    }
    send(s) { this.sent.push(JSON.parse(s)) }
    close() { if (this.onclose) this.onclose({}) }
    open() { if (this.onopen) this.onopen({}) }
    recv(f) { if (this.onmessage) this.onmessage({ data: JSON.stringify(f) }) }
  }
  return { FakeWS, sockets }
}

describe('specs/058: the same id on two boxes is two agents (CLE-77932)', () => {
  it('the people list holds one row per <ID>@<box>, each named with its box', () => {
    const rows = peopleRows(ROSTER, ['CLE-001@sat'], 'HUM-10', 'box-wui').filter((p) => !p.self)
    const cle1 = rows.filter((p) => p.id === 'CLE-001')
    assert.deepEqual(cle1.map((p) => p.label), ['CLE-001@box-desk', 'CLE-001@sat'])
    assert.deepEqual(cle1.map((p) => p.online), [false, true])
    for (const p of cle1) {
      assert.equal(shownPerson(p.id, p.box, {}), p.label, 'shown with its box')
      assert.equal(personTitle(p.id, p.box, {}), p.label, 'hover names the box')
    }
  })

  it('the DM list keeps a peer the reader has DMs with even when no box announces it', () => {
    const roster = { sat: ['CLE-001'], 'box-wui': ['HUM-10'] }
    const peers = peopleRows(roster, [], 'HUM-10', 'box-wui').filter((p) => !p.self)
    const topics = [
      { last_ts: '2026-10-02T03:40:00Z', participants: ['CLE-001@box-desk', 'HUM-10@box-wui'] },
      { last_ts: '2026-10-02T03:00:00Z', participants: ['CLE-001@sat', 'HUM-10@box-wui'] },
      { last_ts: '2026-10-02T02:00:00Z', participants: ['ALL-0@box-wui', 'HUM-10@box-wui'] },
    ]
    const dmAt = dmActivity(topics, 'HUM-10')
    const list = orderPeers(withDmPeers(peers, dmAt, 'HUM-10'), dmAt)
    assert.deepEqual(list.map((p) => p.label), ['CLE-001@box-desk', 'CLE-001@sat'])
    assert.equal(list[0].online, false)
    assert.equal(withDmPeers(peers, {}, 'HUM-10'), peers, 'nothing to add: the same array')
    assert.deepEqual(withDmPeers([], { 'CLE-9': 'x' }, ''), [], 'a label without a box is not a row')
  })

  it('each DM feed holds only its own box\'s lines', () => {
    const home = { from: 'CLE-001', from_box: 'box-desk', to: 'HUM-10', to_box: 'box-wui', channel: null }
    const sat = { from: 'CLE-001', from_box: 'sat', to: 'HUM-10', to_box: 'box-wui', channel: null }
    assert.equal(belongsTo(home, { peer: 'CLE-001@box-desk' }), true)
    assert.equal(belongsTo(sat, { peer: 'CLE-001@box-desk' }), false)
    assert.equal(belongsTo(sat, { peer: 'CLE-001@sat' }), true)
    assert.equal(dmPeerOf(home, 'HUM-10'), 'CLE-001@box-desk')
    assert.equal(dmPeerOf(sat, 'HUM-10'), 'CLE-001@sat')
  })

  it('a picked mention keeps its box all the way to the dispatch', () => {
    const picked = insertMention('@sat', 4, 'CLE-001@sat')
    assert.equal(picked.text, '@CLE-001@sat ')
    assert.deepEqual(parseMention(picked.text + 'deploy'), { to: 'CLE-001', toBox: 'sat', kind: 'task', body: 'deploy' })
    assert.equal('toBox' in parseMention('@CLE-001 deploy'), false, 'a bare id names no box')
  })

  it('a mention poke knows each tag\'s box; the first tag of an id wins', () => {
    const text = 'ask @CLE-001@sat and @CLE-002@box-desk, then @CLE-001@box-desk, and @HUM-10'
    assert.deepEqual(mentionBoxes(text), { 'CLE-001': 'sat', 'CLE-002': 'box-desk' })
    assert.deepEqual(pokeTargets({ text }), ['CLE-001', 'CLE-002', 'HUM-10'])
    assert.deepEqual(mentionBoxes('mail a@CLE-1@x.com'), {}, 'not a mention inside a word')
  })

  it('the socket client sends to_box with its to, and never without one', async () => {
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    const pa = c.send({ task_id: 'T', body: 'x', to: 'CLE-001', to_box: 'sat' })
    const pb = c.send({ task_id: 'T', body: 'y', to_box: 'sat' })
    const pc = c.send({ task_id: 'T', body: 'z', to: 'CLE-001' })
    const [a, b, cc] = sockets[0].sent.filter((f) => f.type === 'send')
    for (const f of [a, b, cc]) sockets[0].recv({ type: 'ack', msg_id: f.msg_id })
    await Promise.all([pa, pb, pc])
    assert.equal(a.to, 'CLE-001')
    assert.equal(a.to_box, 'sat')
    assert.equal('to_box' in b, false, 'no to, no to_box')
    assert.equal('to_box' in cc, false)
  })

  it('every live send path hands the box to the socket', () => {
    const channel = src('src/stores/channel.ts')
    /* spec 117 FR-4: the /dm peer, or the DM topic's other end from /t/<id> */
    assert.match(channel, /const dmTo = peer\.value \|\| dmPeer \|\| ''/)
    assert.match(channel, /const \[peerId, peerBox\] = dmTo\.split\('@'\)/)
    assert.match(channel, /const toBox = asDm \? peerBox : parsed\.toBox/)
    assert.match(channel, /if \(frame\.to && toBox\) frame\.to_box = toBox/)
    assert.match(src('src/stores/live.ts'), /to_box: to \? parsed\.toBox : undefined/)
    const poke = src('src/composables/useMentionPoke.ts')
    assert.match(poke, /pokeFrame\(\{ to: id, body, toBox,/)
    assert.match(src('src/utils/mention-poke.mjs'), /to_box: toBox \|\| undefined/)
    assert.match(poke, /await sendDm\(id, body, boxes\[id\], refOf\(opts\.where\)\)/)
    assert.match(src('src/components/ChannelSidebar.vue'), /orderPeers\(withDmPeers\(roster\.peers, channel\.dmAt/)
  })

  it('a narrow rail row clips neither the id nor the box: the box is its own line', () => {
    const side = src('src/components/ChannelSidebar.vue')
    assert.match(side, /<HumanName class="label" :id="p\.id" :box="p\.box" stacked \/>/, 'DM rows')
    assert.match(side, /<HumanName class="label" :id="a\.id" :box="a\.box" stacked \/>/, 'Agents rows (were the bare id)')
    assert.doesNotMatch(side, /<span class="label">\{\{ a\.id \}\}<\/span>/, 'CONTROL: no bare agent id in the Agents list')
    const name = src('src/components/HumanName.vue')
    assert.match(name, /props\.stacked && props\.id && props\.box && !\/\^\(HUM\|GST\)-\/\.test\(props\.id\)/, 'agents only')
  })
})
