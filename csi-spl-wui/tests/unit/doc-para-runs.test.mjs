// The Qto doc's section body reads as rendered markdown and edits as raw
// markdown (owner HUM-10, t1 09a69b01 msg 5092cd2d). paraRuns decides the
// switch: a body with text has a read view (its text runs, rendered as
// markdown by MarkdownBlock, and this doc's figures between them); a blank
// body has none and stays its textarea (the placeholder, a level-1 section's
// closed paragraph). The text runs keep the raw markdown, so the h() tree is
// built from the text as written, never from HTML.
//
// Run: node tests/unit/doc-para-runs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

/** -doc-pics.ts transpiled, then imported */
async function loadPics() {
  const tmp = mkdtempSync(join(tmpdir(), 'doc-para-runs-'))
  try {
    const src = readFileSync(join(WUI, 'src/components/workspace-docs/-doc-pics.ts'), 'utf8')
    const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    writeFileSync(join(tmp, 'doc-pics.mjs'), js)
    return await import(pathToFileURL(join(tmp, 'doc-pics.mjs')).href)
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

const { paraRuns, assetPaths, assetRoute, figureNumbers } = await loadPics()
const DOC = 'd1'
const pic = (c) => `![${c}](/v1/workspace/doctree/${DOC}/images/${'a'.repeat(64)}.png)`

describe('paraRuns: read or edit', () => {
  it('a body of markdown text reads: one text run, the raw markdown as written', () => {
    const md = 'Some **bold**\n\n- one\n- two\n\nSee [x](https://example.com)'
    assert.deepEqual(paraRuns(md, DOC), [{ kind: 'text', text: md }])
  })
  it('CONTROL a blank body has no read view: it stays the textarea', () => {
    for (const b of ['', '  ', '\n\n']) assert.equal(paraRuns(b, DOC), null, JSON.stringify(b))
  })
  it('a body with pictures: text runs around figures, numbered from first, the breaks around a figure dropped', () => {
    const body = `Before **it**\n${pic('One')}\nBetween\n${pic('Two')}`
    assert.deepEqual(paraRuns(body, DOC, 3), [
      { kind: 'text', text: 'Before **it**' },
      { kind: 'pic', caption: 'One', path: `/v1/workspace/doctree/${DOC}/images/${'a'.repeat(64)}.png`, k: 0, n: 3 },
      { kind: 'text', text: 'Between' },
      { kind: 'pic', caption: 'Two', path: `/v1/workspace/doctree/${DOC}/images/${'a'.repeat(64)}.png`, k: 1, n: 4 },
    ])
  })
  it('another doc\'s picture token is no figure: it stays in the text run, rendered as markdown', () => {
    const body = `x ![y](/v1/workspace/doctree/other/images/${'b'.repeat(64)}.png)`
    assert.deepEqual(paraRuns(body, DOC), [{ kind: 'text', text: body }])
  })
})

// Gap G6 (SPL-2201, spec 137 unified-fs.md section 7): a picture an md page
// brought in keeps its link as written, ![..](<page>.assets/NN-name.ext). The
// read view shows it (an 'asset' run, read from the doc's asset route), but
// it is no numbered figure, so the exports write it as written (byte-stable).
describe('paraRuns: a picture the md page brought in', () => {
  const asset = (c, p = 'guide.assets/01-flow-map.png') => `![${c}](${p})`
  it('an asset picture is its own run, its path as written; the breaks around it are not text', () => {
    const body = `Before\n${asset('Flow map')}\nAfter`
    assert.deepEqual(paraRuns(body, DOC), [
      { kind: 'text', text: 'Before' },
      { kind: 'asset', caption: 'Flow map', path: 'guide.assets/01-flow-map.png' },
      { kind: 'text', text: 'After' },
    ])
  })
  it('it takes no figure number: the hub picture after it is still Figure 1', () => {
    const body = `${asset('A')}\n${pic('One')}`
    const runs = paraRuns(body, DOC)
    assert.deepEqual(runs.map((r) => r.kind), ['asset', 'pic'])
    assert.equal(runs[1].n, 1)
    assert.deepEqual(figureNumbers([{ id: 'x', body, attrs: {} }], DOC).get('x'), { first: 1, image: 0 })
  })
  it('assetPaths lists them as written; assetRoute is the doc\'s asset route', () => {
    assert.deepEqual(assetPaths(`${asset('A')} and ${asset('B', 'guide.assets/02-arch.webp')}`), ['guide.assets/01-flow-map.png', 'guide.assets/02-arch.webp'])
    assert.equal(assetRoute(DOC, 'guide.assets/02-arch.webp'), `/v1/workspace/doctree/${DOC}/assets/guide.assets/02-arch.webp`)
  })
  it('CONTROL a path off the layout is text: ../img, upper case, no number, a URL', () => {
    for (const p of ['../img/a.png', 'guide.assets/01-Flow.png', 'guide.assets/flow.png', 'https://example.com/guide.assets/01-a.png']) {
      const body = `x ${asset('y', p)}`
      assert.deepEqual(paraRuns(body, DOC), [{ kind: 'text', text: body }], p)
      assert.deepEqual(assetPaths(body), [], p)
    }
  })
})
