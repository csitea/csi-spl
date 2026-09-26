// SPL-14 — the omnibox drag handle is a pointer target, not a Tab stop.
//
// The grip is a real button so pointerdown can resize the field. A button
// is in the tab order unless told otherwise, so Tab landed on it between
// the field and Attach. tabindex="-1" takes it out of that cycle and leaves
// the pointer handler where it is.
//
// Run: node tests/unit/omnibox-grip-tab.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = readFileSync(join(WUI, 'src/components/MessageComposer.vue'), 'utf8')

function gripTag() {
  const at = src.indexOf('data-test="omnibox-resize"')
  assert.ok(at > 0, 'omnibox-resize button missing')
  const open = src.lastIndexOf('<button', at)
  return src.slice(open, src.indexOf('>', at) + 1)
}

describe('omnibox grip tab stop (SPL-14)', () => {
  it('the omnibox-resize button carries tabindex="-1"', () => {
    const tag = gripTag()
    assert.match(tag, /class="omnibox-resize"/)
    assert.match(tag, /type="button"/)
    assert.match(tag, /tabindex="-1"/)
    assert.match(tag, /:aria-label="t\('composer\.resize'\)"/)
    assert.match(tag, /@pointerdown="startResize"/)
  })
})
