// Spec 153 3.22.3 (row Q4, SPL-6740): Monitoring -> Queue, read only, the
// util under the page (src/utils/monitoring-queue.mjs): the hub body as a
// view in the hub's order, the cells' words and links, the route and the
// mock. C106's columns and C107's chunk rule, as far as Node sees them (the
// browser half is tests/e2e/monitoring-costs.test.mjs). CONTROL: anyone but
// the operator admin -> 403; a lane in any other form is no link.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  QUEUE_MOCK_KEY,
  QUEUE_MOCK_TOPIC,
  fleetQueueOf,
  mockFleetQueue,
  queueClassKey,
  queueInLine,
  queueIssueRef,
  queueLaneCell,
  queueOpen,
  queuePath,
  queuePositionCell,
  queueTopicRef,
} from '../../src/utils/monitoring-queue.mjs'
import { LANES_MOCK_TOPIC } from '../../src/utils/monitoring-lanes.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

/** A localStorage stand-in. */
function memStore(init = {}) {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => { m.set(k, String(v)) }, removeItem: (k) => { m.delete(k) } }
}

const NOW = new Date('2026-11-28T10:00:00Z')
const OP = { [TOKENS_MOCK_OPERATOR_KEY]: '1' }

describe('monitoring queue: the view', () => {
  it('keeps the hub order, drops a row with no ask id, and never guesses a lane', () => {
    const v = fleetQueueOf({ as_of: '2026-11-28T10:00:00Z', fleet: 'main', total: 2, rows: [
      { ask_id: 'b', state: 'queued', position: 2, priority: 2, priority_source: 'discussion', class: 'feature', flag: 'bypass', vendor: 'agy', in_line_s: 90 },
      { ask_id: '', state: 'queued' },
      null,
      { ask_id: 'a', state: 'queued', position: 1, priority: 9, priority_source: 'nonsense', flag: 'loud', lane: 'c-085@box-a' },
      { ask_id: 'c', state: 'done', lane: 'whoever' },
    ] })
    assert.equal(v.asOf, '2026-11-28T10:00:00Z')
    assert.equal(v.total, 2)
    assert.deepEqual(v.rows.map((r) => r.askId), ['b', 'a', 'c'], 'the hub order, not re-sorted by position')
    assert.equal(v.rows[0].prioritySource, 'discussion')
    assert.equal(v.rows[0].flag, 'bypass')
    assert.equal(v.rows[1].priority, 0, 'a priority outside 1..5 is none')
    assert.equal(v.rows[1].prioritySource, '', 'an unknown source is none')
    assert.equal(v.rows[1].flag, '', 'an unknown flag is none')
    assert.equal(v.rows[2].lane, '', 'C104: a lane not in the <ID>@<box> form is dropped')
    assert.deepEqual(fleetQueueOf(null), { asOf: '', fleet: '', total: 0, rows: [] })
  })
  it('the Position cell: n/total, placing, the closed state', () => {
    assert.deepEqual(queuePositionCell({ state: 'queued', position: 2 }, 3), { text: '2/3' })
    assert.deepEqual(queuePositionCell({ state: 'placing', position: 0 }, 3), { key: 'monitoring.queue.placing' })
    assert.deepEqual(queuePositionCell({ state: 'done', position: 0 }, 3), { key: 'monitoring.queue.state_done' })
    assert.deepEqual(queuePositionCell({ state: 'declined', position: 0 }, 3), { key: 'monitoring.queue.state_declined' })
    assert.deepEqual(queuePositionCell({ state: 'odd', position: 0 }, 3), { text: '—' })
    assert.equal(queueOpen({ state: 'queued' }) && queueOpen({ state: 'placing' }), true)
    assert.equal(queueOpen({ state: 'done' }), false)
  })
  it('Class and In line', () => {
    assert.equal(queueClassKey('ci'), 'monitoring.queue.class_ci')
    assert.equal(queueClassKey('exotic'), null, 'an unknown class is shown as sent')
    assert.deepEqual(queueInLine(59), { key: 'monitoring.queue.in_line_min', params: { n: 0 } })
    assert.deepEqual(queueInLine(5400), { key: 'monitoring.queue.in_line_h', params: { h: 1, m: 30 } })
    assert.deepEqual(queueInLine(93780), { key: 'monitoring.queue.in_line_d', params: { d: 1, h: 2 } })
  })
  it('the discussion and the issue are typed refs of the page\'s workspace; anything else stays text', () => {
    assert.deepEqual(queueTopicRef({ discussion: QUEUE_MOCK_TOPIC.toUpperCase() }, 'mock'), { kind: 'topic', workspace_id: 'mock', ref: QUEUE_MOCK_TOPIC })
    assert.equal(queueTopicRef({ discussion: 'spawn-share' }, 'mock'), null)
    assert.equal(queueTopicRef({ discussion: QUEUE_MOCK_TOPIC }, ''), null, 'no workspace known: text')
    assert.deepEqual(queueIssueRef({ issueKey: 'SPL-6740' }, 'mock'), { kind: 'issue', workspace_id: 'mock', ref: 'SPL-6740' })
    assert.equal(queueIssueRef({ issueKey: 'unknown' }, 'mock'), null)
  })
  it('the Lane cell links an active lane to its Lanes row, an ended one is its agent id as text', () => {
    const active = new Set(['c-085@box-a'])
    assert.deepEqual(queueLaneCell({ lane: 'c-085@box-a' }, active), { lane: 'c-085@box-a', agentId: 'c-085', to: { path: '/monitoring/lanes', query: { lane: 'c-085@box-a' } } })
    assert.deepEqual(queueLaneCell({ lane: 'c-412@box-b' }, active), { lane: 'c-412@box-b', agentId: 'c-412', to: null })
    assert.deepEqual(queueLaneCell({ lane: 'c-412@box-b' }, null).to, { path: '/monitoring/lanes', query: { lane: 'c-412@box-b' } }, 'lanes not read: it links')
    assert.equal(queueLaneCell({ lane: '' }, active), null)
  })
})

describe('monitoring queue: the route and the mock', () => {
  it('the route and its Placed filter (off by default)', () => {
    assert.equal(queuePath(), '/v1/operator/fleet-queue')
    assert.equal(queuePath(true), '/v1/operator/fleet-queue?placed=1')
  })
  it('CONTROL: anyone but the operator admin gets the hub\'s 403', () => {
    assert.throws(() => mockFleetQueue(false, memStore(), NOW), (e) => e.status === 403 && e.permission === 'operator.workspaces')
  })
  it('the operator admin: one placing, three queued in position order, total 3; Placed adds the closed rows', () => {
    const v = fleetQueueOf(mockFleetQueue(false, memStore(OP), NOW))
    assert.deepEqual(v.rows.map((r) => r.state + ':' + r.position), ['placing:0', 'queued:1', 'queued:2', 'queued:3'])
    assert.equal(v.total, 3)
    assert.deepEqual(v.rows.map((r) => r.prioritySource), ['discussion', 'own', 'discussion', 'default'])
    assert.equal(v.rows[3].holdReason, 'grok weekly limit')
    assert.equal(v.rows.some((r) => r.lane), false, 'the line has no lane yet')
    assert.equal(QUEUE_MOCK_TOPIC, LANES_MOCK_TOPIC, 'the Lanes mock topic, so the discussion links /t/<uuid>')
    const p = fleetQueueOf(mockFleetQueue(true, memStore(OP), NOW))
    assert.deepEqual(p.rows.slice(4).map((r) => r.state + ':' + r.lane), ['done:c-085@box-a', 'done:c-412@box-b', 'declined:'])
    assert.deepEqual(fleetQueueOf(mockFleetQueue(true, memStore({ ...OP, [QUEUE_MOCK_KEY]: 'empty' }), NOW)).rows, [])
  })
})

describe('monitoring queue: the page and the chunk rule (C106, C107)', () => {
  const page = read('src/pages/monitoring/queue/index.vue')
  it('C106: the Requests columns in 3.22.3\'s order', () => {
    const cols = (page.match(/const COLUMNS = \[([^\]]+)\]/) || [])[1] || ''
    assert.deepEqual(cols.split(',').map((c) => c.trim().replace(/'/g, '')),
      ['position', 'prio', 'class', 'summary', 'discussion', 'issue', 'vendor', 'in_line', 'waits', 'lane'])
    const en = JSON.parse(read('i18n/locales/en.json')).monitoring.queue
    for (const c of cols.split(',').map((x) => x.trim().replace(/'/g, ''))) assert.ok(en['col_' + c], 'col_' + c)
  })
  it('read only: the page sends no write (Q5 brings the chooser, Q6 the drag)', () => {
    assert.doesNotMatch(page, /method:\s*'(PUT|POST|DELETE|PATCH)'|ask_op|priority\(/)
  })
  it('C107: monitoring-queue.mjs is imported on demand only, by the page and the lazy client', () => {
    const files = []
    const walk = (d) => { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) walk(p); else if (/\.(vue|ts|mjs|js)$/.test(n)) files.push(p) } }
    walk(join(WUI, 'src'))
    const users = []
    for (const f of files) {
      const s = readFileSync(f, 'utf8')
      if (!/monitoring-queue\.mjs/.test(s)) continue
      const rel = relative(WUI, f)
      users.push(rel)
      /* a value import (not `import type`) of the file is the planted static import C107 refuses */
      assert.doesNotMatch(s, /^\s*import\s+(?!type\b)[^\n]*['"][^'"\n]*monitoring-queue\.mjs['"]/m, rel + ': static import')
    }
    assert.deepEqual(users.sort(), ['src/pages/monitoring/queue/index.vue', 'src/utils/spool-client-lazy.mjs'])
    assert.match(read('src/utils/spool-client-lazy.mjs'), /if \(own === 'queue'\) return getFleetQueue\(live, mock, placed === true\)/)
  })
})
