// spec 130 section 3.1: the Flow member picker's rules (src/utils/flow-member.mjs).
// Run: node tests/unit/flow-member.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { flowMemberFromQuery, flowMemberOptions, flowMemberQuery, isFlowMemberKey } from '../../src/utils/flow-member.mjs'

describe('isFlowMemberKey', () => {
  it('takes a person id and an agent with its box', () => {
    for (const id of ['HUM-1', 'GST-12', 'c-002@box-a', 'CLE-7@sat']) assert.equal(isFlowMemberKey(id), true, id)
  })
  it('refuses a bare agent id, the everyone alias and junk', () => {
    for (const id of ['c-002', 'ALL-0@box-wui', 'HUM-', 'hum-1', '', null, 'c-000@box-a', 'c-002@Box']) assert.equal(isFlowMemberKey(id), false, String(id))
  })
})

describe('flowMemberFromQuery / flowMemberQuery', () => {
  it('reads ?flow= and drops what is no member key', () => {
    assert.equal(flowMemberFromQuery({ flow: 'HUM-3' }), 'HUM-3')
    assert.equal(flowMemberFromQuery({ flow: ['c-002@box-a'] }), 'c-002@box-a')
    assert.equal(flowMemberFromQuery({ flow: '<script>' }), '')
    assert.equal(flowMemberFromQuery({}), '')
    assert.equal(flowMemberFromQuery(null), '')
  })
  it('writes ?flow=, and none for the reader (no parameter means me)', () => {
    assert.deepEqual(flowMemberQuery({ topic: 'x' }, 'HUM-3', 'HUM-1'), { topic: 'x', flow: 'HUM-3' })
    assert.deepEqual(flowMemberQuery({ topic: 'x', flow: 'HUM-3' }, 'HUM-1', 'HUM-1'), { topic: 'x' })
    assert.deepEqual(flowMemberQuery({ flow: 'HUM-3' }, '', 'HUM-1'), {})
  })
  it('round-trips', () => {
    for (const m of ['HUM-3', 'c-002@box-a']) assert.equal(flowMemberFromQuery(flowMemberQuery({}, m, 'HUM-1')), m)
  })
})

describe('flowMemberOptions', () => {
  const o = {
    humans: ['HUM-2', 'HUM-1', 'HUM-3'],
    people: [{ id: 'HUM-3', box: 'box-wui' }, { id: 'c-002', box: 'box-b' }, { id: 'c-001', box: 'box-a' }, { id: 'c-001', box: 'box-a' }, { id: 'c-002' }],
    self: 'HUM-1',
    label: (id) => ({ 'HUM-2': 'Zed', 'HUM-3': 'Ann' })[id] || id,
    meLabel: 'Me',
    personsGroup: 'P',
    agentsGroup: 'A',
  }
  it('lists me first, then persons, then agents, A-Z, each once', () => {
    assert.deepEqual(flowMemberOptions(o).map((r) => [r.id, r.label, r.group]), [
      ['HUM-1', 'Me', 'P'], ['HUM-3', 'Ann', 'P'], ['HUM-2', 'Zed', 'P'], ['c-001@box-a', 'c-001@box-a', 'A'], ['c-002@box-b', 'c-002@box-b', 'A'],
    ])
  })
  it('a bare agent (no box) is not offered', () => {
    assert.equal(flowMemberOptions(o).some((r) => r.id === 'c-002'), false)
  })
})
