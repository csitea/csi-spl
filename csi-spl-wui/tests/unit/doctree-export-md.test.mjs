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
