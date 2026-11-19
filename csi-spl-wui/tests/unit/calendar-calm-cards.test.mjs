// SPL-5908 (owner HUM-10, t1 b6d13fc5): the calendar looks calmer and more
// basic - "too many small effects in the ui" (msg 951a60ed) - with one raised
// card per day cell and per event: a soft shadow and a light border, like
// paper on a desk (poll Q1 = A), in every view, phone included (Q3 = A).
//
// 1. The card tokens --cal-card-shadow / --cal-card-border exist for the dark
//    family and for the light family: one non-inset shadow, a 1 px border.
// 2. The day cells and the events of desktop month / week / day and phone
//    month / week / day draw with both tokens; today keeps the one accent.
// 3. Ratchets over every Calendar*.vue and pages/calendar.vue: the count of
//    transition / animation / @keyframes rules stays at or below MAX_MOTION,
//    no box-shadow stacks more than one layer, the stacked bevel tokens are
//    gone, and colour tints (color-mix) stay at or below MAX_TINT.
//
// Each block carries a control: the nearest input that must fail.
// Run: node tests/unit/calendar-calm-cards.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const COMPONENTS = join(WUI, 'src/components')
const VARS = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')

/* the ratchet ceilings: lower them when a rule goes, never raise them.
   Before SPL-5908: 5 motion rules (2 transition, 2 animation, 1 @keyframes),
   7 color-mix tints. MAX_TINT keeps the 4 that carry meaning: the two modal
   scrims (CalendarPhonePeek, CalendarPhoneSheet) and the year strip's
   official-holiday and selected-week days (CalendarYearStrip). */
const MAX_MOTION = 0
const MAX_TINT = 4

const FILES = [
  ...readdirSync(COMPONENTS).filter((n) => /^Calendar.*\.vue$/.test(n)).sort().map((n) => join(COMPONENTS, n)),
  join(WUI, 'src/pages/calendar.vue'),
]

/** the <style> blocks of an SFC, comments dropped */
function styleOf(sfc) {
  return (sfc.match(/<style[\s\S]*?<\/style>/g) || []).join('\n').replace(/\/\*[\s\S]*?\*\//g, '')
}
const STYLES = Object.fromEntries(FILES.map((f) => [f.slice(WUI.length + 1), styleOf(readFileSync(f, 'utf8'))]))

/** every motion rule: a transition / animation declaration that is not `none`, and each @keyframes */
function motion(css) {
  const out = []
  for (const m of css.matchAll(/(?:^|[;{\s])((?:transition|animation)(?:-[a-z]+)?\s*:\s*([^;}]*))/g)) {
    if (m[2].trim() !== 'none') out.push(m[1].trim())
  }
  for (const m of css.matchAll(/@keyframes\s+[\w-]+/g)) out.push(m[0])
  return out
}

/** every box-shadow with more than one layer (a comma outside parentheses) */
function stacked(css) {
  const out = []
  for (const m of css.matchAll(/box-shadow\s*:\s*([^;}]*)/g)) {
    if (m[1].replace(/\([^()]*\)/g, '').includes(',')) out.push(m[0].trim())
  }
  return out
}

const tints = (css) => [...css.matchAll(/color-mix\(/g)].length
const bevels = (css) => [...css.matchAll(/var\(--bevel-(?:shine|shade)\)/g)].length

describe('ratchets: Calendar*.vue and pages/calendar.vue stay calm', () => {
  it('finds the calendar files (never a vacuous pass)', () => {
    assert.ok(FILES.length >= 20, `found ${FILES.length}`)
    assert.ok(Object.values(STYLES).filter((s) => s.length).length >= 15)
  })
  it(`transition / animation / @keyframes rules <= ${MAX_MOTION}`, () => {
    const all = Object.entries(STYLES).flatMap(([f, css]) => motion(css).map((r) => `${f}: ${r}`))
    assert.ok(all.length <= MAX_MOTION, `${all.length} > ${MAX_MOTION}:\n${all.join('\n')}`)
  })
  it('no box-shadow stacks more than one layer (one shadow level)', () => {
    const all = Object.entries(STYLES).flatMap(([f, css]) => stacked(css).map((r) => `${f}: ${r}`))
    assert.deepEqual(all, [])
  })
  it('the stacked bevel tokens are not used by the calendar', () => {
    const all = Object.entries(STYLES).filter(([, css]) => bevels(css)).map(([f]) => f)
    assert.deepEqual(all, [])
  })
  it(`color-mix tints <= ${MAX_TINT}`, () => {
    const n = Object.values(STYLES).reduce((a, css) => a + tints(css), 0)
    assert.ok(n <= MAX_TINT, `${n} > ${MAX_TINT}`)
  })
  it('control: an added transition, animation or keyframes is counted', () => {
    const css = STYLES['src/components/CalendarDeskMonth.vue']
    const before = motion(css).length
    assert.equal(motion(css + '\n.cal-month__cell { transition: box-shadow 0.15s ease; }').length, before + 1)
    assert.equal(motion(css + '\n.x{animation:spin 1s}').length, before + 1)
    assert.equal(motion(css + '\n@keyframes spin { to { opacity: 0 } }').length, before + 1)
    assert.equal(motion('.a { transition: none; animation: none; }').length, 0)
  })
  it('control: the ratchet fails on one added transition', () => {
    const planted = { ...STYLES, 'src/components/CalendarDeskMonth.vue': STYLES['src/components/CalendarDeskMonth.vue'] + '\n.cal-month__cell:hover { transition: background 0.1s; }' }
    const n = Object.values(planted).reduce((a, css) => a + motion(css).length, 0)
    assert.ok(n > MAX_MOTION, `planted count ${n} must exceed ${MAX_MOTION}`)
  })
  it('control: a two-layer shadow is caught, one layer with a var() or rgb() is not', () => {
    assert.equal(stacked('.a { box-shadow: var(--focus-3d), var(--bevel-shine); }').length, 1)
    assert.equal(stacked('.a { box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3); } .b { box-shadow: var(--cal-card-shadow); }').length, 0)
  })
})

/* ---- the token sheet, resolved per theme (as calendar-phone-tokens) ---- */

const BLOCKS = [...VARS.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^}]*)\}/g)].map((m) => ({
  sels: m[1].split(',').map((s) => s.trim()),
  decls: Object.fromEntries([...m[2].matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)].map((d) => [d[1], d[2].trim()])),
}))
const THEMES = ['', 'dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']
function applies(sel, theme) {
  if (sel === ':root') return true
  const eq = sel.match(/^:root\[data-theme="([^"]+)"\]$/)
  if (eq) return eq[1] === theme
  const pre = sel.match(/^:root\[data-theme\^="([^"]+)"\]$/)
  return Boolean(pre && theme.startsWith(pre[1]))
}
function token(theme, name) {
  let v
  for (const b of BLOCKS) if (b.sels.some((s) => applies(s, theme)) && name in b.decls) v = b.decls[name]
  assert.ok(v !== undefined, `${theme || 'default'}: ${name} is not defined`)
  return v
}

describe('the card tokens (light and dark)', () => {
  it('--cal-card-shadow: one blurred, non-inset shadow, its own per family', () => {
    for (const th of THEMES) {
      const v = token(th, '--cal-card-shadow')
      assert.doesNotMatch(v, /inset/, `${th || 'default'}: ${v}`)
      assert.equal(stacked(`.a { box-shadow: ${v}; }`).length, 0, `${th || 'default'} stacks: ${v}`)
      assert.match(v, /^0\s+\d+px\s+\d+px\s/, `${th || 'default'}: offset-y and blur: ${v}`)
    }
    assert.notEqual(token('dark', '--cal-card-shadow'), token('light', '--cal-card-shadow'))
  })
  it('--cal-card-border: a light 1 px solid border, its own per family', () => {
    for (const th of THEMES) assert.match(token(th, '--cal-card-border'), /^1px solid \S/, th || 'default')
    assert.notEqual(token('dark', '--cal-card-border'), token('light', '--cal-card-border'))
  })
})

/* ---- the views use them ---- */

/** the declarations of `sel`'s first rule in a stylesheet */
function rule(css, sel) {
  const esc = sel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const m = css.match(new RegExp(`(?:^|[}\\s])${esc}\\s*\\{([^}]*)\\}`))
  return m ? m[1] : ''
}
const CARDS = [
  ['src/components/CalendarDeskMonth.vue', '.cal-month__cell'],
  ['src/components/CalendarMainView.vue', '.cal-week__item'],
  ['src/components/CalendarMainView.vue', '.cal-week'],
  ['src/components/CalendarPhoneMonth.vue', '.calmonth__cell::before'],
  ['src/components/CalendarPhoneMonth.vue', '.calmonth__card'],
  ['src/components/CalendarPhoneWeek.vue', '.calweek__chip'],
  ['src/components/CalendarPhoneWeek.vue', '.calweek__ev'],
  ['src/components/CalendarPhoneDay.vue', '.calday__ev'],
  ['src/components/CalendarPhoneDay.vue', '.calday__list-row'],
]

describe('day cells and events are raised cards', () => {
  for (const [f, sel] of CARDS) {
    it(`${f.split('/').pop()} ${sel}: --cal-card-shadow and --cal-card-border`, () => {
      const body = rule(STYLES[f], sel)
      assert.ok(body, `${sel} has no rule`)
      assert.match(body, /box-shadow:\s*var\(--cal-card-shadow\)/, sel)
      assert.match(body, /border:\s*var\(--cal-card-border\)/, sel)
    })
  }
  it('the events carry no colour tint: their colour is the start bar or the dot', () => {
    for (const [f, sel] of [['src/components/CalendarMainView.vue', '.cal-ev'], ['src/components/CalendarDeskMonth.vue', '.cal-month__list .cal-week__item']]) {
      const body = rule(STYLES[f], sel)
      assert.ok(body, `${sel} has no rule`)
      assert.doesNotMatch(body, /color-mix/, sel)
      assert.match(body, /border-inline-start:\s*\d+px solid var\(--cal-ev-color/, sel)
    }
  })
  it('today keeps the one accent colour', () => {
    assert.match(rule(STYLES['src/components/CalendarDeskMonth.vue'], '.cal-month__cell--today .cal-month__num'), /background:\s*var\(--color-accent\)/)
    assert.match(rule(STYLES['src/components/CalendarMainView.vue'], '.cal-week__day--today .cal-week__head'), /color:\s*var\(--color-accent\)/)
    assert.match(rule(STYLES['src/components/CalendarPhoneMonth.vue'], '.calmonth__cell--today'), /outline:[^;]*var\(--color-accent\)/)
    assert.match(rule(STYLES['src/components/CalendarPhoneWeek.vue'], '.calweek__chip--today'), /border-color:\s*var\(--color-accent\)/)
  })
  it('control: a rule without the tokens fails the match', () => {
    const body = rule('.calweek__ev { box-shadow: var(--focus-3d); border: 0; }', '.calweek__ev')
    assert.doesNotMatch(body, /box-shadow:\s*var\(--cal-card-shadow\)/)
    assert.equal(rule('.other { border: 0 }', '.calweek__ev'), '')
  })
})
