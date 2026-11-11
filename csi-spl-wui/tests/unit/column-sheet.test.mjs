// SPL-5276 (owner HUM-10, t1 e1e97af9, msg 7ccb6bfa: "Sorting and filtering
// in lanes should behave exactly as sorting and filtering for the event
// log"): the one column sheet both tables use (utils/column-sheet.mjs).
// The cases run the same clicks and filters through the Event log
// (utils/event-sheet.mjs) and Lanes (utils/monitoring-lanes.mjs) and expect
// the same answers, so the two cannot drift apart.
// Control: on origin/master 9cda5fdae the file is missing (import fails), and
// Lanes' filterLanes took one text box over four columns, so the
// "same filter rule" cases fail there.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  emptySheetFilters,
  emptySheetSort,
  nextSheetSort,
  sheetAriaSort,
  sheetFiltersActive,
  sheetPresentValues,
  sheetRowMatches,
  sheetSortDirKey,
  sheetSortLabel,
  sheetSortMark,
  sheetTextHas,
} from '../../src/utils/column-sheet.mjs'
import { EVENT_COLUMNS, applyEventSheet, emptyEventFilters, eventSortLabel, filtersActive, nextEventSort } from '../../src/utils/event-sheet.mjs'
import { LANE_SHEET_COLUMNS, LANES_DEFAULT_SORT, LANES_NO_FILTER, filterLanes, fleetLanesOf, lanesFiltered } from '../../src/utils/monitoring-lanes.mjs'

const COLS = [
  { col: 'name', key: 'k.name', kind: 'text' },
  { col: 'kind', key: 'k.kind', kind: 'choice' },
  { col: 'at', key: 'k.at', kind: 'text', words: 'date' },
  { col: 'n', key: 'k.n', kind: 'choice', words: 'num' },
]

describe('the sort: a header click', () => {
  it('cycles none -> asc -> desc -> none; a new column starts asc; an unknown column is none', () => {
    let s = emptySheetSort()
    s = nextSheetSort('name', s, COLS); assert.deepEqual(s, { col: 'name', dir: 'asc' })
    s = nextSheetSort('name', s, COLS); assert.deepEqual(s, { col: 'name', dir: 'desc' })
    s = nextSheetSort('name', s, COLS); assert.deepEqual(s, { col: '', dir: '' })
    assert.deepEqual(nextSheetSort('kind', { col: 'name', dir: 'desc' }, COLS), { col: 'kind', dir: 'asc' })
    assert.deepEqual(nextSheetSort('nope', { col: 'name', dir: 'asc' }, COLS), { col: '', dir: '' })
    assert.deepEqual(nextSheetSort('name', undefined, COLS), { col: 'name', dir: 'asc' })
  })
  it('only the sorted column shows its mark and its aria-sort', () => {
    const s = { col: 'name', dir: 'asc' }
    assert.equal(sheetSortMark(s, 'name'), '▲')
    assert.equal(sheetSortMark({ col: 'name', dir: 'desc' }, 'name'), '▼')
    assert.equal(sheetSortMark(s, 'kind'), '')
    assert.equal(sheetAriaSort(s, 'name'), 'ascending')
    assert.equal(sheetAriaSort({ col: 'name', dir: 'desc' }, 'name'), 'descending')
    assert.equal(sheetAriaSort(s, 'kind'), 'none')
    assert.equal(sheetAriaSort(emptySheetSort(), 'name'), 'none')
  })
  it('the phone bar\'s words: the column\'s, its kind of direction, the list\'s own order for none', () => {
    const fb = { colKey: 'k.at', dirKey: 'issues_mobile.dir_date_desc' }
    assert.deepEqual(sheetSortLabel(emptySheetSort(), COLS, fb), { ...fb, active: false })
    assert.deepEqual(sheetSortLabel({ col: 'at', dir: 'asc' }, COLS, fb), { colKey: 'k.at', dirKey: 'issues_mobile.dir_date_asc', active: true })
    assert.deepEqual(sheetSortLabel({ col: 'n', dir: 'desc' }, COLS, fb), { colKey: 'k.n', dirKey: 'issues_mobile.dir_num_desc', active: true })
    assert.deepEqual(sheetSortLabel({ col: 'name', dir: 'desc' }, COLS, fb), { colKey: 'k.name', dirKey: 'issues_mobile.dir_text_desc', active: true })
    assert.equal(sheetSortDirKey('asc', 'nope'), 'issues_mobile.dir_text_asc')
  })
})

describe('the filter: one per column', () => {
  const rows = [
    { name: 'Alpha one', kind: 'a', at: '2026-11-11T07:00:00Z', n: '1' },
    { name: 'beta two', kind: 'b', at: '2026-11-10T07:00:00Z', n: '2' },
    { name: 'Gamma', kind: 'a', at: '', n: '' },
  ]
  const cells = { textOf: (r, c) => r[c], choiceOf: (r, c) => r[c] }
  const keep = (f) => rows.filter((r) => sheetRowMatches(r, { ...emptySheetFilters(COLS), ...f }, COLS, cells)).map((r) => r.name)
  it('empty filters, one key per column; active once any holds more than spaces', () => {
    assert.deepEqual(emptySheetFilters(COLS), { name: '', kind: '', at: '', n: '' })
    assert.equal(sheetFiltersActive(emptySheetFilters(COLS), COLS), false)
    assert.equal(sheetFiltersActive({ name: '  ' }, COLS), false)
    assert.equal(sheetFiltersActive({ kind: 'a' }, COLS), true)
    assert.equal(sheetFiltersActive(null, COLS), false)
  })
  it('a text column holds the text, any case, spaces around it ignored', () => {
    assert.deepEqual(keep({ name: 'ALPHA' }), ['Alpha one'])
    assert.deepEqual(keep({ name: ' two ' }), ['beta two'])
    assert.deepEqual(keep({ at: '2026-11-1' }), ['Alpha one', 'beta two'])
    assert.equal(sheetTextHas(null, 'x'), false)
  })
  it('a choice column equals the value picked, never a part of it; filters combine', () => {
    assert.deepEqual(keep({ kind: 'a' }), ['Alpha one', 'Gamma'])
    assert.deepEqual(keep({ n: '1' }), ['Alpha one'])
    assert.deepEqual(keep({ kind: 'a', name: 'gam' }), ['Gamma'])
    assert.deepEqual(keep({ kind: 'A' }), [], 'a choice is exact')
  })
  it('a column the caller matches itself skips the shared rule', () => {
    const own = { ...cells, custom: (r, c, q) => (c === 'n' ? Number(r.n) >= Number(q) : undefined) }
    assert.deepEqual(rows.filter((r) => sheetRowMatches(r, { n: '2' }, COLS, own)).map((r) => r.name), ['beta two'])
  })
  it('a choice column offers the distinct non-blank values, sorted', () => {
    assert.deepEqual(sheetPresentValues(rows, (r) => r.kind), ['a', 'b'])
    assert.deepEqual(sheetPresentValues(rows, (r) => r.n, (a, b) => Number(b) - Number(a)), ['2', '1'])
    assert.deepEqual(sheetPresentValues(null, (r) => r), [])
  })
})

describe('the Event log and Lanes answer alike', () => {
  const both = [['events', EVENT_COLUMNS], ['lanes', LANE_SHEET_COLUMNS]]
  it('every header click cycles the same way on both', () => {
    for (const [name, cols] of both) {
      for (const c of cols) {
        let s = emptySheetSort()
        const seen = []
        for (let i = 0; i < 3; i++) { s = nextSheetSort(c.col, s, cols); seen.push(s.dir) }
        assert.deepEqual(seen, ['asc', 'desc', ''], name + ' ' + c.col)
      }
    }
    for (const c of EVENT_COLUMNS) assert.deepEqual(nextEventSort(c.col, { col: c.col, dir: 'asc' }), nextSheetSort(c.col, { col: c.col, dir: 'asc' }, EVENT_COLUMNS))
  })
  it('no sort reads as the list\'s own order, newest first, on both', () => {
    assert.deepEqual(eventSortLabel(emptySheetSort()), { colKey: 'events.col_when', dirKey: 'issues_mobile.dir_date_desc', active: false })
    assert.equal(sheetSortLabel(emptySheetSort(), LANE_SHEET_COLUMNS, LANES_DEFAULT_SORT).dirKey, 'issues_mobile.dir_date_desc')
  })
  it('one empty filter per column, and the same "is filtered" rule', () => {
    assert.deepEqual(emptyEventFilters(), emptySheetFilters(EVENT_COLUMNS))
    assert.deepEqual({ ...LANES_NO_FILTER }, emptySheetFilters(LANE_SHEET_COLUMNS))
    assert.equal(filtersActive({ ...emptyEventFilters(), message: '  ' }), false)
    assert.equal(lanesFiltered({ ...LANES_NO_FILTER, scope: '  ' }), false)
    assert.equal(filtersActive({ ...emptyEventFilters(), message: 'x' }), true)
    assert.equal(lanesFiltered({ ...LANES_NO_FILTER, scope: 'x' }), true)
  })
  it('the same filter rule: a text part any case, a choice exact', () => {
    const events = [
      { id: 2, at: '2026-11-11T07:00:00Z', error_id: 'e2', source: 'api', status: 500, message: 'Disk Sweep failed', route: '/a' },
      { id: 1, at: '2026-11-11T06:00:00Z', error_id: 'e1', source: 'ui', status: 0, message: 'other', route: '/b' },
    ]
    const lanes = fleetLanesOf({ as_of: '2026-11-11T08:00:00Z', lanes: [
      { agent_id: 'c-2', agent_box: 'api', vendor: 'claude', scope: 'Disk Sweep failed', updated_at: '2026-11-11T07:00:00Z', age_s: 3600 },
      { agent_id: 'c-1', agent_box: 'ui', vendor: 'agy', scope: 'other', updated_at: '2026-11-11T06:00:00Z', age_s: 7200 },
    ] }).lanes
    const ev = (f) => applyEventSheet(events, { filters: { ...emptyEventFilters(), ...f }, sort: emptySheetSort() }).map((r) => r.id).join(',')
    const ln = (f) => filterLanes(lanes, { ...LANES_NO_FILTER, ...f }).map((l) => l.agentId.slice(2)).join(',')
    assert.equal(ev({ message: 'disk sweep' }), '2'); assert.equal(ln({ scope: 'disk sweep' }), '2')
    assert.equal(ev({ message: 'SWEEP' }), '2'); assert.equal(ln({ scope: 'SWEEP' }), '2')
    assert.equal(ev({ message: 'zzz' }), ''); assert.equal(ln({ scope: 'zzz' }), '')
    assert.equal(ev({ source: 'api' }), '2'); assert.equal(ln({ box: 'api' }), '2')
    assert.equal(ev({ source: 'ap' }), ''); assert.equal(ln({ box: 'ap' }), '')
    assert.equal(ev({ source: 'ui', message: 'other' }), '1'); assert.equal(ln({ box: 'ui', scope: 'other' }), '1')
  })
})
