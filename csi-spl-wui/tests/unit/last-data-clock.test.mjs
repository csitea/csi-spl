// The top-bar "last updated" clock: local HH:mm:ss, stamped once per
// successful hub response, not on a timer.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  formatLastDataClock,
  formatLastDataDate,
  lastDataAt,
  noteLastData,
  onLastData,
  resetLastData,
} from '../../src/utils/last-data.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { createLiveClient } from '../../src/utils/live-ws.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const pad = (n) => String(n).padStart(2, '0')
const localClock = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
const wait = (ms = 40) => new Promise((r) => setTimeout(r, ms))

function fakeWs() {
  const sockets = []
  class FakeWS {
    constructor(url) { this.url = url; this.sent = []; sockets.push(this) }
    send(s) { this.sent.push(JSON.parse(s)) }
    close() { if (this.onclose) this.onclose() }
    recv(obj) { if (this.onmessage) this.onmessage({ data: typeof obj === 'string' ? obj : JSON.stringify(obj) }) }
  }
  return { FakeWS, sockets }
}

describe('formatLastDataClock', () => {
  it('prints local HH:mm:ss, zero-padded, 24-hour', () => {
    const evening = new Date(2026, 9, 4, 20, 31, 7)
    const morning = new Date(2026, 0, 1, 1, 2, 3)
    const midnight = new Date(2026, 0, 1, 0, 0, 0)
    assert.equal(formatLastDataClock(evening.getTime()), '20:31:07')
    assert.equal(formatLastDataClock(morning.getTime()), '01:02:03')
    assert.equal(formatLastDataClock(midnight.getTime()), '00:00:00')
    assert.equal(formatLastDataClock(evening.getTime()), localClock(evening))
    assert.equal(formatLastDataDate(evening.getTime()), `2026-10-04 ${localClock(evening)}`)
  })

  it('uses the local clock, not UTC', () => {
    const src = read('src/utils/last-data.mjs')
    assert.match(src, /getHours\(\)/)
    assert.doesNotMatch(src, /getUTC/)
    const d = new Date(2026, 5, 15, 15, 4, 5)
    assert.equal(formatLastDataClock(d.getTime()), localClock(d))
    if (d.getTimezoneOffset() !== 0) {
      const utc = `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`
      assert.notEqual(formatLastDataClock(d.getTime()), utc)
    }
  })

  it('is the placeholder before any instant', () => {
    for (const v of [0, -1, null, undefined, Number.NaN, Number.POSITIVE_INFINITY]) {
      assert.equal(formatLastDataClock(v), '--:--:--')
    }
    assert.equal(formatLastDataDate(0), '')
  })
})

describe('noteLastData', () => {
  it('stores one number and paints once per frame', async () => {
    resetLastData()
    let n = 0
    let last = 0
    onLastData((v) => { n += 1; last = v })
    noteLastData(1_000)
    noteLastData(2_000)
    noteLastData(3_000)
    assert.equal(n, 0)
    assert.equal(lastDataAt(), 3_000)
    await wait()
    assert.equal(n, 1)
    assert.equal(last, 3_000)
    noteLastData(4_000)
    noteLastData(5_000)
    await wait()
    assert.equal(n, 2)
    assert.equal(last, 5_000)
  })

  it('a listener that throws does not drop the stamp or the next listener', async () => {
    resetLastData()
    let last = 0
    onLastData(() => { throw new Error('clock') })
    onLastData((v) => { last = v })
    noteLastData(8_000)
    await wait()
    assert.equal(last, 8_000)
    assert.equal(lastDataAt(), 8_000)
  })
})

describe('the shared hooks', () => {
  it('a hub 2xx stamps and a 500 or a dropped connection does not', async () => {
    resetLastData()
    const ok = createSpoolClient({
      mock: false,
      base: 'https://hub.invalid',
      fetchFn: async () => ({ ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ ok: true }) }),
    })
    const t0 = Date.now()
    await ok.healthz()
    assert.ok(lastDataAt() >= t0)

    resetLastData()
    const denied = createSpoolClient({
      mock: false,
      base: 'https://hub.invalid',
      fetchFn: async () => ({ ok: false, status: 500, headers: { get: () => 'application/json' }, json: async () => ({ error: 'down' }) }),
    })
    await assert.rejects(() => denied.healthz())
    assert.equal(lastDataAt(), 0)

    resetLastData()
    const offline = createSpoolClient({
      mock: false,
      base: 'https://hub.invalid',
      fetchFn: async () => { throw new Error('unreachable') },
    })
    await assert.rejects(() => offline.healthz())
    await wait()
    assert.equal(lastDataAt(), 0)
  })

  it('a mock response stamps, because that client has no HTTP', async () => {
    resetLastData()
    const c = createSpoolClient({ mock: true, base: 'https://hub.invalid' })
    const t0 = Date.now()
    await c.listMessages({ channel: 'lobby' })
    assert.ok(lastDataAt() >= t0)
    assert.match(formatLastDataClock(lastDataAt()), /^\d{2}:\d{2}:\d{2}$/)
  })

  it('a live frame stamps and an error frame does not', async () => {
    resetLastData()
    let n = 0
    onLastData(() => { n += 1 })
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://hub.invalid/v1/wui/ws', WebSocketImpl: FakeWS })
    c.connect()
    sockets[0].recv({ type: 'error', error: 'refused' })
    await wait()
    assert.equal(n, 0)
    assert.equal(lastDataAt(), 0)
    sockets[0].recv({ type: 'welcome', as: 'HUM-1' })
    sockets[0].recv({ type: 'message', msg_id: 'm1', body: 'hi', task_id: 't1' })
    sockets[0].recv('not-json')
    assert.equal(n, 0)
    await wait()
    assert.equal(n, 1)
    assert.ok(lastDataAt() > 0)
  })
})

describe('wiring', () => {
  it('the clock sits right of the version (sidebar foot, phone strip), the top bar only as the fallback, and nothing ticks', () => {
    const bar = read('src/components/TopBar.vue')
    const clock = read('src/components/LastDataClock.vue')
    const side = read('src/components/ChannelSidebar.vue')
    const strip = read('src/components/MobileStatusStrip.vue')
    const host = read('src/composables/useClockHost.ts')
    // desktop: the footer row, straight after the version wrap
    assert.match(side, /data-test="app-version-wrap"[\s\S]*?<\/span>\s*<\/span>\s*(<!--[\s\S]*?-->\s*)?<LastDataClock v-if="clockHost\.foot\.value"/)
    // phone: the status strip, straight after the version button
    assert.match(strip, /data-test="status-strip-version"[\s\S]*?<\/button>\s*(<!--[\s\S]*?-->\s*)?<LastDataClock v-if="clockHost\.strip\.value"/)
    // the top bar: only while neither version is on screen - one clock per screen
    assert.match(bar, /<LastDataClock v-if="clockHost\.bar\.value"/)
    assert.match(host, /bar = computed\(\(\) => !foot\.value && !strip\.value\)/)
    for (const src of [side, strip, bar]) assert.equal((src.match(/<LastDataClock/g) || []).length, 1)
    assert.match(clock, /formatLastDataClock/)
    assert.match(clock, /data-test="last-data-clock"/)
    assert.doesNotMatch(clock, /setInterval|setTimeout/)
    assert.match(read('src/utils/spool-client.mjs'), /noteLastData\(/)
    assert.match(read('src/utils/live-ws.mjs'), /noteLastData\(/)
    assert.doesNotMatch(read('src/composables/useLive.ts'), /noteLastData/)
  })

  it('every locale names it last updated', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const top = JSON.parse(readFileSync(join(dir, f), 'utf8')).topbar || {}
      assert.ok(top.last_updated && top.last_updated.trim(), f)
      assert.match(top.last_updated_title || '', /\{date\}/, f)
    }
  })
})
