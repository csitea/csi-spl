// 010 FR-009 for /search: a member's first read of a fresh page has to be able
// to flip the view door onto the sign-in cookie, or a signed-in human who deep
// links to /search?q=… gets the door prompt instead of results.
//
// Measured on dev 2026-09-21 (WUI 1eeaa84, hub 0.1.17), signed in as the test
// member: GET /search?q=live rendered "This tenant's threads need a member
// sign-in or a view token." and zero result rows. 2dfefe7 fixed exactly this for
// /channel, /dm and the roster; the search store was reading straight through.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const store = readFileSync(join(SRC, 'stores/search.ts'), 'utf8')

describe('the search store reads through the session-door retry', () => {
  it('imports withSessionRetry and uses it for every hub read', () => {
    assert.match(store, /import \{ withSessionRetry \} from '~\/utils\/live-follow\.mjs'/)
    const reads = store.match(/api\.(search|searchOperators)\(/g) || []
    assert.equal(reads.length, 3, 'query, load-more and the operator catalogue')
    for (const call of ['api.search({ q: query })', 'api.search({ q: q.value, cursor })', 'api.searchOperators()']) {
      const at = store.indexOf(call)
      assert.ok(at > 0, call)
      assert.match(store.slice(Math.max(0, at - 60), at), /withSessionRetry\(api, \(\) => $/, call)
    }
  })

  it('CONTROL: no bare useSpoolApi().search( left in the store', () => {
    assert.doesNotMatch(store, /useSpoolApi\(\)\.search/)
    assert.doesNotMatch(store, /useSpoolApi\(\)\.searchOperators/)
  })
})
