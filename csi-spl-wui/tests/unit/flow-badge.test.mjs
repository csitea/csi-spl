// Spec 062 (Flow per user): the badge number, the hub's counts, the Mine /
// All choice, the app-icon badge, Mine entries from the hub's thin events and
// the mock's event rules (contract specs/062-flow-per-user-counts/contracts/flow-v1.md).
//
// Run: node tests/unit/flow-badge.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  FLOW_SCOPES,
  badgeLabel,
  eventAsMessage,
  flowEventKind,
  mockFlowCounts,
  mockFlowEvents,
  parseFlowCounts,
  parseFlowScope,
  railFromUnread,
  syncAppBadge,
} from '../../src/utils/flow-badge.mjs'
import { flowEventEntry, flowUnread, mergeMine } from '../../src/utils/flow-entries.mjs'
import { FRAMES } from '../../src/utils/live-ws.mjs'

const SELF = 'HUM-1'
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8')

describe('badgeLabel (Q3)', () => {
  it('is hidden at 0 and for junk', () => {
    for (const v of [0, -3, NaN, null, undefined, 'x']) assert.equal(badgeLabel(v), '')
  })
  it('shows the number up to 99, then 99+', () => {
    assert.equal(badgeLabel(1), '1')
    assert.equal(badgeLabel(99), '99')
    assert.equal(badgeLabel(100), '99+')
  })
})

describe('parseFlowCounts', () => {
  it('null without counts', () => {
    assert.equal(parseFlowCounts(null), null)
    assert.equal(parseFlowCounts('8'), null)
  })
  it('keeps the hub total and cleans the kinds', () => {
    assert.deepEqual(parseFlowCounts({ mention: 2, reply: 5, dm: 1, total: 8 }), { mention: 2, reply: 5, dm: 1, total: 8 })
    assert.deepEqual(parseFlowCounts({ mention: -1, reply: 2.7, dm: 'x', total: 2 }), { mention: 0, reply: 2, dm: 0, total: 2 })
  })
  it('folds a poke into mention and sums when no total (Q5)', () => {
    assert.deepEqual(parseFlowCounts({ mention: 1, poke: 2, dm: 1 }), { mention: 3, reply: 0, dm: 1, total: 4 })
  })
  it('keeps the hub split by channels / dms when it sends one (t1 f4e6c677)', () => {
    assert.deepEqual(parseFlowCounts({ mention: 2, reply: 5, dm: 1, total: 8, channels: 7, dms: 1 }),
      { mention: 2, reply: 5, dm: 1, total: 8, channels: 7, dms: 1 })
    assert.deepEqual(parseFlowCounts({ mention: 1, total: 1, channels: -3, dms: 'x' }),
      { mention: 1, reply: 0, dm: 0, total: 1, channels: 0, dms: 0 })
  })
})

describe('rail numbers: Channels and Direct messages (owner, t1 f4e6c677)', () => {
  it('the hub unread split, or null from a hub without it (the pip stays)', () => {
    assert.deepEqual(railFromUnread(parseFlowCounts({ mention: 1, reply: 2, dm: 3, channels: 3, dms: 3 })), { channels: 3, dms: 3 })
    assert.equal(railFromUnread(parseFlowCounts({ mention: 1, reply: 2, dm: 3 })), null)
    assert.equal(railFromUnread(null), null)
  })
  it('Channels and DM tabs carry the red number; the Flow number is the neutral grey badge', () => {
    const side = read('../../src/components/ChannelSidebar.vue')
    assert.match(side, /data-testid="sidebar-tab-flow-count" class="sidebar-tab__count sidebar-tab__count--neutral"|class="sidebar-tab__count sidebar-tab__count--neutral"[^>]*data-testid="sidebar-tab-flow-count"/)
    assert.match(side, /:data-testid="'sidebar-tab-' \+ item\.id \+ '-count'"/)
    const css = side.slice(side.indexOf('.sidebar-tab__count--neutral {'))
    assert.match(css, /^\.sidebar-tab__count--neutral \{[^}]*background: var\(--color-bg-3\)/)
    assert.doesNotMatch(css.slice(0, css.indexOf('}')), /--color-danger/)
  })
  it('the store fills the rail from the hub unread, never from message frames', () => {
    const store = read('../../src/stores/flow.ts')
    assert.match(store, /rail\.value = railFromUnread\(/)
    assert.match(read('../../src/composables/useFlowBadge.ts'), /export function useFlowRail\(\)/)
  })
})

describe('Mine / All (Q1)', () => {
  it('Mine is the default', () => {
    assert.deepEqual([...FLOW_SCOPES], ['mine', 'all'])
    assert.equal(parseFlowScope(''), 'mine')
    assert.equal(parseFlowScope('ALL'), 'mine')
    assert.equal(parseFlowScope('all'), 'all')
  })
  it('a poke reads as a mention; unknown kinds as none', () => {
    assert.equal(flowEventKind('poke'), 'mention')
    assert.equal(flowEventKind('reply'), 'reply')
    assert.equal(flowEventKind('channel'), '')
  })
})

describe('syncAppBadge (FR-013)', () => {
  it('sets the number and clears at 0', () => {
    const calls = []
    const nav = { setAppBadge: (n) => { calls.push(['set', n]); return Promise.resolve() }, clearAppBadge: () => { calls.push(['clear']); return Promise.reject(new Error('x')) } }
    assert.equal(syncAppBadge(nav, 8), true)
    assert.equal(syncAppBadge(nav, 0), true)
    assert.deepEqual(calls, [['set', 8], ['clear']])
  })
  it('does nothing where the API is missing or throws', () => {
    assert.equal(syncAppBadge({}, 3), false)
    assert.equal(syncAppBadge(null, 3), false)
    assert.equal(syncAppBadge({ setAppBadge: () => { throw new Error('no') } }, 3), false)
  })
})

describe('Mine entries from the hub (flow-v1 §2.1)', () => {
  const ev = { msg_id: 'm9', cursor: 'c9', received_at: '2026-10-02T12:00:00Z', kind: 'poke', unread: true, from: 'HUM-2', from_box: '', to: '', to_box: '', channel: 'lobby', task_id: 't9', text: 'hi @HUM-1', files: 2 }
  it('a thin event becomes an entry with its kind and unread verdict', () => {
    assert.deepEqual(eventAsMessage(ev).files.length, 2)
    const e = flowEventEntry(ev, SELF)
    assert.equal(e.event, 'mention')
    assert.equal(e.fresh, true)
    assert.equal(e.files, 2)
    assert.equal(e.at, '2026-10-02T12:00:00Z')
    assert.equal(flowUnread(e, {}, null), true)
    assert.equal(flowUnread({ ...e, fresh: false }, {}, null), false)
    assert.equal(flowUnread(e, {}, new Set(['m9'])), false)
  })
  it('a later copy with a new verdict replaces the held one', () => {
    const one = mergeMine([], [ev], SELF)
    const two = mergeMine(one, [{ ...ev, unread: false }], SELF)
    assert.notEqual(two, one)
    assert.equal(two[0].fresh, false)
    assert.equal(mergeMine(two, [{ ...ev, unread: false }], SELF), two)
  })
})

describe('mock flow (spec 2.1; the hub counts in live mode)', () => {
  const m = (id, at, over) => ({ msg_id: id, task_id: 't1', ts: at, from: 'HUM-2', body: 'x', channel: 'lobby', ...over })
  const feed = [
    m('a', '2026-10-02T10:00:00Z', { body: 'nobody named' }),
    m('b', '2026-10-02T10:01:00Z', { body: 'ping @HUM-1' }),
    m('c', '2026-10-02T10:02:00Z', { body: 'a reply in t1' }),
    m('d', '2026-10-02T10:03:00Z', { from: SELF, body: 'my own line' }),
    m('e', '2026-10-02T10:04:00Z', { channel: null, to: SELF, task_id: 't2', body: 'a DM' }),
    m('f', '2026-10-02T10:05:00Z', { task_id: 't3', body: 'not my thread' }),
  ]
  it('mentions, DMs and replies in watched threads only, newest first, never my own', () => {
    const evs = mockFlowEvents(feed, SELF)
    assert.deepEqual(evs.map((e) => [e.msg_id, e.kind]), [['e', 'dm'], ['c', 'reply'], ['b', 'mention']])
  })
  it('counts unseen and unopened', () => {
    const evs = mockFlowEvents(feed, SELF)
    assert.deepEqual(mockFlowCounts(evs), { mention: 1, reply: 1, dm: 1, total: 3, channels: 2, dms: 1 })
    assert.deepEqual(mockFlowCounts(evs, '2026-10-02T10:02:00Z'), { mention: 0, reply: 0, dm: 1, total: 1, channels: 0, dms: 1 })
    assert.deepEqual(mockFlowCounts(evs, '', new Set(['b'])), { mention: 0, reply: 1, dm: 1, total: 2, channels: 1, dms: 1 })
  })
})

describe('wiring (FR-005/007/008, budget)', () => {
  it('the socket knows the flow frame', () => {
    assert.equal(FRAMES.flow, 'flow')
    assert.match(read('../../src/utils/live-ws.mjs'), /case FRAMES\.flow:\s*\n\s*onFlow\(f\)/)
  })
  it('the Flow store and the chips stay out of the initial JS: the sidebar loads the store lazily', () => {
    const side = read('../../src/components/ChannelSidebar.vue')
    assert.match(side, /import\('~\/stores\/flow'\)/)
    assert.doesNotMatch(side, /from '~\/stores\/flow'/)
    assert.doesNotMatch(read('../../src/app.vue'), /stores\/flow|flow-badge\.mjs/)
  })
  it('the WUI never counts Flow events from message frames (FR-008)', () => {
    const store = read('../../src/stores/flow.ts')
    assert.doesNotMatch(store, /mockFlowCounts|mockFlowEvents/)
    assert.match(store, /live\.onFlow\(onFlowFrame\)/)
  })
  it('the client methods are lazy stubs', () => {
    const client = read('../../src/utils/spool-client.mjs')
    assert.match(client, /'listFlow',/)
    assert.match(client, /'markFlow',/)
  })
})
