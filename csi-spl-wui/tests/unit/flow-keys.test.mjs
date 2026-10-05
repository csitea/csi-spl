// Owner, t1 77540e6f (HUM-10): "7 new messages" over Direct messages while
// no DM row showed anything new. A section's number is the sum of its rows'
// unread, and both come from one map, the hub's Flow `keys`
// (contract specs/062-flow-per-user-counts/contracts/flow-v1.md section 2).
//
// Run: node tests/unit/flow-keys.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { flowDmPeers, rowUnread, sectionTotal } from '../../src/utils/flow-keys.mjs'
import { flowPlaceKey, mockFlowCounts, mockFlowEvents, mockFlowKeys, parseFlowKeys, railFromUnread, parseFlowCounts } from '../../src/utils/flow-badge.mjs'
import { withDmPeers } from '../../src/utils/live-follow.mjs'

const SELF = 'HUM-10'
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8')

// HUM-10's 08:31Z state: 7 DMs from retired agents (no roster row), and two
// discussions in a channel they take part in.
const HUB = {
  unread: { mention: 1, reply: 1, dm: 7, total: 9, channels: 2, dms: 7 },
  keys: { 'dm:c-034@box-a': 3, 'dm:c-035@box-a': 2, 'dm:c-042@box-a': 2, 'ch:devel': 2, 't:a': 7, 't:b': 2 },
}

describe('parseFlowKeys', () => {
  it('keeps whole counts > 0 under ch:/dm:/t: keys; null from a hub without keys', () => {
    assert.deepEqual(parseFlowKeys({ 'ch:x': 2, 'dm:y@b': 1.7, 't:z': 0, 'f:seen': 3, junk: 1, 'ch:': 4 }), { 'ch:x': 2, 'dm:y@b': 1 })
    assert.equal(parseFlowKeys(undefined), null)
    assert.equal(parseFlowKeys([1]), null)
    assert.deepEqual(parseFlowKeys({}), {})
  })
})

describe('section number = sum of its rows (one map)', () => {
  const keys = parseFlowKeys(HUB.keys)
  it('reproduces the bug: the old rail number counted DM rows nobody lists', () => {
    const rosterPeers = [{ id: 'HUM-2', box: 'box-wui', label: 'HUM-2@box-wui' }]
    const listedBefore = withDmPeers(rosterPeers, {}, SELF).map((p) => p.label)
    const rail = railFromUnread(parseFlowCounts(HUB.unread))
    assert.equal(rail.dms, 7)
    assert.equal(sectionTotal(keys, 'dm:', listedBefore), 0, 'no listed row carried any of the 7')
  })
  it('every DM peer with unread lines gets a row, so the rows add up to the total', () => {
    const rosterPeers = [{ id: 'HUM-2', box: 'box-wui', label: 'HUM-2@box-wui' }]
    const listed = withDmPeers(rosterPeers, flowDmPeers(keys), SELF).map((p) => p.label)
    assert.deepEqual(listed, ['HUM-2@box-wui', 'c-034@box-a', 'c-035@box-a', 'c-042@box-a'])
    assert.equal(sectionTotal(keys, 'dm:', listed), HUB.unread.dms)
    assert.equal(listed.reduce((n, l) => n + rowUnread(keys, {}, 'dm:' + l), 0), HUB.unread.dms)
  })
  it('channels and topics sum their listed rows; an id listed twice counts once', () => {
    assert.equal(sectionTotal(keys, 'ch:', ['devel', 'lobby', 'devel']), HUB.unread.channels)
    assert.equal(sectionTotal(keys, 't:', ['a', 'b']), HUB.unread.total)
    assert.equal(sectionTotal(null, 'ch:', ['devel']), 0)
  })
  it('a row reads the hub keys once known, its own count before (an older hub)', () => {
    assert.equal(rowUnread(keys, { 'ch:devel': 40 }, 'ch:devel'), 2)
    assert.equal(rowUnread(keys, { 'ch:lobby': 40 }, 'ch:lobby'), 0, 'not a discussion the reader took part in')
    assert.equal(rowUnread(null, { 'ch:lobby': 40 }, 'ch:lobby'), 40)
  })
})

describe('mock twin of the hub keys', () => {
  it('counts each unread event once under its place and once under its topic', () => {
    const msgs = [
      { msg_id: '1', task_id: 'a', channel: 'devel', from: SELF, from_box: 'box-wui', body: 'root', received_at: '2026-10-03T08:00:00Z' },
      { msg_id: '2', task_id: 'a', channel: 'devel', from: 'c-001', from_box: 'box-a', body: 'reply', received_at: '2026-10-03T08:01:00Z' },
      { msg_id: '3', task_id: 'd', from: 'c-034', from_box: 'box-a', to: SELF, to_box: 'box-wui', body: 'dm', received_at: '2026-10-03T08:02:00Z' },
      { msg_id: '4', task_id: 'e', from: 'c-035', from_box: 'box-a', to: 'c-001', to_box: 'box-a', body: 'agent to agent', received_at: '2026-10-03T08:03:00Z' },
    ]
    const events = mockFlowEvents(msgs, SELF)
    const keys = mockFlowKeys(events)
    assert.deepEqual(keys, { 'ch:devel': 1, 't:a': 1, 'dm:c-034@box-a': 1, 't:d': 1 })
    const u = mockFlowCounts(events)
    assert.equal(sectionTotal(keys, 'ch:', ['devel']), u.channels)
    assert.equal(sectionTotal(keys, 'dm:', Object.keys(flowDmPeers(keys))), u.dms)
    assert.deepEqual(mockFlowKeys(events, new Set(['3'])), { 'ch:devel': 1, 't:a': 1 })
    assert.equal(flowPlaceKey({ from: 'HUM-2' }), 'dm:HUM-2')
  })
})

describe('the sidebar reads one map', () => {
  const side = read('../../src/components/ChannelSidebar.vue')
  it('row badges and section numbers both go through the keys', () => {
    assert.match(side, /unreadOf\('dm:' \+ p\.label\)/)
    assert.match(side, /unreadOf\('ch:' \+ c\.channel_id\)/)
    assert.match(side, /unreadOf\('t:' \+ row\.task_id\)/)
    /* spec 079 FR-007: the section number sums the model's listed rows */
    assert.match(side, /return unread\.rowOf\(key\)/)
    assert.match(side, /listedSum\('ch:', channelRows\.value/)
    assert.match(side, /listedSum\('dm:', peers\.value/)
    assert.match(side, /listedSum\('t:', topicRows\.value/)
    assert.match(side, /flowDmPeers\(flowKeys\.value\)/)
  })
})
