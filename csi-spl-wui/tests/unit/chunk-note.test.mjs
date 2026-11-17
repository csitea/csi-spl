// SPL-4525 (row 3 of SPL-4419): a tab older than a WUI deploy asks for a
// removed /_nuxt/<hash>.js. chunk-reload reloads it, but the vue:error hook of
// error-journal.client.ts journaled every failure as an error: 5 of the last
// 100 prd human_events rows. The hook filter now turns them into ONE info
// "app updated, reloaded" note per page load; any other Vue error stays one.
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { importTs, importTsPatched } from './lib/load-ts.mjs'
import { getErrors, noteError, resetErrorJournal } from '../../src/composables/errorJournal.mjs'

const { APP_UPDATED_NOTE, createChunkNoteFilter } = await importTs('src/utils/chunk-note.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const CHUNK = new TypeError('Failed to fetch dynamically imported module: https://x.example.test/_nuxt/Ab12.js')

describe('vue:error hook filter: a stale chunk is one note, not errors', () => {
  it('the first chunk failure of a page load is the note, the rest are skipped', () => {
    const filter = createChunkNoteFilter()
    assert.deepEqual([filter(CHUNK), filter(CHUNK), filter(new Error('Loading chunk 12 failed'))], ['note', 'skip', 'skip'])
  })

  it('CONTROL: any other Vue error stays an error, before and after the note', () => {
    const filter = createChunkNoteFilter()
    assert.equal(filter(new TypeError("Cannot read properties of undefined (reading 'id')")), 'error')
    assert.equal(filter(CHUNK), 'note')
    assert.equal(filter(new Error('insertBefore')), 'error')
    assert.equal(filter(undefined), 'error')
  })

  it('offline the page does not reload (chunk-reload, 080 T006): the failure stays an error', () => {
    const filter = createChunkNoteFilter(() => false)
    assert.equal(filter(CHUNK), 'error')
    assert.equal(filter(CHUNK), 'error')
  })
})

describe('the note in the journal', () => {
  beforeEach(() => resetErrorJournal())

  it('is info, says "app updated, reloaded" and stays out of the snackbar', () => {
    noteError({ source: 'app-update', ...APP_UPDATED_NOTE }, { isClient: true })
    const [rec] = getErrors()
    assert.equal(rec.source, 'app-update')
    assert.equal(rec.name, 'Info')
    assert.equal(rec.code, 'info.app_updated')
    assert.equal(rec.message, 'app updated, reloaded')
    assert.equal(rec.inline, true)
  })
})

describe('wiring in error-journal.client.ts', () => {
  const src = readFileSync(join(WUI, 'src/plugins/error-journal.client.ts'), 'utf8')
  const hook = src.slice(src.indexOf("nuxtApp.hook('vue:error'"), src.indexOf("nuxtApp.hook('app:error'"))
  const helper = src.slice(src.indexOf('function asAppUpdate('), src.indexOf("nuxtApp.hook('vue:error'"))

  it('the vue:error hook asks the filter before it records', () => {
    assert.ok(src.includes('createChunkNoteFilter(chunkReloadsThisLoad)'), 'filter built on chunk-reload\'s own decision')
    assert.match(helper, /const kind = chunkNote\(err\)/)
    assert.match(helper, /if \(kind === 'note'\) record\('app-update', undefined, APP_UPDATED_NOTE\)/)
    assert.match(helper, /return kind !== 'error'/)
    assert.match(hook, /if \(asAppUpdate\(err\)\) return/)
    assert.ok(hook.indexOf('asAppUpdate(err)') < hook.indexOf("record('vue', err"), 'filter runs first')
  })

  // SPL-5742 (F1): every source of the journal asks the same filter, one per page load.
  it('every record call of the plugin but the note itself sits behind asAppUpdate', () => {
    const body = src.slice(src.indexOf('export default defineNuxtPlugin'))
    const sources = [...body.matchAll(/record\('([\w-]+)'/g)].map((m) => m[1])
    assert.deepEqual([...new Set(sources)].sort(), ['app', 'app-update', 'promise', 'vue', 'window'])
    assert.equal((body.match(/createChunkNoteFilter\(/g) || []).length, 1, 'one filter shared by every source')
    assert.equal((body.match(/if \(asAppUpdate\(/g) || []).length, 4, 'vue, app, window, promise')
  })
})

describe('wiring in error.vue (SPL-5742)', () => {
  const src = readFileSync(join(WUI, 'src/error.vue'), 'utf8')

  it('the error-page notice, which journals on mount, is left out for a stale chunk chunk-reload reloads for', () => {
    assert.match(src, /const staleChunk = import\.meta\.client && isChunkLoadError\(props\.error\) && chunkReloadsThisLoad\(\)/)
    assert.match(src, /<ErrorNotice\s+v-if="!is404 && !staleChunk"/)
    assert.match(src, /source="error-page"/)
  })
})

// R7 W1: the note must follow chunk-reload's OWN reload decision. Inside its
// 10 s guard (a second failure right after a reload: a broken deploy, a
// hosting outage) chunk-reload does not reload, so the failure is a real error.
// These drive the two real plugins against a stub window and journal.
describe('the note follows chunk-reload\'s reload decision (behaviour)', () => {
  const KEY = 'spool.chunk-reload-at'
  const store = new Map()
  const reloads = []
  let online = true
  let win
  Object.assign(globalThis, {
    defineNuxtPlugin: (fn) => fn,
    sessionStorage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)) },
  })
  Object.defineProperty(globalThis, 'navigator', { configurable: true, get: () => ({ onLine: online }) })

  /** One page load: a fresh window, both plugins set up afresh, their hooks returned. */
  async function pageLoads() {
    win = new EventTarget()
    win.location = { reload: () => reloads.push(Date.now()) }
    globalThis.window = win
    const { default: chunkReload } = await importTs('src/plugins/chunk-reload.client.ts')
    const { default: journal } = await importTsPatched('src/plugins/error-journal.client.ts',
      "from '@/composables/errorJournal.mjs'", "from '~/composables/errorJournal.mjs'; import.meta.client = true")
    const hooks = {}
    const nuxtApp = { hook: (name, fn) => { hooks[name] = fn } }
    chunkReload(nuxtApp)
    journal(nuxtApp)
    return hooks
  }
  const pageLoad = async () => (await pageLoads())['vue:error']
  /** A chunk failure no caller caught, as the browser dispatches it. */
  function rejection(reason) {
    const ev = new Event('unhandledrejection', { cancelable: true })
    ev.reason = reason
    win.dispatchEvent(ev)
  }
  function windowError(error) {
    const ev = new Event('error')
    ev.error = error
    ev.message = String(error?.message || '')
    win.dispatchEvent(ev)
  }
  function preloadError() {
    const ev = new Event('vite:preloadError', { cancelable: true })
    ev.payload = CHUNK
    win.dispatchEvent(ev)
  }
  const settle = () => new Promise((r) => setTimeout(r, 50))
  const sources = () => getErrors().map((r) => r.source)

  beforeEach(() => { resetErrorJournal(); store.clear(); reloads.length = 0; online = true })

  it('a stale chunk that reloads the tab is the note, even though the reload wrote its key first', async () => {
    const vueError = await pageLoad()
    preloadError()
    vueError(CHUNK, null, '')
    await settle()
    assert.equal(reloads.length, 1, 'chunk-reload reloaded')
    assert.deepEqual(sources(), ['app-update'])
  })

  it('vue:error before chunk-reload acts: still the note, and chunk-reload then reloads', async () => {
    const vueError = await pageLoad()
    vueError(CHUNK, null, '')
    preloadError()
    await settle()
    assert.equal(reloads.length, 1)
    assert.deepEqual(sources(), ['app-update'])
  })

  it('W1: a chunk failure inside the 10 s guard after a reload does not reload, so it stays an error', async () => {
    store.set(KEY, String(Date.now() - 3000))
    const vueError = await pageLoad()
    preloadError()
    vueError(CHUNK, null, '')
    await settle()
    assert.equal(reloads.length, 0, 'chunk-reload refused inside its guard')
    assert.deepEqual(sources(), ['vue'])
  })

  it('offline chunk-reload does not reload: the failure stays an error', async () => {
    online = false
    const vueError = await pageLoad()
    preloadError()
    vueError(CHUNK, null, '')
    await settle()
    assert.equal(reloads.length, 0)
    assert.deepEqual(sources(), ['vue'])
  })

  // SPL-5742 (F1): prd 2026-11-03..17 kept 19 promise + 9 app + 1 error-page
  // chunk-load rows: only vue:error asked the filter. Each source now asks it.
  it('F1: a chunk rejection that reloads the tab is the note, not a promise error', async () => {
    await pageLoads()
    rejection(CHUNK)
    await settle()
    assert.equal(reloads.length, 1, 'chunk-reload reloaded')
    assert.deepEqual(sources(), ['app-update'])
  })

  it('F1: a chunk failure through app:error (showError, the error page) is the note, not an app error', async () => {
    const hooks = await pageLoads()
    preloadError()
    hooks['app:error'](CHUNK)
    await settle()
    assert.deepEqual(sources(), ['app-update'])
  })

  it('F1: one stale chunk seen by every source is ONE note for the page load', async () => {
    const hooks = await pageLoads()
    preloadError()
    const chunk = () => new TypeError(CHUNK.message)
    hooks['vue:error'](chunk(), null, '')
    hooks['app:error'](chunk())
    rejection(chunk())
    windowError(chunk())
    await settle()
    assert.equal(reloads.length, 1)
    assert.deepEqual(sources(), ['app-update'])
  })

  it('F1 CONTROL: inside the 10 s guard every source keeps its error', async () => {
    store.set(KEY, String(Date.now() - 3000))
    const hooks = await pageLoads()
    /* three failures, three objects: the journal merges one object's records */
    const chunk = () => new TypeError(CHUNK.message)
    hooks['app:error'](chunk())
    rejection(chunk())
    windowError(chunk())
    await settle()
    assert.equal(reloads.length, 0)
    assert.deepEqual(sources().sort(), ['app', 'promise', 'window'])
  })

  it('F1 CONTROL: any other rejection or app error is still recorded as before', async () => {
    const hooks = await pageLoads()
    hooks['app:error'](new Error('plugin failed'))
    rejection(new TypeError("Cannot read properties of null (reading 'x')"))
    await settle()
    assert.equal(reloads.length, 0)
    assert.deepEqual(sources().sort(), ['app', 'promise'])
  })
})
