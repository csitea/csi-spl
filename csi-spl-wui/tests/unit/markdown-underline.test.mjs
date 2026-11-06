// SPL-4893 (owner HUM-10, t1 ba784026, msg de86531f: "bolding underlying"):
// ++text++ is underline in the shared renderer (utils/markdown.mjs), the wiki
// mark the notes editor writes. Discussions render through the same file, so
// the dispatcher's condition (c-002, msg c62b9d4c): a source with no "++"
// renders BYTE-EQUAL to before. The golden file holds the renders of that
// corpus taken from the file as it was on origin/master a1330c318, before the
// rule (both the fence options and the whole-message ones: html + breaks).
// CONTROL: with 'u' out of TAGS, or with the rule as a nested inline.parse
// (the first draft: it threw beside **bold**, so the editor's View fell back
// to plain text), the cases below FAIL.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { markdownToHtml } from '../../src/utils/markdown.mjs'

const golden = JSON.parse(readFileSync(new URL('./markdown-underline-golden.json', import.meta.url), 'utf8'))
const ORIGIN = 'https://app.example.com'

describe('++underline++ in the shared markdown renderer', () => {
  it('every golden source has no "++" and renders byte-equal to before', () => {
    assert.ok(golden.length >= 20, `golden holds ${golden.length}`)
    for (const g of golden) {
      assert.ok(!g.src.includes('++'), g.src)
      assert.equal(markdownToHtml(g.src, ORIGIN, g.opts), g.html, g.src)
    }
  })
  it('++text++ is <u>', () => {
    assert.equal(markdownToHtml('a ++word++ b'), '<p>a <u>word</u> b</p>')
  })
  it('inline markdown and links inside it still work', () => {
    assert.equal(markdownToHtml('++**both**++'), '<p><u><strong>both</strong></u></p>')
    assert.match(markdownToHtml('++see https://example.com/x++'), /^<p><u>see <a href="https:\/\/example.com\/x"[^>]*>https:\/\/example.com\/x<\/a><\/u><\/p>$/)
  })
  it('beside **bold** and _em_ on one line, and over a list body', () => {
    assert.equal(markdownToHtml('**B** ++U++ _e_'), '<p><strong>B</strong> <u>U</u> <em>e</em></p>')
    assert.equal(markdownToHtml('**++ub++**'), '<p><strong><u>ub</u></strong></p>')
    assert.equal(markdownToHtml('1. ++one++\n2. two'), '<ol><li><u>one</u></li><li>two</li></ol>')
  })
  it('twins stay text: C++, a spaced ++, an empty ++++, an unclosed ++', () => {
    assert.equal(markdownToHtml('C++ and C++'), '<p>C++ and C++</p>')
    assert.equal(markdownToHtml('a ++ b ++ c'), '<p>a ++ b ++ c</p>')
    assert.equal(markdownToHtml('++++'), '<p>++++</p>')
    assert.equal(markdownToHtml('++open'), '<p>++open</p>')
  })
  it('raw <u> HTML is still text, never markup', () => {
    assert.equal(markdownToHtml('<u>x</u>'), '<p>&lt;u&gt;x&lt;/u&gt;</p>')
  })
})
