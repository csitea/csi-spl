// t1 b921518d: the selected topic card drops the left bracket bar.
// A 1px soft-grey border on every side and a small grey drop shadow.
// The card is not translated. The phone topic-heading rule in main.css
// is a different element and is not restated here.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const src = readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'),
  'utf8',
)
const style = src.slice(src.lastIndexOf('<style scoped>'))
const rule = style.match(/\.msg\.selected \{([^}]*)\}/)

describe('selected topic card', () => {
  it('draws a 1px grey border on all four sides and a raised shadow, with no left bar', () => {
    assert.ok(rule, 'a .msg.selected rule in MessageCard')
    const body = rule[1]
    assert.match(body, /border:\s*1px solid rgba\(128, 128, 128, 0\.45\)/)
    assert.match(body, /box-shadow:\s*0 2px 6px rgba\(100, 100, 100, 0\.22\)/)
    assert.doesNotMatch(body, /var\(--focus-ring\)|var\(--focus-3d\)|var\(--color-accent\)/)
    assert.doesNotMatch(body, /inset|var\(--select-bar-w\)|transform/)
    assert.doesNotMatch(style, /translateY/)
  })

  it('does not set a px font size on the selected card', () => {
    assert.ok(rule)
    assert.doesNotMatch(rule[1], /font-size/)
  })
})
