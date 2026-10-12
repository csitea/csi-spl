// The second i18n catalogue never blocks the app for longer than a bound
// (src/utils/i18n-more-boot.mjs): a cold /issues load on prd showed only the
// shell for 33 s while that chunk was slow (2026-10-12 16:55:12Z).
// tests/e2e/i18n-split.test.mjs holds the chunk in Chrome; this proves the
// helper and that the plugin's two waits go through it.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { MORE_WAIT_MS, boundedWait } from '../../src/utils/i18n-more-boot.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const plugin = readFileSync(join(WUI, 'src/plugins/i18n-more.client.ts'), 'utf8')

describe('boundedWait', () => {
  it('answers false once the bound passes on a promise that never settles', async () => {
    const t0 = Date.now()
    assert.equal(await boundedWait(new Promise(() => {}), 30), false)
    assert.ok(Date.now() - t0 < 1000)
  })
  it('answers true when the promise fulfils first', async () => {
    assert.equal(await boundedWait(Promise.resolve('x'), 1000), true)
  })
  it('answers true, never rejects, when the promise rejects first', async () => {
    assert.equal(await boundedWait(Promise.reject(new Error('chunk')), 1000), true)
  })
  it('clears its timer once the promise settled', async () => {
    let cleared = 0
    await boundedWait(Promise.resolve(), 1000, { set: setTimeout, clear: (t) => { cleared++; clearTimeout(t) } })
    assert.equal(cleared, 1)
  })
  it('bounds a few seconds: long enough for a normal load, short against a stuck one', () => {
    assert.ok(MORE_WAIT_MS >= 2000 && MORE_WAIT_MS <= 8000, String(MORE_WAIT_MS))
  })
})

describe('plugins/i18n-more.client.ts', () => {
  it('awaits the catalogue only through boundedWait, at boot and before a route', () => {
    assert.match(plugin, /from '~\/utils\/i18n-more-boot\.mjs'/)
    const waits = plugin.match(/await [^\n]*\bload\(/g) || []
    assert.deepEqual(waits.filter((w) => !/await boundedWait\(load\(/.test(w)), [], 'an unbounded await of load()')
    assert.equal((plugin.match(/await boundedWait\(load\(/g) || []).length, 2)
  })
})
