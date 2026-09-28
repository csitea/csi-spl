// CLE-34994 — WCAG AA contrast of every theme the palette picker offers,
// computed from variables.css (not eyeballed). Prints the table it asserts,
// so the numbers posted to the owner come from this run.
//
// Bars: text 4.5:1 (1.4.3), focus ring 3:1 (1.4.11). The light theme's ring
// and its accent/button pair predate this lane and are owner-ruled or known
// (see variables.css, CLE-3427); they are printed, flagged, and held to what
// they measure today so they cannot get worse. The three new tinted themes
// must clear every bar.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const VARS = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
/* the picker's themes, in THEMES order (src/utils/theme.mjs) */
const THEME_IDS = ['dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']

function block(selector) {
  const i = VARS.indexOf(selector + ' {')
  assert.notEqual(i, -1, `no block for ${selector}`)
  return VARS.slice(i, VARS.indexOf('\n}', i))
}

function token(theme, name) {
  const re = new RegExp(`\\s${name}:\\s*([^;]+);`)
  const m = block(`:root[data-theme="${theme}"]`).match(re) ?? block(':root').match(re)
  assert.ok(m, `${theme} ${name}`)
  return m[1].trim()
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

const SURFACES = ['--color-bg', '--color-bg-2', '--color-surface', '--color-surface-hover']
/* [label, foreground, backgrounds, bar] */
const PAIRS = [
  ['text', '--color-fg', [...SURFACES, '--color-selected', '--color-composer'], 4.5],
  ['muted text', '--color-muted', SURFACES, 4.5],
  ['accent text', '--color-accent', ['--color-bg', '--color-surface'], 4.5],
  ['button text', '--color-on-accent', ['--color-accent', '--color-accent-pressed'], 4.5],
  ['error text', '--color-danger', ['--color-bg', '--color-surface'], 4.5],
  ['focus ring', '--focus-ring', SURFACES, 3],
]

/* Pre-existing light-theme shortfalls: pinned at today's value, never lower. */
const KNOWN = {
  'light accent text on --color-bg': 2.96,
  'light accent text on --color-surface': 3.16,
  'light button text on --color-accent': 3.16,
  'light button text on --color-accent-pressed': 4.36,
  'light focus ring on --color-bg': 2.01,
  'light focus ring on --color-bg-2': 1.83,
  'light focus ring on --color-surface': 2.15,
  'light focus ring on --color-surface-hover': 1.75,
}

describe('theme contrast', () => {
  const rows = []
  for (const theme of THEME_IDS) {
    for (const [label, fg, bgs, bar] of PAIRS) {
      for (const bg of bgs) {
        const ratio = contrast(token(theme, fg), token(theme, bg))
        rows.push({ theme, what: `${label} on ${bg}`, ratio, bar })
      }
    }
  }

  it('prints the table', () => {
    for (const r of rows) {
      const flag = r.ratio >= r.bar ? 'AA' : 'BELOW'
      console.log(`  ${r.theme.padEnd(13)} ${r.what.padEnd(44)} ${r.ratio.toFixed(2).padStart(6)}:1  ${flag}`)
    }
  })

  it('every pair clears its WCAG AA bar, except the pinned light-theme shortfalls', () => {
    for (const r of rows) {
      const key = `${r.theme} ${r.what}`
      if (key in KNOWN) {
        assert.ok(r.ratio >= KNOWN[key] - 0.005, `${key} fell to ${r.ratio.toFixed(2)} (pinned ${KNOWN[key]})`)
        continue
      }
      assert.ok(r.ratio >= r.bar, `${key}: ${r.ratio.toFixed(2)}:1 < ${r.bar}:1`)
    }
  })

  it('the new themes carry no exception at all', () => {
    for (const k of Object.keys(KNOWN)) assert.ok(k.startsWith('light '), k)
  })
})
