// Spec 169 8.5.4 to 8.5.6 (row T19): the Move to workspace dialog's logic
// (src/utils/channel-workspace-move.mjs) and its lazy client calls.
// Run: node --test tests/unit/channel-workspace-move.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MOVE_MOCK_KEY, MOVE_MOCK_SENT_KEY, blockedLines, countRows, mockMoveConfirm, mockMovePlan, mockMoveProbe,
  mockMoveStatus, moveBody, openMoveId, screenAfterPlan, statusView, stopKind,
} from '../../src/utils/channel-workspace-move.mjs'
import { lazySpoolMethods } from '../../src/utils/spool-client-lazy.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const memStore = (init = {}) => {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), map: m }
}

describe('channel move screens (8.5.4)', () => {
  it('sends dst, keep, keep_emails and leave_hours, never a mode or a new name', () => {
    assert.deepEqual(moveBody('beta', { keep: ['HUM-2'], leaveHours: ['HUM-7'] }),
      { dst: 'beta', keep: ['HUM-2'], keep_emails: [], leave_hours: ['HUM-7'] })
    assert.deepEqual(Object.keys(moveBody('')), ['dst', 'keep', 'keep_emails', 'leave_hours'])
  })

  it('a plan with any .blocked line shows the blocked screen, else the confirm', () => {
    assert.equal(screenAfterPlan({ blocked: [] }), 'confirm')
    assert.equal(screenAfterPlan({}), 'confirm')
    assert.equal(screenAfterPlan({ blocked: ['beta has no orchestrator seat, the probe\'s recipient (W2)'] }), 'blocked')
    assert.deepEqual(blockedLines({ blocked: ['a', '', null, 'b'] }), ['a', 'b'])
  })

  it('names what clears each stop in the hub\'s words, and the member of an hours stop', () => {
    const cases = [
      ['seat c-401 on boxa has no desk in beta (W2)', 'seat'],
      ['box boxa is not pinned in beta (R1)', 'pin'],
      ['shared issue SPL-1: a staying topic links it', 'shared'],
      ['channel design exists in beta: set TO_NAME', 'name'],
      ['beta has no orchestrator seat, the probe\'s recipient (W2)', 'orchestrator'],
      ['the channel\'s files do not fit the file quota of beta', 'quota'],
      ['something new', 'other'],
    ]
    for (const [line, kind] of cases) assert.deepEqual(stopKind(line), { kind, member: '' }, line)
    assert.deepEqual(stopKind('hours: HUM-77 2 rows not coming to beta (Q5)'), { kind: 'hours', member: 'HUM-77' })
    assert.deepEqual(stopKind('hours: HUM-77 2 rows inside a frozen or approved sheet (Q8)'), { kind: 'hours', member: 'HUM-77' })
  })

  it('every stop kind and every state has its text in en.json', () => {
    const en = JSON.parse(src('i18n/locales/en.json')).channel_move
    for (const k of ['seat', 'pin', 'shared', 'hours', 'name', 'orchestrator', 'quota', 'other']) assert.ok(en.clears[k], k)
    for (const s of ['waiting', 'stuck', 'running', 'not_moved', 'cleanup_failed', 'traces', 'moved']) assert.ok(en.state[s], s)
  })

  it('counts drop the empty ones, largest first', () => {
    assert.deepEqual(countRows({ counts: { messages: 5, channels: 1, issues: 0, 'messages refs': 2 } }),
      [{ table: 'messages', n: 5 }, { table: 'messages refs', n: 2 }, { table: 'channels', n: 1 }])
    assert.deepEqual(countRows(null), [])
  })

  it('a 409 move_open names its move id; any other error none', () => {
    const id = '0f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0'
    assert.equal(openMoveId({ token: 'move_open', detail: `this channel's move is already confirmed: ${id}` }), id)
    assert.equal(openMoveId({ token: 'move_blocked', detail: id }), '')
    assert.equal(openMoveId(null), '')
  })
})

describe('the stuck table (8.5.6)', () => {
  it('shows each state with only what its row lists; nothing is moved before the hub says moved', () => {
    assert.equal(statusView({ state: 'waiting', stuck: false }).state, 'waiting')
    assert.equal(statusView({ state: 'waiting', stuck: true }).state, 'stuck')
    assert.equal(statusView({ state: 'what' }).state, 'running')
    const nm = statusView({ state: 'not_moved', reason: 'seat c-401 on boxa has no desk in beta (W2)', link: 'x', kept: [{ store: 'a' }] })
    assert.deepEqual([nm.reason, nm.link, nm.kept], ['seat c-401 on boxa has no desk in beta (W2)', '', []])
    const tr = statusView({ state: 'traces', proofs: [{ name: 'M4 files left in alpha', count: 2 }], link: 'https://beta.example.com/channel/design' })
    assert.deepEqual(tr.proofs, [{ name: 'M4 files left in alpha', count: 2 }])
    assert.equal(tr.link, 'https://beta.example.com/channel/design')
    const mv = statusView({ state: 'moved', kept: [{ store: 'hub logs', until: '2027-01-01' }], link: 'L' })
    assert.deepEqual([mv.kept, mv.link, mv.proofs], [[{ store: 'hub logs', until: '2027-01-01' }], 'L', []])
  })
})

describe('the mock (e2e only)', () => {
  it('offers no move without the e2e fixture', () => {
    assert.deepEqual(mockMoveProbe(memStore()), { allowed: false, targets: [] })
    assert.throws(() => mockMovePlan({}, memStore()), (e) => e.status === 403)
    assert.throws(() => mockMoveStatus('x', memStore()), (e) => e.token === 'unknown_move')
  })

  it('clears an hours stop for a member left behind, refuses a blocked confirm, records the GO body', () => {
    const plan = { counts: { messages: 3 }, blocked: ['hours: HUM-7 2 rows not coming to beta (Q5)'] }
    const store = memStore({ [MOVE_MOCK_KEY]: JSON.stringify({ targets: [{ slug: 'beta', name: 'Beta' }], plan, confirm: { move_id: 'm1', topic: 't1' } }) })
    assert.deepEqual(mockMoveProbe(store), { allowed: true, targets: [{ slug: 'beta', name: 'Beta' }] })
    assert.equal(mockMovePlan({ leave_hours: [] }, store).blocked.length, 1)
    assert.deepEqual(mockMovePlan({ leave_hours: ['HUM-7'] }, store).blocked, [])
    assert.throws(() => mockMoveConfirm(moveBody('beta'), store), (e) => e.token === 'move_blocked')
    assert.deepEqual(mockMoveConfirm(moveBody('beta', { leaveHours: ['HUM-7'] }), store), { move_id: 'm1', topic: 't1' })
    assert.deepEqual(JSON.parse(store.map.get(MOVE_MOCK_SENT_KEY)).leave_hours, ['HUM-7'])
  })
})

describe('the client calls (T14, T15, T17 routes)', () => {
  it('posts the plan and the confirm, and reads the status by move id', async () => {
    const calls = []
    const ctx = { mock: false, live: async (path, opts) => { calls.push({ path, method: opts?.method || 'GET', body: opts?.body }); return {} } }
    const body = moveBody('beta', { keep: ['HUM-2'] })
    await lazySpoolMethods.channelWorkspaceMovePlan(ctx, 'team a', body)
    await lazySpoolMethods.channelWorkspaceMoveConfirm(ctx, 'team a', body)
    await lazySpoolMethods.channelMoveStatus(ctx, 'ABC')
    assert.deepEqual(calls, [
      { path: '/v1/channels/team%20a/workspace-move/plan', method: 'POST', body: JSON.stringify(body) },
      { path: '/v1/channels/team%20a/workspace-move', method: 'POST', body: JSON.stringify(body) },
      { path: '/v1/channel-moves/ABC', method: 'GET', body: undefined },
    ])
    for (const m of ['channelWorkspaceMovePlan', 'channelWorkspaceMoveConfirm', 'channelMoveStatus']) {
      assert.ok(src('src/utils/spool-client.mjs').includes(`'${m}',`), m)
    }
  })

  it('the dialog is lazy, mounted on the menu\'s target, and the item is on', () => {
    const side = src('src/components/ChannelSidebar.vue')
    assert.match(side, /<LazyChannelWorkspaceMoveDialog\s+v-if="workspaceMoveTarget\.channel_id"/)
    assert.equal(/import ChannelWorkspaceMoveDialog/.test(side), false)
    assert.match(src('src/utils/sidebar-row-menu.mjs'), /export const WORKSPACE_MOVE_BUILT = true/)
  })
})
