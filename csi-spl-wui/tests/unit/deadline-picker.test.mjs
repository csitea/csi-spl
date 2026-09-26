// owner, topic 778ad161: the deadline is a calendar control (a month grid plus
// a 24-hour time) that shows and takes YYYY-MM-DD HH:MM in every locale, and
// is never a native date input (those render mm/dd/yyyy for the owner).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  deadlineText, parseDeadlineText, monthOf, shiftMonth, monthGrid, localInputToDeadline, deadlineToLocalInput,
} from '../../src/utils/issues-view.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')

describe('deadline text: YYYY-MM-DD HH:MM', () => {
  it('shows a local value with a space, never a T', () => {
    assert.equal(deadlineText('2026-10-02T15:30'), '2026-10-02 15:30')
    assert.equal(deadlineText(''), '')
  })
  it('takes the shown form, the T form, a one-digit hour and a bare day', () => {
    assert.equal(parseDeadlineText('2026-10-02 15:30'), '2026-10-02T15:30')
    assert.equal(parseDeadlineText(' 2026-10-02T07:05 '), '2026-10-02T07:05')
    assert.equal(parseDeadlineText('2026-10-02 7:05'), '2026-10-02T07:05')
    assert.equal(parseDeadlineText('2026-10-02'), '2026-10-02T09:00')
    assert.equal(parseDeadlineText('2026-10-02', '23:59'), '2026-10-02T23:59')
    assert.equal(parseDeadlineText(''), '')
  })
  it('refuses what is not a real day or a 24-hour time (CONTROL)', () => {
    for (const bad of ['10/02/2026', '02.10.2026', '2026-02-30', '2026-13-01', '2026-10-02 24:00', '2026-10-02 3pm', '2026-10-02 12:60']) {
      assert.equal(parseDeadlineText(bad), null, bad)
    }
  })
  it('round-trips through the RFC 3339 UTC the hub stores', () => {
    const local = parseDeadlineText('2026-10-02 15:30')
    const utc = localInputToDeadline(local, 180)
    assert.equal(utc, '2026-10-02T12:30:00Z')
    assert.equal(deadlineText(deadlineToLocalInput(utc, 180)), '2026-10-02 15:30')
  })
})

describe('the calendar month', () => {
  it('opens on the value month, else on today', () => {
    assert.equal(monthOf('2026-10-02T15:30', '2026-09-26'), '2026-10')
    assert.equal(monthOf('', '2026-09-26'), '2026-09')
  })
  it('moves across years', () => {
    assert.equal(shiftMonth('2026-12', 1), '2027-01')
    assert.equal(shiftMonth('2026-01', -1), '2025-12')
  })
  it('is 6 weeks of 7, Monday first', () => {
    const g = monthGrid('2026-10')
    assert.equal(g.length, 6)
    assert.ok(g.every((w) => w.length === 7))
    /* 2026-10-01 is a Thursday: Mon 09-28 .. Wed 09-30 lead in */
    assert.deepEqual(g[0].slice(0, 4).map((d) => d.date), ['2026-09-28', '2026-09-29', '2026-09-30', '2026-10-01'])
    assert.equal(g[0][3].inMonth, true)
    assert.equal(g[0][0].inMonth, false)
    assert.equal(g.flat().filter((d) => d.inMonth).length, 31)
  })
})

describe('the issues page uses the picker, not a native date input', () => {
  const page = read('pages/issues.vue')
  const picker = read('components/DeadlinePicker.vue')
  it('the filter row and the issue form both mount DeadlinePicker', () => {
    assert.match(page, /<DeadlinePicker[^>]*test-id="issues-filter-deadline-date"/)
    assert.match(page, /<DeadlinePicker[^>]*test-id="issues-deadline"/)
  })
  it('no type=date / datetime-local anywhere in the WUI source', () => {
    assert.doesNotMatch(page + picker, /type="(date|datetime-local)"/)
  })
  it('the picker shows YYYY-MM-DD HH:MM and has a month grid and a time list', () => {
    assert.match(picker, /placeholder="YYYY-MM-DD HH:MM"/)
    assert.match(picker, /role="grid"/)
    assert.match(picker, /deadlineTimes\(/)
  })
})
