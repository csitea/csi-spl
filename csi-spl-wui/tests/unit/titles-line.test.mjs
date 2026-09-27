// SPL-943 — Titles is the meta row plus one line of text, nothing else.
//
// Run: node tests/unit/titles-line.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')

describe('titles view is one line (SPL-943)', () => {
  it('the title is a single ellipsized line', () => {
    assert.match(vue, /\.msg-title \{[^}]*white-space:\s*nowrap/s)
    assert.match(vue, /\.msg-title \{[^}]*text-overflow:\s*ellipsis/s)
    assert.match(vue, /\.msg-title \{[^}]*overflow:\s*hidden/s)
  })

  it('reactions, the emoji error, and the open icon are not part of a titles card', () => {
    assert.match(vue, /v-if="chips\.length && !titleOnly && !mobile"/)
    assert.match(vue, /const phoneChips = computed\(\(\) => mobile\.value && chips\.value\.length > 0 && !titleOnly\.value\)/)
    assert.match(vue, /v-if="reactError && !titleOnly"/)
    assert.match(vue, /v-if="topicLink && !titleOnly"/)
    assert.match(vue, /const titleOnly = computed\(\(\) => props\.clipMode === 'titles' && !editing\.value\)/)
  })
})
