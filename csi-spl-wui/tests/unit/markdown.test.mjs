// spec 040 markdown compatibility (owner, 2026-09-26): a ```md / ```markdown
// fence renders as standard markdown; raw HTML never runs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { renderMarkdown } from '../../src/utils/markdown.mjs'
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
    const internal = renderMarkdown('[home](https://spool-hub.ai/channel/x) [dev](https://dev.spool-hub.ai/channel/x)')
    assert.match(internal, /<a href="https:\/\/spool-hub.ai\/channel\/x"[^>]*rel="nofollow">home<\/a>/)
    assert.match(internal, /dev\.spool-hub.ai\/channel\/x" title="https:\/\/dev\.spool-hub.ai\/channel\/x" target="_blank"/)
  })
  it('CONTROL: raw HTML and script links never become markup', () => {
    const html = renderMarkdown('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1))')
    assert.equal(/<script/i.test(html), false)
    assert.equal(/<img/i.test(html), false)
    assert.equal(/href="javascript:/i.test(html), false)
    assert.match(html, /&lt;script&gt;/)
  })
})
