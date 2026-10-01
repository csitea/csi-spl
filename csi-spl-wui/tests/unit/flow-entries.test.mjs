// Flow in the left panel (topic 635f8072): one short entry per message,
// newest first, agents' DMs as entries, the unread dot, keyboard stepping.
//
// Run: node tests/unit/flow-entries.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  FLOW_CAP,
  FLOW_PAGE,
  dropFlow,
  flowEntry,
  flowKeyOf,
  flowText,
  flowUnread,
  flowWindow,
  isThreadReply,
  mergeFlow,
} from '../../src/utils/flow-entries.mjs'
import { MOCK_MESSAGES } from '../../src/utils/mock-data.mjs'

const SELF = 'HUM-1'
const msg = (over) => ({ msg_id: 'm1', task_id: 't1', ts: '2026-09-18T10:00:00Z', from: 'CLE-07', to: SELF, body: 'hello', channel: 'lobby', ...over })

describe('flowText', () => {
  it('flattens markdown to one short line', () => {
    assert.equal(flowText('Welcome to **#lobby**.\n\nSee [the doc](https://example.com) `x`'), 'Welcome to lobby. See the doc x')
  })
  it('cuts long text with an ellipsis, not inside an emoji', () => {
    const t = flowText('😀'.repeat(200), 10)
    assert.equal(Array.from(t).length, 11)
    assert.ok(t.endsWith('…'))
  })
})

describe('flowEntry', () => {
  it('a channel message names its channel', () => {
    const e = flowEntry(msg({}), SELF)
    assert.equal(e.kind, 'channel')
    assert.equal(e.where, 'lobby')
    assert.equal(e.key, 'm1')
    assert.equal(e.reply, false)
  })
  it('a DM names the other party, whoever sent it', () => {
    const mine = flowEntry(msg({ channel: null, from: SELF, from_box: 'box-wui', to: 'GRK-03', to_box: 'box-a' }), SELF)
    assert.equal(mine.kind, 'dm')
    assert.equal(mine.where, 'GRK-03@box-a')
    assert.equal(mine.mine, true)
    const theirs = flowEntry(msg({ channel: null, from: 'GRK-03', from_box: 'box-a' }), SELF)
    assert.equal(theirs.where, 'GRK-03@box-a')
  })
  it('a thread reply is marked', () => {
    assert.equal(isThreadReply(msg({ parent_task_id: 'p' })), true)
    assert.equal(isThreadReply(msg({ parent_task_id: 't1' })), false)
    assert.equal(flowEntry(msg({ parent_task_id: 'p' })).reply, true)
  })
  it('skips rows with no id, and empty rows with no file', () => {
    assert.equal(flowEntry(msg({ msg_id: '' })), null)
    assert.equal(flowEntry(msg({ body: '  ' })), null)
    assert.ok(flowEntry(msg({ body: '', files: [{ file_id: 'f' }] })))
  })
  it('flowKeyOf matches the notification keys', () => {
    assert.equal(flowKeyOf(msg({})), 'ch:lobby')
    assert.equal(flowKeyOf(msg({ channel: null, from: 'GRK-03', from_box: 'box-a' }), SELF), 'dm:GRK-03@box-a')
  })
})

describe('mergeFlow', () => {
  it('the mock feed: newest first, the agent DM is an entry', () => {
    const list = mergeFlow([], MOCK_MESSAGES, SELF)
    assert.equal(list.length, MOCK_MESSAGES.length)
    assert.equal(list[0].key, '88888888-8888-4888-8888-888888888888')
    const dm = list.find((e) => e.key === '77777777-7777-4777-8777-777777777777')
    assert.equal(dm.kind, 'dm')
    assert.equal(dm.where, 'GRK-03@box-a')
    for (let i = 1; i < list.length; i++) assert.ok(list[i - 1].at >= list[i].at)
  })
  it('dedupes by msg_id; an edit replaces the held copy', () => {
    const a = mergeFlow([], [msg({})], SELF)
    assert.equal(mergeFlow(a, [msg({})], SELF), a, 'same row: no write')
    const b = mergeFlow(a, [msg({ body: 'edited' })], SELF)
    assert.equal(b.length, 1)
    assert.equal(b[0].text, 'edited')
  })
  it('a live message goes on top, the cap drops the oldest', () => {
    let list = []
    for (let i = 0; i < FLOW_CAP + 5; i++) {
      list = mergeFlow(list, [msg({ msg_id: 'm' + String(i).padStart(4, '0'), ts: `2026-09-18T10:${String(i % 60).padStart(2, '0')}:${String(Math.floor(i / 60)).padStart(2, '0')}Z` })], SELF)
    }
    assert.equal(list.length, FLOW_CAP)
    const live = mergeFlow(list, [msg({ msg_id: 'new', ts: '2026-09-19T00:00:00Z' })], SELF)
    assert.equal(live[0].key, 'new')
  })
  it('dropFlow removes a deleted message', () => {
    const a = mergeFlow([], [msg({}), msg({ msg_id: 'm2' })], SELF)
    assert.deepEqual(dropFlow(a, 'm1').map((e) => e.key), ['m2'])
    assert.equal(dropFlow(a, 'nope'), a)
  })
})

describe('flowUnread', () => {
  const e = flowEntry(msg({}), SELF)
  it('unread with no cursor, read once the cursor passes it', () => {
    assert.equal(flowUnread(e, {}), true)
    assert.equal(flowUnread(e, { 'ch:lobby': { ts: '2026-09-18T11:00:00Z', id: '' } }), false)
  })
  it('never for the reader\'s own message, nor one opened from the Flow', () => {
    assert.equal(flowUnread(flowEntry(msg({ from: SELF }), SELF), {}), false)
    assert.equal(flowUnread(e, {}, new Set(['m1'])), false)
    /* CLE-77889: a line the viewer typed at an agent's terminal */
    assert.equal(flowUnread(flowEntry(msg({ from: 'CLE-07', typed_by: SELF }), SELF), {}), false)
  })
})

describe('the Flow panel', () => {
  const vue = readFileSync(new URL('../../src/components/ChannelSidebar.vue', import.meta.url), 'utf8')
  const panel = vue.slice(vue.indexOf('id="sidebar-panel-flow"'), vue.indexOf('<!-- Issues, third rail tab'))
  it('holds no channel / agent / topic list any more', () => {
    assert.doesNotMatch(panel, /row\.kind === 'dm'/)
    assert.doesNotMatch(panel, /flowRows|flowOrder/)
    assert.match(panel, /<LazyFlowList/)
  })
  it('renders the shared left list in flow mode', () => {
    const list = readFileSync(new URL('../../src/components/FlowList.vue', import.meta.url), 'utf8')
    assert.match(list, /<LazySideHitList[\s\S]*mode="flow"/)
    assert.match(list, /msgId: e\.msg_id/)
    /* lane A (CLE-77882): the entry opens in its original place, the whole row passed */
    assert.match(list, /await openMessage\(row\)/)
  })
})

// owner 73c9704c (2026-10-01): "use the last 30 entries ... to be quick and
// nimble" - the first paint is one page, Load more adds the next.
describe('flowWindow', () => {
  const at = (i) => new Date(Date.UTC(2026, 9, 1, 12, 0, 0) - i * 60000).toISOString()
  const held = Array.from({ length: 70 }, (_, i) => ({ key: 'm' + i, at: at(i) }))
  it('a page is 30 entries', () => assert.equal(FLOW_PAGE, 30))
  it('shows the newest page, newest first, and says more is held', () => {
    const w = flowWindow(held, FLOW_PAGE)
    assert.deepEqual(w.entries.map((e) => e.key), held.slice(0, 30).map((e) => e.key))
    assert.equal(w.more, true)
  })
  it('Load more widens the window by a page', () => {
    assert.equal(flowWindow(held, 2 * FLOW_PAGE).entries.length, 60)
    const all = flowWindow(held, 3 * FLOW_PAGE)
    assert.equal(all.entries.length, 70)
    assert.equal(all.more, false)
  })
  it('an entry older than the oldest read topic waits for the next topic page', () => {
    const w = flowWindow(held, FLOW_PAGE, at(9))
    assert.deepEqual(w.entries.map((e) => e.key), held.slice(0, 10).map((e) => e.key))
    assert.equal(w.more, true)
  })
  it('CONTROL: without a boundary the same entries pass', () => {
    assert.equal(flowWindow(held, FLOW_PAGE).entries.length, 30)
  })
  it('an unread page means more even when everything held is shown', () => {
    assert.equal(flowWindow(held.slice(0, 5), FLOW_PAGE, at(40)).more, true)
    assert.equal(flowWindow(held.slice(0, 5), FLOW_PAGE).more, false)
  })
})
