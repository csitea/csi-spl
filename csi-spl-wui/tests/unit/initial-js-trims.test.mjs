// Perf audit round 3, lane F: two trims of the live initial JS.
//
// P3-15: the mock tenant's data stays out of it. spool-client.mjs is in the
// entry chunk, so it reaches mock-data.mjs only through import(). Nuxt
// auto-imports every utils/ export: a bare `cloneMock` / `MOCK_*` name in
// spool-client.mjs (even a destructured one) makes it inject a STATIC import,
// and the data rides every first load again (measured: ci_initial_gzip_kb
// 148.8 with one, 147.5 without).
//
// P3-30: the client's writers, admin and issue calls live in
// spool-client-lazy.mjs; spool-client.mjs keeps a stub per name that loads
// that chunk on first use. The same auto-import trap applies to it.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { lazySpoolMethods } from '../../src/utils/spool-client-lazy.mjs'

const read = (rel) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8')
const exportsOf = (src) => [...src.matchAll(/^export (?:async )?(?:const|function) (\w+)/gm)].map((m) => m[1])
const client = read('../../src/utils/spool-client.mjs')
const lazySrc = read('../../src/utils/spool-client-lazy.mjs')
const bare = (name) => new RegExp(`(?<![.\\w'])${name}\\b`)

describe('mock data out of the live initial JS (P3-15)', () => {
  it('spool-client.mjs names no mock-data export bare and imports it only dynamically', () => {
    const names = exportsOf(read('../../src/utils/mock-data.mjs'))
    assert.ok(names.includes('cloneMock'), 'control: the export scan sees cloneMock')
    assert.doesNotMatch(client, /^import[^\n]*mock-data/m)
    for (const name of names) assert.doesNotMatch(client, bare(name), `${name} must be read as a member (data.${name}), never bare`)
  })

  it('useLive takes the lobby id from mock-ids.mjs, not mock-data.mjs', () => {
    const src = read('../../src/composables/useLive.ts')
    assert.doesNotMatch(src, /mock-data/)
    assert.match(src, /from '~\/utils\/mock-ids\.mjs'/)
  })

  it('a mock client\'s first calls wait for the lazily loaded mock data', async () => {
    const c = createSpoolClient({ mock: true })
    const [channels, roster] = await Promise.all([c.listChannels(), c.listRoster()])
    assert.ok(channels.length > 0)
    assert.equal(roster.me.id, 'HUM-1')
    assert.equal(c.hasToken(), false, 'a sync method stays sync')
  })
})

describe('the client\'s lazy half (P3-30)', () => {
  const stubs = [...client.match(/const LAZY_METHODS = \[([\s\S]*?)\]/)[1].matchAll(/'(\w+)'/g)].map((m) => m[1])

  it('LAZY_METHODS names exactly what spool-client-lazy.mjs carries', () => {
    assert.ok(stubs.length >= 40, `control: the stub list parsed (${stubs.length})`)
    assert.deepEqual([...stubs].sort(), Object.keys(lazySpoolMethods).sort())
  })

  it('a moved method is no longer defined in spool-client.mjs', () => {
    for (const name of stubs) assert.doesNotMatch(client, new RegExp(`async ${name}\\(`), name)
  })

  it('spool-client.mjs loads it only with import(), read as a member', () => {
    assert.doesNotMatch(client, /^import[^\n]*spool-client-lazy/m)
    assert.match(client, /import\('\.\/spool-client-lazy\.mjs'\)/)
    assert.doesNotMatch(client, bare('lazySpoolMethods'))
  })

  it('exports one name only: a utils/ export is a Nuxt auto-import, and createChannel etc. would collide', () => {
    assert.deepEqual(exportsOf(lazySrc), ['lazySpoolMethods'])
  })

  it('a live write goes through the stub to the hub, a live first-screen read does not load it', async () => {
    const calls = []
    const fetchFn = async (url, init) => {
      calls.push(`${(init && init.method) || 'GET'} ${url}`)
      return new Response(JSON.stringify({ channel: 'x', members: [] }), { status: 200, headers: { 'content-type': 'application/json' } })
    }
    const c = createSpoolClient({ mock: false, base: 'https://hub.invalid', fetchFn })
    await c.setMembersOpenInvite('x', true)
    await c.listChannelMembers('x')
    assert.deepEqual(calls, ['PATCH https://hub.invalid/v1/channels/x', 'GET https://hub.invalid/v1/channels/x/members'])
  })

  it('a mock client\'s moved methods see the mock state', async () => {
    const c = createSpoolClient({ mock: true })
    const row = await c.createChannel({ channel_id: 'lane-f', name: 'Lane F' })
    assert.equal(row.channel_id, 'lane-f')
    const members = await c.listChannelMembers('lane-f')
    assert.deepEqual(members.members, ['HUM-1'])
    assert.ok((await c.listChannels()).some((ch) => ch.channel_id === 'lane-f'))
  })
})

describe('the phone stack out of the live initial JS (stale-login plugin)', () => {
  // A plugin is in the entry chunk. 087 T003's static import of
  // useMobileStack carried the whole phone stack into every first load:
  // ci_initial_gzip_kb 155.4 > 155 with it, 152.7 with import() (bdb0459a).
  const plugin = read('../../src/plugins/mobile-stale-login.client.ts')
  const code = plugin.replace(/\/\*[\s\S]*?\*\//g, '').replace(/'[^'\n]*'/g, "''")

  it('mobile-stale-login.client.ts loads useMobileStack only with import()', () => {
    assert.doesNotMatch(plugin, /^import[^\n]*useMobileStack/m)
    assert.match(plugin, /import\('~\/composables\/useMobileStack'\)/)
  })

  it('names useMobileStack only as a member of the loaded module (a bare name is a Nuxt auto-import)', () => {
    assert.doesNotMatch(code, bare('useMobileStack'))
    assert.match(code, /\.useMobileStack\(\)\.guardStaleLogin\(\)/)
  })
})
