// SPL-2267 Gate B (owner HUM-10, t1 1f583d2a: "no hardcoding in the UI for
// text which should be part of the translation set"). Per file under src/, the
// hard-coded user-visible strings (template text, static title/placeholder/
// aria-label/alt/label, literal alert/confirm/prompt messages) must not exceed
// i18n/i18n-raw-text-baseline.json. A ratchet: refactor lanes move strings
// into the translation set and lower it; a new literal is red. Scanner:
// src/node/i18n/i18n-gates.mjs.
//
// Run: node tests/unit/i18n-no-raw-text.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  RAW_TEXT_BASELINE, overBaseline, rawTextScan, scriptHits, templateHits,
} from '../../src/node/i18n/i18n-gates.mjs'

const baseline = JSON.parse(readFileSync(RAW_TEXT_BASELINE, 'utf8'))
const scan = rawTextScan()

describe('hard-coded UI text (ratchet)', () => {
  it('no file holds more hard-coded strings than its baseline', () => {
    const over = overBaseline(Object.fromEntries(Object.entries(scan).map(([f, h]) => [f, h.length])), baseline)
    assert.deepEqual(over, [], over.map((o) =>
      `${o.name}: ${o.count} > baseline ${o.baseline}: ${JSON.stringify(scan[o.name])}` +
      ' — use $t(\'key\') with the key in en.json and every locale, never a literal').join('\n'))
  })
})

describe('scanner', () => {
  it('red control: a raw "Hello" in a template is a hit', () => {
    assert.deepEqual(templateHits('<div class="x">{{ t(\'a\') }}</div>'), [])
    assert.deepEqual(templateHits('<div class="x">Hello</div>'), ['Hello'])
    assert.equal(overBaseline({ 'src/x.vue': 1 }, {}).length, 1)
  })
  it('skips interpolation, comments, bound attrs and operators inside tags', () => {
    assert.deepEqual(templateHits('<!-- Some note --><p v-if="a > b" :title="t(\'k\')">{{ msg }} · {{ n }}</p>'), [])
  })
  it('counts static user-visible attributes', () => {
    assert.deepEqual(templateHits('<button aria-label="Close dialog" title="Close"></button>'), ['Close dialog', 'Close'])
  })
  it('counts a literal message to a browser dialog', () => {
    assert.deepEqual(scriptHits("if (confirm('Delete this topic?')) go()"), ['Delete this topic?'])
    assert.deepEqual(scriptHits("confirm(t('topic.delete'))"), [])
  })
})
