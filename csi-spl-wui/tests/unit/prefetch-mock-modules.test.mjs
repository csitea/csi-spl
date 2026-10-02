// CLE-77933 (owner topic 87eaa57b, first-load network): the generated
// documents keep Nuxt's <link rel="prefetch"> hints (89 of 101 are chunks the
// first screen's import waterfall needs; without them the rail came later on
// prd), but never hint a mock-only module - a live build never loads one, so
// its prefetch was 5 requests / 12.5 KB of prd's cold first load for nothing.
//
// nuxt.config's build:manifest hook decides that from the module path. This
// test pins the rule to the files on disk: every mock-only util matches, no
// other util does (a live module wrongly matched would lose its prefetch and
// join the waterfall late), and the hook still drops prefetch, never more.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')

/** the regex literal inside nuxt.config's isMockOnlyModule */
function mockRule() {
  const m = /function isMockOnlyModule\(src: string\): boolean \{\s*return (\/.+\/)\.test\(src\)/.exec(cfg)
  assert.ok(m, 'nuxt.config.ts defines isMockOnlyModule(src) as one regex test')
  const lit = m[1]
  return new RegExp(lit.slice(1, -1))
}

describe('prefetch: mock-only modules are never hinted', () => {
  it('the build:manifest hook turns prefetch off for mock-only modules only', () => {
    assert.match(cfg, /"build:manifest"\(manifest\) \{\s*for \(const \[src, chunk\] of Object\.entries\(manifest\)\) \{\s*if \(isMockOnlyModule\(src\)\) chunk\.prefetch = false\s*\}/)
    assert.doesNotMatch(cfg, /Object\.values\(manifest\)\) chunk\.prefetch = false/,
      'prefetch stays on for every other chunk (removing it all made the rail slower, 94f46ac6)')
  })

  it('every *-mock.mjs / mock-*.mjs util matches the rule as the manifest names it, no live util does', () => {
    const rule = mockRule()
    const utils = readdirSync(join(WUI, 'src/utils')).filter((f) => f.endsWith('.mjs'))
    const mock = utils.filter((f) => /(^mock-|-mock\.mjs$)/.test(f))
    assert.ok(mock.length >= 5, `mock-only utils on disk: ${mock.join(' ')}`)
    for (const f of utils) {
      assert.equal(rule.test(`utils/${f}`), mock.includes(f), `utils/${f}`)
    }
    // the manifest key shape (srcDir-relative); a component or page never matches
    assert.equal(rule.test('components/MockBanner.vue'), false)
    assert.equal(rule.test('pages/mock.vue'), false)
  })
})
