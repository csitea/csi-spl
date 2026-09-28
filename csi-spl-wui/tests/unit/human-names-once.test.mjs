// CLE-35075: useHumanNames() runs in about seven components per card. The
// sign-in watcher is wired ONCE per tab (it forgot and re-read the roster
// once per instance), a mount joins a read already on its way, and the
// JSON.stringify pair per mount is a key/value compare (sameNames).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { sameNames } from '../../src/utils/display-name.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

describe('sameNames', () => {
  it('equal pairs in any key order are the same', () => {
    assert.equal(sameNames({ a: 'A', b: 'B' }, { b: 'B', a: 'A' }), true)
    assert.equal(sameNames({}, {}), true)
    assert.equal(sameNames(null, {}), true)
  })
  it('a changed, missing or extra name is a change', () => {
    assert.equal(sameNames({ a: 'A' }, { a: 'Z' }), false)
    assert.equal(sameNames({ a: 'A', b: 'B' }, { a: 'A' }), false)
    assert.equal(sameNames({ a: 'A' }, { a: 'A', b: 'B' }), false)
    assert.equal(sameNames({ a: 'A', b: undefined }, { a: 'A', c: undefined }), false)
  })
})

describe('useHumanNames wiring', () => {
  const src = readFileSync(join(SRC, 'composables/useHumanNames.ts'), 'utf8')
  it('one session watcher per tab, in a detached scope', () => {
    assert.match(src, /if \(import\.meta\.client && !wired\) \{\n\s+wired = true\n\s+effectScope\(true\)\.run/)
    assert.equal((src.match(/watch\(\(\) => session\.state/g) || []).length, 1)
  })
  it('a mount joins the read in flight; a forced read does not', () => {
    assert.match(src, /if \(inFlight && !force\) return inFlight/)
    assert.doesNotMatch(src, /JSON\.stringify/)
  })
})
