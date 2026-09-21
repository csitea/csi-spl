// GRK-3376 — radius tokens are the only corner radii in the WUI.
// Raw `border-radius: 8px` (and friends) drift; 50% is a circle, not a box.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const SRC = join(WUI, 'src')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

function walk(dir, acc = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, acc)
    else if (/\.(css|vue)$/.test(name)) acc.push(p)
  }
  return acc
}

describe('rounded corners (GRK-3376)', () => {
  const vars = read('src/assets/css/variables.css')
  const root = vars.slice(vars.indexOf(':root {'), vars.indexOf('\n}'))

  it('the scale lives once in :root — sm/md/lg/pill plus the default --radius', () => {
    for (const [name, value] of [
      ['--radius', '8px'],
      ['--radius-sm', '8px'],
      ['--radius-md', '12px'],
      ['--radius-lg', '16px'],
      ['--radius-pill', '999px'],
    ]) {
      const re = new RegExp(name.replace('--', '--') + ':\\s*' + value)
      assert.match(root, re, `${name} should be ${value} in :root`)
    }
  })

  it('no stylesheet sprinkles a raw pixel radius (circles 50% are not boxes)', () => {
    const files = walk(SRC)
    const raw = /border-radius\s*:\s*[\d.]+px\b/g
    const zero = /border-radius\s*:\s*0(?:px)?\b/g
    const hits = []
    for (const p of files) {
      const css = readFileSync(p, 'utf8')
      for (const re of [raw, zero]) {
        re.lastIndex = 0
        let m
        while ((m = re.exec(css))) {
          const line = css.slice(0, m.index).split('\n').length
          hits.push(`${relative(WUI, p)}:${line}: ${m[0]}`)
        }
      }
    }
    assert.equal(hits.length, 0, hits.join('\n'))
  })

  it('interactive rows that currently look like boxes carry a token radius', () => {
    const main = read('src/assets/css/main.css')
    assert.match(main, /\.nav-item\s*\{[^}]*border-radius:\s*var\(--radius/)
    assert.match(main, /\.thread-row\s*\{[^}]*border-radius:\s*var\(--radius/)
    assert.match(main, /\.icon-btn\s*\{[^}]*border-radius:\s*var\(--radius/)
    assert.match(main, /\.btn[\s,{][^}]*border-radius:\s*var\(--radius/)
    assert.match(main, /\.composer-box\s*\{[^}]*border-radius:\s*var\(--radius/)
    assert.match(main, /\.login-card\s*\{[^}]*border-radius:\s*var\(--radius/)
    assert.match(main, /\.new-pill[^{]*\{[^}]*border-radius:\s*var\(--radius-pill/)
  })

  it('settings nav keeps a radius on the mobile row (no sharp tabs)', () => {
    const src = read('src/pages/settings.vue')
    assert.match(src, /\.settings-nav__link\s*\{[^}]*border-radius:\s*var\(--radius/)
    assert.equal(/border-radius:\s*0/.test(src), false)
  })

  it('selected/active marker bars are one colour and at most 3px in settings nav', () => {
    const src = read('src/pages/settings.vue')
    assert.match(src, /border-inline-start:\s*3px solid transparent/)
    /* CLE-3427 owns the colour (--focus-ring); we assert the 3px ceiling. */
    assert.match(src, /border-inline-start-color:\s*var\(--focus-ring\)/)
  })
})
