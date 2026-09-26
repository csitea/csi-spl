// SPL-975 (owner, 2026-09-26, topic 467d6325): markdown renders WITHOUT a
// fence in messages, comments and issue descriptions: all the major syntax,
// GFM pipe tables and HTML tables through a strict allow-list. ```md fences
// keep rendering; a short plain line does not change.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { htmlTableNodes, markdownToHtml, markdownTree, treeToHtml } from '../../src/utils/markdown.mjs'
import { looksLikeMarkdown, markdownSource, mentionParts, parseBody } from '../../src/utils/code-blocks.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const WHOLE = { breaks: true, html: true }
/* what MessageBody + MarkdownBlock(bare) render, as HTML */
const render = (body) => markdownToHtml(markdownSource(body), undefined, WHOLE)

describe('one fixture per syntax, no fence', () => {
  const cases = [
    ['heading', '## Обхват\ntext', /<h2>Обхват<\/h2>/],
    ['h1..h6', '# a\n###### f', /<h1>a<\/h1><h6>f<\/h6>/],
    ['bold', 'a **b** c\n- x', /<strong>b<\/strong>/],
    ['italic *', 'an *em* word', /<em>em<\/em>/],
    ['italic _', 'an _em_ word', /<em>em<\/em>/],
    ['strike', 'was ~~old~~', /<s>old<\/s>/],
    ['bulleted list', '- a\n- b', /<ul>\s*<li>a<\/li>\s*<li>b<\/li>\s*<\/ul>/],
    ['numbered list', '1. a\n2. b', /<ol>\s*<li>a<\/li>\s*<li>b<\/li>\s*<\/ol>/],
    ['nested list', '- a\n  - a1\n- b', /<li>a\s*<ul>\s*<li>a1<\/li>\s*<\/ul>\s*<\/li>/],
    ['link', 'see [the doc](https://example.com/x)', /<a href="https:\/\/example\.com\/x"[^>]*>the doc<\/a>/],
    ['inline code', '- use `rm -rf` never', /<code>rm -rf<\/code>/],
    ['code block', '## run\n```bash\nls -la\n```', /<pre data-lang="bash"><code>ls -la<\/code><\/pre>/],
    ['blockquote', '> quoted', /<blockquote>\s*<p>quoted<\/p>\s*<\/blockquote>/],
    ['GFM pipe table', '| a | b |\n|---|--:|\n| 1 | 2 |', /<table><thead><tr><th>a<\/th><th data-align="right">b<\/th><\/tr><\/thead><tbody><tr><td>1<\/td><td data-align="right">2<\/td><\/tr><\/tbody><\/table>/],
    ['horizontal rule', '- a\n\n---\n\nb', /<hr>/],
    ['HTML table', '<table><thead><tr><th>k</th></tr></thead><tbody><tr><td align="center">v</td></tr></tbody></table>', /<table><thead><tr><th>k<\/th><\/tr><\/thead><tbody><tr><td data-align="center">v<\/td><\/tr><\/tbody><\/table>/],
    ['line break', '- x\n\nline one\nline two', /line one<br>line two/],
  ]
  for (const [name, src, want] of cases) {
    it(name, () => {
      assert.equal(looksLikeMarkdown(src), true, `${name} must switch to markdown`)
      assert.match(render(src), want)
    })
  }
})

describe('a plain message does not change', () => {
  for (const s of [
    'hello',
    'ok **bold** and https://example.com',
    'PR #12 and #13 landed',
    'rm *.log *.tmp',
    'price 2*3*4',
    'foo_bar_baz and snake_case',
    'a -> b',
    '`- not a list`',
    '```\n- inside a code block\n```',
    '@CLE-1 please look',
  ]) {
    it(JSON.stringify(s), () => assert.equal(looksLikeMarkdown(s), false))
  }
})

describe('fences stay backward compatible', () => {
  it('a ```md fence alone keeps the fenced path (MarkdownBlock with Show source)', () => {
    const body = 'intro\n```md\n| a |\n|---|\n| 1 |\n```'
    assert.equal(looksLikeMarkdown(body), false)
    assert.deepEqual(parseBody(body).map((b) => [b.type, b.lang || '']), [['para', ''], ['code', 'md']])
  })

  it('whole-body mode unwraps a ```md fence and keeps other fences as code', () => {
    const body = '## T\n```md\n| a |\n|---|\n| 1 |\n```\n```js\nlet `x`\n```'
    const src = markdownSource(body)
    assert.doesNotMatch(src, /```md/)
    assert.match(render(body), /<table>/)
    assert.match(render(body), /<pre data-lang="js"><code>let `x`<\/code><\/pre>/)
  })

  it('Slack fences: a mid-line ``` block and an unclosed one still read as code', () => {
    assert.match(render('- a\nsee ```x = 1``` here'), /<pre><code>x = 1<\/code><\/pre>/)
    assert.match(render('- a\n```\nopen'), /<pre><code>open<\/code><\/pre>/)
  })

  it('a {{wiki}} region renders its markdown and the markers are gone', () => {
    const html = render('- a\n{{wiki}}\n# W\n{{/wiki}}')
    assert.match(html, /<h1>W<\/h1>/)
    assert.doesNotMatch(html, /wiki/)
  })

  it('a fenced md block keeps html off and no breaks (as before)', () => {
    assert.equal(markdownToHtml('a\nb'), '<p>a\nb</p>')
    assert.match(markdownToHtml('<table><tr><td>x</td></tr></table>'), /&lt;table&gt;/)
  })

  it('mentions stay mentions', () => {
    assert.deepEqual(mentionParts('hi @CLE-35016 and a@b.io').map((p) => p.type), ['text', 'mention', 'text'])
  })
})

describe('hostile input never becomes markup', () => {
  const XSS = [
    '<script>alert(1)</script>',
    '<img src=x onerror=alert(1)>',
    '<svg onload=alert(1)>',
    '<iframe src="javascript:alert(1)"></iframe>',
    '[x](javascript:alert(1))',
    '[x](data:text/html,<script>alert(1)</script>)',
    '<a href="javascript:alert(1)">x</a>',
    '<table><tr><td onclick="alert(1)" style="background:url(javascript:alert(1))">c</td></tr></table>',
    '<table><tr><td><script>alert(1)</script><img src=x onerror=alert(1)>c</td></tr></table>',
    '<table><tr><td><a href="javascript:alert(1)">x</a><style>*{display:none}</style></td></tr></table>',
    '<table><tr><td colspan="999" rowspan="x" align="evil">c</td></tr></table>',
    '<table><tr><td>&lt;script&gt;alert(1)&lt;/script&gt;&#0;&#xD800;</td></tr></table>',
    '<TABLE><TR><TD><div onmouseover=alert(1)>c</div></TD></TR></TABLE>',
    '<table><!-- <script>alert(1)</script> --><tr><td>c</td></tr></table>',
  ]
  for (const src of XSS) {
    it(src, () => {
      const html = render('- x\n\n' + src)
      assert.doesNotMatch(html, /<(script|img|svg|iframe|style|div|a\b[^>]*javascript)/i)
      assert.doesNotMatch(html, /<[^>]*\son\w+=/i)
      assert.doesNotMatch(html, /<[^>]*style=/i)
      assert.doesNotMatch(html, /href="(javascript|data):/i)
    })
  }

  it('the table allow-list keeps only its attributes', () => {
    const html = treeToHtml(htmlTableNodes('<table><tr><td colspan="999" rowspan="2" align="evil" style="text-align:right">c</td></tr></table>'))
    assert.equal(html, '<table><tr><td data-align="right" rowspan="2">c</td></tr></table>')
  })

  it('script-like elements lose their content; other tags keep their text', () => {
    assert.equal(treeToHtml(htmlTableNodes('<table><tr><td><script>bad()</script><span>ok</span></td></tr></table>')), '<table><tr><td>ok</td></tr></table>')
  })

  it('entities decode to TEXT, never markup', () => {
    const tree = htmlTableNodes('<table><tr><td>&lt;b&gt;x&lt;/b&gt;</td></tr></table>')
    assert.equal(treeToHtml(tree), '<table><tr><td>&lt;b&gt;x&lt;/b&gt;</td></tr></table>')
  })

  it('a raw tag outside a table stays visible text', () => {
    assert.match(render('- x\n\nsay <b>hi</b> <script>x</script>'), /&lt;b&gt;hi&lt;\/b&gt; &lt;script&gt;x&lt;\/script&gt;/)
  })

  it('the tree has no attribute outside the allow-list', () => {
    const walk = (nodes) => nodes.every((n) => typeof n === 'string' || (Object.keys(n.attrs).every((k) => ['href', 'title', 'start', 'data-align', 'data-lang', 'colspan', 'rowspan'].includes(k)) && walk(n.children)))
    assert.ok(walk(markdownTree(markdownSource(XSS.join('\n\n')), WHOLE)))
  })
})

describe('the components', () => {
  const body = read('src/components/MessageBody.vue')
  const block = read('src/components/MarkdownBlock.vue')
  const desc = read('src/components/IssueDescription.vue')
  const issues = read('src/pages/issues.vue')

  it('MessageBody switches to markdown only when the body looks like it, or is told to', () => {
    assert.match(body, /props\.markdown \|\| looksLikeMarkdown\(props\.body\)/)
    assert.match(body, /<MarkdownBlock v-if="mdSource !== null"[^>]*bare/)
    // markdown-it stays a lazy chunk
    assert.doesNotMatch(body, /utils\/markdown\.mjs/)
  })

  it('bare mode: breaks + html tables, CodeBlock for code, mentions, no v-html', () => {
    assert.match(block, /props\.bare \? \{ breaks: true, html: true \}/)
    assert.match(block, /h\(CodeBlock/)
    assert.match(block, /mentionParts/)
    assert.doesNotMatch(block.replace(/<!--[\s\S]*?-->/g, ''), /v-html|innerHTML/)
  })

  it('the description: rendered view, click / Enter / e edits, blur saves, a failed save shows an error', () => {
    assert.match(desc, /data-test="issues-detail-rendered"/)
    assert.match(desc, /@click="onViewClick"/)
    assert.match(desc, /@keydown\.enter\.self\.prevent="edit"/)
    assert.match(desc, /@blur="commit"/)
    assert.match(desc, /role="alert" data-test="issues-description-error"/)
    assert.match(desc, /if \(ok\) close\(\)/)
    // the view returns after the pointer is up, so the click that blurred the editor lands
    assert.match(desc, /addEventListener\('pointerup', \(\) => setTimeout/)
    assert.match(issues, /if \(k === 'e' && form\.value\) \{ void descEl\.value\?\.edit\(\)/)
    assert.match(issues, /return !saveError\.value/)
  })
})
