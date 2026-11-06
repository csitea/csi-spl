// SPL-4893: the note editor's toolbar (utils/note-wiki.mjs) writes wiki marks
// into the plain-text body, never HTML (owner HUM-10, t1 ba784026, msg
// de86531f: "to be wiki based, not html based").
// CONTROL: with toggleMark always wrapping (no unwrap branch), or toggleList
// numbering every line 1, the cases below FAIL; so do the N2 / N3 cases with
// the file at 937927764 (edge spaces inside the marks, empty lines numbered).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { toggleList, toggleMark } from '../../src/utils/note-wiki.mjs'

describe('note editor toolbar marks', () => {
  it('bold wraps the selection, and a second click takes it off', () => {
    const on = toggleMark('make this bold', 5, 9, '**')
    assert.deepEqual(on, { text: 'make **this** bold', start: 7, end: 11 })
    assert.deepEqual(toggleMark(on.text, on.start, on.end, '**'), { text: 'make this bold', start: 5, end: 9 })
    assert.deepEqual(toggleMark('make **this** bold', 5, 13, '**'), { text: 'make this bold', start: 5, end: 9 })
  })
  it('underline is ++ and an empty selection puts the caret between the marks', () => {
    assert.deepEqual(toggleMark('ab', 1, 1, '++'), { text: 'a++++b', start: 3, end: 3 })
    assert.deepEqual(toggleMark('x word y', 2, 6, '++'), { text: 'x ++word++ y', start: 4, end: 8 })
  })
  it('bullets prefix every touched line, and come off again', () => {
    const on = toggleList('a\nb\nc', 0, 3, 'bullet')
    assert.deepEqual(on, { text: '- a\n- b\nc', start: 0, end: 7 })
    assert.equal(toggleList(on.text, 0, 7, 'bullet').text, 'a\nb\nc')
  })
  it('numbers count 1, 2, 3 and replace bullets', () => {
    assert.equal(toggleList('one\ntwo\nthree', 0, 13, 'number').text, '1. one\n2. two\n3. three')
    assert.equal(toggleList('- one\n- two', 0, 11, 'number').text, '1. one\n2. two')
    assert.equal(toggleList('1. one\n2. two', 0, 13, 'number').text, 'one\ntwo')
  })
  it('edge whitespace of the selection stays outside the marks (R7 c-232 N2)', () => {
    assert.deepEqual(toggleMark('a word b', 2, 7, '**'), { text: 'a **word** b', start: 4, end: 8 })
    assert.deepEqual(toggleMark('a word b', 1, 6, '++'), { text: 'a ++word++ b', start: 4, end: 8 })
  })
  it('empty lines are neither items nor counted (R7 c-232 N3)', () => {
    assert.equal(toggleList('one\n\ntwo', 0, 8, 'number').text, '1. one\n\n2. two')
    assert.equal(toggleList('a\n\nb', 0, 4, 'bullet').text, '- a\n\n- b')
    assert.equal(toggleList('1. one\n\n2. two', 0, 14, 'number').text, 'one\n\ntwo')
  })
  it('a caret inside a line makes just that line an item', () => {
    assert.equal(toggleList('top\nmiddle\nend', 6, 6, 'bullet').text, 'top\n- middle\nend')
  })
  it('it writes only wiki marks, never a tag', () => {
    const t = [toggleMark('x', 0, 1, '**'), toggleMark('x', 0, 1, '++'), toggleList('x', 0, 1, 'number'), toggleList('x', 0, 1, 'bullet')].map((e) => e.text).join(' ')
    assert.doesNotMatch(t, /[<>]/)
  })
})
