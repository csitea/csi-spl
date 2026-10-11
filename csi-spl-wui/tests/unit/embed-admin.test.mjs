// Spec 121 T204: the embed admin page's helpers and the mock hub (the WUI
// side of T203's /v1/tenant/embeds). The page itself, in a real browser, is
// tests/e2e/tenant-settings.test.mjs step 18.
// Run: node tests/unit/embed-admin.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  EMBED_ID_RE, EMBED_MAX_ORIGINS, embedErrorKey, embedIdValid, embedRow, embedRows, originsFromText, originsText,
} from '../../src/utils/embed-admin.mjs'
import { createMockEmbeds } from '../../src/utils/embed-admin-mock.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const HUB = '../csi-spl-api/src/go/spool-hub-api/internal/hub/embed_admin.go'

describe('embedRows', () => {
  it('normalizes, drops id-less rows, sorts by id, never carries a private key', () => {
    const rows = embedRows({ embeds: [
      { embed_id: 'zeta', allowed_origins: ['https://z.example.com'], enabled: true, key_id: 'k1', key_alg: 'ES256', private_key: 'x' },
      { embed_id: '' },
      { embed_id: 'alpha', allowed_origins: null, enabled: 'yes' },
    ] })
    assert.deepEqual(rows.map((r) => r.embedId), ['alpha', 'zeta'])
    assert.deepEqual(rows[0], { embedId: 'alpha', origins: [], enabled: false, keyId: '', keyAlg: '' })
    assert.equal('privateKey' in rows[1], false)
  })
  it('a junk body is an empty list', () => {
    assert.deepEqual(embedRows(null), [])
    assert.deepEqual(embedRows({ embeds: 'x' }), [])
    assert.equal(embedRow(null).embedId, '')
  })
})

describe('origins textarea', () => {
  it('one per line, trimmed, blanks and repeats dropped', () => {
    assert.deepEqual(originsFromText(' https://a.example.com \r\n\nhttps://b.example.com\nhttps://a.example.com\n'), ['https://a.example.com', 'https://b.example.com'])
    assert.deepEqual(originsFromText(''), [])
  })
  it('round-trips the list', () => {
    const list = ['https://a.example.com', 'http://localhost:3000']
    assert.deepEqual(originsFromText(originsText(list)), list)
    assert.equal(originsText(null), '')
  })
})

describe('embedIdValid', () => {
  it('follows the hub check', () => {
    for (const ok of ['abc', 'site-1', 'a'.repeat(64)]) assert.equal(embedIdValid(ok), true, ok)
    for (const bad of ['', 'ab', '-abc', 'Abc', 'a_b', 'a'.repeat(65)]) assert.equal(embedIdValid(bad), false, bad)
  })
  it('the pattern and the 32-origin cap are the hub\'s', () => {
    const go = src(HUB)
    assert.ok(go.includes('`' + EMBED_ID_RE.source + '`'), 'embedIDPattern differs')
    assert.match(go, new RegExp(`embedMaxOrigins = ${EMBED_MAX_ORIGINS}\\b`))
  })
})

describe('embedErrorKey', () => {
  it('maps the hub refusals', () => {
    assert.equal(embedErrorKey({ status: 403, token: 'forbidden' }, { listing: true }), 'embed.not_owner')
    assert.equal(embedErrorKey({ status: 404, token: 'not_found' }, { listing: true }), 'embed.disabled')
    assert.equal(embedErrorKey({ status: 404, token: 'not_found' }), 'embed.save_failed')
    assert.equal(embedErrorKey({ status: 409, token: 'embed_exists' }), 'embed.exists')
    assert.equal(embedErrorKey({ status: 400, token: 'bad_origin' }), 'embed.bad_origin')
    assert.equal(embedErrorKey({ status: 400, token: 'bad_embed' }), 'embed.bad_id')
    assert.equal(embedErrorKey({ status: 500 }, { listing: true }), 'embed.fetch_failed')
    assert.equal(embedErrorKey(null), 'embed.save_failed')
  })
  it('the tokens are the hub\'s', () => {
    const go = src(HUB)
    for (const tok of ['embed_exists', 'bad_origin', 'bad_embed']) assert.ok(go.includes(`"${tok}"`), tok)
  })
})

describe('createMockEmbeds', () => {
  it('create is disabled and keyless; patch sets origins and the switch', () => {
    const m = createMockEmbeds()
    const e = m.create({ embed_id: 'site', allowed_origins: ['HTTPS://Shop.Example.com'] })
    assert.equal(e.enabled, false)
    assert.equal(e.key_id, '')
    assert.deepEqual(e.allowed_origins, ['https://shop.example.com'])
    const p = m.patch('site', { allowed_origins: ['https://a.example.com', 'http://localhost:8080'], enabled: true })
    assert.equal(p.enabled, true)
    assert.deepEqual(m.list().embeds.map((x) => x.allowed_origins), [['https://a.example.com', 'http://localhost:8080']])
  })
  it('the private key is in the key answer only, and a new key replaces the old', () => {
    const m = createMockEmbeds()
    m.create({ embed_id: 'site' })
    const k1 = m.newKey('site')
    assert.ok(k1.private_key)
    assert.equal(k1.key_alg, 'ES256')
    const k2 = m.newKey('site')
    assert.notEqual(k2.key_id, k1.key_id)
    const listed = m.list().embeds[0]
    assert.equal(listed.key_id, k2.key_id)
    assert.equal('private_key' in listed, false)
  })
  it('refuses like the hub: bad id, taken id, bad origin, unknown embed, flag off', () => {
    const m = createMockEmbeds()
    m.create({ embed_id: 'site' })
    assert.throws(() => m.create({ embed_id: 'x' }), { status: 400, token: 'bad_embed' })
    assert.throws(() => m.create({ embed_id: 'site' }), { status: 409, token: 'embed_exists' })
    for (const o of ['http://shop.example.com', 'https://*.example.com', 'https://a.example.com/path']) {
      assert.throws(() => m.patch('site', { allowed_origins: [o] }), { status: 400, token: 'bad_origin' }, o)
    }
    assert.throws(() => m.patch('site', {}), { status: 400, token: 'bad_embed' })
    assert.throws(() => m.newKey('nope'), { status: 404 })
    assert.throws(() => createMockEmbeds({ enabled: false }).list(), { status: 404 })
  })
})

describe('i18n', () => {
  it('every embed.* key the page uses is in all 19 locales, same set as en', () => {
    const page = src('src/pages/embed/index.vue')
    const used = [...new Set([...page.matchAll(/t\('(embed\.[a-z_]+)'/g)].map((m) => m[1].slice(6)))]
    const used2 = ['disabled', 'exists', 'bad_origin', 'bad_id', 'not_owner', 'fetch_failed', 'save_failed']
    const dir = join(WUI, 'i18n/locales')
    const en = Object.keys(JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).embed).sort()
    for (const k of [...used, ...used2]) assert.ok(en.includes(k), k)
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const e = JSON.parse(readFileSync(join(dir, f), 'utf8')).embed || {}
      assert.deepEqual(Object.keys(e).sort(), en, f)
      assert.equal(e.key_id.includes('{id}') && e.key_id.includes('{alg}'), true, f)
    }
  })
})
