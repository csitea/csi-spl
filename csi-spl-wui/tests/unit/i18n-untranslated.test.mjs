// SPL-2267 Gate A (owner HUM-10, t1 9f867807): no locale value left in
// English. Per locale, the count of values identical to en.json (a 3+ letter
// word after removing {placeholders} and URLs), minus the one allow-list
// i18n/i18n-keep-english.json, must not exceed i18n/i18n-untranslated-baseline.json.
// A ratchet: translation lanes lower the counts (and may lower the baseline);
// nobody raises it. Counting code: src/node/i18n/i18n-gates.mjs.
//
// Run: node tests/unit/i18n-untranslated.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  KEEP_FILE, UNTRANSLATED_BASELINE, hasWord, overBaseline, untranslatedCounts, untranslatedKeys,
} from '../../src/node/i18n/i18n-gates.mjs'

const keep = JSON.parse(readFileSync(KEEP_FILE, 'utf8'))
const baseline = JSON.parse(readFileSync(UNTRANSLATED_BASELINE, 'utf8'))
const counts = untranslatedCounts()

describe('untranslated locale values (ratchet)', () => {
  it('every locale has a baseline entry', () => {
    assert.deepEqual(Object.keys(counts).sort(), Object.keys(baseline).sort())
  })
  it('no locale holds more English values than its baseline', () => {
    const over = overBaseline(Object.fromEntries(Object.entries(counts).map(([l, v]) => [l, v.count])), baseline)
    assert.deepEqual(over, [], over.map((o) =>
      `${o.name}: ${o.count} > baseline ${o.baseline}; new English values: ${counts[o.name].keys.slice(0, 10).join(', ')}` +
      ' — translate them (key in en.json + every locale), or allow-list a brand/code in i18n/i18n-keep-english.json with its reason').join('\n'))
  })
  it('every allow-list entry carries a reason', () => {
    for (const [k, why] of [...Object.entries(keep.values), ...Object.entries(keep.keys)]) {
      assert.ok(typeof why === 'string' && why.trim().length > 2, `${k} has no reason`)
    }
  })
})

describe('counting rule', () => {
  it('a 3+ letter word outside {placeholders} and URLs counts', () => {
    assert.ok(hasWord('Post anyway'))
    assert.ok(!hasWord('{count} · {size}'))
    assert.ok(!hasWord('OK'))
    assert.ok(!hasWord('https://example.com/abc'))
  })
  it('red control: one English value copied into bg goes above its baseline', () => {
    const en = { 'a.remove': 'Remove', 'a.brand': 'Claude', 'a.ok': 'OK' }
    const bg = { 'a.remove': 'Премахни', 'a.brand': 'Claude', 'a.ok': 'OK' }
    assert.equal(untranslatedKeys(en, bg, keep).length, 0)
    const planted = { ...bg, 'a.remove': 'Remove' }
    const n = untranslatedKeys(en, planted, keep).length
    assert.equal(n, 1)
    assert.equal(overBaseline({ bg: n }, { bg: 0 }).length, 1)
  })
})
