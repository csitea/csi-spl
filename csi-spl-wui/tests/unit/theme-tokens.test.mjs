import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

describe('theme tokens', () => {
  it('variables.css has dark default and light/dark data-theme', () => {
    const css = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
    assert.equal(css.includes('color-scheme: dark'), true)
    assert.equal(css.includes(':root[data-theme="light"]'), true)
    assert.equal(css.includes(':root[data-theme="dark"]'), true)
    assert.equal(css.includes('--color-accent'), true)
    assert.equal(css.includes('--color-bg'), true)
    assert.equal(css.includes('#34d5f0'), true)
    assert.equal(css.includes('#060912'), true)
  })

  it('CLE-34994: every picker theme is a FULL palette, same tokens as light', () => {
    const css = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
    const blockOf = (sel) => {
      const i = css.indexOf(sel + ' {')
      assert.notEqual(i, -1, sel)
      return css.slice(i, css.indexOf('\n}', i))
    }
    const names = (b) => [...b.matchAll(/\s(--[a-z0-9-]+):/g)].map((m) => m[1]).sort()
    const light = names(blockOf(':root[data-theme="light"]'))
    assert.ok(light.length >= 25, `light palette has ${light.length} tokens`)
    for (const id of ['light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']) {
      const b = blockOf(`:root[data-theme="${id}"]`)
      assert.deepEqual(names(b), light, `${id} token set`)
      assert.match(b, /color-scheme: light;/)
    }
  })

  it('carries the donor token scale', () => {
    const css = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
    for (const t of ['--spacing-xl', '--radius-sm', '--radius-pill', '--z-modal', '--color-danger', '--color-success', '--font-display']) {
      assert.equal(css.includes(t + ':'), true, t)
    }
  })

  it('does not copy shop or camp brand fills', () => {
    const css = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
    assert.equal(css.includes('#0a7a4b'), false)
    assert.equal(css.includes('#e86f00'), false)
    assert.equal(css.includes('#faf8f5'), false)
    assert.equal(css.includes('whatsapp'), false)
  })
})
