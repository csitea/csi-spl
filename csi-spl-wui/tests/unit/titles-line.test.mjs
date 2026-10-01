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

  it('the open icon is not part of a titles card', () => {
    assert.match(vue, /v-if="topicLink && !titleOnly"/)
    assert.match(vue, /const titleOnly = computed\(\(\) => props\.clipMode === 'titles' && !editing\.value\)/)
  })

  /* CLE-77873 (owner, t1 d6c9661e): SPL-982 moved the chips INTO the header
     line a titles card keeps, beside its smile; gated off there, a pick
     toggled with nothing drawn. The chips and the failure note follow the
     smile, never the height mode. */
  it('a titles card keeps its reaction chips and the emoji error', () => {
    assert.match(vue, /v-if="chips\.length && !mobile" class="msg-reactions" data-testid="msg-reactions"/)
    assert.match(vue, /const phoneChips = computed\(\(\) => mobile\.value && chips\.value\.length > 0\)/)
    assert.match(vue, /v-if="reactError" class="msg-edit-error" role="alert" data-testid="msg-emoji-error"/)
    assert.doesNotMatch(vue, /chips[^"\n]*titleOnly|reactError && !titleOnly/)
  })
})
