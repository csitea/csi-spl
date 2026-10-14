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

// SPL-1900 (Qto gaps G1 + G2): the export gives back the md file as the
// author wrote it. The fixture is the one every exporter is held to
// (cmd/spool TestDocTreeMarkdownFidelity, csi-spl-orc doctree-export-md.tst.sh
// for spl-doctree-md.py): "1." kept (attrs.outline_dot), an indented first
// line, 6 blank lines under a heading, blank runs at a body's edges, text
// right under a heading and right above the next (attrs.tight, tight_end).
describe('branchToMarkdown: the export keeps the heading dot and the spacing (SPL-1900)', () => {
  const FX = join(WUI, '../csi-spl-api/src/go/spool-hub-api/cmd/spool/testdata/doctree-export-fidelity.json')
  const fx = JSON.parse(readFileSync(FX, 'utf8'))
  const [root, ...items] = fx.items

  it('writes the fixture export byte for byte, as cmd/spool does', () => {
    assert.equal(branchToMarkdown(items, 'Untitled', undefined, root), fx.export)
  })

  it('keeps "1." where attrs.outline_dot is set, "1.1" where not', () => {
    const md = branchToMarkdown(items, 'Untitled')
    assert.match(md, /^# 1\. The job$/m)
    assert.match(md, /^## 1\.1 Read$/m)
  })

  it('a body stored trimmed (the old import, the WUI) exports as before', () => {
    const old = [
      { id: 'a', outline: '1', depth: 1, title: 'A', body: 'Text.', attrs: {} },
      { id: 'b', outline: '2', depth: 1, title: 'B', body: 'More.\n', attrs: {} },
      { id: 'c', outline: '3', depth: 1, title: 'C', body: '', attrs: {} },
    ]
    assert.equal(branchToMarkdown(old, 'Untitled'), '# 1 A\n\nText.\n\n# 2 B\n\nMore.\n\n# 3 C\n')
  })
})
