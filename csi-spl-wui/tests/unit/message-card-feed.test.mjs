// SPL-1750 (ui panel 34f4da14, consensus items 4 and 5): the message card
//   - skips style/layout/paint off screen (content-visibility), except while
//     it swipes or holds the focus, where paint containment would clip the
//     swipe strip and the edit box's mention list. SPL-1762: the feed
//     re-follows a row that grows from its 72px estimate, because the scroll
//     anchor observes every row, not only the list (message-order A5);
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

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, '../../src/components/MessageCard.vue'), 'utf8')
const anchor = readFileSync(join(here, '../../src/composables/useScrollAnchor.ts'), 'utf8')
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

describe('MessageCard feed rendering (SPL-1750, SPL-1762)', () => {
  it('an idle card is content-visibility: auto with a remembered 72px size', () => {
    const b = block('.msg:not(.msg--swiping):not(.msg--swipe-settle):not(:focus-within) {')
    assert.match(b, /content-visibility:\s*auto;/)
    assert.match(b, /contain-intrinsic-size:\s*auto 72px;/)
    assert.equal((css.match(/content-visibility:/g) || []).length, 1, 'only the guarded rule sets it')
  })
  it('SPL-1762: the scroll anchor observes each row after every patch, and lets go of removed ones', () => {
    assert.match(anchor, /function observeRows\(a: Anchor\)[\s\S]*?querySelectorAll\('\[data-key\]'\)[\s\S]*?ro\.observe\(el\)/)
    assert.match(anchor, /if \(!el\.isConnected\) \{\s*ro\.unobserve\(el\)/)
    assert.match(anchor, /if \(a\.newestLast\(\)\) \{\s*observeRows\(a\)\s*afterAppend/)
  })
  it('the replies button marks an empty count (no replies, nothing new: SPL-2422)', () => {
    assert.match(src, /data-test="topic-replies"[\s\S]{0,120}:data-zero="count === 0 && unreadCount === 0 \? 'true' : undefined"/)
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
