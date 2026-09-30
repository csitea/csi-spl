// CLE-77799: the per-person Activity log rows (owner topic 1fc29f99). Slice 1
// sources them from the act-as trail (GET /v1/audit/clones).
// Run: node tests/unit/activity-log.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ACTIVITY_KINDS, cloneActivityRows, filterActivity, memberActivityRows, sortActivity } from '../../src/utils/activity-log.mjs'

const CLONES = [
  { target_hum: 'HUM-2', created_by: 'HUM-1', role: 'developer', created_at: '2026-09-20T09:00:00Z', ended_at: '2026-09-20T09:20:00Z', end_reason: 'stop' },
  { target_hum: 'HUM-2', created_by: 'HUM-1', role: 'developer', created_at: '2026-09-18T12:00:00Z', ended_at: null, end_reason: '' },
  { target_hum: 'HUM-9', created_by: 'HUM-1', role: 'tester', created_at: '2026-09-19T12:00:00Z', ended_at: '2026-09-19T13:00:00Z', end_reason: 'expired' },
]

describe('cloneActivityRows', () => {
  it('keeps only the target and splits each clone into started (+ ended)', () => {
    const rows = cloneActivityRows(CLONES, 'HUM-2')
    // clone A: started + ended (2), clone B: started only (1) = 3 rows
    assert.equal(rows.length, 3)
    assert.ok(rows.every((r) => r.actor === 'HUM-1'))
    const kinds = rows.map((r) => r.kind)
    assert.ok(kinds.includes('act_as_started') && kinds.includes('act_as_ended'))
  })
  it('is newest-first by default', () => {
    const rows = cloneActivityRows(CLONES, 'HUM-2')
    // newest event is clone A's ended_at 09-20T09:20, then its start 09:00, then B's 09-18
    assert.deepEqual(rows.map((r) => r.at), ['2026-09-20T09:20:00Z', '2026-09-20T09:00:00Z', '2026-09-18T12:00:00Z'])
    assert.equal(rows[0].kind, 'act_as_ended')
    assert.equal(rows[0].detail, 'stop')
  })
  it('a person with no clones has no rows; tolerates junk', () => {
    assert.deepEqual(cloneActivityRows(CLONES, 'HUM-404'), [])
    assert.deepEqual(cloneActivityRows(null, 'HUM-2'), [])
    assert.deepEqual(cloneActivityRows([{}], 'HUM-2'), [])
  })
  it('the started row carries the role, the ended row the reason', () => {
    const rows = cloneActivityRows(CLONES, 'HUM-9')
    const started = rows.find((r) => r.kind === 'act_as_started')
    const ended = rows.find((r) => r.kind === 'act_as_ended')
    assert.equal(started.detail, 'tester')
    assert.equal(ended.detail, 'expired')
  })
})

describe('memberActivityRows', () => {
  it('maps the hub rows (by -> actor), dropping timeless/kindless ones', () => {
    const rows = memberActivityRows([
      { at: '2026-09-21T10:00:00Z', kind: 'role_changed', detail: 'tester', by: 'HUM-1' },
      { at: '2026-09-22T08:00:00Z', kind: 'sign_in', detail: 'google', ip: '203.0.113.0/24' },
      { kind: 'sign_out' }, // no time -> dropped
      { at: '2026-09-23T08:00:00Z' }, // no kind -> dropped
    ])
    assert.equal(rows.length, 2)
    const roleRow = rows.find((r) => r.kind === 'role_changed')
    assert.equal(roleRow.actor, 'HUM-1')
    assert.equal(roleRow.detail, 'tester')
    const signin = rows.find((r) => r.kind === 'sign_in')
    assert.equal(signin.actor, '')
    assert.equal(signin.ip, '203.0.113.0/24')
  })
  it('tolerates junk', () => {
    assert.deepEqual(memberActivityRows(null), [])
    assert.deepEqual(memberActivityRows([null, {}]), [])
  })
})

describe('sortActivity / filterActivity', () => {
  const rows = cloneActivityRows(CLONES, 'HUM-2')
  it('sorts ascending and descending, stable on ties', () => {
    const asc = sortActivity(rows, 'at', 'asc')
    assert.equal(asc[0].at, '2026-09-18T12:00:00Z')
    assert.equal(asc.at(-1).at, '2026-09-20T09:20:00Z')
    assert.deepEqual(sortActivity(rows, 'at', 'desc').map((r) => r.at), rows.map((r) => r.at))
  })
  it('sorts by event kind', () => {
    const byKind = sortActivity(rows, 'kind', 'asc')
    assert.equal(byKind[0].kind, 'act_as_ended') // alphabetical: ended < started
  })
  it('filters by kind; empty keeps all', () => {
    assert.equal(filterActivity(rows, 'act_as_started').length, 2)
    assert.equal(filterActivity(rows, 'act_as_ended').length, 1)
    assert.equal(filterActivity(rows, '').length, rows.length)
    assert.equal(filterActivity(rows, 'nope').length, 0)
  })
  it('ACTIVITY_KINDS lists every kind the slices emit', () => {
    for (const k of ['act_as_started', 'act_as_ended', 'invited', 'role_changed', 'removed', 'sign_in', 'sign_out', 'session_expiry']) {
      assert.ok(ACTIVITY_KINDS.includes(k), k)
    }
  })
})
