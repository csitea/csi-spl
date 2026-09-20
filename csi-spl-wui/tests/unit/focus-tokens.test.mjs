// CLE-3427 — the focus / selection tokens, asserted as NUMBERS rather than as
// "the CSS mentions a colour": a focus indicator is an accessibility control,
// so the test computes relative luminance and contrast from variables.css and
// fails when a future edit makes the ring darker than the owner asked for or
// drops it below the WCAG 2.2 focus-appearance floor.
//
// Owner (2026-09-20): "the line in the light theme is too dark, it should be
// bit lighter … also the selected element should change his color to a bit
// darker one".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const VARS = read('src/assets/css/variables.css')
const MAIN = read('src/assets/css/main.css')

/** The declarations of one top-level block, by selector text. */
function block(css, selector) {
  const i = css.indexOf(selector + ' {')
  assert.notEqual(i, -1, `no block for ${selector}`)
  const j = css.indexOf('\n}', i)
  return css.slice(i, j)
}

/** `--name: value` of a block (the last one wins, as the cascade does). */
function tokenOf(src, name) {
  const re = new RegExp('\\' + `-\\-${name.replace(/^--/, '')}:([^;]+);`, 'g')
  let m, out = null
  while ((m = re.exec(src))) out = m[1].trim()
  return out
}

/** The theme's token, falling back to the dark default :root block. */
function token(theme, name) {
  const scoped = theme === 'root' ? block(VARS, ':root') : block(VARS, `:root[data-theme="${theme}"]`)
  return tokenOf(scoped, name) ?? tokenOf(block(VARS, ':root'), name)
}

function rgb(value) {
  const hex = String(value).trim().match(/^#([0-9a-f]{6})$/i)
  if (hex) return [0, 2, 4].map((i) => parseInt(hex[1].slice(i, i + 2), 16) / 255)
  const fn = String(value).match(/^rgba?\(([^)]+)\)$/i)
  assert.ok(fn, `not a colour: ${value}`)
  const parts = fn[1].split(',').map((p) => Number(p.trim()))
  return parts.slice(0, 3).map((n) => n / 255)
}

/** WCAG relative luminance. */
function luminance(value) {
  const [r, g, b] = rgb(value).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

/* the flat line the light theme used before this lane */
const OLD_LIGHT_LINE = '#0a97c4'
const SURFACES = ['--color-bg', '--color-bg-2', '--color-surface', '--color-surface-hover', '--color-sidebar']

describe('focus + selection tokens (CLE-3427)', () => {
  it('every theme defines the whole set — a half-themed token is a broken theme', () => {
    for (const theme of ['root', 'light', 'dark']) {
      for (const name of ['--focus-ring', '--focus-edge', '--focus-ring-w', '--focus-offset', '--focus-3d', '--color-selected', '--color-accent-pressed']) {
        assert.ok(token(theme, name), `${theme} is missing ${name}`)
      }
    }
  })

  it('the light focus line is LIGHTER than the one it replaces', () => {
    const now = luminance(token('light', '--focus-ring'))
    const before = luminance(OLD_LIGHT_LINE)
    assert.ok(now > before, `light --focus-ring luminance ${now.toFixed(3)} must exceed ${before.toFixed(3)}`)
  })

  it('the indicator still meets the WCAG 2.2 3:1 floor against every surface', () => {
    /* the light ring is deliberately low-contrast; the dark hairline beside it
       is what the check must pass on. Measured together, per surface. */
    for (const theme of ['light', 'dark']) {
      for (const surface of SURFACES) {
        const best = Math.max(
          contrast(token(theme, '--focus-ring'), token(theme, surface)),
          contrast(token(theme, '--focus-edge'), token(theme, surface)),
        )
        assert.ok(best >= 3, `${theme} focus indicator on ${surface}: ${best.toFixed(2)}:1`)
      }
      /* and the two halves of the indicator must read as two halves */
      const pair = contrast(token(theme, '--focus-ring'), token(theme, '--focus-edge'))
      assert.ok(pair >= 3, `${theme} ring vs edge: ${pair.toFixed(2)}:1`)
    }
  })

  it('the selected fill is DARKER than the fills it replaces, in both themes', () => {
    for (const theme of ['light', 'dark']) {
      const selected = luminance(token(theme, '--color-selected'))
      for (const surface of ['--color-surface-hover', '--color-sidebar', '--color-bg']) {
        assert.ok(selected < luminance(token(theme, surface)), `${theme} --color-selected is not darker than ${surface}`)
      }
      /* still readable: body text on the selected fill */
      const text = contrast(token(theme, '--color-fg'), token(theme, '--color-selected'))
      assert.ok(text >= 4.5, `${theme} text on --color-selected: ${text.toFixed(2)}:1`)
    }
  })

  it('the pressed accent is darker than the accent it darkens', () => {
    for (const theme of ['light', 'dark']) {
      assert.ok(
        luminance(token(theme, '--color-accent-pressed')) < luminance(token(theme, '--color-accent')),
        `${theme} --color-accent-pressed is not darker than --color-accent`,
      )
    }
  })

  it('one rule in main.css carries the treatment for every view', () => {
    assert.match(MAIN, /:focus-visible\s*\{[^}]*outline:\s*var\(--focus-ring-w\) solid var\(--focus-ring\) !important/)
    assert.match(MAIN, /:focus-visible\s*\{[^}]*box-shadow:\s*var\(--focus-3d\)/)
    assert.match(MAIN, /\.nav-item\.active[^{]*\{[^}]*background:\s*var\(--color-selected\)/)
    assert.match(MAIN, /\.msg\.selected/)
  })

  it('no stylesheet takes an outline away on focus without putting something back', () => {
    const files = []
    const walk = (dir) => {
      for (const name of readdirSync(dir)) {
        const p = join(dir, name)
        if (statSync(p).isDirectory()) walk(p)
        else if (/\.(css|vue)$/.test(name)) files.push(p)
      }
    }
    walk(join(WUI, 'src'))
    for (const p of files) {
      const css = readFileSync(p, 'utf8')
      for (const m of css.matchAll(/([^{}]*:focus-visible[^{}]*)\{([^}]*)\}/g)) {
        if (!/outline:\s*none|outline:\s*0/.test(m[2])) continue
        assert.match(m[2], /box-shadow|border|background/, `${p}: ${m[1].trim()} removes the outline and replaces nothing`)
      }
    }
  })
})
