// SPL-3396 (owner, t1 2fc43707 msg 4e64e8d4): the calendar header's New event
// button is a plain round + like Issues (issues-fab) and Docs (wsdocs-fab):
// the plus icon only, no visible label, its name from calendar_event.new as
// aria-label and title. data-test="calendar-new" and openCreate(focus) stay.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const src = readFileSync(new URL('../../src/components/CalendarMainView.vue', import.meta.url), 'utf8')
const m = src.match(/<button\b[^>]*data-test="calendar-new"[^>]*>([\s\S]*?)<\/button>/)
const tag = m ? m[0].slice(0, m[0].indexOf('>') + 1) : ''
const body = m ? m[1] : ''

describe('calendar header + button (SPL-3396)', () => {
  it('exists, keeps its data-test and openCreate(focus)', () => {
    assert.ok(m, 'no button with data-test="calendar-new"')
    assert.match(tag, /@click="openCreate\(focus\)"/)
  })
  it('shows the plus icon only, no visible text label', () => {
    assert.match(body, /<UiIcon name="plus"/)
    assert.doesNotMatch(body.replace(/<UiIcon[^>]*\/>/g, ''), /\S/, `visible label left: ${body.trim()}`)
  })
  it('names itself with calendar_event.new as aria-label and title', () => {
    assert.match(tag, /:aria-label="t\('calendar_event\.new'\)"/)
    assert.match(tag, /:title="t\('calendar_event\.new'\)"/)
  })
  it('is the round accent + of Issues and Docs', () => {
    assert.match(tag, /class="cal-main__new"/)
    const css = src.match(/\.cal-main__new\s*\{([^}]*)\}/)
    assert.ok(css, 'no .cal-main__new rule')
    for (const want of ['border-radius: 50%', 'width: 2.5rem', 'height: 2.5rem', 'background: var(--color-accent)', 'color: var(--color-on-accent)']) {
      assert.ok(css[1].includes(want), `.cal-main__new lacks ${want}`)
    }
  })
})
