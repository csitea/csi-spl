// the focus / selection tokens, asserted as NUMBERS rather than as
// "the CSS mentions a colour": the test computes relative luminance from
// variables.css and fails when a future edit makes the ring darker than the
// owner asked for, widens a ring past the ceiling, or lets a second colour
// into the treatment.
//
// Owner (2026-09-20): "the line in the light theme is too dark, it should be
// bit lighter … also the selected element should change his color to a bit
// darker one" and, later the same day: "any selected item should have no more
// than 1 color in the selected border which cannot be wider than 3 px".
//
// Those two orders and the WCAG 1.4.11 3:1 bar for the indicator cannot all
// hold at once on a light surface — a single line light enough to read as
// "lighter" measures about 2:1 there, and the two-tone ring that did clear
// 3:1 is what "no more than 1 color" forbids. The owner's rule wins; the
// arithmetic is recorded in variables.css so nobody has to rediscover it.
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

/* every theme the picker offers (CLE-34994: five) */
const THEMES = ['dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']

/* the flat line the light theme used before this lane */
const OLD_LIGHT_LINE = '#0a97c4'
const SURFACES = ['--color-bg', '--color-bg-2', '--color-surface', '--color-surface-hover', '--color-sidebar']

describe('focus + selection tokens', () => {
  it('every theme defines the whole set — a half-themed token is a broken theme', () => {
    for (const theme of ['root', ...THEMES]) {
      for (const name of ['--focus-ring', '--focus-ring-w', '--focus-offset', '--select-bar-w', '--focus-3d', '--color-selected', '--color-accent-pressed']) {
        assert.ok(token(theme, name), `${theme} is missing ${name}`)
      }
    }
  })

  it('the light focus line is LIGHTER than the one it replaces', () => {
    const now = luminance(token('light', '--focus-ring'))
    const before = luminance(OLD_LIGHT_LINE)
    assert.ok(now > before, `light --focus-ring luminance ${now.toFixed(3)} must exceed ${before.toFixed(3)}`)
  })

  it('one colour and no more than 3px: the owner\'s ceiling, read off the tokens', () => {
    for (const theme of THEMES) {
      for (const w of ['--focus-ring-w', '--select-bar-w']) {
        const px = Number(String(token(theme, w)).replace('px', '').trim())
        assert.ok(px > 0 && px <= 3, `${theme} ${w} is ${token(theme, w)}, ceiling is 3px`)
      }
      /* the raise may not draw a second ring: a spread would be one */
      const shadow = String(token(theme, '--focus-3d'))
      assert.equal(/inset/.test(shadow), false, `${theme} --focus-3d draws an inset ring`)
      const layers = shadow.split(/,(?![^(]*\))/)
      assert.equal(layers.length, 1, `${theme} --focus-3d stacks ${layers.length} shadows`)
      const lengths = layers[0].replace(/rgba?\([^)]*\)|#[0-9a-f]{3,8}/gi, '').trim().split(/\s+/).filter(Boolean)
      assert.equal(lengths.length, 3, `${theme} --focus-3d must be offset-x offset-y blur with NO spread: ${shadow}`)
    }
  })

  it('CLE-77812 (owner a3c2cf08): the selected rail tab is RAISED, not ringed — no ring colour of its own', () => {
    const rule = MAIN.match(/\.sidebar-tab\[aria-selected="true"\]\s*\{([^}]*)\}/)
    assert.ok(rule, 'a rule of its own for the selected rail tab')
    /* the owner removed the ring box: no var(--focus-ring) on the selected tab now */
    assert.doesNotMatch(rule[1], /var\(--focus-ring\)/, 'the selected rail tab still draws a ring box')
    /* CLE-77838: the tile is the ::before, below; the button itself stays bare */
    assert.match(rule[1], /background:\s*transparent/, 'the selected rail tab paints a full-size fill')
  })

  it('CLE-77838 (owner a3c2cf08): the selected rail tile is 1px smaller on every side and darker', () => {
    const rule = MAIN.match(/\.sidebar-tab\[aria-selected="true"\]::before\s*\{([^}]*)\}/)
    assert.ok(rule, 'a ::before tile for the selected rail tab')
    /* 1px in from each edge: 2px less width and height than the button */
    assert.match(rule[1], /inset:\s*1px;/, 'the selected tile is not inset 1px on every side')
    /* the darker selected fill, a theme token, so light and dark both get it */
    assert.match(rule[1], /background:\s*var\(--color-selected\)/, 'the selected tile lost the darker fill')
    /* still raised via the theme-aware drop shadow token, still no ring colour */
    assert.match(rule[1], /box-shadow:[^}]*var\(--focus-3d\)/, 'the selected rail tile is not raised')
    assert.doesNotMatch(rule[1], /var\(--focus-ring\)/, 'the selected rail tile draws a ring box')
    /* --color-selected is a step darker than the rail it sits on, in every theme */
    const lum = (hex) => {
      const c = hex.replace('#', '').match(/../g).map((h) => parseInt(h, 16) / 255)
        .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
      return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }
    const themes = [...VARS.matchAll(/(:root[^{]*)\{([^}]*)\}/g)]
    let seen = 0
    for (const [, sel, body] of themes) {
      const selected = body.match(/--color-selected:\s*(#[0-9a-f]{6})/i)
      const sidebar = body.match(/--color-sidebar:\s*(#[0-9a-f]{6})/i)
      if (!selected || !sidebar) continue
      seen++
      assert.ok(lum(selected[1]) < lum(sidebar[1]), `${sel.trim()}: the selected tile is not darker than the rail`)
    }
    assert.ok(seen >= 2, 'expected light and dark themes to define both tokens')
  })

  it('the selected marker is the SAME colour as the focus ring, so a selected + focused row shows one', () => {
    assert.match(MAIN, /box-shadow:\s*inset var\(--select-bar-w\) 0 0 var\(--focus-ring\)/)
    /* and nothing in the shared treatment reaches for a second ring colour */
    /* the declarations only: a comment that QUOTES another rule is prose, not a ring */
    const treatment = MAIN.slice(MAIN.indexOf('/* ---- keyboard focus and selection')).replace(/\/\*[\s\S]*?\*\//g, '')
    const NOT_A_COLOUR = ['--focus-ring-w', '--select-bar-w', '--focus-offset', '--focus-3d', '--radius']
    const ringColours = new Set(
      [...treatment.matchAll(/(?:outline|box-shadow):([^;]*);/g)]
        .flatMap((decl) => [...decl[1].matchAll(/var\((--[a-z0-9-]+)\)/g)].map((v) => v[1]))
        .filter((v) => !NOT_A_COLOUR.includes(v)),
    )
    assert.deepEqual([...ringColours], ['--focus-ring'], 'more than one ring colour in the treatment')
  })

  it('the selected fill is DARKER than the fills it replaces, in every theme', () => {
    for (const theme of THEMES) {
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
    for (const theme of THEMES) {
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

  it('CLE-77812: the selected sidebar row reads bolder and RAISED — on tokens, no extra ring colour', () => {
    /* the .nav-item.active rule of its own (not the shared selected block) */
    const rule = MAIN.match(/\.nav-item\.active\s*\{([^}]*)\}(?![\s\S]*\.nav-item\.active\s*\{)/)
    assert.ok(rule, 'a .nav-item.active rule that carries the raise')
    assert.match(rule[1], /font-weight:\s*[6-9]\d\d/, 'the selected row is bolder')
    /* the raise is the theme-aware drop shadow token, so every theme gets it */
    assert.match(rule[1], /box-shadow:[^;]*var\(--focus-3d\)/, 'the selected row is raised with var(--focus-3d)')
    /* it keeps the darker fill */
    assert.match(rule[1], /background:\s*var\(--color-selected\)/, 'the selected row keeps the darker fill')
    /* owner a3c2cf08 removed the left accent bar: no ring colour on the row now */
    assert.doesNotMatch(rule[1], /var\(--focus-ring\)/, 'the selected row still draws the left bar')
    const ringColours = new Set(
      [...rule[1].matchAll(/box-shadow:([^;]*);/g)]
        .flatMap((decl) => [...decl[1].matchAll(/var\((--[a-z0-9-]+)\)/g)].map((v) => v[1]))
        .filter((v) => !['--focus-ring-w', '--select-bar-w', '--focus-offset', '--focus-3d', '--radius'].includes(v)),
    )
    assert.deepEqual([...ringColours], [], 'the selected row must carry no ring colour now')
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
