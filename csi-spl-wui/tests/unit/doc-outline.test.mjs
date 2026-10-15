// Spec 137 T012a, the WUI half: a heading whose attrs.numbered is false has
// no outline number, does not count among its siblings, and the items under
// it have none either, as the store numbers them (csi-spl-api
// TestWorkspaceDocUnnumberedOutline, TestOutlineOfUnnumbered) and the CLI
// exports them (TestDocTreeMarkdownUnnumbered: the same items, the same text).
// One helper, -doc-outline.ts, used by the export, the doc view and the mock.
//
// Run: node tests/unit/doc-outline.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const DIR = 'src/components/workspace-docs'

/** -doc-outline.ts and -doctree-export.ts (with -doc-pics.ts) transpiled side by side, then imported */
async function load() {
  const tmp = mkdtempSync(join(tmpdir(), 'doc-outline-'))
  try {
    for (const name of ['-doc-pics', '-doc-outline', '-doctree-export']) {
      const src = readFileSync(join(WUI, DIR, `${name}.ts`), 'utf8')
      const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
      writeFileSync(join(tmp, `${name}.mjs`), js.replace(/from '\.\/(-doc-pics|-doc-outline)'/g, "from './$1.mjs'"))
    }
    const at = (n) => import(pathToFileURL(join(tmp, `${n}.mjs`)).href)
    return { outline: await at('-doc-outline'), exp: await at('-doctree-export') }
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

const { outline: o, exp } = await load()

/* the store test's tree: a, b (unnumbered) > b1, c > c1 (unnumbered), c2 */
const off = { numbered: false }
const tree = { '': [
  { id: 'a', ord: 1, attrs: {} }, { id: 'b', ord: 2, attrs: off }, { id: 'c', ord: 3, attrs: { numbered: true } },
], b: [{ id: 'b1', ord: 1, attrs: {} }], c: [{ id: 'c1', ord: 1, attrs: off }, { id: 'c2', ord: 2, attrs: {} }] }
const parentOf = { a: '', b: '', c: '', b1: 'b', c1: 'c', c2: 'c' }
function outlineOfId(id) {
  const path = []
  for (let cur = id; cur; cur = parentOf[cur]) path.unshift(o.siblingNumbers(tree[parentOf[cur]]).get(cur))
  return o.outlineOf(path)
}

describe('numbering: as the store derives the outline', () => {
  it('an unnumbered item and everything under it has no outline; its numbered siblings close the gap', () => {
    const got = ['a', 'b', 'b1', 'c', 'c1', 'c2'].map((id) => `${id}=${outlineOfId(id)}`)
    assert.deepEqual(got, ['a=1', 'b=', 'b1=', 'c=2', 'c1=', 'c2=2.1'])
  })

  it('outlineOf: the root, a 0 anywhere in the path, and a plain path (TestOutlineOfUnnumbered)', () => {
    assert.equal(o.outlineOf([]), '')
    assert.equal(o.outlineOf([2, 1]), '2.1')
    assert.equal(o.outlineOf([0]), '')
    assert.equal(o.outlineOf([0, 1]), '')
    assert.equal(o.outlineOf([2, 0]), '')
  })

  it('control: with no attrs.numbered the numbers are the plain ord order', () => {
    const plain = [{ id: 'x', ord: 3, attrs: {} }, { id: 'y', ord: 1 }, { id: 'z', ord: 2, attrs: { numbered: true } }]
    assert.deepEqual([...o.siblingNumbers(plain)], [['y', 1], ['z', 2], ['x', 3]])
  })

  it('authorOutline: the md author\'s number (attrs.outline_author, SPL-2024) on a numbered item (TestAuthorOutline)', () => {
    assert.equal(o.authorOutline('1', {}), '1')
    assert.equal(o.authorOutline('1', { outline_author: '0' }), '0')
    assert.equal(o.authorOutline('5', { outline_author: '3.1', outline_dot: true }), '3.1')
    assert.equal(o.authorOutline('4.1', { outline_author: '1' }), '1')
    assert.equal(o.authorOutline('', { outline_author: '2' }), '')
    assert.equal(o.authorOutline('2', { outline_author: 'x' }), '2')
    assert.equal(o.authorOutline('2', { outline_author: 3 }), '2')
    assert.equal(o.authorOutline('2'), '2')
  })

  it('the hub JSON may carry "false" as a string: still unnumbered', () => {
    assert.equal(o.isNumbered({ attrs: { numbered: 'false' } }), false)
    assert.equal(o.isNumbered({ attrs: { numbered: false } }), false)
    assert.equal(o.isNumbered({ attrs: {} }), true)
    assert.equal(o.isNumbered({}), true)
  })
})

/* the CLI parity case, TestDocTreeMarkdownUnnumbered */
const items = [
  { id: 'o', outline: '', depth: 1, title: 'Overview', body: 'Why.', attrs: off },
  { id: 'd', outline: '', depth: 2, title: 'Details', body: '', attrs: {} },
  { id: 'a', outline: '1', depth: 1, title: 'Goals', body: '', attrs: {} },
  { id: 'b', outline: '1.1', depth: 2, title: 'First', body: '', attrs: {} },
]

describe('the outline prefix and the branch', () => {
  it('an unnumbered heading shows its title alone; a numbered one keeps its number', () => {
    assert.equal(o.headingText('', 'Overview'), 'Overview')
    assert.equal(o.headingText('1.1', 'First'), '1.1 First')
    assert.equal(o.headingText('1', 'Goals', true), '1. Goals')
    assert.equal(o.headingText('', 'Overview', true), 'Overview')
  })

  it('the branch of an unnumbered item is it and the deeper items after it', () => {
    assert.deepEqual(o.branchOf(items, 'o').map((x) => x.id), ['o', 'd'])
  })

  it('control: the branch of a numbered item is unchanged', () => {
    assert.deepEqual(o.branchOf(items, 'a').map((x) => x.id), ['a', 'b'])
    assert.deepEqual(o.branchOf(items, 'b').map((x) => x.id), ['b'])
    assert.deepEqual(o.branchOf(items, 'nope'), [])
  })
})

describe('branchToMarkdown: the same text as the CLI export', () => {
  it('the whole document: no number and no stray space on an unnumbered heading', () => {
    assert.equal(exp.branchToMarkdown(items, 'Untitled'), '# Overview\n\nWhy.\n\n## Details\n\n# 1 Goals\n\n## 1.1 First\n')
  })

  it('the branch of an unnumbered item', () => {
    assert.equal(exp.branchToMarkdown(o.branchOf(items, 'o'), 'Untitled'), '# Overview\n\nWhy.\n\n## Details\n')
  })

  it('control: the branch of a numbered item', () => {
    assert.equal(exp.branchToMarkdown(o.branchOf(items, 'a'), 'Untitled'), '# 1 Goals\n\n## 1.1 First\n')
  })
})

describe('the doc view and the mock number through the helper', () => {
  const src = (f) => readFileSync(join(WUI, DIR, f), 'utf8')

  it('WorkspaceDocView takes its branch from branchOf, never an outline prefix', () => {
    const v = src('WorkspaceDocView.vue')
    assert.match(v, /from '\.\/-doc-outline'/)
    assert.doesNotMatch(v, /outline\.startsWith\(/)
  })

  it('the mock tenant derives the outline with outlineOf + siblingNumbers, the author\'s number through authorOutline', () => {
    const m = src('-doctree-mock.ts')
    assert.match(m, /import \{ authorOutline, outlineOf, siblingNumbers \} from '\.\/-doc-outline'/)
    assert.match(m, /outline: authorOutline\(outlineOf\(path\), it\.attrs\)/)
    assert.doesNotMatch(m, /outline: path\.join\('\.'\)/)
  })
})
