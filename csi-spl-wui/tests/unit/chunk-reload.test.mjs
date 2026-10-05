// A stale tab after a deploy reloads once into the new build (owner's event
// log 2026-09-26: "Failed to fetch dynamically imported module ...").
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { RELOAD_GUARD_MS, isChunkLoadError, onPreloadError, onUnhandledChunkError, shouldReload } from '../../src/utils/chunk-reload.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

describe('chunk reload', () => {
  it('recognises a missing build chunk in the browsers wording', () => {
    assert.equal(isChunkLoadError(new TypeError('Failed to fetch dynamically imported module: https://example.com/_nuxt/-gF1wazt.js')), true)
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
  it('080 T006: offline, a failed chunk is the network - no reload that would blank the tab', () => {
    const src = readFileSync(join(WUI, 'src/plugins/chunk-reload.client.ts'), 'utf8')
    assert.match(src, /if \(navigator\.onLine === false \|\| !shouldReload\(last\)\) return/)
  })
  it('the plugin listens to vite:preloadError and app:chunkError', () => {
    const src = readFileSync(join(WUI, 'src/plugins/chunk-reload.client.ts'), 'utf8')
    assert.match(src, /'vite:preloadError'/)
    assert.match(src, /'app:chunkError'/)
    assert.match(src, /shouldReload\(/)
  })

  // c-339: wf 10 runs 37376596312 / 37365176316 - a chunk fetch that died
  // (net::ERR_NETWORK_CHANGED) became "Cannot destructure property
  // 'bindShipperToJournal' of 'undefined'" / "reading 'useMobileStack'".
  // Vite's preload helper (vite/dist/node/chunks/config.js preload()), as
  // shipped: preventDefault() turns the rejection into undefined.
  function vitePreload(win, baseModule, deps = []) {
    function handlePreloadError(err) {
      const e = new Event('vite:preloadError', { cancelable: true })
      e.payload = err
      win.dispatchEvent(e)
      if (!e.defaultPrevented) throw err
    }
    return Promise.allSettled(deps).then((res) => {
      for (const item of res) if (item.status === 'rejected') handlePreloadError(item.reason)
      return baseModule().catch(handlePreloadError)
    })
  }
  function armedWindow() {
    const win = new EventTarget()
    const reloads = []
    win.addEventListener('vite:preloadError', (ev) => onPreloadError(ev, () => reloads.push('preload')))
    return { win, reloads }
  }
  it('a failed JS chunk REJECTS the import (never resolves undefined) and reloads once', async () => {
    const { win, reloads } = armedWindow()
    const boom = new TypeError('Failed to fetch dynamically imported module: https://example.com/_nuxt/x.js')
    await assert.rejects(vitePreload(win, () => Promise.reject(boom)), boom)
    assert.deepEqual(reloads, ['preload'])
  })
  it('a .then() on the failed import never runs, so no TypeError page error', async () => {
    const { win } = armedWindow()
    let ran = false
    const p = vitePreload(win, () => Promise.reject(new TypeError('Failed to fetch dynamically imported module: x')))
      .then((m) => { ran = true; return m.useMobileStack() })
    await assert.rejects(p, /Failed to fetch dynamically imported module/)
    assert.equal(ran, false)
  })
  it('a failed JS dep preload rejects too', async () => {
    const { win, reloads } = armedWindow()
    await assert.rejects(vitePreload(win, () => Promise.resolve({ ok: 1 }), [Promise.reject(new Error('Unable to preload x.js'))]))
    assert.deepEqual(reloads, ['preload'])
  })
  it('a failed CSS preload is cancelled: the module still loads (Nuxt does the same)', async () => {
    const { win, reloads } = armedWindow()
    const m = await vitePreload(win, () => Promise.resolve({ ok: 1 }), [Promise.reject(new Error('Unable to preload CSS for /_nuxt/a.css'))])
    assert.deepEqual(m, { ok: 1 })
    assert.deepEqual(reloads, ['preload'])
  })
  it('CONTROL: cancelling a JS failure (the old listener) resolves the import to undefined', async () => {
    const win = new EventTarget()
    win.addEventListener('vite:preloadError', (ev) => ev.preventDefault())
    const m = await vitePreload(win, () => Promise.reject(new TypeError('Failed to fetch dynamically imported module: x')))
    assert.equal(m, undefined)
  })
  it('an uncaught chunk rejection takes the reload path and is marked handled; others are left alone', () => {
    const reloads = []
    const chunk = new Event('unhandledrejection', { cancelable: true })
    chunk.reason = new TypeError('Failed to fetch dynamically imported module: x')
    onUnhandledChunkError(chunk, () => reloads.push(1))
    assert.equal(chunk.defaultPrevented, true)
    const other = new Event('unhandledrejection', { cancelable: true })
    other.reason = new TypeError('Failed to fetch')
    onUnhandledChunkError(other, () => reloads.push(2))
    assert.equal(other.defaultPrevented, false)
    assert.deepEqual(reloads, [1])
  })
  it('the plugin routes both listeners through these helpers and never cancels on its own', () => {
    const src = readFileSync(join(WUI, 'src/plugins/chunk-reload.client.ts'), 'utf8')
    assert.match(src, /'vite:preloadError', \(ev\) => onPreloadError\(ev, reloadOnce\)/)
    assert.match(src, /'unhandledrejection', \(ev\) => onUnhandledChunkError\(ev, reloadOnce\)/)
    assert.doesNotMatch(src, /preventDefault/)
  })
})
