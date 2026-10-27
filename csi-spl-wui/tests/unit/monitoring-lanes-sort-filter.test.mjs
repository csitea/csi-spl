// SPL-3887 (owner HUM-10, t1 31f6f470, msgs 1eedefed and 08b25696): the
// Lanes listing sorts by every column and filters by box, vendor, state, age
// and text with the Issues sheet's controls: one header button
// (components/SheetSortButton.vue) and one sort cycle (utils/sheet-sort.mjs),
// never a second copy.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cycleSort } from '../../src/utils/sheet-sort.mjs'
import { nextSort, SHEET_COLUMNS } from '../../src/utils/issues-view.mjs'
import {
  LANE_COLUMNS,
  LANES_NO_FILTER,
  filterLanes,
  fleetLanesOf,
  laneFilterChoices,
  laneState,
  lanesFiltered,
  sortLanes,
} from '../../src/utils/monitoring-lanes.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const ids = (lanes) => lanes.map((l) => l.agentId).join(',')

/* hub order: newest write first */
const VIEW = fleetLanesOf({ as_of: '2026-10-27T12:00:00Z', fleet: 'main', lanes: [
  { agent_id: 'c-10', agent_box: 'box-b', vendor: 'claude', scope: 'Lanes sort', topic_id: 't', topic_title: 'Beta topic',
    issues: [{ key: 'SPL-20', status: 'wip' }], updated_at: '2026-10-27T11:58:00Z', age_s: 120, last_active: '2026-10-27T11:59:00Z', workspace: 'w1', workspace_name: 'Ops' },
  { agent_id: 'c-9', agent_box: 'box-a', vendor: 'claude', scope: 'Disk sweep', topic_id: '', topic_title: '',
    issues: [], updated_at: '2026-10-27T09:00:00Z', age_s: 10800, last_active: '', workspace: 'w2', workspace_name: 'Acme' },
  { agent_id: 'a-277', agent_box: 'box-a', vendor: 'agy', scope: 'Review the locale text', topic_id: 'x', topic_title: 'Alpha topic',
    issues: [{ key: 'SPL-3', status: '' }], updated_at: '2026-10-25T12:00:00Z', age_s: 172800, last_active: '2026-10-26T12:00:00Z', workspace: 'w1', workspace_name: 'Ops' },
  { agent_id: 'm-039', agent_box: 'box-b', vendor: 'mistral', scope: 'Queued summary', state: 'queued',
    issues: [], updated_at: '2026-10-27T11:30:00Z', age_s: 1800, last_active: '', workspace: 'w1', workspace_name: 'Ops' },
] }).lanes

describe('one sort cycle for both sheets', () => {
  it('none -> asc -> desc -> none; an unknown column is the default', () => {
    let s = { col: '', dir: '' }
    s = cycleSort('vendor', s, LANE_COLUMNS); assert.deepEqual(s, { col: 'vendor', dir: 'asc' })
    s = cycleSort('vendor', s, LANE_COLUMNS); assert.deepEqual(s, { col: 'vendor', dir: 'desc' })
    s = cycleSort('vendor', s, LANE_COLUMNS); assert.deepEqual(s, { col: '', dir: '' })
    assert.deepEqual(cycleSort('box', { col: 'vendor', dir: 'asc' }, LANE_COLUMNS), { col: '', dir: '' })
  })
  it('the Issues sheet\'s nextSort is the same cycle over its columns', () => {
    for (const col of [...SHEET_COLUMNS, 'nope']) {
      for (const cur of [{ col: '', dir: '' }, { col, dir: 'asc' }, { col, dir: 'desc' }]) assert.deepEqual(nextSort(col, cur), cycleSort(col, cur, SHEET_COLUMNS))
    }
  })
})

describe('the lanes sort by every column', () => {
  it('no sort keeps the hub order', () => {
    assert.equal(ids(sortLanes(VIEW, { col: '', dir: '' })), 'c-10,c-9,a-277,m-039')
  })
  it('every column of the table sorts', () => {
    const want = {
      agent: ['a-277,c-9,c-10,m-039', 'm-039,c-10,c-9,a-277'],
      vendor: ['a-277,c-10,c-9,m-039', 'm-039,c-10,c-9,a-277'],
      state: ['c-10,c-9,a-277,m-039', 'm-039,c-10,c-9,a-277'],
      scope: ['c-9,c-10,m-039,a-277', 'a-277,m-039,c-10,c-9'],
      topic: ['a-277,c-10,c-9,m-039', 'c-10,a-277,c-9,m-039'],
      issues: ['a-277,c-10,c-9,m-039', 'c-10,a-277,c-9,m-039'],
      updated: ['a-277,c-9,m-039,c-10', 'c-10,m-039,c-9,a-277'],
      active: ['a-277,c-10,c-9,m-039', 'c-10,a-277,c-9,m-039'],
      workspace: ['c-9,c-10,a-277,m-039', 'c-10,a-277,m-039,c-9'],
    }
    assert.deepEqual(Object.keys(want), LANE_COLUMNS, 'a case per column')
    for (const col of LANE_COLUMNS) {
      assert.equal(ids(sortLanes(VIEW, { col, dir: 'asc' })), want[col][0], col + ' asc')
      assert.equal(ids(sortLanes(VIEW, { col, dir: 'desc' })), want[col][1], col + ' desc')
    }
  })
  it('names compare with numbers (c-9 before c-10) and an empty cell is last both ways', () => {
    assert.ok(ids(sortLanes(VIEW, { col: 'agent', dir: 'asc' })).indexOf('c-9') < ids(sortLanes(VIEW, { col: 'agent', dir: 'asc' })).indexOf('c-10'))
    assert.match(ids(sortLanes(VIEW, { col: 'active', dir: 'desc' })), /c-9,m-039$/)
  })
  it('sorting does not touch the input', () => {
    const copy = VIEW.slice()
    sortLanes(VIEW, { col: 'agent', dir: 'asc' })
    assert.deepEqual(VIEW, copy)
  })
})

describe('the lanes filter by box, vendor, state, age and text', () => {
  it('no filter keeps every lane, and says it is not filtered', () => {
    assert.equal(ids(filterLanes(VIEW, LANES_NO_FILTER)), 'c-10,c-9,a-277,m-039')
    assert.equal(lanesFiltered(LANES_NO_FILTER), false)
    assert.equal(lanesFiltered({ ...LANES_NO_FILTER, text: '   ' }), false)
  })
  it('box, vendor and state each keep their equal lanes', () => {
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, box: 'box-a' })), 'c-9,a-277')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, vendor: 'claude' })), 'c-10,c-9')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, state: 'queued' })), 'm-039')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, state: 'live' })), 'c-10,c-9,a-277')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, box: 'box-a', vendor: 'agy' })), 'a-277', 'the filters combine')
  })
  it('age: within 1 h, within 24 h, over 24 h', () => {
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, age: '1h' })), 'c-10,m-039')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, age: '24h' })), 'c-10,c-9,m-039')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, age: 'older' })), 'a-277')
  })
  it('text: every word, any case, in the agent, scope, discussion, issue keys or workspace', () => {
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, text: 'SPL-3' })), 'a-277')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, text: 'alpha' })), 'a-277')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, text: 'ACME' })), 'c-9')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, text: 'c-10@box-b' })), 'c-10')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, text: 'ops sort' })), 'c-10')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, text: 'nothing-matches' })), '')
    assert.equal(lanesFiltered({ ...LANES_NO_FILTER, text: 'x' }), true)
  })
  it('the selects offer the answer\'s distinct values; a lane with no state is live', () => {
    assert.deepEqual(laneFilterChoices(VIEW), { box: ['box-a', 'box-b'], vendor: ['agy', 'claude', 'mistral'], state: ['live', 'queued'] })
    assert.equal(laneState({}), 'live')
    assert.equal(VIEW[0].state, 'live')
    assert.equal(VIEW[3].state, 'queued')
  })
})

describe('one control, not a copy', () => {
  const button = read('src/components/SheetSortButton.vue')
  const issues = read('src/pages/issues.vue')
  const lanes = read('src/pages/monitoring/lanes/index.vue')
  it('both sheets render SheetSortButton and neither carries its own sort button', () => {
    assert.match(button, /class="issues-sort-h"/)
    for (const [name, page] of [['issues', issues], ['lanes', lanes]]) {
      assert.match(page, /<SheetSortButton\b/, name)
      assert.doesNotMatch(page, /class="issues-sort-h"|class="issues-sort-mark"/, name)
    }
  })
  it('the lanes page sorts through the shared cycle and binds aria-sort on each name', () => {
    assert.match(lanes, /cycleSort\(col, sort\.value, LANE_COLUMNS\)/)
    assert.match(lanes, /:aria-sort=/)
    for (const f of ['box', 'vendor', 'state', 'age', 'text']) assert.match(lanes, new RegExp(`data-test="lanes-filter-${f}"`), f)
  })
})
