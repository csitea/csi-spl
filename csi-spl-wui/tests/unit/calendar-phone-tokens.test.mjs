// spec 106 T004: the phone calendar draws with the WUI's own tokens (H5,
// spec 4.7) and its event dots read in every theme (S4-8, WCAG 1.4.11).
//
// 1. Lint, for every src/components/CalendarPhone*.vue (T004..T010): no
//    colour literal (#hex, rgb(), hsl()) and no px radius or shadow - a
//    border-radius or box-shadow is a token (var(--radius*), var(--focus-3d),
//    var(--bevel-*), ...) or none / 0.
// 2. The bevel tokens --bevel-shine / --bevel-shade exist for the dark
//    family and for the light family (9.4 #6), as inset shadows only (no
//    ring, the owner's focus rule), and the raised controls use them.
// 3. Dot contrast in all 8 themes (the default, dark and the six light-*):
//    each of the 11 event colours reaches 3:1 against --color-bg and
//    --color-surface by itself, or through its --cal-dot-ring edge.
//
// Each block carries a control: the nearest input that must fail.
// Run: node tests/unit/calendar-phone-tokens.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const COMPONENTS = join(WUI, 'src/components')
const VARS = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')

/* ---- 1. the lint ---- */

/** the <style> blocks of an SFC, comments dropped */
function styleOf(sfc) {
  return (sfc.match(/<style[\s\S]*?<\/style>/g) || []).join('\n').replace(/\/\*[\s\S]*?\*\//g, '')
}

/** every H5 breach in a stylesheet: [rule, text] */
function lint(css) {
  const out = []
  for (const m of css.matchAll(/#[0-9a-fA-F]{3,8}\b/g)) out.push(['hex colour', m[0]])
  for (const m of css.matchAll(/\b(?:rgba?|hsla?)\s*\(/g)) out.push(['colour function', m[0]])
  for (const m of css.matchAll(/(?:^|[;{\s])((?:border(?:-[a-z]+)*-radius|box-shadow)\s*:\s*([^;}]*))/g)) {
    if (/\d(?:\.\d+)?px\b/.test(m[2].replace(/var\([^)]*\)/g, ''))) out.push(['px radius / shadow', m[1].trim()])
  }
  return out
}

const PHONE_FILES = readdirSync(COMPONENTS).filter((n) => /^CalendarPhone.*\.vue$/.test(n)).sort()

describe('H5 lint: CalendarPhone*.vue use tokens only', () => {
  it('finds the phone files (never a vacuous pass)', () => {
    assert.ok(PHONE_FILES.includes('CalendarPhone.vue'), `found ${PHONE_FILES.join(', ') || 'none'}`)
  })
  for (const name of PHONE_FILES) {
    it(`${name}: no colour literal, no px radius or shadow`, () => {
      const css = styleOf(readFileSync(join(COMPONENTS, name), 'utf8'))
      assert.ok(css.length > 0, `${name} has no <style>`)
      assert.deepEqual(lint(css), [])
    })
  }
  it('control: each breach is caught', () => {
    const bad = lint('.a { color: #fff; } .b { background: rgb(1, 2, 3); } .c { fill: hsl(1 2% 3%); } .d { border-radius: 8px; } .e { box-shadow: 0 2px 4px var(--x); } .f { border-top-left-radius: 4px }')
    assert.deepEqual(bad.map((b) => b[0]), ['hex colour', 'colour function', 'colour function', 'px radius / shadow', 'px radius / shadow', 'px radius / shadow'])
  })
  it('control: tokens, none and 0 pass', () => {
    assert.deepEqual(lint('.a { border-radius: var(--radius-pill); box-shadow: var(--focus-3d), var(--bevel-shine); } .b { box-shadow: none; border-radius: 0; color: var(--color-fg); }'), [])
  })
})

/* ---- the token sheet, resolved per theme ---- */

const BLOCKS = [...VARS.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^}]*)\}/g)].map((m) => ({
  sels: m[1].split(',').map((s) => s.trim()),
  decls: Object.fromEntries([...m[2].matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)].map((d) => [d[1], d[2].trim()])),
}))
/* the default (no data-theme) and the picker's seven */
const THEMES = ['', 'dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']

function applies(sel, theme) {
  if (sel === ':root') return true
  const eq = sel.match(/^:root\[data-theme="([^"]+)"\]$/)
  if (eq) return eq[1] === theme
  const pre = sel.match(/^:root\[data-theme\^="([^"]+)"\]$/)
  return Boolean(pre && theme.startsWith(pre[1]))
}

/** the token's value in `theme`: the last block that applies wins (equal specificity), var() resolved */
function token(theme, name, depth = 0) {
  let v
  for (const b of BLOCKS) if (b.sels.some((s) => applies(s, theme)) && name in b.decls) v = b.decls[name]
  assert.ok(v !== undefined, `${theme || 'default'}: ${name} is not defined`)
  assert.ok(depth < 8, `${name}: var() loop`)
  return v.replace(/var\((--[a-z0-9-]+)\)/g, (_, n) => token(theme, n, depth + 1))
}

function luminance(hex) {
  const m = String(hex).match(/^#([0-9a-f]{6})$/i)
  assert.ok(m, `not an opaque hex colour: ${hex}`)
  const [r, g, b] = [0, 2, 4]
    .map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

/* ---- 2. the bevel ---- */

describe('bevel tokens (9.4 #6)', () => {
  it('both families define --bevel-shine and --bevel-shade as inset shadows, distinct per family', () => {
    for (const name of ['--bevel-shine', '--bevel-shade']) {
      const dark = token('dark', name)
      const light = token('light', name)
      for (const v of [dark, light]) assert.match(v, /^inset\s/, `${name}: ${v}`)
      assert.notEqual(dark, light, `${name}: the light theme needs its own`)
      for (const th of THEMES) assert.match(token(th, name), /^inset\s/, `${th || 'default'} ${name}`)
    }
  })
  it('the shine lights the top, the shade darkens the bottom', () => {
    for (const th of ['dark', 'light']) {
      assert.match(token(th, '--bevel-shine'), /^inset\s+0\s+[1-9]/, `${th} shine offset is downward (top edge)`)
      assert.match(token(th, '--bevel-shade'), /^inset\s+0\s+-[1-9]/, `${th} shade offset is upward (bottom edge)`)
    }
  })
  it('the raised controls of CalendarPhone.vue carry --focus-3d plus the bevel', () => {
    const css = styleOf(readFileSync(join(COMPONENTS, 'CalendarPhone.vue'), 'utf8'))
    for (const sel of ['.calphone__add', '.calphone__seg-btn--on', '.calphone__today']) {
      const rule = css.match(new RegExp(`${sel.replace('.', '\\.')}\\s*\\{([^}]*)\\}`))
      assert.ok(rule, `${sel} rule`)
      assert.match(rule[1], /box-shadow:\s*var\(--focus-3d\),\s*var\(--bevel-shine\),\s*var\(--bevel-shade\)/, sel)
    }
  })
})

/* ---- 3. the dots ---- */

const CAL_COLORS = ['tomato', 'flamingo', 'tangerine', 'banana', 'sage', 'basil', 'peacock', 'blueberry', 'lavender', 'grape', 'graphite']
const SURFACES = ['--color-bg', '--color-surface']

/** the ring's colour, or '' when it draws nothing */
function ringColour(ring) {
  const m = ring.match(/^0\s+0\s+0\s+(\d+(?:\.\d+)?)(?:px)?\s+(#[0-9a-f]{6}|transparent)$/i)
  assert.ok(m, `--cal-dot-ring is "0 0 0 <w>px <colour>": ${ring}`)
  return Number(m[1]) >= 1 && m[2] !== 'transparent' ? m[2] : ''
}

/** each dot's best contrast on a surface: its fill, or its ring when it has one */
function dotReport(theme, ring = token(theme, '--cal-dot-ring')) {
  const edge = ringColour(ring)
  const rows = []
  for (const s of SURFACES) {
    const bg = token(theme, s)
    for (const c of CAL_COLORS) {
      const fill = contrast(token(theme, `--cal-color-${c}`), bg)
      const best = Math.max(fill, edge ? contrast(edge, bg) : 0)
      rows.push({ theme: theme || 'default', surface: s, colour: c, fill: +fill.toFixed(2), best: +best.toFixed(2) })
    }
  }
  return rows
}

describe('event dot contrast >= 3:1 in all 8 themes (S4-8)', () => {
  for (const th of THEMES) {
    it(`${th || 'default'}: every event colour, by fill or ring`, () => {
      const low = dotReport(th).filter((r) => r.best < 3)
      assert.deepEqual(low, [])
    })
  }
  it('control: without the ring the light themes fail (banana on white is ~1.5:1)', () => {
    for (const th of THEMES.filter((x) => x.startsWith('light'))) {
      const low = dotReport(th, '0 0 0 0 transparent').filter((r) => r.best < 3)
      assert.ok(low.some((r) => r.colour === 'banana'), `${th}: ${JSON.stringify(low)}`)
    }
  })
  it('the dark family needs no ring: its fills clear 3:1 alone', () => {
    for (const th of ['', 'dark']) assert.deepEqual(dotReport(th, '0 0 0 0 transparent').filter((r) => r.fill < 3), [])
  })
})
