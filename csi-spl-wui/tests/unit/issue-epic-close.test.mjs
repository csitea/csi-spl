// SPL-1643 (owner HUM-10, t1 1ccf3a20): closing an epic closes and archives
// its issues, once the member confirms. The refusal's count, the answer's
// archived keys, and the mock hub's gate (the e2e bundle runs on it).
//
// Run: node tests/unit/issue-epic-close.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { epicCloseOpenCount, epicClosedKeys } from '../../src/utils/issue-epic-close.mjs'
import { createMockIssues } from '../../src/utils/issues.mjs'
import { MOCK_DEFAULT_TOPIC } from '../../src/utils/issue-discussions.mjs'

/* SPL-1593 (rdb 0194): the mock hub, like the hub, refuses an issue with no discussion */
const LINK = { discussions: [MOCK_DEFAULT_TOPIC] }

describe('epicCloseOpenCount', () => {
  it('reads the count of the hub refusal', () => {
    assert.equal(epicCloseOpenCount({ token: 'epic_close_confirm', detail: 'SPL-17 has 12 open issues: closing it closes and archives them' }), 12)
  })
  it('is null for any other error (control)', () => {
    assert.equal(epicCloseOpenCount({ token: 'issue_has_children', detail: 'SPL-17 has 12 open issues' }), null)
    assert.equal(epicCloseOpenCount(null), null)
  })
})

describe('epicClosedKeys', () => {
  it('names the row then its issues when the answer archived them', () => {
    assert.deepEqual(epicClosedKeys('SPL-1', { archived: true, descendants: ['SPL-2', 'SPL-3'] }), ['SPL-1', 'SPL-2', 'SPL-3'])
  })
  it('is empty for a plain update or a failed cascade (control)', () => {
    assert.deepEqual(epicClosedKeys('SPL-1', { issue: {} }), [])
    assert.deepEqual(epicClosedKeys('SPL-1', { archived: false, cascade_error: 'x' }), [])
  })
})

describe('the mock hub closes an epic like the hub', () => {
  const rig = () => {
    const m = createMockIssues({ me: 'HUM-1' })
    const epic = m.create({ title: 'Epic', kind: 'epic', ...LINK }).issue.key
    const open = m.create({ title: 'Open', epic, status: 'wip', ...LINK }).issue.key
    const done = m.create({ title: 'Done', epic, status: 'done', ...LINK }).issue.key
    const plain = m.create({ title: 'Plain', ...LINK }).issue.key
    const keys = () => m.list('').issues.map((i) => i.key)
    return { m, epic, open, done, plain, keys }
  }
  it('refuses without the confirmation, naming the count; nothing changes', () => {
    const { m, epic, keys } = rig()
    const before = keys()
    assert.throws(() => m.update(epic, { status: 'done' }), (e) => epicCloseOpenCount(e) === 1)
    assert.deepEqual(keys(), before)
    assert.notEqual(m.get(epic).issue.status, 'done')
  })
  it('confirmed: closes the open issue and archives all three', () => {
    const { m, epic, open, done, plain, keys } = rig()
    const out = m.update(epic, { status: 'done', cascade: true })
    assert.equal(out.archived, true)
    assert.deepEqual(out.closed, [open])
    assert.deepEqual(epicClosedKeys(epic, out).sort(), [epic, open, done].sort())
    for (const k of [epic, open, done]) assert.ok(!keys().includes(k), k)
    assert.ok(keys().includes(plain))
  })
  it('a plain issue closes alone (control)', () => {
    const { m, plain, epic, keys } = rig()
    const out = m.update(plain, { status: 'done' })
    assert.equal(out.archived, undefined)
    assert.ok(keys().includes(plain) && keys().includes(epic))
  })
})
