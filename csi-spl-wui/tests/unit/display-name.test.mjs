// the "Display name" field in Settings → Profile.
//
// What it proves:
//  - validDisplayName mirrors the hub's ValidDisplayName (trim, 1..200
//    CHARACTERS, one line, no control character);
//  - applyDisplayName saves first and mirrors only what the hub stored (its
//    echo), never an optimistic name, and a refusal leaves the claims alone;
//  - the client sends ONLY display_name, with no header the hub's auth CORS
//    does not allow (auth_cors.go: Content-Type, X-Locale; a new one breaks
//    sign-in);
//  - the user menu renders the mirrored claim;
//  - the component sits on /settings/profile, and every locale has its copy.
// CONTROL: a refused save must leave the mirrored name unchanged, and the
// "unchanged" short-cut must not call the hub at all.
// Run: node tests/unit/display-name.test.mjs
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createAuthClient } from '../../src/utils/auth-client.mjs'
const { userIdentity } = await importTs('src/utils/user-menu.ts')
import { importTs } from './lib/load-ts.mjs'

const { MAX_DISPLAY_NAME, applyDisplayName, validDisplayName, validNamePart, validPhone, splitDisplayName, applyProfile } = await importTs('src/utils/display-name.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
let failed = 0
async function it(name, fn) {
  try { await fn(); console.log('  OK  ', name) } catch (e) { failed++; console.log('  FAIL', name + ':', e.message) }
}

console.log('display-name')

await it('validDisplayName admits a trimmed 1..200-character line', () => {
  assert.deepEqual(validDisplayName('  Ana Maria  '), { ok: true, name: 'Ana Maria' })
  assert.equal(validDisplayName('ä'.repeat(MAX_DISPLAY_NAME)).ok, true, '200 characters of 2-byte text')
  assert.equal(validDisplayName('👩‍💻 Dev').ok, true, 'emoji with a zero-width joiner')
  assert.equal(MAX_DISPLAY_NAME, 200)
})

await it('validDisplayName refuses what the hub refuses', () => {
  for (const bad of ['', '   ', 'a\nb', 'a\rb', 'a\tb', 'a\u0000b', 'a\u007fb', 'a\u0085b', 'a\u2028b', 'a\u2029b',
    'a'.repeat(MAX_DISPLAY_NAME + 1), null, undefined, 42, ['a']]) {
    assert.equal(validDisplayName(bad).ok, false, JSON.stringify(bad))
  }
})

await it('applyDisplayName saves, then mirrors the hub echo', async () => {
  const seen = []
  let applied = null
  const res = await applyDisplayName('  New Name ', {
    current: 'Old',
    save: async (n) => { seen.push(n); return { ok: true, data: { display_name: 'New Name' } } },
    apply: (n) => { applied = n },
  })
  assert.deepEqual(res, { ok: true, name: 'New Name' })
  assert.deepEqual(seen, ['New Name'], 'the trimmed name is what is sent')
  assert.equal(applied, 'New Name')
})

await it('CONTROL: a refused or failed save mirrors nothing', async () => {
  for (const save of [
    async () => ({ ok: false, status: 400, error: 'invalid_display_name' }),
    async () => { throw new Error('offline') },
  ]) {
    let applied = null
    const res = await applyDisplayName('New Name', { current: 'Old', save, apply: (n) => { applied = n } })
    assert.equal(res.ok, false)
    assert.equal(res.reason, 'refused')
    assert.equal(applied, null)
  }
})

await it('CONTROL: an invalid or unchanged name never reaches the hub', async () => {
  let calls = 0
  const io = { current: 'Same', save: async () => { calls++; return { ok: true } }, apply: () => {} }
  assert.equal((await applyDisplayName('a\nb', io)).reason, 'invalid')
  assert.equal((await applyDisplayName(' Same ', io)).reason, 'unchanged')
  assert.equal(calls, 0)
})

await it('saveDisplayName PUTs only display_name, with no header auth CORS does not allow', async () => {
  const calls = []
  const fetchFn = async (url, opts) => {
    calls.push({ url, opts })
    return { ok: true, status: 200, json: async () => ({ display_name: 'X' }) }
  }
  const out = await createAuthClient({ fetchFn, locale: () => 'fi', sendLocale: true }).saveDisplayName('X')
  assert.equal(out.ok, true)
  assert.equal(out.data.display_name, 'X')
  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, '/api/v1/auth/preferences')
  assert.equal(calls[0].opts.method, 'PUT')
  assert.deepEqual(JSON.parse(calls[0].opts.body), { display_name: 'X' })
  // Accept is CORS-safelisted; auth CORS allows Content-Type and X-Locale.
  const sent = Object.keys(calls[0].opts.headers).map((h) => h.toLowerCase())
  assert.ok(sent.includes('content-type'), sent.join(','))
  assert.deepEqual(sent.filter((h) => !['accept', 'content-type', 'x-locale'].includes(h)), [], sent.join(','))
})

// SPL-5707 (spec 154 section 12.5): first + last name and the phone, the
// hub's ValidNamePart / ValidPhone / SplitDisplayName mirrored (auth/profile_test.go).
await it('validPhone admits the international form only, normalised', () => {
  const cases = {
    '+358 40 123 4567': '+358401234567', '+1 (555) 000-1111': '+15550001111', '+44.20.7946.0958': '+442079460958',
    '+1234567': '+1234567', '+123456789012345': '+123456789012345',
    '040 123 4567': '', '00358401234567': '', '+0401234567': '', '+123456': '', '+1234567890123456': '', '+358 40 abc': '', '': '',
  }
  for (const [raw, want] of Object.entries(cases)) assert.deepEqual(validPhone(raw), { ok: want !== '', phone: want }, raw)
  assert.equal(validPhone(null).ok, false)
})

await it('splitDisplayName is the hub split: the first word, then the rest', () => {
  assert.deepEqual(splitDisplayName('FirstName LastName'), { first: 'FirstName', last: 'LastName' })
  assert.deepEqual(splitDisplayName('  Mary \t Ann  Smith '), { first: 'Mary', last: 'Ann  Smith' })
  assert.deepEqual(splitDisplayName('Solo'), { first: 'Solo', last: '' })
  assert.deepEqual(splitDisplayName(undefined), { first: '', last: '' })
  assert.equal(validNamePart('a'.repeat(100)).ok, true)
  assert.equal(validNamePart('a'.repeat(101)).ok, false)
})

await it('applyProfile saves the three together and mirrors the hub echo', async () => {
  const seen = []
  let applied = null
  const res = await applyProfile({ first: ' Ana ', last: ' Maria Smith ', phone: '+358 40 123 4567' }, {
    current: { first: 'Old', last: '', phone: '' },
    save: async (v) => { seen.push(v); return { ok: true, data: { display_name: 'Ana Maria Smith' } } },
    apply: (n) => { applied = n },
  })
  assert.equal(res.ok, true)
  assert.deepEqual(seen, [{ first: 'Ana', last: 'Maria Smith', phone: '+358401234567' }])
  assert.equal(applied, 'Ana Maria Smith')
})

await it('CONTROL: a bad name or phone, or no change, never reaches the hub', async () => {
  let calls = 0
  const io = { current: { first: 'Same', last: 'Name', phone: '' }, save: async () => { calls++; return { ok: true } }, apply: () => {} }
  assert.equal((await applyProfile({ first: '', last: 'X', phone: '' }, io)).reason, 'invalid_name')
  assert.equal((await applyProfile({ first: 'A', last: 'x'.repeat(101), phone: '' }, io)).reason, 'invalid_name')
  assert.equal((await applyProfile({ first: 'A', last: '', phone: '040 123 4567' }, io)).reason, 'invalid_phone')
  assert.equal((await applyProfile({ first: ' Same ', last: 'Name ', phone: '' }, io)).reason, 'unchanged')
  assert.equal(calls, 0)
})

await it('saveProfile PUTs first_name, last_name and phone together; "" is null', async () => {
  const calls = []
  const fetchFn = async (url, opts) => { calls.push({ url, opts }); return { ok: true, status: 200, json: async () => ({}) } }
  await createAuthClient({ fetchFn }).saveProfile({ first: 'Ana', last: '', phone: '' })
  assert.equal(calls[0].url, '/api/v1/auth/preferences')
  assert.equal(calls[0].opts.method, 'PUT')
  assert.deepEqual(JSON.parse(calls[0].opts.body), { first_name: 'Ana', last_name: null, phone: null })
})

await it('getProfile GETs /profile; the mock answers ok false', async () => {
  const calls = []
  const fetchFn = async (url, opts) => { calls.push({ url, opts }); return { ok: true, status: 200, json: async () => ({ first_name: 'A', last_name: null, phone: '+1234567' }) } }
  const out = await createAuthClient({ fetchFn }).getProfile()
  assert.equal(calls[0].url, '/api/v1/auth/profile')
  assert.equal(String(calls[0].opts.method || 'GET'), 'GET')
  assert.deepEqual(out, { ok: true, data: { first_name: 'A', last_name: null, phone: '+1234567' } })
  assert.deepEqual(await createAuthClient({ fetchFn, mock: true }).getProfile(), { ok: false, data: null })
  assert.equal(calls.length, 1)
})

await it('the user menu renders the mirrored name', () => {
  const me = userIdentity({ name: 'New Name', email: 'person@example.com', hum: 'HUM-4' })
  assert.equal(me.primary, 'New Name')
  assert.equal(me.secondary, 'person@example.com')
})

await it('the field is on /settings/profile and every locale has its copy', () => {
  const page = readFileSync(join(WUI, 'src/components/settings/profile.vue'), 'utf8')
  assert.match(page, /<DisplayNameSetting \/>/)
  const comp = readFileSync(join(WUI, 'src/components/DisplayNameSetting.vue'), 'utf8')
  const keys = [...comp.matchAll(/t\('(settings\.display_name\.[a-z_]+)'\)/g)].map((m) => m[1])
  assert.ok(keys.length >= 6, 'component keys found: ' + keys.length)
  const dir = join(WUI, 'i18n/locales')
  const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
  assert.equal(files.length, 19)
  const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).settings.display_name
  for (const f of files) {
    const d = JSON.parse(readFileSync(join(dir, f), 'utf8')).settings.display_name
    for (const k of keys) {
      const leaf = k.split('.').pop()
      assert.equal(typeof d?.[leaf], 'string', `${f} ${k}`)
      assert.ok(d[leaf].trim(), `${f} ${k} empty`)
    }
    // translated, not English copied: label and hint differ from en outside en.json
    if (f !== 'en.json') {
      assert.notEqual(d.label, en.label, `${f} label is untranslated`)
      assert.notEqual(d.hint, en.hint, `${f} hint is untranslated`)
    }
  }
})

if (failed) { console.log(`display-name: ${failed} failed`); process.exit(1) }
console.log('display-name: all passed')
