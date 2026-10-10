// CLE-77799: the Boxes section groups the roster by box. Owner (topic
// 1fc29f99): "people use boxes and agents use boxes" — a box's users are BOTH
// the humans and the agents — and "later on we will have more boxes than the
// current one box", so this is exercised with a fixture of FOUR boxes: two
// machine boxes with agents, a machine box that hosts both a human and an
// agent, and the browser box with humans only.
//
// Machines only (owner, t1 topic b3bf3d13: "It should show only machines"):
// the browser box is in the fixture so the tests prove it is left OUT.
//
// Run: node tests/unit/box-rows.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { boxRows, boxByID, boxTag, isBrowserBox, filterBoxes } from '../../src/utils/box-rows.mjs'
import { SEATS_AGENTS, SEATS_PEOPLE, seatsAnchorOf } from '../../src/utils/box-seats.mjs'

/* peopleRows() shape: one {id, box, online} per seat. Four boxes: box-desk (an
   agent AND a human), box-a (two agents), box-b (an offline agent), box-wui
   (the browser box, humans only). */
const PEOPLE = [
  { id: 'CLE-07', box: 'box-desk', label: 'CLE-07@box-desk', online: true },
  { id: 'HUM-9', box: 'box-desk', label: 'HUM-9@box-desk', online: true },
  { id: 'GRK-03', box: 'box-a', label: 'GRK-03@box-a', online: true },
  { id: 'AGY-02', box: 'box-a', label: 'AGY-02@box-a', online: false },
  { id: 'CLE-11', box: 'box-b', label: 'CLE-11@box-b', online: false },
  { id: 'HUM-1', box: 'box-wui', label: 'HUM-1@box-wui', online: true },
  { id: 'HUM-2', box: 'box-wui', label: 'HUM-2@box-wui', online: false },
]
const BOXES = {
  'box-desk': { online: true, last_hello_at: '2026-09-18T10:00:00Z' },
  'box-a': { online: true, last_hello_at: '2026-09-18T09:00:00Z' },
  'box-b': { online: false, last_hello_at: '2026-09-17T09:00:00Z' },
  // box-wui has no detail: it is the browser box, which the hub does not
  // announce as a box; its liveness comes from who is seated on it.
}

describe('boxTag / isBrowserBox', () => {
  it('drops the box- prefix for the tag, keeps a bare id', () => {
    assert.equal(boxTag('box-desk'), 'desk')
    assert.equal(boxTag('box-wui'), 'wui')
    assert.equal(boxTag('nea'), 'nea')
    assert.equal(boxTag(''), '')
  })
  it('only box-wui is the browser box', () => {
    assert.equal(isBrowserBox('box-wui'), true)
    assert.equal(isBrowserBox('box-desk'), false)
  })
})

describe('boxRows', () => {
  const rows = boxRows(PEOPLE, BOXES)
  it('one row per machine box (many boxes, not one)', () => {
    assert.equal(rows.length, 3)
    assert.deepEqual(rows.map((r) => r.id).sort(), ['box-a', 'box-b', 'box-desk'])
  })
  it('machines only: the browser box (box-wui) is not a row, a machine box still is', () => {
    assert.equal(rows.some((r) => r.id === 'box-wui'), false)
    assert.equal(rows.some((r) => r.browser), false)
    // control: a machine box with a human seated on it keeps that human
    assert.deepEqual(rows.find((r) => r.id === 'box-desk').people.map((p) => p.id), ['HUM-9'])
    // even when the detail names box-wui, it stays out
    const withWuiDetail = boxRows(PEOPLE, { ...BOXES, 'box-wui': { online: true, last_hello_at: '' } })
    assert.deepEqual(withWuiDetail.map((r) => r.id).sort(), ['box-a', 'box-b', 'box-desk'])
  })
  it('splits each box\'s seats into people AND agents, with the user count', () => {
    const desk = rows.find((r) => r.id === 'box-desk')
    assert.deepEqual(desk.people.map((p) => p.id), ['HUM-9'])
    assert.deepEqual(desk.agents.map((a) => a.id), ['CLE-07'])
    assert.equal(desk.userCount, 2)
  })
  it('online is the detail flag, or any seat online for a detail-less box', () => {
    assert.equal(rows.find((r) => r.id === 'box-a').online, true)
    assert.equal(rows.find((r) => r.id === 'box-b').online, false)
    // box-c has no detail; its agent is online, so the box reads online
    const c = boxRows([{ id: 'CLE-12', box: 'box-c', label: 'CLE-12@box-c', online: true }], {})
    assert.equal(c[0].online, true)
  })
  it('sorts online first, then by id', () => {
    // online: box-a, box-desk ; offline: box-b
    assert.deepEqual(rows.map((r) => r.id), ['box-a', 'box-desk', 'box-b'])
  })
  it('a box named only in the detail (no seat yet) still lists, with zero users', () => {
    const withEmpty = boxRows([], { 'box-nea': { online: true, last_hello_at: '' } })
    assert.equal(withEmpty.length, 1)
    assert.equal(withEmpty[0].userCount, 0)
    assert.equal(withEmpty[0].tag, 'nea')
  })
  it('tolerates no input', () => {
    assert.deepEqual(boxRows(null, null), [])
    assert.deepEqual(boxRows(undefined), [])
  })
})

describe('boxByID', () => {
  it('returns the matching row', () => {
    const b = boxByID('box-desk', PEOPLE, BOXES)
    assert.equal(b.userCount, 2)
    assert.equal(b.lastHello, '2026-09-18T10:00:00Z')
  })
  it('an unknown box is a bare empty row, not null', () => {
    const b = boxByID('box-ghost', PEOPLE, BOXES)
    assert.equal(b.id, 'box-ghost')
    assert.equal(b.tag, 'ghost')
    assert.equal(b.userCount, 0)
    assert.deepEqual(b.people, [])
    assert.deepEqual(b.agents, [])
  })
})

describe('filterBoxes', () => {
  const rows = boxRows(PEOPLE, BOXES)
  it('matches id or tag, case-insensitively; empty keeps all', () => {
    assert.equal(filterBoxes(rows, '').length, 3)
    assert.deepEqual(filterBoxes(rows, 'DESK').map((r) => r.id), ['box-desk'])
    // the browser box is not a row, so the filter cannot find it either
    assert.equal(filterBoxes(rows, 'wui').length, 0)
    // "box-" is in every id, so it keeps all
    assert.equal(filterBoxes(rows, 'box-').length, 3)
    assert.equal(filterBoxes(rows, 'zzz').length, 0)
  })
})

// HUM-10 (t1 58857a17): "N people · M agents", each count a link to its own
// list on /boxes/<id>; the hash names which list opens.
describe('seatsAnchorOf', () => {
  it('opens the people or the agents list, nothing else', () => {
    assert.equal(seatsAnchorOf('#box-people'), SEATS_PEOPLE)
    assert.equal(seatsAnchorOf('#box-agents'), SEATS_AGENTS)
    assert.equal(seatsAnchorOf('box-agents'), SEATS_AGENTS)
    assert.equal(seatsAnchorOf('#box-users'), '')
    assert.equal(seatsAnchorOf(''), '')
    assert.equal(seatsAnchorOf(undefined), '')
  })
})
