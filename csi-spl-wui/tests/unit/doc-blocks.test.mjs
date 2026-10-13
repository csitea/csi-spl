// Spec 137 T010 / T011 (owner HUM-10, t1 bed3ed0a msgs 2c82489a and
// b1661d1c): the Qto paragraph toolbar's Insert table and Insert quote.
// The paragraph stays markdown (P-Q3, P-Q4 choice A): a pipe-table
// skeleton or a blockquote with its attribution line goes in at the
// cursor, on lines of its own, its first placeholder selected; and what
// was inserted renders as a table, and as a quote whose source line is
// set apart (p[data-cite]).
//
// Run: node tests/unit/doc-blocks.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'
import { renderMarkdown } from '../../src/utils/markdown.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

/** -doc-blocks.ts transpiled, then imported */
async function loadBlocks() {
  const tmp = mkdtempSync(join(tmpdir(), 'doc-blocks-'))
  try {
    const src = readFileSync(join(WUI, 'src/components/workspace-docs/-doc-blocks.ts'), 'utf8')
    const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    writeFileSync(join(tmp, 'doc-blocks.mjs'), js)
    return await import(pathToFileURL(join(tmp, 'doc-blocks.mjs')).href)
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

const { insertBlock, quoteBlock, tableBlock } = await loadBlocks()
const head = (n) => `Header ${n}`
const cell = (n) => `Cell ${n}`
const table = () => tableBlock(head, cell)
const quote = (sel) => quoteBlock(sel, 'Quoted passage', 'Author or source')
const picked = (r) => r.value.slice(r.selStart, r.selEnd)

describe('T010: Insert table', () => {
  it('the skeleton is the spec\'s 3-column pipe table, Header 1 picked', () => {
    const r = insertBlock('', 0, 0, table)
    assert.equal(r.value, '| Header 1 | Header 2 | Header 3 |\n|---|---|---|\n| Cell 1 | Cell 2 | Cell 3 |')
    assert.equal(picked(r), 'Header 1')
  })
  it('at the cursor in a sentence: its own block, a blank line on each side', () => {
    const v = 'Before the table. After it.'
    const r = insertBlock(v, 18, 18, table)
    assert.equal(r.value, 'Before the table.\n\n' + table().text + '\n\nAfter it.')
    assert.equal(picked(r), 'Header 1')
  })
  it('renders as a table with the text around it untouched', () => {
    const r = insertBlock('Intro\nline', 5, 5, table)
    const html = renderMarkdown(r.value)
    assert.match(html, /^<p>Intro<\/p><table><thead><tr><th>Header 1<\/th><th>Header 2<\/th><th>Header 3<\/th><\/tr><\/thead><tbody><tr><td>Cell 1<\/td>/)
    assert.match(html, /<\/table><p>line<\/p>$/)
  })
  it('CONTROL: glued on with no blank line, the next text runs into the table', () => {
    const html = renderMarkdown(table().text + '\nline')
    assert.match(html, /<td>line<\/td>/)
  })
  it('more rows and columns number their cells across', () => {
    assert.equal(tableBlock(head, cell, 2, 2).text, '| Header 1 | Header 2 |\n|---|---|\n| Cell 1 | Cell 2 |\n| Cell 3 | Cell 4 |')
  })
})

describe('T011: Insert quote', () => {
  it('no selection: passage placeholder, the attribution line, the passage picked', () => {
    const r = insertBlock('', 0, 0, quote)
    assert.equal(r.value, '> Quoted passage\n>\n> — [Author or source](https://)')
    assert.equal(picked(r), 'Quoted passage')
  })
  it('a selection is quoted, line by line, and the source is picked', () => {
    const v = 'He said:\nfirst line\n\nsecond line\nThe end.'
    const r = insertBlock(v, 9, 33, quote)
    assert.equal(r.value, 'He said:\n\n> first line\n>\n> second line\n>\n> — [Author or source](https://)\n\nThe end.')
    assert.equal(picked(r), 'Author or source')
  })
  it('renders as one blockquote whose last paragraph is the citation', () => {
    const r = insertBlock('', 0, 0, (s) => quoteBlock(s, 'To be.', 'Hamlet'))
    const done = r.value.replace('(https://)', '(https://example.com/play)')
    const html = renderMarkdown(done)
    assert.match(html, /^<blockquote><p>To be\.<\/p><p data-cite="true">— <a href="https:\/\/example\.com\/play"[^>]*>Hamlet<\/a><\/p><\/blockquote>$/)
  })
  it('CONTROL: a quote with no dash line, or a single dash paragraph, has no citation', () => {
    assert.doesNotMatch(renderMarkdown('> just a quote\n>\n> more'), /data-cite/)
    assert.doesNotMatch(renderMarkdown('> -- only line'), /data-cite/)
    assert.doesNotMatch(renderMarkdown('> a\n>\n> --not a dash line'), /data-cite/)
  })
})
