// Spec 130 L2a (owner HUM-10, t1 da98036e): the Flow's folded lines - one per
// topic per UTC day and one per UTC day of releases - shaped from the hub's
// fold=day read (contract flow-fold-v1), folded the same way for the mock,
// opened where they point, and marked read as a whole.
//
// Run: node tests/unit/flow-fold.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  FLOW_LINE_GLYPH, MOCK_RELEASES, flowByNewest, flowLineKey, flowLineMark, flowLineOffered, flowLineTarget,
  foldFlowEvents, foldReleases, mergeFlowLines, parseFlowLine, parseFlowLines, refreshFlowLines, utcDay,
} from '../../src/utils/flow-fold.mjs'

const T = 'aaaaaaaa-0000-4000-8000-000000000001'
const T2 = 'aaaaaaaa-0000-4000-8000-000000000002'
const ev = (msg, at, kind, from, task = T, more = {}) => ({ msg_id: msg, task_id: task, at, kind, from, body: 'body of ' + msg, channel: 'ch-1', ...more })

describe('foldFlowEvents: one line per topic per UTC day (spec 130 section 2.1)', () => {
  const events = [
    ev('m5', '2026-10-11T16:40:00Z', 'reply', 'c-002'),
    ev('m4', '2026-10-11T15:00:00Z', 'mention', 'c-003'),
    ev('m3', '2026-10-11T12:00:00Z', 'blocked', 'c-004', T, { unread: false }),
    ev('m2', '2026-10-11T09:00:00Z', 'reply', 'c-002'),
    ev('m1', '2026-10-10T23:59:00Z', 'reply', 'c-005'),
    ev('n1', '2026-10-11T10:00:00Z', 'dm', 'HUM-2', T2, { channel: null }),
  ]
  const lines = foldFlowEvents(events, { titleOf: (t) => (t === T ? 'Flow v2' : '') })

  it('a topic\'s events of one UTC day fold into ONE line; another day is another line', () => {
    const t = lines.filter((l) => l.task_id === T)
    assert.equal(t.length, 2, JSON.stringify(t.map((l) => l.day)))
    assert.deepEqual(t.map((l) => [l.day, l.count]), [['2026-10-11', 4], ['2026-10-10', 1]])
  })

  it('the line shows the strongest kind, the newest event, up to two ids then +N', () => {
    const l = lines.find((x) => x.task_id === T && x.day === '2026-10-11')
    assert.equal(l.kind, 'blocked')
    assert.equal(l.msg_id, 'm5')
    assert.equal(l.at, '2026-10-11T16:40:00Z')
    assert.deepEqual(l.ids, ['c-002', 'c-003'])
    assert.equal(l.ids_more, 1)
    assert.equal(l.title, 'Flow v2')
    assert.equal(l.unread, true, 'any folded event unread')
    assert.equal(l.link, `/t/${T}#m5`)
    assert.equal(l.mark, 't:' + T)
  })

  it('a DM line keeps channel null', () => {
    const d = lines.find((x) => x.task_id === T2)
    assert.equal(d.channel, null)
    assert.equal(d.kind, 'dm')
  })

  it('utcDay reads the UTC calendar day, not the local one', () => {
    assert.equal(utcDay('2026-10-10T23:59:00-02:00'), '2026-10-11')
    assert.equal(utcDay('nope'), '')
  })
})

describe('parseFlowLine: the hub\'s wire line (contract flow-fold-v1 section 2)', () => {
  it('a topic line keeps its fields and its link / mark', () => {
    const l = parseFlowLine({ kind: 'ready', day: '2026-10-11', count: 3, at: '2026-10-11T16:40:00Z', unread: true, link: `/t/${T}#m9`, mark: 't:' + T, task_id: T, msg_id: 'm9', channel: null, title: 'x', text: 'y', ids: ['c-002'], ids_more: 2, issue: 12, extra: 1 })
    assert.equal(l.kind, 'ready')
    assert.equal(l.issue, 12)
    assert.equal(l.ids_more, 2)
    assert.equal('extra' in l, false)
    assert.equal(l.key, flowLineKey(l))
  })

  it('a release line: span, sha, its /releases link and f:rel: mark', () => {
    const l = parseFlowLine({ kind: 'release', day: '2026-10-11', at: '2026-10-11T17:00:00Z', version_from: 'v1.3.400', version_to: 'v1.3.420', versions: 21, sha: 'abc', unread: true })
    assert.equal(l.versions, 21)
    assert.equal(l.link, '/releases/abc')
    assert.equal(l.mark, 'f:rel:v1.3.420')
  })

  it('a line that cannot open is dropped', () => {
    assert.deepEqual(parseFlowLines([{ kind: 'mention' }, { kind: 'release', version_to: 'v1' }, null]), [])
  })

  it('every kind has a glyph', () => {
    for (const k of ['blocked', 'ready', 'mention', 'poke', 'dm', 'reply', 'release']) assert.ok(FLOW_LINE_GLYPH[k], k)
  })
})

describe('where a line opens and what it marks (spec 130 sections 2.4, 2.5)', () => {
  const topic = parseFlowLine({ kind: 'mention', at: '2026-10-11T16:40:00Z', task_id: T, msg_id: 'm5', issue: 7 })
  const blocked = parseFlowLine({ kind: 'blocked', at: '2026-10-11T16:40:00Z', task_id: T, msg_id: 'm5', issue: 7 })
  const blockedNoIssue = parseFlowLine({ kind: 'blocked', at: '2026-10-11T16:40:00Z', task_id: T, msg_id: 'm5' })
  const rel = parseFlowLine({ kind: 'release', at: '2026-10-11T17:00:00Z', version_to: 'v1.3.420', sha: 'abc' })

  it('a blocked line opens its topic\'s issue; without one, its message', () => {
    assert.deepEqual(flowLineTarget(blocked), { to: 'issue', path: '/issues?issue=7' })
    assert.deepEqual(flowLineTarget(blockedNoIssue), { to: 'message', path: `/t/${T}#m5` })
    assert.deepEqual(flowLineTarget(topic), { to: 'message', path: `/t/${T}#m5` })
    assert.deepEqual(flowLineTarget(rel), { to: 'release', path: '/releases/abc' })
  })

  it('opening writes t:<task_id> at the newest event; a release line f:rel:<version>', () => {
    assert.deepEqual(flowLineMark(topic), { ['t:' + T]: { ts: '2026-10-11T16:40:00Z', id: 'm5' } })
    assert.deepEqual(flowLineMark(rel), { 'f:rel:v1.3.420': { ts: '2026-10-11T17:00:00Z' } })
  })

  it('the menu offers what the line points to', () => {
    assert.deepEqual(flowLineOffered(topic), ['open', 'issue', 'copy', 'copy-text'])
    assert.deepEqual(flowLineOffered(blockedNoIssue), ['open', 'copy', 'copy-text'])
    assert.deepEqual(flowLineOffered({ ...rel, unread: true }), ['release', 'copy', 'copy-text', 'read'])
  })
})

describe('pages and refreshes', () => {
  const a = parseFlowLine({ kind: 'reply', day: '2026-10-11', at: '2026-10-11T10:00:00Z', task_id: T, msg_id: 'm1' })
  const b = parseFlowLine({ kind: 'reply', day: '2026-10-10', at: '2026-10-10T10:00:00Z', task_id: T2, msg_id: 'n1' })
  const a2 = parseFlowLine({ kind: 'mention', day: '2026-10-11', at: '2026-10-11T11:00:00Z', task_id: T, msg_id: 'm2' })

  it('a next page adds below; a key is held once', () => {
    assert.deepEqual(mergeFlowLines([a], [a, b]).map((l) => l.key), [a.key, b.key])
  })

  it('a fresh newest page replaces a topic-day whose newest event moved, the older pages stay', () => {
    assert.deepEqual(refreshFlowLines([a2], [a, b]).map((l) => l.msg_id), ['m2', 'n1'])
  })

  it('the mock releases fold per UTC day and merge by time; unread only after f:seen', () => {
    const rel = foldReleases(MOCK_RELEASES)
    assert.equal(rel.length, 1)
    assert.deepEqual([rel[0].version_from, rel[0].version_to, rel[0].versions], ['v1.3.400', 'v1.3.402', 3])
    assert.equal(rel[0].unread, false, 'no f:seen yet: nothing unread')
    assert.equal(foldReleases(MOCK_RELEASES, { seen: '2026-09-01T00:00:00Z' })[0].unread, true)
    assert.equal(foldReleases(MOCK_RELEASES, { seen: '2026-09-01T00:00:00Z', marked: (v) => v === 'v1.3.402' })[0].unread, false)
    assert.deepEqual(flowByNewest([b, rel[0], a]).map((l) => l.key), [a.key, b.key, rel[0].key])
  })
})
