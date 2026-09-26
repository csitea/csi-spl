// Static guards: document horizontal scroll on mobile is forbidden.
// Pattern from the donor WUI's tests/unit/no-x-scroll.test.mjs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

describe('no document x-scroll', () => {
  const basePath = join(WUI, 'src/assets/css/base.css')
  it('base.css exists with the donor clip guard', () => {
    assert.equal(existsSync(basePath), true)
    const css = readFileSync(basePath, 'utf8')
    for (const marker of [
      'overflow-x: clip',
      'overflow: hidden',
      'overscroll-behavior: none',
      '100dvh',
      'max-width: 100%',
      'Document horizontal scroll on mobile is FORBIDDEN',
      '#__nuxt',
    ]) {
      assert.equal(css.includes(marker), true, marker)
    }
    assert.equal(/\b100vw\b/.test(css), false, 'no 100vw')
    assert.equal(/overflow-x\s*:\s*scroll/.test(css), false, 'no overflow-x: scroll')
  })

  it('shell layout and feed cannot widen the document', () => {
    const main = readFileSync(join(WUI, 'src/assets/css/main.css'), 'utf8')
    for (const marker of ['max-width: 100%', 'min-width: 0', 'overflow-wrap: anywhere']) {
      assert.equal(main.includes(marker), true, marker)
    }
    assert.equal(/\b100vw\b/.test(main), false, 'main.css has no 100vw')
    const layout = readFileSync(join(WUI, 'src/layouts/default.vue'), 'utf8')
    assert.equal(layout.includes('max-width:100%'), true)
    assert.equal(layout.includes('min-width:0'), true)
    assert.equal(layout.includes('overflow: hidden'), true)
    const login = readFileSync(join(WUI, 'src/layouts/login.vue'), 'utf8')
    assert.equal(login.includes('overflow-y: auto'), true, 'login body scrolls inside the locked window')
    assert.equal(login.includes('min-height: 0'), true)
  })
})
