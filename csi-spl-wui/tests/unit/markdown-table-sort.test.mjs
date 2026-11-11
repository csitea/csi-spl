// SPL-2466 row 05 (md-tables panel plan v1.0, section 3.2): which tables in a
// post sort by a header click, and how MarkdownBlock / MdTable wire it.
// A table sorts with a header row and >= 3 body rows, no colspan / rowspan,
// no no-sort hint; a pipe table and an HTML table alike. The sort is a view:
// the tree keeps the author's order. The sort code is a lazy chunk.
//
// Red control: on origin/master c10b3ce97 there is no table-sort.ts and no
// MdTable.vue: the import fails and every test here fails.
//
// Run: node tests/unit/markdown-table-sort.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { markdownTree } from '../../src/utils/markdown.mjs'
import { importTs } from './lib/load-ts.mjs'

const { sortModel, sortOrder, MIN_SORT_ROWS } = await importTs('src/utils/table-sort.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const MSG = { html: true, breaks: true }
const tableOf = (src, opts = MSG) => markdownTree(src, opts).find((n) => typeof n !== 'string' && n.tag === 'table')
const pipe = (n) => ['| name | size |', '|---|---|', ...Array.from({ length: n }, (_, i) => `| r${i} | ${10 - i} KB |`)].join('\n')

describe('which tables sort', () => {
  it('the threshold is 3 body rows', () => assert.equal(MIN_SORT_ROWS, 3))
  for (const n of [1, 2]) {
    it(`a pipe table with ${n} body row(s) stays as written`, () => assert.equal(sortModel(tableOf(pipe(n))), null))
  }
  for (const n of [3, 12]) {
    it(`a pipe table with ${n} body rows sorts`, () => {
      const m = sortModel(tableOf(pipe(n)))
      assert.ok(m)
      assert.equal(m.rows.length, n)
      assert.deepEqual(m.cells[0], ['r0', '10 KB'])
      assert.equal(m.head.children.filter((c) => typeof c !== 'string').length, 2)
    })
  }
  it('in a ```md fence too', () => assert.ok(sortModel(tableOf(pipe(3), undefined))))
  it('a no-sort hint keeps it as written', () => {
    assert.equal(sortModel(tableOf(`<!-- table: no-sort -->\n${pipe(5)}`)), null)
    assert.equal(sortModel(tableOf(`${pipe(5)}\nTable: [no-sort] Sizes`)), null)
  })
  it('another hint does not stop the sort', () => assert.ok(sortModel(tableOf(`<!-- table: compact -->\n${pipe(5)}`))))
  it('a caption is not a body row', () => {
    const m = sortModel(tableOf(`${pipe(3)}\nTable: Sizes`))
    assert.ok(m)
    assert.equal(m.rows.length, 3)
  })
  const rows = '<tr><td>a</td><td>3</td></tr><tr><td>b</td><td>1</td></tr><tr><td>c</td><td>2</td></tr>'
  it('an HTML table with thead and tbody sorts', () => {
    assert.ok(sortModel(tableOf(`<table><thead><tr><th>k</th><th>v</th></tr></thead><tbody>${rows}</tbody></table>`)))
  })
  it('an HTML table without thead takes a first row of th as its header', () => {
    const m = sortModel(tableOf(`<table><tr><th>k</th><th>v</th></tr>${rows}</table>`))
    assert.ok(m)
    assert.equal(m.rows.length, 3)
    assert.deepEqual(m.cells.map((r) => r[1]), ['3', '1', '2'])
  })
  it('an HTML table with no header row stays as written', () => assert.equal(sortModel(tableOf(`<table>${rows}</table>`)), null))
  it('a colspan anywhere keeps it as written', () => {
    assert.equal(sortModel(tableOf(`<table><tr><th colspan="2">kv</th></tr>${rows}</table>`)), null)
    assert.equal(sortModel(tableOf(`<table><tr><th>k</th><th>v</th></tr>${rows}<tr><td colspan="2">all</td></tr></table>`)), null)
  })
  it('a rowspan keeps it as written', () => {
    assert.equal(sortModel(tableOf(`<table><tr><th>k</th><th>v</th></tr><tr><td rowspan="2">a</td><td>1</td></tr><tr><td>2</td></tr><tr><td>b</td><td>3</td></tr></table>`)), null)
  })
  it('two tbody groups keep it as written', () => {
    assert.equal(sortModel(tableOf(`<table><thead><tr><th>k</th><th>v</th></tr></thead><tbody>${rows}</tbody><tbody>${rows}</tbody></table>`)), null)
  })
  it('a node that is not a table is not sortable', () => assert.equal(sortModel({ tag: 'p', attrs: {}, children: [] }), null))
})

describe('the sort is a view', () => {
  it('ordering the rows leaves the tree in the author\'s order', () => {
    const t = tableOf(pipe(4))
    const before = JSON.stringify(t)
    const m = sortModel(t)
    assert.deepEqual(sortOrder(m.cells.map((r) => r[1]), 'ascending', 'en'), [3, 2, 1, 0])
    assert.equal(JSON.stringify(t), before)
  })
})

describe('MarkdownBlock and MdTable wiring', () => {
  const block = readFileSync(join(WUI, 'src/components/MarkdownBlock.vue'), 'utf8')
  const table = readFileSync(join(WUI, 'src/components/MdTable.vue'), 'utf8')
  it('MarkdownBlock loads MdTable lazily (a dynamic import), never statically', () => {
    assert.match(block, /await import\('~\/components\/MdTable\.vue'\)/)
    assert.doesNotMatch(block, /^import MdTable\b/m)
    assert.doesNotMatch(block, /^import [^\n]*table-sort/m)
  })
  it('MdTable renders aria-sort and a button per sortable header', () => {
    assert.match(table, /'aria-sort': state/)
    assert.match(table, /h\('button', \{\s*type: 'button'/)
  })
  it('a header click does not reach the card around the post', () => assert.match(table, /e\.stopPropagation\(\)/))
  it('the button names its column and state with the row 03 keys', () => {
    for (const k of ['markdown.table_sort.sort_by', 'markdown.table_sort.state_', 'markdown.table_sort.hint']) assert.ok(table.includes(k), k)
  })
  it('the cycle is the Issues list\'s (sheet-sort.mjs cycleSort)', () => assert.match(table, /cycleSort\(/))
})
