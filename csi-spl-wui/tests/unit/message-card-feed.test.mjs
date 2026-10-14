// SPL-1750 (ui panel 34f4da14, consensus items 4 and 5): the message card
//   - does NOT set content-visibility: a new row at the feed's end is laid
//     out at the intrinsic estimate, grows, and the feed stops short of the
//     bottom (message-order.test.mjs A5);
//   - on a desktop pointer shows Open topic, an empty "0 >>", the smile and
//     the menu on hover / focus only (opacity, so Tab and clicks are kept);
//     a reply count above 0 stays;
//   - on the phone stack drops "0 >>" so the name fits; the kind icon stays
//     (a hold under the header lands on it: move-by-drag.test.mjs step 8).
// The live proof (390 + 1440 px, CDP layout+style on 300 cards) is in the
// lane's result; this pins the rules in the source.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
const css = src.slice(src.indexOf('<style scoped>'))
const block = (head) => {
  const i = css.indexOf(head)
  assert.ok(i >= 0, `missing: ${head}`)
  let d = 0
  for (let j = css.indexOf('{', i); j < css.length; j++) {
    if (css[j] === '{') d++
    else if (css[j] === '}' && --d === 0) return css.slice(i, j + 1)
  }
  return ''
}

describe('MessageCard feed rendering (SPL-1750)', () => {
  it('the card sets no content-visibility (the feed must re-follow first)', () => {
    assert.doesNotMatch(css.replace(/\/\*[\s\S]*?\*\//g, ''), /(content-visibility|contain-intrinsic-size)\s*:/)
  })
  it('the replies button marks an empty count', () => {
    assert.match(src, /data-test="topic-replies"[\s\S]{0,120}:data-zero="count === 0 \? 'true' : undefined"/)
  })
  it('desktop pointer: the actions fade in on hover, focus, selection or an open menu', () => {
    const b = block('@media (hover: hover) and (min-width: 821px) {')
    for (const sel of ['[data-test="open-topic"]', '.replies[data-zero]', '[data-testid="msg-emoji-btn"]', '.msg-menu-btn']) assert.ok(b.includes(sel), sel)
    assert.match(b, /opacity:\s*0;/)
    assert.doesNotMatch(b, /display:\s*none|visibility:\s*hidden/, 'hidden by opacity only: Tab order and clicks stay')
    assert.doesNotMatch(b, /\.replies\s*[,{](?![^{]*data-zero)/, 'a count above 0 is never hidden')
    for (const sel of ['.msg:hover .msg-actions > *', '.msg:focus-within .msg-actions > *', '.msg.selected .msg-actions > *', '.msg-actions > [aria-expanded="true"]']) assert.ok(b.includes(sel), sel)
  })
  it('phone stack: no "0 >>", the kind icon stays, the name grows first', () => {
    const b = block('@media (max-width: 820px) {')
    assert.match(b, /\.msg-actions \.replies\[data-zero\] \{ display: none; \}/)
    assert.doesNotMatch(b, /:deep\(\.kind\) \{ display: none; \}/, 'the kind icon is the hold target under the header')
    assert.match(b, /\.msg-meta > :deep\(\.msg-author\) \{ flex-grow: 100; \}/)
  })
})
