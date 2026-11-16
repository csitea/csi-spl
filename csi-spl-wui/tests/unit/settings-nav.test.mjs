// Spec 149 B8 (SPL-3227): Settings -> Google Calendar.
//   C25  SETTINGS_SECTIONS has 8 ids, calendar-google last, and the hyphened
//        id is a section everywhere a section id is read (query, old path)
//   C25b a workspace outside gcal.workspaces (the hub's 404, the mock's 'off'):
//        the section shows "not available here" and no Connect button
//   C27  the section is its own chunk: one lazy import in SettingsDialog.vue
// plus the client's routes and views, and every gcal.* key the section names
// in en.json (the placeholder title of section 2.5 included).
//
// Red control: on origin/master before B8 this file fails C25 (7 ids) and the
// rest (no components/settings/calendar-google.vue, no utils/gcal-client.mjs).
//
// Run: node tests/unit/settings-nav.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SETTINGS_SECTIONS, isSettingsPath, settingsModalTarget, settingsQuerySection, settingsSectionOf,
} from '../../src/utils/settings-nav.mjs'
import {
  MOCK_GCAL_KEY, gcalBannerKey, gcalConnect, gcalDisconnect, gcalReturnNotice, gcalStatus, gcalSync, gcalSyncFollower, gcalUrl, gcalView,
} from '../../src/utils/gcal-client.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const en = JSON.parse(read('i18n/locales/en.json'))
const section = read('src/components/settings/calendar-google.vue')
const banner = read('src/components/CalendarGcalBanner.vue')

/** a Map-backed localStorage for the mock half */
function mockStorage() {
  const m = new Map()
  globalThis.localStorage = {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
  }
  return m
}

describe('C25 the section list', () => {
  it('has calendar-google after keys, with its catalogue label (spec 155 B10 appends notes)', () => {
    assert.equal(SETTINGS_SECTIONS.length, 9)
    const at = SETTINGS_SECTIONS.findIndex((s) => s.id === 'calendar-google')
    assert.equal(SETTINGS_SECTIONS[at - 1].id, 'keys')
    assert.equal(SETTINGS_SECTIONS[at].label, 'settings.calendar_google')
    assert.equal(typeof en.settings.calendar_google, 'string')
  })
  it('reads the hyphened id from a query and an old address', () => {
    assert.equal(settingsQuerySection({ settings: 'calendar-google' }), 'calendar-google')
    assert.equal(settingsSectionOf('/settings/calendar-google'), 'calendar-google')
    assert.equal(settingsSectionOf('/fi/settings/calendar-google/'), 'calendar-google')
    assert.ok(isSettingsPath('/fi/settings/calendar-google'))
    assert.deepEqual(settingsModalTarget('/settings/calendar-google', null), { path: '/lobby', query: { settings: 'calendar-google' } })
  })
  it('CONTROL: an unknown hyphened id is still no section', () => {
    assert.equal(settingsQuerySection({ settings: 'calendar-bogus' }), '')
    assert.equal(settingsSectionOf('/settings/calendar-bogus'), '')
  })
})

describe('C25b not available in this workspace', () => {
  it('the hub 404 and 503 are views of their own, never the Connect view', () => {
    assert.equal(gcalView(null, { status: 404 }), 'off')
    assert.equal(gcalView(null, { status: 503 }), 'not_configured')
    assert.equal(gcalView(null, { status: 0 }), 'failed')
    assert.equal(gcalView({ connected: false }, null), 'disconnected')
  })
  it('the mock answers 404 for a workspace that is off', async () => {
    mockStorage().set(MOCK_GCAL_KEY, 'off')
    await assert.rejects(gcalStatus({ mock: true }), (e) => e.status === 404 && e.error === 'not_found')
  })
  it('the off branch shows the unavailable text and the Connect button lives only in the disconnected branch', () => {
    const off = /v-else-if="view === 'off'"[^>]*data-test="gcal-off">\{\{ t\('gcal\.unavailable'\) \}\}/
    assert.match(section, off)
    const branch = section.split(`<template v-else-if="view === 'disconnected'">`)
    assert.equal(branch.length, 2)
    assert.ok(!branch[0].includes('data-test="gcal-connect"'), 'no Connect before the disconnected branch')
    assert.ok(branch[1].split('</template>')[0].includes('data-test="gcal-connect"'))
  })
})

describe('the connection views and the mock flow', () => {
  it('connected and broken', () => {
    assert.equal(gcalView({ connected: true, status: 'connected' }, null), 'connected')
    assert.equal(gcalView({ connected: true, status: 'revoked' }, null), 'broken')
    assert.equal(gcalView({ connected: true, status: 'error' }, null), 'broken')
  })
  it('connect, sync and disconnect in the mock', async () => {
    mockStorage()
    const api = { mock: true }
    assert.deepEqual(await gcalStatus(api), { connected: false })
    assert.equal(await gcalConnect(api), '')
    const on = await gcalStatus(api)
    assert.equal(on.connected, true)
    assert.equal(on.google_email, 'member@example.com')
    await gcalSync(api)
    await gcalDisconnect(api, true)
    assert.deepEqual(await gcalStatus(api), { connected: false })
  })
  it('the routes of spec 149 section 4, the workspace first', () => {
    const api = { base: 'https://hub.example.com/', tenant: 'w2' }
    assert.equal(gcalUrl(api, '', null), 'https://hub.example.com/v1/me/google-calendar?workspace=w2')
    assert.equal(gcalUrl(api, '/connect', null), 'https://hub.example.com/v1/me/google-calendar/connect?workspace=w2')
    assert.equal(gcalUrl(api, '', { remove_imported: 1 }), 'https://hub.example.com/v1/me/google-calendar?workspace=w2&remove_imported=1')
    assert.equal(gcalUrl({ base: '' }, '/sync', null), '/v1/me/google-calendar/sync')
  })
  it('the callback way back names its notice', () => {
    assert.equal(gcalReturnNotice({ settings: 'calendar-google', gcal: 'connected' }), 'gcal.notice_connected')
    assert.equal(gcalReturnNotice({ gcal_error: 'cancelled' }), 'gcal.notice_error')
    assert.equal(gcalReturnNotice({ settings: 'calendar-google' }), '')
  })
})

// SPL-5726: prd 2026-11-16, the browser requested the OAuth callback twice
// 0.4 s apart; the first connected, the second found its code used and sent
// ?gcal_error=code_expired, so the panel said "was not connected" next to
// "Connected". Red control: on origin/master 55dcf0449 the error shows for a
// connected status (gcalReturnNotice ignores the view) and sync_busy is red.
describe('SPL-5726 the callback error shows only while it is true', () => {
  const q = { settings: 'calendar-google', gcal_error: 'code_expired' }
  it('a status read of connected clears it', () => {
    assert.equal(gcalReturnNotice(q, 'connected'), '')
  })
  it('it waits for the status read', () => {
    assert.equal(gcalReturnNotice(q, 'loading'), '')
  })
  it('it stays when the status says it is true', () => {
    for (const v of ['disconnected', 'broken', 'failed']) assert.equal(gcalReturnNotice(q, v), 'gcal.notice_error', v)
  })
  it('the connected notice is unchanged', () => {
    assert.equal(gcalReturnNotice({ gcal: 'connected' }, 'connected'), 'gcal.notice_connected')
  })
  it('the section passes its view, and "a sync is already running" is not a warning', () => {
    assert.match(section, /gcalReturnNotice\([^)]*,\s*view\.value\)/)
    assert.match(section, /said\('gcal\.sync_busy'\)/)
    assert.doesNotMatch(section, /'gcal\.sync_busy'[^\n]*,\s*true\)/)
  })
  it('Sync now re-reads until the last sync moves, and leaving the page stops it', () => {
    assert.match(section, /follower\.start\(before\)/)
    assert.match(section, /onBeforeUnmount\(\(\) => follower\.stop\(\)\)/)
  })
})

// SPL-5726 review W1/N2: the re-read run driven with hand-fired timers and
// reads the test resolves. Red control: the first version re-armed a timer
// from a read that landed after the page was left (5 more GETs over 25 s).
describe('SPL-5726 gcalSyncFollower', () => {
  function rig() {
    const timers = []
    const pending = []
    const seen = []
    const f = gcalSyncFollower(
      () => new Promise((res) => pending.push(res)),
      (st) => seen.push(st),
      { reads: 6, ms: 1, setT: (fn) => { timers.push(fn); return timers.length }, clearT: (id) => { timers[id - 1] = null } },
    )
    const live = () => timers.filter(Boolean).length
    const fire = () => { const i = timers.findIndex(Boolean); const fn = timers[i]; timers[i] = null; fn() }
    const tick = () => new Promise((r) => setImmediate(r))
    return { f, pending, seen, live, fire, tick }
  }
  it('reads until last_synced_at moves', async () => {
    const r = rig()
    r.f.start('t0')
    r.fire(); r.pending.shift()({ last_synced_at: 't0' }); await r.tick()
    assert.equal(r.live(), 1)
    r.fire(); r.pending.shift()({ last_synced_at: 't1' }); await r.tick()
    assert.equal(r.live(), 0)
    assert.equal(r.seen.length, 2)
  })
  it('stops after its reads run out', async () => {
    const r = rig()
    r.f.start('t0')
    let reads = 0
    while (r.live()) { r.fire(); reads++; r.pending.shift()({ last_synced_at: 't0' }); await r.tick() }
    assert.equal(reads, 6)
  })
  it('stop() during a read in flight: the read is dropped and nothing re-arms (W1)', async () => {
    const r = rig()
    r.f.start('t0')
    r.fire()
    r.f.stop()
    r.pending.shift()({ last_synced_at: 't0' }); await r.tick()
    assert.equal(r.live(), 0)
    assert.equal(r.pending.length, 0)
    assert.equal(r.seen.length, 0)
  })
  it('a second start() during a read in flight leaves one run (N2)', async () => {
    const r = rig()
    r.f.start('t0')
    r.fire()
    r.f.start('t0')
    r.pending.shift()({ last_synced_at: 't0' }); await r.tick()
    assert.equal(r.live(), 1)
    assert.equal(r.seen.length, 0)
  })
  it('a failed read stays quiet and the run goes on', async () => {
    const r = rig()
    r.f.start('t0')
    r.fire(); r.pending.shift()(Promise.reject(new Error('network'))); await r.tick()
    assert.equal(r.seen.length, 0)
    assert.equal(r.live(), 1)
  })
})

// SPL-5719: a connection Google ended (invalid_grant) or one in error shows
// on the Calendar page with Reconnect; nothing else does. Red control: on
// origin/master before SPL-5719 there is no gcalBannerKey and no banner file.
describe('SPL-5719 the Calendar page banner', () => {
  it('only a broken connection names a key', () => {
    assert.equal(gcalBannerKey({ connected: true, status: 'revoked', status_detail: 'x' }), 'gcal.status_revoked')
    assert.equal(gcalBannerKey({ connected: true, status: 'error' }), 'gcal.status_error')
    assert.equal(gcalBannerKey({ connected: true, status: 'connected' }), '')
    assert.equal(gcalBannerKey({ connected: false }), '')
    assert.equal(gcalBannerKey(null), '')
  })
  it('calendar.vue loads the banner lazily, signed in only', () => {
    const page = read('src/pages/calendar.vue')
    assert.ok(page.includes("defineAsyncComponent(() => import('~/components/CalendarGcalBanner.vue'))"))
    assert.ok(/<CalendarGcalBanner v-if="session\.state === 'in'" \/>/.test(page))
    assert.ok(!/from\s+'~\/utils\/gcal-client/.test(page))
  })
  it('the banner reuses keys that exist: no new text', () => {
    const named = [...banner.matchAll(/t\('([a-z_]+\.[a-z_]+)'\)/g)].map((m) => m[1])
    assert.ok(named.includes('gcal.reconnect') && named.includes('settings.calendar_google'), named.join(','))
    for (const k of named) {
      const [ns, leaf] = k.split('.')
      assert.equal(typeof en[ns][leaf], 'string', k)
    }
  })
})

describe('C27 its own chunk', () => {
  it('SettingsDialog.vue imports the section lazily, once', () => {
    const dialog = read('src/components/SettingsDialog.vue')
    const lazy = "'calendar-google': defineAsyncComponent(() => import('~/components/settings/calendar-google.vue'))"
    assert.ok(dialog.includes(lazy))
    assert.equal(dialog.split('settings/calendar-google.vue').length, 2)
    assert.ok(!/import\s+\w+\s+from\s+'~\/utils\/gcal-client/.test(dialog))
  })
})

describe('the catalogue', () => {
  it('every gcal.* key the section names is in en.json, the placeholder title too', () => {
    const named = new Set([...section.matchAll(/'(gcal\.[a-z_]+)'/g)].map((m) => m[1]))
    assert.ok(named.size >= 20, `found ${named.size}`)
    for (const k of named) assert.equal(typeof en.gcal[k.slice(5)], 'string', k)
    assert.equal(en.gcal.untitled_event, '(No title)')
  })
  it('pnpm test runs this suite', () => {
    const s = runsInUnitSuite(import.meta.url)
    assert.ok(s.ok, s.why)
  })
})
