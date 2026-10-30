// Spec 155 B10 (SPL-4331): Settings -> Notes, export and erase.
//   C31 (unit half) the section is listed and reachable at /settings/notes;
//       the export is named notes-<date>.json; Erase needs the typed word,
//       a wrong word erases nothing; the hub calls are the realm routes
//       (no workspace header); on the mock bundle both go through the store
//   its own chunk: one lazy import in SettingsDialog.vue
// The browser half (a download, the list empty after Erase, 390 px) is
// tests/e2e/settings-notes.test.mjs.
//
// Red control: on origin/master before B10 this file fails (no
// utils/notes-data.mjs, no 'notes' in SETTINGS_SECTIONS).
//
// Run: node tests/unit/settings-notes.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { SETTINGS_SECTIONS, settingsQuerySection, settingsSectionOf } from '../../src/utils/settings-nav.mjs'
import { eraseConfirmed, eraseNotes, exportNotes, notesDownloadName, notesExportName } from '../../src/utils/notes-data.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const en = JSON.parse(read('i18n/locales/en.json'))
const section = read('src/components/settings/notes.vue')

/** a fetch that records each call and answers `answer(url, init)` */
function stubFetch(answer) {
  const calls = []
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', headers: { ...(init.headers || {}) } })
    return answer(String(url), init)
  }
  return calls
}

/**
 * the notes store's surface the util reads: load, notes, hidden, get, remove.
 * `held` are ids deleted on the Notes page and waiting on their Undo toast:
 * the list leaves them out, as stores/notes.ts does.
 */
function fakeStore(rows, held = []) {
  const s = {
    all: rows.map((r) => ({ ...r })),
    notes: [],
    hidden: [...held],
    loads: 0,
    removed: [],
    async load() { s.loads++; s.notes = s.all.filter((n) => !s.hidden.includes(n.id)).map((n) => ({ id: n.id, title: n.title })) },
    async get(id) { const n = s.all.find((x) => x.id === id); return n ? { note: { ...n } } : { missing: true } },
    async remove(id) { s.removed.push(id); s.hidden = s.hidden.filter((x) => x !== id); s.all = s.all.filter((n) => n.id !== id); return true },
  }
  return s
}

describe('C31 the section', () => {
  it('is the last section, with its catalogue label', () => {
    assert.equal(SETTINGS_SECTIONS.at(-1).id, 'notes')
    assert.equal(SETTINGS_SECTIONS.at(-1).label, 'notes.settings.title')
    assert.equal(en.notes.settings.title, 'Notes')
  })
  it('opens from ?settings=notes and the old /settings/notes address', () => {
    assert.equal(settingsQuerySection({ settings: 'notes' }), 'notes')
    assert.equal(settingsSectionOf('/settings/notes'), 'notes')
    assert.equal(settingsSectionOf('/fi/settings/notes/'), 'notes')
  })
  it('SettingsDialog.vue imports it lazily, once', () => {
    const dialog = read('src/components/SettingsDialog.vue')
    assert.ok(dialog.includes("notes: defineAsyncComponent(() => import('~/components/settings/notes.vue'))"))
    assert.equal(dialog.split('settings/notes.vue').length, 2)
    assert.ok(!/notes-data/.test(dialog))
  })
  it('every notes.* key the section names is in en.json', () => {
    const named = new Set([...section.matchAll(/'(notes\.[a-z_.]+)'/g)].map((m) => m[1]))
    assert.ok(named.size >= 8, `found ${named.size}`)
    for (const k of named) {
      const v = k.split('.').reduce((o, p) => (o ? o[p] : undefined), en)
      assert.equal(typeof v, 'string', k)
    }
  })
})

describe('C31 the confirmation word', () => {
  it('admits the word, case and outer spaces aside', () => {
    assert.ok(eraseConfirmed('erase', 'erase'))
    assert.ok(eraseConfirmed('  ERASE ', 'erase'))
  })
  it('CONTROL: a wrong, partial or empty word is refused', () => {
    assert.ok(!eraseConfirmed('eras', 'erase'))
    assert.ok(!eraseConfirmed('delete', 'erase'))
    assert.ok(!eraseConfirmed('', 'erase'))
    assert.ok(!eraseConfirmed('', ''))
  })
})

describe('C31 the file name', () => {
  it('is notes-<UTC date>.json', () => {
    assert.equal(notesExportName(new Date('2026-10-30T23:30:00Z')), 'notes-2026-10-30.json')
  })
  it("takes the hub's Content-Disposition name, else the fallback", () => {
    assert.equal(notesDownloadName('attachment; filename="notes-2026-10-29.json"', 'x.json'), 'notes-2026-10-29.json')
    assert.equal(notesDownloadName('attachment; filename="../evil.sh"', 'notes-2026-10-30.json'), 'notes-2026-10-30.json')
    assert.equal(notesDownloadName(null, 'notes-2026-10-30.json'), 'notes-2026-10-30.json')
  })
})

describe('C31 the hub calls', () => {
  const api = { base: 'https://hub.example.com/', token: 'tok', mock: false }
  it('export GETs /v1/me/realm/notes/export with no workspace header', async () => {
    const calls = stubFetch(() => new Response('{"exported_at":"x","notes":[]}', { status: 200, headers: { 'content-disposition': 'attachment; filename="notes-2026-10-29.json"' } }))
    const store = fakeStore([])
    const got = await exportNotes(api, store, new Date('2026-10-30T10:00:00Z'))
    assert.equal(calls.length, 1)
    assert.equal(calls[0].url, 'https://hub.example.com/v1/me/realm/notes/export')
    assert.equal(calls[0].method, 'GET')
    assert.equal(calls[0].headers.authorization, 'Bearer tok')
    assert.ok(!Object.keys(calls[0].headers).some((h) => /tenant/i.test(h)))
    assert.equal(got.name, 'notes-2026-10-29.json')
    assert.equal(await got.blob.text(), '{"exported_at":"x","notes":[]}')
    assert.equal(store.loads, 0)
  })
  it('erase DELETEs /v1/me/realm/notes, then reads the list again', async () => {
    const calls = stubFetch(() => new Response(null, { status: 204 }))
    const store = fakeStore([])
    await eraseNotes(api, store)
    assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), ['DELETE https://hub.example.com/v1/me/realm/notes'])
    assert.equal(store.loads, 1)
  })
  it('SPL-4390: a note waiting on its Undo is no longer held after the erase, and no DELETE of its own goes', async () => {
    const calls = stubFetch(() => new Response(null, { status: 204 }))
    const store = fakeStore([], ['held'])
    await eraseNotes(api, store)
    assert.deepEqual(store.hidden, [])
    assert.equal(calls.length, 1)
    assert.deepEqual(store.removed, [])
  })
  it('a refusal throws its token (notes_off), and the list is not reread', async () => {
    stubFetch(() => new Response('{"error":"notes_off"}', { status: 404 }))
    const store = fakeStore([])
    await assert.rejects(eraseNotes(api, store), (e) => e.token === 'notes_off' && e.status === 404)
    await assert.rejects(exportNotes(api, store), (e) => e.token === 'notes_off')
    assert.equal(store.loads, 0)
  })
})

describe('C31 on the mock bundle', () => {
  const api = { base: '', mock: true }
  const rows = [{ id: 'a', title: 'One', archived: false }, { id: 'b', title: 'Two', archived: true }]
  it('export holds every note whole, archived ones too, and sends nothing', async () => {
    const calls = stubFetch(() => { throw new Error('no hub on the mock') })
    const got = await exportNotes(api, fakeStore(rows), new Date('2026-10-30T10:00:00Z'))
    const body = JSON.parse(await got.blob.text())
    assert.equal(got.name, 'notes-2026-10-30.json')
    assert.equal(body.exported_at, '2026-10-30T10:00:00.000Z')
    assert.deepEqual(body.notes.map((n) => n.id), ['a', 'b'])
    assert.equal(calls.length, 0)
  })
  it('erase removes every note through the store; the list is empty after', async () => {
    const store = fakeStore(rows)
    await eraseNotes(api, store)
    assert.deepEqual(store.removed, ['a', 'b'])
    assert.equal(store.notes.length, 0)
  })
  it('SPL-4390: erase also removes a note waiting on its Undo toast; nothing is left to bring back', async () => {
    const store = fakeStore([...rows, { id: 'c', title: 'Held', archived: false }], ['c'])
    await eraseNotes(api, store)
    assert.deepEqual([...store.removed].sort(), ['a', 'b', 'c'])
    assert.deepEqual(store.all, [])
    assert.deepEqual(store.hidden, [])
  })
})

describe('the suite', () => {
  it('pnpm test runs this suite', () => {
    const s = runsInUnitSuite(import.meta.url)
    assert.ok(s.ok, s.why)
  })
})
