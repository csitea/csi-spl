// SPL-4729 (spec 153 3.15; owner HUM-10, t1 0a730c21, msg ea87c5c1: "the full
// state of the lanes listing must be shareable via a link"): the Lanes list's
// sort and filters to its URL and back. A default writes no parameter, a bad
// value reads as not named, other parameters (?lane=) pass through, and a
// value the answer does not offer (a member's link with a box) is set back to All.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { LANES_NO_FILTER, LANE_COLUMNS, fleetLanesOf, laneFilterChoices } from '../../src/utils/monitoring-lanes.mjs'
import { LANES_URL_PARAMS, lanesFiltersOffered, lanesStateFromQuery, lanesStateQuery, plainQuery, sameLanesQuery } from '../../src/utils/monitoring-lanes-url.mjs'

const FULL = { sort: 'agent', dir: 'desc', box: 'box-b', vendor: 'agy', state: 'live', age: '1h', workspace: 'w2', text: 'spl 3216' }

describe('lanes URL: the query as the list state', () => {
  it('reads every parameter', () => {
    const s = lanesStateFromQuery(FULL)
    assert.deepEqual(s.sort, { col: 'agent', dir: 'desc' })
    assert.deepEqual(s.filters, { text: 'spl 3216', box: 'box-b', vendor: 'agy', state: 'live', age: '1h', workspace: 'w2' })
  })
  it('round-trips: the state written back is the same query', () => {
    assert.ok(sameLanesQuery(lanesStateQuery(lanesStateFromQuery(FULL)), FULL))
  })
  it('a default writes no parameter, other parameters pass through', () => {
    assert.deepEqual(lanesStateQuery({ sort: { col: '', dir: '' }, filters: { ...LANES_NO_FILTER } }, { lane: 'c-085@box-a', ...FULL }), { lane: 'c-085@box-a' })
  })
  it('the text keeps its spaces as typed, a blank text writes none', () => {
    assert.equal(lanesStateQuery({ sort: { col: '', dir: '' }, filters: { ...LANES_NO_FILTER, text: 'spl ' } }).text, 'spl ')
    assert.equal(lanesStateQuery({ sort: { col: '', dir: '' }, filters: { ...LANES_NO_FILTER, text: '   ' } }).text, undefined)
  })
  it('bad values read as not named, never an error', () => {
    const s = lanesStateFromQuery({ sort: 'nope', dir: 'asc', age: '2h', box: '<script>', vendor: ['claude', 'agy'], state: '', text: 'x'.repeat(201), workspace: 42 })
    assert.deepEqual(s.sort, { col: '', dir: '' })
    assert.deepEqual(s.filters, { ...LANES_NO_FILTER, vendor: 'claude' })
    assert.deepEqual(lanesStateFromQuery({ sort: 'agent', dir: 'up' }).sort, { col: '', dir: '' })
    assert.deepEqual(lanesStateFromQuery(undefined).filters, { ...LANES_NO_FILTER })
  })
  it('every sortable column is a valid sort', () => {
    for (const col of LANE_COLUMNS) assert.deepEqual(lanesStateFromQuery({ sort: col, dir: 'asc' }).sort, { col, dir: 'asc' })
  })
  it('owns exactly the sort and every filter of the row', () => {
    assert.deepEqual([...LANES_URL_PARAMS].sort(), ['dir', 'sort', ...Object.keys(LANES_NO_FILTER)].sort())
  })
  it('plainQuery takes the first of a repeated key and drops non-strings', () => {
    assert.deepEqual(plainQuery({ a: ['1', '2'], b: '3', c: null }), { a: '1', b: '3' })
  })
})

describe('lanes URL: values the answer does not offer', () => {
  const lanes = (box) => fleetLanesOf({ lanes: [
    { agent_id: 'c-085', agent_box: box, vendor: 'claude', state: 'live', workspace: 'mock', workspace_name: 'Mock workspace' },
  ] }).lanes
  const f = { ...LANES_NO_FILTER, box: 'box-a', vendor: 'claude', state: 'live', workspace: 'mock', text: 'c-085' }
  it('the fleet route offers the box: every value kept', () => {
    assert.deepEqual(lanesFiltersOffered(f, laneFilterChoices(lanes('box-a'))), f)
  })
  it('the workspace route sends no box: the box is set back to All, the rest kept', () => {
    assert.deepEqual(lanesFiltersOffered(f, laneFilterChoices(lanes(''))), { ...f, box: '' })
  })
  it('a vendor, state or workspace the answer lacks is set back to All', () => {
    const got = lanesFiltersOffered({ ...f, vendor: 'grok', state: 'queued', workspace: 'w9' }, laneFilterChoices(lanes('box-a')))
    assert.deepEqual(got, { ...f, vendor: '', state: '', workspace: '' })
  })
})
