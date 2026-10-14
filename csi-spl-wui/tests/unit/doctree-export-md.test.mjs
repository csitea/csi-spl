// Qto "export to md" keeps a code item's language (dispatch-5f3da0ba,
// qto-cli-gap): a code item with attrs.lang is fenced ```<lang>, so GitHub
// still renders a mermaid diagram; without a lang the fence stays bare. The
// CLI `spool doctree export` is a port of this function and pins the same
// output in cmd/spool/doctree_test.go (TestDocTreeMarkdownWUIParity).
//
// Run: node tests/unit/doctree-export-md.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const DIR = 'src/components/workspace-docs'

/** -doctree-export.ts and its imports (-doc-pics.ts, -doc-outline.ts) transpiled side by side, then imported */
async function loadExport() {
  const tmp = mkdtempSync(join(tmpdir(), 'doctree-export-'))
  try {
    for (const name of ['-doc-pics', '-doc-outline', '-doctree-export']) {
      const src = readFileSync(join(WUI, DIR, `${name}.ts`), 'utf8')
      const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
      writeFileSync(join(tmp, `${name}.mjs`), js.replace(/from '\.\/(-doc-pics|-doc-outline)'/g, "from './$1.mjs'"))
    }
    return await import(pathToFileURL(join(tmp, '-doctree-export.mjs')).href)
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

const { branchToMarkdown } = await loadExport()

describe('branchToMarkdown: a code item keeps its language', () => {
  const items = [
    { id: 'a', outline: '1', depth: 1, title: 'Flow', body: '', attrs: { src: 'graph TD\n  A --> B', lang: 'mermaid' } },
    { id: 'b', outline: '2', depth: 1, title: 'Plain', body: '', attrs: { src: 'echo hi' } },
  ]
  const md = branchToMarkdown(items, 'Untitled')

  it('fences a mermaid block as ```mermaid', () => {
    assert.match(md, /^```mermaid\ngraph TD\n {2}A --> B\n```$/m)
  })

  it('leaves a code item without a lang bare', () => {
    assert.match(md, /^```\necho hi\n```$/m)
  })

  it('is the whole file, verbatim', () => {
    assert.equal(md, '# 1 Flow\n\n```mermaid\ngraph TD\n  A --> B\n```\n\n# 2 Plain\n\n```\necho hi\n```\n')
  })
})

// SPL-1612: a whole-document export opens with the preamble, the hidden
// root's body, its pictures numbered first; a branch export has none. The
// same fixture and output as cmd/spool/doctree_preamble_test.go
// (TestDocTreeMarkdownPreamble): change both together.
describe('branchToMarkdown: the preamble opens a whole-document export', () => {
  const pic = '![map](/v1/workspace/doctree/d1/images/' + '0'.repeat(64) + '.png)'
  const root = { id: 'r', outline: '', depth: 0, title: '', body: '  Who holds it.\n\n' + pic + '\n', attrs: {} }
  const items = [{ id: 'a', outline: '1', depth: 1, title: 'Job', body: 'x ' + pic, attrs: {} }]
  const figs = new Map([['r', { first: 1, image: 0 }], ['a', { first: 2, image: 0 }]])
  const f = { doc: 'd1', figs, figure: (n) => `Figure ${n}:` }

  it('puts the preamble before section 1, verbatim', () => {
    assert.equal(branchToMarkdown(items, 'Untitled', f, root),
      'Who holds it.\n\n' + pic + '\n\n*Figure 1: map*\n\n# 1 Job\n\nx ' + pic + '\n\n*Figure 2: map*\n')
  })

  it('a branch export (no preamble given) has none', () => {
    assert.equal(branchToMarkdown(items, 'Untitled', f), '# 1 Job\n\nx ' + pic + '\n\n*Figure 2: map*\n')
  })

  it('a doc with a preamble only', () => {
    assert.equal(branchToMarkdown([], 'Untitled', f, root), 'Who holds it.\n\n' + pic + '\n\n*Figure 1: map*\n')
  })
})
