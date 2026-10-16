// SPL-2213: the person picker's matcher and keys (src/utils/person-picker.mjs).
// Run: node tests/unit/person-picker.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { enterPick, personMatches, personRows, stepActive } from '../../src/utils/person-picker.mjs'

const PEOPLE = [
  { id: '', label: 'No assignee' },
  { id: 'HUM-10', label: 'FirstName LastName' },
  { id: 'HUM-12', label: 'Ada Lovelace' },
  { id: 'c-779', label: 'c-779' },
]

describe('personMatches', () => {
  it('matches three letters of the name in any case', () => {
    assert.equal(personMatches(PEOPLE[2], 'lac'), true)
    assert.equal(personMatches(PEOPLE[2], 'LAC'), true)
    assert.equal(personMatches(PEOPLE[2], 'aCe'), true)
  })
  it('matches the id (a HUM id or an agent id) in any case', () => {
    assert.equal(personMatches(PEOPLE[1], 'hum-1'), true)
    assert.equal(personMatches(PEOPLE[3], 'C-77'), true)
  })
  it('control: letters in neither the name nor the id do not match', () => {
    assert.equal(personMatches(PEOPLE[2], 'xyz'), false)
    assert.equal(personMatches(PEOPLE[1], 'lac'), false)
  })
  it('an empty, blank or missing query matches everyone', () => {
    for (const q of ['', '   ', undefined, null, 7]) assert.equal(personMatches(PEOPLE[2], q), true)
  })
  it('a person with no name or id matches only the empty query', () => {
    assert.equal(personMatches({}, ''), true)
    assert.equal(personMatches({}, 'a'), false)
  })
})

describe('personRows', () => {
  it('keeps the matches in their order', () => {
    assert.deepEqual(personRows(PEOPLE, 'hum').map((p) => p.id), ['HUM-10', 'HUM-12'])
    assert.deepEqual(personRows(PEOPLE, 'lac').map((p) => p.id), ['HUM-12'])
  })
  it('no list is no rows', () => {
    assert.deepEqual(personRows(null, 'a'), [])
  })
})

describe('stepActive', () => {
  it('moves and wraps at both ends', () => {
    assert.equal(stepActive(0, 1, 3), 1)
    assert.equal(stepActive(2, 1, 3), 0)
    assert.equal(stepActive(0, -1, 3), 2)
  })
  it('from no highlight, Down is the first row and Up the last', () => {
    assert.equal(stepActive(-1, 1, 3), 0)
    assert.equal(stepActive(-1, -1, 3), 2)
    assert.equal(stepActive(9, 1, 3), 0)
  })
  it('no rows: no highlight', () => {
    assert.equal(stepActive(0, 1, 0), -1)
  })
})

describe('enterPick', () => {
  it('picks the highlighted row', () => {
    assert.equal(enterPick(PEOPLE, 2), PEOPLE[2])
  })
  it('with nothing highlighted, picks the only row left, else nothing', () => {
    assert.equal(enterPick([PEOPLE[2]], -1), PEOPLE[2])
    assert.equal(enterPick(PEOPLE, -1), null)
    assert.equal(enterPick([], 0), null)
  })
})
