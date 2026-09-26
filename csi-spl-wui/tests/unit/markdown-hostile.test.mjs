// Hostile markdown (SPL-73, spec 040): whatever sits between the ```md
// start and stop marker, the render tree holds only allow-listed tags and
// attributes, every href is an absolute http / https / mailto URL or a
// safe relative path (SPL-951), nothing is fetched, and the component
// never binds HTML.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { ATTRS, TAGS, markdownToHtml, markdownTree, safeHref, treeToHtml } from '../../src/utils/markdown.mjs'
import { classifyHref } from '../../src/utils/link-target.mjs'
import { hasMarkdownBlock, isMarkdownLang, parseBody } from '../../src/utils/code-blocks.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

/** Every element of a tree, depth first. */
function* walk(nodes) {
  for (const n of nodes) {
    if (typeof n === 'string') continue
    yield n
    yield* walk(n.children)
  }
}

/** The tree obeys the allow-list: tags, attributes, link schemes. */
function assertClean(src) {
  const tree = markdownTree(src)
  for (const n of walk(tree)) {
    assert.ok(TAGS.has(n.tag), `tag <${n.tag}> from ${JSON.stringify(src)}`)
    const allowed = ATTRS[n.tag] || new Set()
    for (const k of Object.keys(n.attrs)) {
      assert.ok(allowed.has(k), `attribute ${k} on <${n.tag}> from ${JSON.stringify(src)}`)
    }
    if (n.tag === 'a') {
      const c = classifyHref(n.attrs.href, 'https://app.example')
      assert.ok(c, `href ${n.attrs.href} from ${JSON.stringify(src)}`)
      if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(n.attrs.href)) {
        const u = new URL(n.attrs.href)
        assert.ok(['http:', 'https:', 'mailto:'].includes(u.protocol), `href ${n.attrs.href}`)
      }
    }
  }
  // the string form too: text is escaped, so every "<" left is a real tag
  const html = treeToHtml(tree)
  for (const [, tag, attrs] of html.matchAll(/<\/?([a-z0-9]+)([^>]*)>/gi)) {
    assert.ok(TAGS.has(tag.toLowerCase()), `<${tag}> in ${html}`)
    for (const [, k] of attrs.matchAll(/\s([^\s=]+)="[^"]*"/g)) {
      assert.ok(['href', 'title', 'start', 'data-align', 'data-lang', 'target', 'rel'].includes(k), `${k} in ${html}`)
    }
  }
  for (const m of html.matchAll(/href="([^"]*)"/g)) {
    const href = m[1].replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    assert.ok(classifyHref(href, 'https://app.example'), `html href ${href}`)
  }
  return { tree, html }
}

const HOSTILE = [
  '<script>alert(1)</script>',
  '<SCRIPT SRC=https://evil.example/x.js></SCRIPT>',
  '<style>body{display:none}</style>',
  '<iframe src="https://evil.example"></iframe>',
  '<object data="https://evil.example/x.swf"></object><embed src="x">',
  '<img src=x onerror=alert(1)>',
  '<svg onload=alert(1)><circle/></svg>',
  '<div onclick="alert(1)" style="position:fixed">x</div>',
  '<a href="javascript:alert(1)">x</a>',
  '<form action="https://evil.example"><input name=p></form>',
  '[x](javascript:alert(1))',
  '[x](JaVaScRiPt:alert(1))',
  '[x](java\tscript:alert(1))',
  '[x](jav&#x61;script:alert(1))',
  '[x](%6Aavascript:alert(1))',
  '[x]( javascript:alert(1))',
  '[x](vbscript:msgbox(1))',
  '[x](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)',
  '[x](file:///etc/passwd)',
  '[x](//evil.example/path)',
  '[x](/relative/path)',
  '[x](#frag)',
  '<javascript:alert(1)>',
  '[x][r]\n\n[r]: javascript:alert(1)',
  '![x](javascript:alert(1))',
  '![x](data:image/svg+xml;base64,PHN2ZyBvbmxvYWQ9YWxlcnQoMSk+)',
  '![pixel](https://tracker.example/p.gif)',
  '[x](https://ok.example "t\\" onmouseover=\\"alert(1)")',
  '| a |\n|---|\n| <script>alert(1)</script> |',
  '- <img src=x onerror=alert(1)>\n- [y](javascript:alert(1))',
  '> <iframe src=https://evil.example>',
  '`<script>alert(1)</script>`',
  '```html\n<script>alert(1)</script>\n```',
  '# <script>alert(1)</script>',
  '[x](https://ok.example){style="color:red" onclick="alert(1)"}',
  '<!-- comment --><?php echo 1 ?><![CDATA[ x ]]>',
  'x\u202Egpj.exe [a](https://ok.example/\u202Egnp.exe)',
]

describe('hostile markdown never becomes markup', () => {
  for (const src of HOSTILE) {
    it(JSON.stringify(src).slice(0, 70), () => { assertClean(src) })
  }

  it('raw HTML arrives as visible text, not as nothing', () => {
    const { html } = assertClean('<script>alert(1)</script>')
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/)
  })

  it('an unsafe link keeps its text and loses its href', () => {
    const { tree } = assertClean('[click me](javascript:alert(1))')
    assert.deepEqual(tree, [{ tag: 'p', attrs: {}, children: ['click me'] }])
  })

  it('an image is never fetched: a safe one is a link to the picture, labelled with its alt', () => {
    const { tree } = assertClean('![the chart](https://example.com/c.png)')
    assert.deepEqual(tree, [{
      tag: 'p',
      attrs: {},
      children: [{ tag: 'a', attrs: { href: 'https://example.com/c.png', title: 'https://example.com/c.png' }, children: ['the chart'] }],
    }])
  })

  it('a deeply nested input renders without throwing', () => {
    assertClean('>'.repeat(5000) + ' deep')
    assertClean('- '.repeat(2000) + 'deep')
    assertClean('*'.repeat(20000) + 'x')
  })

  it('safeHref: three schemes, absolute only', () => {
    assert.equal(safeHref('https://example.com/a?b=1'), 'https://example.com/a?b=1')
    assert.equal(safeHref('mailto:a@example.com'), 'mailto:a@example.com')
    for (const bad of ['javascript:alert(1)', 'data:text/html,x', 'vbscript:x', 'file:///x', '/rel', '//host/x', '', 'http://']) {
      assert.equal(safeHref(bad), '', bad)
    }
  })

  it('CONTROL: treeToHtml drops a tag or attribute a broken tree smuggles in', () => {
    const smuggled = [{ tag: 'script', attrs: {}, children: ['alert(1)'] },
      { tag: 'p', attrs: { onclick: 'alert(1)', style: 'x' }, children: ['ok'] }]
    assert.equal(treeToHtml(smuggled), 'alert(1)<p>ok</p>')
  })
})

describe('the start/stop marker', () => {
  it('a fence tagged md or markdown, any case; nothing else', () => {
    for (const l of ['md', 'MD', 'markdown', 'Markdown']) assert.equal(isMarkdownLang(l), true, l)
    for (const l of ['', 'text', 'mdx', 'markdownx', 'js', ' md']) assert.equal(isMarkdownLang(l), false, l)
  })

  it('hasMarkdownBlock sees the marker, not a mention of it', () => {
    assert.equal(hasMarkdownBlock('a\n```md\n# T\n```\nb'), true)
    assert.equal(hasMarkdownBlock('```markdown\n- x'), true)
    assert.equal(hasMarkdownBlock('write `md` fences'), false)
    assert.equal(hasMarkdownBlock('```text\n# T\n```'), false)
  })

  it('outside the marker nothing changes: links, inline code and fences parse as before', () => {
    const body = 'see https://example.com and `x`\n```md\n| a |\n|---|\n| 1 |\n```\n```js\nlet a\n```'
    const blocks = parseBody(body)
    assert.equal(blocks[0].type, 'para')
    assert.deepEqual(blocks[0].parts.map((p) => p.type), ['text', 'link', 'text', 'inline'])
    assert.deepEqual(blocks.slice(1).map((b) => [b.type, b.lang]), [['code', 'md'], ['code', 'js']])
  })
})

describe('the component', () => {
  const block = read('src/components/MarkdownBlock.vue')
  const body = read('src/components/MessageBody.vue')

  it('binds no HTML: the tree is rendered with h()', () => {
    assert.doesNotMatch(block, /v-html=|innerHTML|domProps/)
    assert.match(block, /\bh\(/)
  })

  it('markdown-it is a lazy chunk: only a dynamic import reaches markdown.mjs', () => {
    assert.match(block, /import\('~\/utils\/markdown\.mjs'\)/)
    // a type-only import is erased at build time; a value import would be eager
    assert.doesNotMatch(block, /^import (?!type )[^\n]*from '~\/utils\/markdown\.mjs'/m)
    assert.doesNotMatch(body, /utils\/markdown\.mjs/)
  })

  it('links open through the shared target rule', () => {
    assert.match(block, /link-target\.mjs/)
    assert.match(block, /followSameTabLink/)
    assert.match(block, /linkOpen/)
    assert.doesNotMatch(block, /target:\s*'_blank'/)
  })

  it('tables scroll inside the block, never widen the page; no px font sizes', () => {
    assert.match(block, /\.md-table\)\s*\{[^}]*overflow-x:\s*auto/)
    assert.doesNotMatch(block, /font-size:\s*\d+px/)
  })

  it('the issue pane renders comments and the description through MessageBody', () => {
    const issues = read('src/pages/issues.vue')
    // SPL-982: a comment is a MessageCard, whose body is MessageBody
    assert.match(issues, /<MessageCard[\s\S]*?class="issues-comment"[\s\S]*?:msg="c"/)
    // SPL-975: the whole description renders as markdown, fenced or not
    assert.match(issues, /<IssueDescription\b/)
    assert.match(read('src/components/IssueDescription.vue'), /<MessageBody v-if="text\.trim\(\)" :body="text" markdown \/>/)
  })
})

describe('markdown the owner asked for still renders', () => {
  it('tables with alignment, lists, headings, emphasis, quotes, code', () => {
    const html = markdownToHtml('## T\n\n| l | r |\n|:--|--:|\n| 1 | 2 |\n\n- a\n- b\n\n3. c\n\n> q\n\n`x` **b** _e_ ~~s~~')
    assert.match(html, /<h2>T<\/h2>/)
    assert.match(html, /<th data-align="left">l<\/th><th data-align="right">r<\/th>/)
    assert.match(html, /<ul><li>a<\/li><li>b<\/li><\/ul>/)
    assert.match(html, /<ol start="3"><li>c<\/li><\/ol>/)
    assert.match(html, /<blockquote><p>q<\/p><\/blockquote>/)
    assert.match(html, /<code>x<\/code> <strong>b<\/strong> <em>e<\/em> <s>s<\/s>/)
  })
})
