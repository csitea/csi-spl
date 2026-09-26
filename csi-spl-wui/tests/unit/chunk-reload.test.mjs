// A stale tab after a deploy reloads once into the new build (owner's event
// log 2026-09-26: "Failed to fetch dynamically imported module ...").
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { RELOAD_GUARD_MS, isChunkLoadError, shouldReload } from '../../src/utils/chunk-reload.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

describe('chunk reload', () => {
  it('recognises a missing build chunk in the browsers wording', () => {
    assert.equal(isChunkLoadError(new TypeError('Failed to fetch dynamically imported module: https://spool-hub.ai/_nuxt/-gF1wazt.js')), true)
    assert.equal(isChunkLoadError(new TypeError('Importing a module script failed.')), true)
    assert.equal(isChunkLoadError({ message: 'error loading dynamically imported module' }), true)
  })
  it('CONTROL: an ordinary failure is not a chunk failure', () => {
    assert.equal(isChunkLoadError(new TypeError('Failed to fetch')), false)
    assert.equal(isChunkLoadError(null), false)
  })
  it('reloads once, then refuses inside the guard window (no loop)', () => {
    const now = 1_000_000
    assert.equal(shouldReload(0, now), true)
    assert.equal(shouldReload(now - 1000, now), false)
    assert.equal(shouldReload(now - RELOAD_GUARD_MS, now), true)
  })
  it('the plugin listens to vite:preloadError and app:chunkError', () => {
    const src = readFileSync(join(WUI, 'src/plugins/chunk-reload.client.ts'), 'utf8')
    assert.match(src, /'vite:preloadError'/)
    assert.match(src, /'app:chunkError'/)
    assert.match(src, /shouldReload\(/)
  })
})
