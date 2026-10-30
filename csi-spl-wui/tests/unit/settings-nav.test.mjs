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
  MOCK_GCAL_KEY, gcalConnect, gcalDisconnect, gcalReturnNotice, gcalStatus, gcalSync, gcalUrl, gcalView,
} from '../../src/utils/gcal-client.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const en = JSON.parse(read('i18n/locales/en.json'))
const section = read('src/components/settings/calendar-google.vue')

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
