// SPL-2466 row 02 (md-tables panel plan v1.0, section 3.4): a post styles a
// table with portable author hints. A "<!-- table: ... -->" comment on the
// line before or after a pipe table, a "Table: [...]" caption hint, or an
// HTML table's class become md-table--<hint> classes on the table; the
// comment leaves the text. Only TABLE_HINTS words pass, nothing else.
//
// Red control: on a markdown.mjs without the hint pass (origin/master
// 27d840dc5) the comment renders as a visible paragraph or row and no table
// carries a class: 14 of these 18 tests fail; the 4 CONTROL and no-class
// tests pass on both.
//
// Run: node tests/unit/markdown-table-hints.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { markdownTree, renderMarkdown, safeTableClass, treeToHtml } from '../../src/utils/markdown.mjs'

const T = '| metric | value |\n|---|---|\n| memory | 142MB |\n| cpu | 4% |\n| disk | 9 GB |'
const ROWS = '<tr><td>memory</td><td>142MB</td></tr><tr><td>cpu</td><td>4%</td></tr><tr><td>disk</td><td>9 GB</td></tr>'
const BODY = `<thead><tr><th>metric</th><th>value</th></tr></thead><tbody>${ROWS}</tbody>`
const MSG = { html: true, breaks: true }
const tableOf = (src, opts) => markdownTree(src, opts).find((n) => typeof n !== 'string' && n.tag === 'table')

describe('table author hints: comment', () => {
  for (const [name, opts] of [['a ```md fence', undefined], ['a whole message', MSG]]) {
    it(`${name}: the comment on the line before is taken out and its hints become classes`, () => {
      for (const src of [`<!-- table: compact, no-sort -->\n${T}`, `<!-- table: compact, no-sort -->\n\n${T}`]) {
        assert.equal(renderMarkdown(src, undefined, opts), `<table class="md-table--compact md-table--no-sort">${BODY}</table>`)
      }
    })
    it(`${name}: the comment on the line after is taken out, never left as a row`, () => {
      for (const src of [`${T}\n<!-- table: dense -->`, `${T}\n\n<!-- table: dense -->`]) {
        assert.equal(renderMarkdown(src, undefined, opts), `<table class="md-table--dense">${BODY}</table>`)
      }
    })
  }
  it('every hint word maps to its class, case and spacing aside', () => {
    const t = tableOf(`<!--table:Compact dense,no-zebra , stacked scroll no-sort-->\n${T}`)
    assert.equal(t.attrs.class, 'md-table--compact md-table--dense md-table--no-zebra md-table--stacked md-table--scroll md-table--no-sort')
  })
  it('a hint comment goes to the table after it, not also to the one before', () => {
    const tree = markdownTree(`${T}\n\n<!-- table: compact -->\n\n${T}`)
    const tables = tree.filter((n) => typeof n !== 'string' && n.tag === 'table')
    assert.equal(tables.length, 2)
    assert.equal(tables[0].attrs.class, undefined)
    assert.equal(tables[1].attrs.class, 'md-table--compact')
    assert.equal(tree.length, 2)
  })
  it('CONTROL: a hint comment away from a table, or naming no known hint, stays as written', () => {
    assert.equal(renderMarkdown('<!-- table: compact -->'), '<p>&lt;!-- table: compact --&gt;</p>')
    assert.equal(renderMarkdown(`<!-- table: compact -->\n\nprose\n\n${T}`).match(/table: compact/g).length, 1)
    assert.match(renderMarkdown(`<!-- table: fancy -->\n${T}`), /^<p>&lt;!-- table: fancy --&gt;<\/p><table>/)
    assert.match(renderMarkdown(`<!-- note: compact -->\n${T}`), /^<p>&lt;!-- note: compact --&gt;<\/p><table>/)
  })
  it('an unknown word next to a known one is dropped silently', () => {
    assert.equal(tableOf(`<!-- table: compact, evil -->\n${T}`).attrs.class, 'md-table--compact')
  })
})

describe('table author hints: caption', () => {
  it('a leading [hints] bracket is taken off the caption and applied', () => {
    const html = renderMarkdown(`${T}\nTable: [compact, dense] Performance summary`)
    assert.equal(html, `<table class="md-table--compact md-table--dense"><caption><strong>Table:</strong> Performance summary</caption>${BODY}</table>`)
    assert.match(renderMarkdown(`${T}\n\nTable: [no-zebra] Runs`), /^<table class="md-table--no-zebra"><caption><strong>Table:<\/strong> Runs<\/caption>/)
  })
  it('a bracket alone is the whole hint: the caption keeps its label only', () => {
    assert.match(renderMarkdown(`${T}\nTable: [scroll]`), /^<table class="md-table--scroll"><caption><strong>Table:<\/strong><\/caption>/)
  })
  it('CONTROL: a bracket that names no hint stays caption text', () => {
    assert.match(renderMarkdown(`${T}\nTable: [draft] Results`), /^<table><caption><strong>Table:<\/strong> \[draft\] Results<\/caption>/)
  })
  it('a comment hint and a caption hint add up', () => {
    assert.deepEqual(tableOf(`<!-- table: compact -->\n${T}\nTable: [no-sort] x`).attrs.class.split(' ').sort(), ['md-table--compact', 'md-table--no-sort'])
  })
})

describe('table author hints: html table class', () => {
  it('allow-listed words on <table class> become classes, the rest are dropped', () => {
    const html = renderMarkdown('<table class="compact no-sort evil md-table--dense"><tr><td>1</td></tr></table>', undefined, MSG)
    assert.equal(html, '<table class="md-table--compact md-table--no-sort md-table--dense"><tr><td>1</td></tr></table>')
  })
  it('a table with no known class has no class attribute', () => {
    assert.equal(renderMarkdown('<table class="x y"><tr><td>1</td></tr></table>', undefined, MSG), '<table><tr><td>1</td></tr></table>')
  })
})

describe('table author hints: hostile input', () => {
  it('a style, an event handler or a crafted class never reaches the table', () => {
    const html = renderMarkdown('<table class="compact&quot; onclick=&quot;x" style="color:red" onmouseover="alert(1)" id="x"><tr><td>1</td></tr></table>', undefined, MSG)
    assert.equal(html, '<table><tr><td>1</td></tr></table>')
  })
  it('a hint comment cannot carry markup or a class outside the set', () => {
    const src = `<!-- table: compact" onclick="x --><script>alert(1)</script>\n${T}`
    assert.doesNotMatch(renderMarkdown(src, undefined, MSG), /<script|onclick="|class="(?!md-table--)/)
    assert.equal(tableOf(`<!-- table: md-table--x, Compact -->\n${T}`).attrs.class, 'md-table--compact')
  })
  it('safeTableClass keeps only md-table--<hint> words, once each', () => {
    assert.equal(safeTableClass('md-table--compact md-table--compact x md-table--evil msg-link md-table--scroll'), 'md-table--compact md-table--scroll')
    assert.equal(safeTableClass(undefined), '')
    assert.equal(safeTableClass('md-table--compact" onclick="x'), '')
  })
  it('a tree node with a forged class is filtered again at render', () => {
    const forged = [{ tag: 'table', attrs: { class: 'md-table--compact evil', style: 'x' }, children: [] }]
    assert.equal(treeToHtml(forged), '<table class="md-table--compact"></table>')
    assert.equal(treeToHtml([{ tag: 'table', attrs: { class: 'evil' }, children: [] }]), '<table></table>')
  })
})
