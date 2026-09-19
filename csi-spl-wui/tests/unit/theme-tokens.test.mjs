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
