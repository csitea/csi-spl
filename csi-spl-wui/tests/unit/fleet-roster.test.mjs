// Spec 153 3.18 (SPL-4786): the operator's cross-workspace roster, the util
// under Agents, Boxes and the agent card (src/utils/fleet-roster.mjs): the
// hub body as rows keyed id@box with their workspace, the groups, the filter,
// the card's lookup by label AND workspace, and the mock's 403.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  MOCK_FLEET_WORKSPACE, byWorkspace, filterForeignBoxes, foreignAgent, foreignAgentLink, foreignAgents,
  mockFleetRoster, normalizeFleetRoster,
} from '../../src/utils/fleet-roster.mjs'

const body = {
  boxes: [
    { workspace: 'tb', workspace_name: 'Beta', box_id: 'mac-01', online: true, last_hello_at: '2026-11-04T10:00:00Z', agents: ['c-001'],
      agent_presence: { 'c-001': { state: 'online' } } },
    { workspace: 'tb', workspace_name: 'Beta', box_id: 'lab', online: true, agents: ['c-002'], agent_presence: { 'c-002': { state: 'not_running' } } },
    { workspace: 'tc', workspace_name: '', box_id: 'mac-01', online: false, agents: ['c-001'] },
    { workspace: '', box_id: 'nows', agents: ['c-009'] },
  ],
  also_seated: { sat: [{ workspace: 'tb', workspace_name: 'Beta' }, { workspace: 'tc' }], bad: 'x' },
}

const store = (op) => ({ getItem: (k) => (k === 'spool.mock.fleet_operator' && op ? '1' : null) })

describe('fleet roster (spec 153 3.18)', () => {
  it('reads the hub body: rows keyed id@box, workspace named, malformed rows dropped', () => {
    const v = normalizeFleetRoster(body)
    assert.deepEqual(v.boxes.map((b) => b.workspace + '/' + b.id), ['tb/mac-01', 'tb/lab', 'tc/mac-01'])
    const a = foreignAgents(v.boxes)
    assert.deepEqual(a.map((x) => x.label + '|' + x.workspaceName + '|' + x.state), [
      'c-001@mac-01|Beta|online', 'c-002@lab|Beta|not_running', 'c-001@mac-01|tc|offline'])
    assert.equal(a[1].online, false)
    assert.deepEqual(v.alsoSeated, { sat: [{ workspace: 'tb', workspaceName: 'Beta' }, { workspace: 'tc', workspaceName: 'tc' }] })
    assert.deepEqual(normalizeFleetRoster(null), { boxes: [], alsoSeated: {} })
  })

  it('groups by workspace in the hub order and filters on box or workspace', () => {
    const v = normalizeFleetRoster(body)
    assert.deepEqual(byWorkspace(v.boxes).map((g) => g.name + ':' + g.rows.length), ['Beta:2', 'tc:1'])
    assert.deepEqual(filterForeignBoxes(v.boxes, 'beta').map((b) => b.id), ['mac-01', 'lab'])
    assert.deepEqual(filterForeignBoxes(v.boxes, 'LAB').map((b) => b.id), ['lab'])
    assert.equal(filterForeignBoxes(v.boxes, ' ').length, 3)
  })

  it('the card finds a foreign agent by label AND workspace, else null', () => {
    const v = normalizeFleetRoster(body)
    assert.equal(foreignAgent(v.boxes, 'c-001@mac-01', 'tc')?.workspace, 'tc')
    assert.equal(foreignAgent(v.boxes, 'c-001@mac-01', 'tb')?.online, true)
    assert.equal(foreignAgent(v.boxes, 'c-001@mac-01', 'tz'), null)
    assert.deepEqual(foreignAgentLink(foreignAgent(v.boxes, 'c-001@mac-01', 'tb')), { path: '/monitoring/agents/c-001%40mac-01', query: { ws: 'tb' } })
  })

  it('the mock answers the operator only, a box-a agent id on its own box', () => {
    assert.throws(() => mockFleetRoster(store(false)), (e) => e.status === 403 && e.permission === 'operator.workspaces')
    const v = normalizeFleetRoster(mockFleetRoster(store(true)))
    assert.deepEqual(foreignAgents(v.boxes).map((a) => a.label + '|' + a.workspace), ['CLE-07@mac-01|' + MOCK_FLEET_WORKSPACE.id])
    assert.ok(v.alsoSeated['box-a'])
  })
})
