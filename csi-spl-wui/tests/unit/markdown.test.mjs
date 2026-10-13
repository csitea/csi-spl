// spec 040 markdown compatibility (owner, 2026-09-26): a ```md / ```markdown
// fence renders as standard markdown; raw HTML never runs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ANCHOR_PREFIX, headingSlug, markdownTree, renderMarkdown, splitFootnotes } from '../../src/utils/markdown.mjs'
import { isMarkdownLang, parseBody } from '../../src/utils/code-blocks.mjs'

describe('markdown compatibility', () => {
  it('the start/stop tag is a fence labelled md or markdown', () => {
    assert.equal(isMarkdownLang('md'), true)
    assert.equal(isMarkdownLang('Markdown'), true)
    assert.equal(isMarkdownLang('js'), false)
    assert.equal(isMarkdownLang(''), false)
    const blocks = parseBody('before\n```md\n# Title\n```\nafter')
    const fence = blocks.find((b) => b.type === 'code')
    assert.ok(fence && isMarkdownLang(fence.lang), JSON.stringify(blocks))
  })
  it('renders tables, lists, headings, emphasis', () => {
    const html = renderMarkdown('# Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- one\n- two\n\n1. x\n\n**bold** _it_ ~~gone~~')
    assert.match(html, /<h1>Plan<\/h1>/)
    assert.match(html, /<table>[\s\S]*<th>a<\/th>[\s\S]*<td>2<\/td>/)
    assert.match(html, /<ul>\s*<li>one<\/li>/)
    assert.match(html, /<ol>/)
    assert.match(html, /<strong>bold<\/strong>/)
    assert.match(html, /<em>it<\/em>/)
    assert.match(html, /<s>gone<\/s>/)
  })
  it('links are http/https/mailto only and open safely', () => {
    const html = renderMarkdown('[ok](https://example.com) [mail](mailto:a@example.com)')
    assert.match(html, /<a href="https:\/\/example.com\/" title="https:\/\/example.com\/" target="_blank" rel="noopener noreferrer nofollow">ok<\/a>/)
    assert.match(html, /href="mailto:a@example.com"/)
    const fromPrd = renderMarkdown('[home](https://app.example/channel/x) [dev](https://dev.app.example/channel/x)', 'https://app.example')
    assert.match(fromPrd, /<a href="https:\/\/app\.example\/channel\/x" title="https:\/\/app\.example\/channel\/x">home<\/a>/)
    assert.match(fromPrd, /dev\.app\.example\/channel\/x" title="https:\/\/dev\.app\.example\/channel\/x" target="_blank"/)
    const fromDev = renderMarkdown('[home](https://app.example/channel/x) [dev](https://dev.app.example/channel/x)', 'https://dev.app.example')
    assert.match(fromDev, /<a href="https:\/\/app\.example\/channel\/x" title="https:\/\/app\.example\/channel\/x" target="_blank"/)
    assert.match(fromDev, /<a href="https:\/\/dev\.app\.example\/channel\/x" title="https:\/\/dev\.app\.example\/channel\/x">dev<\/a>/)
  })
  it('CONTROL: raw HTML and script links never become markup', () => {
    const html = renderMarkdown('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1))')
    assert.equal(/<script/i.test(html), false)
    assert.equal(/<img/i.test(html), false)
    assert.equal(/href="javascript:/i.test(html), false)
    assert.match(html, /&lt;script&gt;/)
  })
})

// spec 137 T018 (§1.4, F18-F20): task lists, footnotes and heading ids, the
// three a repo doc uses that the renderer dropped (104, 17 and 5 files).
describe('spec 137 T018: task lists, footnotes, heading ids', () => {
  it('a task item is an li marked todo / done, its marker gone', () => {
    const html = renderMarkdown('- [ ] open\n- [x] shut\n- [X] also\n- plain')
    assert.match(html, /<li data-task="todo">open<\/li>/)
    assert.match(html, /<li data-task="done">shut<\/li>/)
    assert.match(html, /<li data-task="done">also<\/li>/)
    assert.match(html, /<li>plain<\/li>/)
    const loose = renderMarkdown('- [ ] one\n\n- [x] two')
    assert.match(loose, /<li data-task="todo"><p>one<\/p><\/li>/)
  })
  it('CONTROL: a bracket that is no task marker stays text', () => {
    assert.match(renderMarkdown('- [y] no\n- []x'), /<li>\[y\] no<\/li><li>\[\]x<\/li>/)
    assert.doesNotMatch(renderMarkdown('[ ] not a list'), /data-task/)
  })
  it('a footnote is a superscript number, its note listed after the document', () => {
    const tree = markdownTree('Alpha[^a] beta[^b] again[^a].\n\n[^b]: Second.\n[^a]: First *one*\n    still first')
    const html = renderMarkdown('Alpha[^a] beta[^b] again[^a].\n\n[^b]: Second.\n[^a]: First *one*\n    still first')
    assert.match(html, /^<p>Alpha<sup>1<\/sup> beta<sup>2<\/sup> again<sup>1<\/sup>\.<\/p><hr><ol data-footnotes="true">/)
    assert.match(html, /<li>First <em>one<\/em>\nstill first<\/li><li>Second\.<\/li><\/ol>$/)
    assert.equal(tree.at(-1).tag, 'ol')
    assert.equal(tree.at(-1).children.length, 2)
  })
  it('CONTROL: a citation with no note, and a note in a code fence, stay as written', () => {
    assert.equal(renderMarkdown('x[^none]'), '<p>x[^none]</p>')
    const html = renderMarkdown('```\n[^1]: code\n```\ny[^1]')
    assert.match(html, /<pre><code>\[\^1\]: code<\/code><\/pre><p>y\[\^1\]<\/p>/)
    assert.doesNotMatch(html, /<sup>/)
    assert.equal(renderMarkdown('`a[^1]`\n\n[^1]: n'), '<p><code>a[^1]</code></p>')
  })
  it('splitFootnotes takes the definitions out, the first of an id wins', () => {
    const r = splitFootnotes('a\n[^1]: one\n[^1]: two\nb')
    assert.equal(r.body, 'a\nb')
    assert.deepEqual([...r.notes], [['1', 'one']])
  })
  it('anchors: each heading has a prefixed slug id, repeats numbered', () => {
    const html = renderMarkdown('# Hello, World!\n\n## Hello World\n\n## Hello World\n\n### Über `code` 1.2', undefined, { anchors: true })
    assert.match(html, new RegExp(`<h1 id="${ANCHOR_PREFIX}hello-world">`))
    assert.match(html, /<h2 id="md-hello-world-1">Hello World<\/h2><h2 id="md-hello-world-2">/)
    assert.match(html, /<h3 id="md-über-code-12">/)
    assert.equal(headingSlug(' A  b_c-d? '), 'a--b_c-d')
  })
  it('anchors: a #fragment link finds its heading; a footnote links there and back', () => {
    const html = renderMarkdown('# Top\n\n[up](#top) n[^x]\n\n[^x]: note', undefined, { anchors: true })
    assert.match(html, /<a href="#md-top" title="#md-top">up<\/a>/)
    assert.match(html, /<sup id="md-fnref-x"><a href="#md-fn-x" title="#md-fn-x">1<\/a><\/sup>/)
    assert.match(html, /<li id="md-fn-x">note <a href="#md-fnref-x" title="#md-fnref-x">↩<\/a><\/li>/)
  })
  it('CONTROL: without anchors (a chat message) no id is written at all', () => {
    const html = renderMarkdown('# Top\n\n[up](#top) n[^x]\n\n[^x]: note')
    assert.doesNotMatch(html, / id=/)
    assert.match(html, /<a href="#top" title="#top">up<\/a>/)
  })
  it('CONTROL: an id is a slug, never markup or a global name as written', () => {
    const html = renderMarkdown('# <img src=x onerror=alert(1)>\n\n# location\n\n# "quoted"', undefined, { anchors: true })
    assert.doesNotMatch(html, /<img/)
    assert.match(html, /<h1 id="md-img-srcx-onerroralert1">/)
    assert.match(html, /<h1 id="md-location">location<\/h1>/)
    assert.match(html, /<h1 id="md-quoted">&quot;quoted&quot;<\/h1>/)
  })
})
