// SPL-3887 (owner HUM-10, t1 31f6f470, msgs 1eedefed and 08b25696): the
// Lanes listing sorts by every column and filters by box, vendor, state, age
// and text with the Issues sheet's controls: one header button
// (components/SheetSortButton.vue) and one sort cycle (utils/sheet-sort.mjs),
// never a second copy.
// SPL-5276 (owner HUM-10, t1 e1e97af9, msg 7ccb6bfa: "Sorting and filtering
// in lanes should behave exactly as sorting and filtering for the event
// log"): the sheet is now the Event log's column sheet (utils/column-sheet.mjs,
// components/SheetHead.vue + SheetPhoneBar.vue): one filter per column.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cycleSort } from '../../src/utils/sheet-sort.mjs'
import { nextSort, SHEET_COLUMNS } from '../../src/utils/issues-view.mjs'
import {
  LANE_COLUMNS,
  LANE_SHEET_COLUMNS,
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
    issues: [{ key: 'SPL-20', status: 'wip', priority: 3 }], priority: 3, origin_issue: { key: 'SPL-20', status: 'wip' }, updated_at: '2026-10-27T11:58:00Z', age_s: 120, last_active: '2026-10-27T11:59:00Z', workspace: 'w1', workspace_name: 'Ops' },
  { agent_id: 'c-9', agent_box: 'box-a', vendor: 'claude', scope: 'Disk sweep', topic_id: '', topic_title: '',
    issues: [], updated_at: '2026-10-27T09:00:00Z', age_s: 10800, last_active: '', workspace: 'w2', workspace_name: 'Acme' },
  { agent_id: 'a-277', agent_box: 'box-a', vendor: 'agy', scope: 'Review the locale text', topic_id: 'x', topic_title: 'Alpha topic',
    issues: [{ key: 'SPL-3', status: '', priority: 1 }], priority: 1, origin_issue: { key: 'OPS-7', status: '' }, updated_at: '2026-10-25T12:00:00Z', age_s: 172800, last_active: '2026-10-26T12:00:00Z', workspace: 'w1', workspace_name: 'Ops' },
  { agent_id: 'm-039', agent_box: 'box-b', vendor: 'mistral', scope: 'Queued summary', state: 'queued',
    issues: [], updated_at: '2026-10-27T11:30:00Z', age_s: 1800, last_active: '', workspace: 'w1', workspace_name: 'Ops' },
] }).lanes

describe('one sort cycle for both sheets', () => {
  it('none -> asc -> desc -> none; an unknown column is the default', () => {
    let s = { col: '', dir: '' }
    s = cycleSort('vendor', s, LANE_COLUMNS); assert.deepEqual(s, { col: 'vendor', dir: 'asc' })
    s = cycleSort('vendor', s, LANE_COLUMNS); assert.deepEqual(s, { col: 'vendor', dir: 'desc' })
    s = cycleSort('vendor', s, LANE_COLUMNS); assert.deepEqual(s, { col: '', dir: '' })
    assert.deepEqual(cycleSort('nope', { col: 'vendor', dir: 'asc' }, LANE_COLUMNS), { col: '', dir: '' })
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
      box: ['c-9,a-277,c-10,m-039', 'c-10,m-039,c-9,a-277'],
      priority: ['a-277,c-10,c-9,m-039', 'c-10,a-277,c-9,m-039'],
      vendor: ['a-277,c-10,c-9,m-039', 'm-039,c-10,c-9,a-277'],
      state: ['c-10,c-9,a-277,m-039', 'm-039,c-10,c-9,a-277'],
      scope: ['c-9,c-10,m-039,a-277', 'a-277,m-039,c-10,c-9'],
      topic: ['a-277,c-10,c-9,m-039', 'c-10,a-277,c-9,m-039'],
      issues: ['a-277,c-10,c-9,m-039', 'c-10,a-277,c-9,m-039'],
      origin: ['a-277,c-10,c-9,m-039', 'c-10,a-277,c-9,m-039'],
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

const AS_OF = '2026-10-27T12:00:00Z'
const only = (f) => ids(filterLanes(VIEW, { ...LANES_NO_FILTER, ...f }, AS_OF))

describe('the lanes filter one column at a time, as the Event log', () => {
  it('no filter keeps every lane, and says it is not filtered', () => {
    assert.equal(only({}), 'c-10,c-9,a-277,m-039')
    assert.equal(lanesFiltered(LANES_NO_FILTER), false)
    assert.equal(lanesFiltered({ ...LANES_NO_FILTER, scope: '   ' }), false)
  })
  it('box, prio, vendor, state and workspace each keep their equal lanes', () => {
    assert.equal(only({ box: 'box-a' }), 'c-9,a-277')
    assert.equal(only({ priority: '1' }), 'a-277')
    assert.equal(only({ vendor: 'claude' }), 'c-10,c-9')
    assert.equal(only({ state: 'queued' }), 'm-039')
    assert.equal(only({ state: 'live' }), 'c-10,c-9,a-277')
    assert.equal(only({ box: 'box-a', vendor: 'agy' }), 'a-277', 'the filters combine')
    assert.equal(only({ vendor: 'clau' }), '', 'a choice is equal, never a part')
  })
  it('Updated picks the write\'s age: within 1 h, within 24 h, over 24 h', () => {
    assert.equal(only({ updated: '1h' }), 'c-10,m-039')
    assert.equal(only({ updated: '24h' }), 'c-10,c-9,m-039')
    assert.equal(only({ updated: 'older' }), 'a-277')
  })
  it('Last active picks the last token minute\'s age against as_of; a lane with none matches no age', () => {
    assert.equal(only({ active: '1h' }), 'c-10')
    assert.equal(only({ active: '24h' }), 'c-10')
    assert.equal(only({ active: 'older' }), 'a-277')
  })
  it('a text column keeps the lanes whose cell holds the text, any case', () => {
    assert.equal(only({ agent: 'C-10@BOX' }), 'c-10')
    assert.equal(only({ agent: 'box-a' }), 'c-9,a-277')
    assert.equal(only({ scope: 'sweep' }), 'c-9')
    assert.equal(only({ topic: 'alpha' }), 'a-277')
    assert.equal(only({ topic: 'x' }), 'a-277', 'the topic id too')
    assert.equal(only({ issues: 'spl-2' }), 'c-10')
    assert.equal(only({ origin: 'ops-7' }), 'a-277')
    assert.equal(only({ scope: 'nothing-matches' }), '')
    assert.equal(only({ scope: 'locale', agent: 'c-' }), '', 'text filters combine too')
    assert.equal(lanesFiltered({ ...LANES_NO_FILTER, agent: 'x' }), true)
  })
  it('a filter on one column never searches another (the old four-column box is gone)', () => {
    assert.equal(only({ scope: 'Ops' }), '', 'the workspace name is not in the scope')
    assert.equal('text' in LANES_NO_FILTER, false)
    assert.deepEqual(Object.keys(LANES_NO_FILTER), LANE_COLUMNS)
  })
  it('the selects offer the answer\'s distinct values; a lane with no state is live', () => {
    assert.deepEqual(laneFilterChoices(VIEW), { box: ['box-a', 'box-b'], priority: ['1', '3'], vendor: ['agy', 'claude', 'mistral'], state: ['live', 'queued'],
      workspace: [{ id: 'w2', name: 'Acme' }, { id: 'w1', name: 'Ops' }] })
    assert.equal(laneState({}), 'live')
    assert.equal(VIEW[0].state, 'live')
    assert.equal(VIEW[3].state, 'queued')
  })
  it('every column is a text or a choice, as the Event log\'s', () => {
    assert.deepEqual(LANE_SHEET_COLUMNS.map((c) => c.col + ':' + c.kind), ['agent:text', 'box:choice', 'priority:choice', 'vendor:choice', 'state:choice',
      'scope:text', 'topic:text', 'issues:text', 'origin:text', 'updated:choice', 'active:choice', 'workspace:choice'])
  })
})

describe('one control, not a copy', () => {
  const button = read('src/components/SheetSortButton.vue')
  const issues = read('src/pages/issues.vue')
  const lanes = read('src/pages/monitoring/lanes/index.vue')
  const events = read('src/pages/monitoring/events/index.vue')
  it('the Issues sheet renders SheetSortButton; Lanes and the Event log render the one SheetHead and SheetPhoneBar', () => {
    assert.match(button, /class="issues-sort-h"/)
    assert.match(issues, /<SheetSortButton\b/)
    for (const [name, page, prefix] of [['lanes', lanes, 'lanes'], ['events', events, 'events']]) {
      assert.match(page, new RegExp(`<SheetHead [^>]*prefix="${prefix}"`), name)
      assert.match(page, new RegExp(`<SheetPhoneBar[\\s\\S]*?prefix="${prefix}"`), name)
      assert.doesNotMatch(page, /<thead|<SheetSortButton\b|class="issues-sort-h"|sort-mark|events-sheet|events-mbar/, name + ' carries no own head, sort button or sheet')
    }
  })
  it('the lanes page sorts through the shared cycle over its columns', () => {
    assert.match(lanes, /nextSheetSort\(col, sort\.value, LANE_SHEET_COLUMNS\)/)
    assert.match(lanes, /filterLanes\(view\.value\.lanes, filters, view\.value\.asOf\)/)
  })
})

/* SPL-4458 (owner HUM-10, t1 0acd4eaa, msg 97453531): "the lanes should get
   also a box attribute on the listing - aka on which box the lane is
   working". The box is its own sortable column, right after the agent. */
describe('the Box column', () => {
  const lanes = read('src/pages/monitoring/lanes/index.vue')
  it('is the second column of the sheet', () => {
    assert.deepEqual(LANE_COLUMNS.slice(0, 2), ['agent', 'box'])
  })
  it('a lane with no box sorts last both ways, ties keep the hub order', () => {
    const noBox = fleetLanesOf({ as_of: '2026-10-27T12:00:00Z', fleet: 'main', lanes: [
      { agent_id: 'c-1', agent_box: '', vendor: 'claude', updated_at: '2026-10-27T11:00:00Z' },
      { agent_id: 'c-2', agent_box: 'box-b', vendor: 'claude', updated_at: '2026-10-27T11:00:00Z' },
      { agent_id: 'c-3', vendor: 'claude', updated_at: '2026-10-27T11:00:00Z' },
      { agent_id: 'c-4', agent_box: 'box-a', vendor: 'claude', updated_at: '2026-10-27T11:00:00Z' },
    ] }).lanes
    assert.equal(noBox[0].box, '')
    assert.equal(noBox[2].box, '')
    assert.equal(ids(sortLanes(noBox, { col: 'box', dir: 'asc' })), 'c-4,c-2,c-1,c-3')
    assert.equal(ids(sortLanes(noBox, { col: 'box', dir: 'desc' })), 'c-2,c-4,c-1,c-3')
  })
  it('each row renders the box the hub sent, a dash when none', () => {
    assert.match(lanes, /<td class="ln-box" data-test="lanes-box">\{\{ l\.box \|\| DASH \}\}<\/td>/)
    assert.deepEqual(LANE_SHEET_COLUMNS[1], { col: 'box', key: 'monitoring.lanes.col_box', kind: 'choice' })
  })
  it('the header word is in all 19 locales', () => {
    for (const loc of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const word = JSON.parse(read('i18n/locales/' + loc + '.json')).monitoring?.lanes?.col_box
      assert.equal(typeof word, 'string', loc)
      assert.ok(word.length > 0 && word.length <= 12, loc + ': ' + word)
    }
  })
})

/* SPL-4705, spec 153 3.13 C60 (owner HUM-10, t1 0ea86216, poll 33a36dde,
   msg c50a260f: "C — I want to filter the list by workspace"): a select
   under the Workspace column, which stays last (msg 67c63b8d). It offers
   the workspaces in the answer by name and matches on the row's id. */
describe('the Workspace filter', () => {
  const lanes = read('src/pages/monitoring/lanes/index.vue')
  it('keeps the lanes of one workspace, matched on its id', () => {
    assert.equal(LANES_NO_FILTER.workspace, '')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, workspace: 'w1' })), 'c-10,a-277,m-039')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, workspace: 'w2' })), 'c-9')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, workspace: 'Ops' })), '', 'a name is no id')
    assert.equal(ids(filterLanes(VIEW, { ...LANES_NO_FILTER, workspace: 'w1', vendor: 'claude' })), 'c-10', 'it combines')
    assert.equal(lanesFiltered({ ...LANES_NO_FILTER, workspace: 'w2' }), true)
  })
  it('offers each workspace once, by name (the id when it has none), sorted by name', () => {
    const v = fleetLanesOf({ lanes: [
      { agent_id: 'c-1', workspace: 'w9', workspace_name: 'zeta' }, { agent_id: 'c-2', workspace: 'w3' },
      { agent_id: 'c-3', workspace: 'w9', workspace_name: 'zeta' }, { agent_id: 'c-4', workspace: '' },
      { agent_id: 'c-5', workspace: 'w4', workspace_name: 'Alpha' }] }).lanes
    assert.deepEqual(laneFilterChoices(v).workspace, [{ id: 'w4', name: 'Alpha' }, { id: 'w3', name: 'w3' }, { id: 'w9', name: 'zeta' }])
  })
  it('the Workspace column is still last, a choice offered by name and matched on the id', () => {
    assert.equal(LANE_COLUMNS[LANE_COLUMNS.length - 1], 'workspace')
    assert.match(lanes, /col === 'workspace'\) return choices\.value\.workspace\.map\(\(w\) => \(\{ value: w\.id, label: w\.name \}\)\)/)
  })
})

/* SPL-4727, spec 153 3.14 C63 (owner HUM-10, t1 0d0bc34c, msgs 136f2e49
   and c78812f2: "the lanes must have their prio attributes in the lanes
   hilisting and it should be possible to sort them by prio", "the prio
   shoud be the 3rd attribute"). The hub sends the lane's prio, the highest
   among its issues; the sheet shows it 3rd and sorts by it, 1 first. */
describe('the Prio column', () => {
  const lanes = read('src/pages/monitoring/lanes/index.vue')
  it('is the 3rd column of the sheet', () => {
    assert.deepEqual(LANE_COLUMNS.slice(0, 3), ['agent', 'box', 'priority'])
  })
  it('keeps the hub\'s prio of the lane and of each issue; junk is none', () => {
    const v = fleetLanesOf({ lanes: [
      { agent_id: 'c-1', priority: 2, issues: [{ key: 'SPL-1', status: 'wip', priority: 2 }, { key: 'SPL-2', status: 'eval', priority: 4 }] },
      { agent_id: 'c-2' }, { agent_id: 'c-3', priority: 9 }, { agent_id: 'c-4', priority: '1' }, { agent_id: 'c-5', priority: -1 }] }).lanes
    assert.deepEqual(v.map((l) => l.priority), [2, 0, 0, 1, 0])
    assert.deepEqual(v[0].issues.map((i) => i.priority), [2, 4])
  })
  it('sorts prio 1 first; a lane with no prio is last both ways, ties keep the hub order', () => {
    const v = fleetLanesOf({ lanes: [{ agent_id: 'c-1', priority: 3 }, { agent_id: 'c-2' }, { agent_id: 'c-3', priority: 1 },
      { agent_id: 'c-4', priority: 3 }, { agent_id: 'c-5' }] }).lanes
    assert.equal(ids(sortLanes(v, { col: 'priority', dir: 'asc' })), 'c-3,c-1,c-4,c-2,c-5')
    assert.equal(ids(sortLanes(v, { col: 'priority', dir: 'desc' })), 'c-1,c-4,c-3,c-2,c-5')
    assert.equal(ids(sortLanes(v, { col: '', dir: '' })), 'c-1,c-2,c-3,c-4,c-5', 'the default order is unchanged')
  })
  it('the page renders the prio as the 3rd cell, a dash for none, under the Issues sheet\'s word', () => {
    const row = lanes.slice(lanes.indexOf('data-test="lanes-row"'))
    assert.match(row, /data-test="lanes-agent"[^\n]*\n\s*<td class="ln-box"[^\n]*\n\s*<td class="num" data-test="lanes-priority"/)
    assert.deepEqual(LANE_SHEET_COLUMNS[2], { col: 'priority', key: 'issues.field_priority', kind: 'choice', words: 'num' })
  })
})
