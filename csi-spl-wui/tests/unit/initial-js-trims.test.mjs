// Perf audit round 3, lane F: trims of the live initial JS.
//
// P3-15: the mock tenant's data stays out of it. spool-client.mjs is in the
// entry chunk, so it reaches mock-data.mjs only through import(). Nuxt
// auto-imports every utils/ export: a bare `cloneMock` / `MOCK_*` name in
// spool-client.mjs (even a destructured one) makes it inject a STATIC import,
// and the data rides every first load again (measured: ci_initial_gzip_kb
// 148.8 with one, 147.5 without).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const read = (rel) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8')
const exportsOf = (src) => [...src.matchAll(/^export (?:async )?(?:const|function) (\w+)/gm)].map((m) => m[1])
const client = read('../../src/utils/spool-client.mjs')
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
