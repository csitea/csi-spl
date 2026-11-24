// perf round 19 row 05 (SPL-6421): creating the notification store reads the
// browser's Notification.permission 0 times; the idle callback, the bell, the
// first gesture and a site-settings change on return (HUM-24, 311427c6) still
// read it, and the bell and the first gesture read it before they ask.
// Before the read, permission is 'pending': the bell and Settings show it
// neutral, not as a warning or 'unsupported'.
// The real store is bundled with esbuild as the client build (import.meta.client
// true) against stubs for pinia and the names composable; the browser is stubbed
// with a Notification whose `permission` getter counts its reads.
//
// Run: node --test tests/unit/notification-permission-lazy.test.mjs
import { before, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { computed, ref, watch } from 'vue'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

const STUBS = {
  pinia: 'export const defineStore = (_, fn) => fn; export const skipHydrate = (x) => x',
  '~/composables/useHumanNames': 'export const useHumanNames = () => ({ names: { value: {} } })',
  '~/utils/notify-sound.mjs': 'export const playSound = () => {}',
}

let bundled = ''
async function freshStore() {
  if (!bundled) {
    const out = await build({
      entryPoints: [join(WUI, 'src/stores/notification.ts')],
      bundle: true,
      format: 'esm',
      platform: 'neutral',
      write: false,
      define: { 'import.meta.client': 'true' },
      plugins: [{
        name: 'stubs',
        setup(b) {
          b.onResolve({ filter: /^(pinia|~\/.*)$/ }, (a) => (STUBS[a.path]
            ? { path: a.path, namespace: 'stub' }
            : { path: join(WUI, 'src', a.path.slice(2)) + (/\.\w+$/.test(a.path) ? '' : '.ts') }))
          b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js' }))
        },
      }],
    })
    bundled = out.outputFiles[0].text
  }
  const url = `data:text/javascript;base64,${Buffer.from(`${bundled}\n// ${Math.random()}`).toString('base64')}`
  return (await import(url)).useNotificationStore
}

/** A browser: listeners by event, idle callbacks held until run, a counting Notification. */
let b
function browser(state = 'default') {
  const on = (map) => (type, fn) => { (map[type] ??= []).push(fn) }
  const off = (map) => (type, fn) => { map[type] = (map[type] || []).filter((f) => f !== fn) }
  const win = {}
  const doc = {}
  b = { reads: 0, asks: 0, state, idle: [], win, doc }
  class Notification {
    static get permission() { b.reads++; return b.state }
    static async requestPermission() { b.asks++; return b.state }
  }
  Object.assign(globalThis, {
    computed, ref, watch,
    useNuxtApp: () => ({ $i18n: { t: (k) => k }, $localePath: (p) => p }),
    Notification,
    requestIdleCallback: (fn) => b.idle.push(fn),
    window: { addEventListener: on(win), removeEventListener: off(win) },
    document: { hidden: false, addEventListener: on(doc), hasFocus: () => true },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  })
}
const fire = (map, type) => (map[type] || []).forEach((fn) => fn({}))

let useNotificationStore
before(async () => {
  browser()
  useNotificationStore = await freshStore()
})
beforeEach(() => browser())

describe('notification store: Notification.permission is read lazily (p19-05)', () => {
  it('creating the store reads the permission 0 times', () => {
    const s = useNotificationStore()
    assert.equal(b.reads, 0, `permission reads at store creation: ${b.reads}`)
    assert.equal(s.permission.value, 'pending')
  })

  it('before the idle read the bell and Settings show a neutral state, not a warning', async () => {
    const s = useNotificationStore()
    const status = s.alertStatus.value
    assert.notEqual(status, 'unsupported', 'an unread permission is not "unsupported"')
    assert.equal(status, 'pending')
    assert.equal(b.reads, 0, 'rendering the status read nothing')
    const { alertWarns, alertCanTest } = await import('../../src/utils/notify.mjs')
    assert.equal(alertWarns(status), false, 'the bell and Settings draw no warning')
    assert.equal(alertCanTest(status), false, 'Settings offers no test until the browser is read')
    b.state = 'denied'
    b.idle[0]()
    assert.equal(alertWarns(s.alertStatus.value), true, 'a blocked browser still warns after the read')
  })

  it('the idle callback reads it once, and the bell shows the browser state', () => {
    const s = useNotificationStore()
    assert.equal(b.idle.length, 1, 'one idle read is scheduled')
    b.idle[0]()
    assert.equal(b.reads, 1)
    assert.equal(s.alertStatus.value, 'ask')
  })

  it('the bell reads it before it asks, without waiting for the idle callback', async () => {
    b.state = 'granted'
    const s = useNotificationStore()
    s.alertsEnabled.value = false
    await s.toggleAlerts()
    assert.equal(b.reads, 1, 'the bell read the permission')
    assert.equal(b.asks, 0, 'a granted browser is not asked again')
    assert.equal(s.alertsOn.value, true)
  })

  it('the first gesture reads it, then asks once while undecided (HUM-24)', async () => {
    useNotificationStore()
    fire(b.win, 'pointerdown')
    assert.equal(b.reads, 1, 'the gesture read the permission')
    assert.equal(b.asks, 1, 'an undecided browser is asked once')
    fire(b.win, 'pointerdown')
    assert.equal(b.asks, 1, 'the second gesture asks nothing')
  })

  it('a permission changed in site settings shows on return (HUM-24)', () => {
    const s = useNotificationStore()
    b.idle[0]()
    b.state = 'denied'
    fire(b.doc, 'visibilitychange')
    assert.equal(s.alertStatus.value, 'blocked')
  })

  it('a ping before the idle callback reads it, so the first alert still shows', () => {
    b.state = 'granted'
    const s = useNotificationStore()
    s.ping('t', 'b')
    assert.equal(b.reads, 1)
    assert.equal(s.alertsOn.value, true)
  })
})
