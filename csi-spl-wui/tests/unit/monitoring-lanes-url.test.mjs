// SPL-4729 (spec 153 3.15; owner HUM-10, t1 0a730c21, msg ea87c5c1: "the full
// state of the lanes listing must be shareable via a link"): the Lanes list's
// sort and filters to its URL and back. A default writes no parameter, a bad
// value reads as not named, other parameters (?lane=) pass through, and a
// value the answer does not offer (a member's link with a box) is set back to All.
// SPL-5276: one filter per column, as the Event log's, each its own
// parameter named as its column; an old link's `age` reads as Updated's, its
// `text` (the four-column box, gone) is dropped and not written back.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { LANES_NO_FILTER, LANE_COLUMNS, fleetLanesOf, laneFilterChoices } from '../../src/utils/monitoring-lanes.mjs'
import { LANES_URL_PARAMS, lanesFiltersOffered, lanesStateFromQuery, lanesStateQuery, plainQuery, sameLanesQuery } from '../../src/utils/monitoring-lanes-url.mjs'

const FULL = { sort: 'agent', dir: 'desc', agent: 'c-0', box: 'box-b', priority: '2', vendor: 'agy', state: 'live', scope: 'disk sweep',
  topic: 'alpha', issues: 'SPL-3', origin: 'OPS', updated: '1h', active: 'older', workspace: 'w2' }

describe('lanes URL: the query as the list state', () => {
  it('reads every parameter', () => {
    const s = lanesStateFromQuery(FULL)
    assert.deepEqual(s.sort, { col: 'agent', dir: 'desc' })
    assert.deepEqual(s.filters, { agent: 'c-0', box: 'box-b', priority: '2', vendor: 'agy', state: 'live', scope: 'disk sweep',
      topic: 'alpha', issues: 'SPL-3', origin: 'OPS', updated: '1h', active: 'older', workspace: 'w2' })
  })
  it('an old link: `age` is Updated\'s age, `text` is dropped, neither is written back', () => {
    const s = lanesStateFromQuery({ age: '24h', text: 'spl', vendor: 'agy' })
    assert.deepEqual(s.filters, { ...LANES_NO_FILTER, updated: '24h', vendor: 'agy' })
    assert.deepEqual(lanesStateQuery(s, { lane: 'c-1', age: '24h', text: 'spl', vendor: 'agy' }), { lane: 'c-1', updated: '24h', vendor: 'agy' })
    assert.equal(lanesStateFromQuery({ age: '1h', updated: 'older' }).filters.updated, 'older', 'the new name wins')
  })
  it('round-trips: the state written back is the same query', () => {
    assert.ok(sameLanesQuery(lanesStateQuery(lanesStateFromQuery(FULL)), FULL))
  })
  it('a default writes no parameter, other parameters pass through', () => {
    assert.deepEqual(lanesStateQuery({ sort: { col: '', dir: '' }, filters: { ...LANES_NO_FILTER } }, { lane: 'c-085@box-a', ...FULL }), { lane: 'c-085@box-a' })
  })
  it('a text filter keeps its spaces as typed, a blank one writes none', () => {
    assert.equal(lanesStateQuery({ sort: { col: '', dir: '' }, filters: { ...LANES_NO_FILTER, scope: 'spl ' } }).scope, 'spl ')
    assert.equal(lanesStateQuery({ sort: { col: '', dir: '' }, filters: { ...LANES_NO_FILTER, scope: '   ' } }).scope, undefined)
    assert.equal(lanesStateFromQuery({ topic: 'two words ' }).filters.topic, 'two words ')
  })
  it('bad values read as not named, never an error', () => {
    const s = lanesStateFromQuery({ sort: 'nope', dir: 'asc', updated: '2h', active: 'x', box: '<script>', vendor: ['claude', 'agy'], state: '', scope: 'x'.repeat(201), workspace: 42 })
    assert.deepEqual(s.sort, { col: '', dir: '' })
    assert.deepEqual(s.filters, { ...LANES_NO_FILTER, vendor: 'claude' })
    assert.deepEqual(lanesStateFromQuery({ sort: 'agent', dir: 'up' }).sort, { col: '', dir: '' })
    assert.deepEqual(lanesStateFromQuery(undefined).filters, { ...LANES_NO_FILTER })
  })
  it('every sortable column is a valid sort', () => {
    for (const col of LANE_COLUMNS) assert.deepEqual(lanesStateFromQuery({ sort: col, dir: 'asc' }).sort, { col, dir: 'asc' })
  })
  it('owns exactly the sort and every filter of the row', () => {
    assert.deepEqual([...LANES_URL_PARAMS].sort(), ['age', 'dir', 'sort', 'text', ...Object.keys(LANES_NO_FILTER)].sort())
    assert.deepEqual(Object.keys(LANES_NO_FILTER), LANE_COLUMNS, 'one filter per column')
  })
  it('plainQuery takes the first of a repeated key and drops non-strings', () => {
    assert.deepEqual(plainQuery({ a: ['1', '2'], b: '3', c: null }), { a: '1', b: '3' })
  })
})

describe('lanes URL: values the answer does not offer', () => {
  const lanes = (box) => fleetLanesOf({ lanes: [
    { agent_id: 'c-085', agent_box: box, vendor: 'claude', state: 'live', workspace: 'mock', workspace_name: 'Mock workspace' },
  ] }).lanes
  const f = { ...LANES_NO_FILTER, box: 'box-a', vendor: 'claude', state: 'live', workspace: 'mock', agent: 'c-085' }
  it('the fleet route offers the box: every value kept', () => {
    assert.deepEqual(lanesFiltersOffered(f, laneFilterChoices(lanes('box-a'))), f)
  })
  it('the workspace route sends no box: the box is set back to All, the rest kept', () => {
    assert.deepEqual(lanesFiltersOffered(f, laneFilterChoices(lanes(''))), { ...f, box: '' })
  })
  it('a prio, vendor, state or workspace the answer lacks is set back to All', () => {
    const got = lanesFiltersOffered({ ...f, priority: '1', vendor: 'grok', state: 'queued', workspace: 'w9' }, laneFilterChoices(lanes('box-a')))
    assert.deepEqual(got, { ...f, priority: '', vendor: '', state: '', workspace: '' })
  })
})
