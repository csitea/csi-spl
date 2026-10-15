// Spec 138 (SPL-1966): the Qto section link's resolver. The owner's picks,
// t1 topic 7c968b85: "Copy link" writes form A `#ws-doc-<item id>` (msg
// 748ecf3c); form D `#<number>-<slug>~<8 hex>` opens its section through
// the id suffix only (msg 7f2f7bd9), so a stale number and title still land
// right; a bare number (B) or title slug (C) is an unknown anchor.
//
// Run: node tests/unit/doc-anchor.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const tmp = mkdtempSync(join(tmpdir(), 'doc-anchor-'))
let a
try {
  const src = readFileSync(join(WUI, 'src/components/workspace-docs/-doc-anchor.ts'), 'utf8')
  const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
  writeFileSync(join(tmp, 'a.mjs'), js)
  a = await import(pathToFileURL(join(tmp, 'a.mjs')).href)
} finally {
  rmSync(tmp, { recursive: true, force: true })
}

const IDS = ['3f2a91c0-1111-4222-8333-444455556666', '7b00aa12-1111-4222-8333-444455556666', '7b00aa13-0000-4000-8000-000000000000']

describe('resolveAnchor', () => {
  it('form A: the full id, with or without the #, escaped or not', () => {
    assert.equal(a.resolveAnchor('#ws-doc-' + IDS[0], IDS), IDS[0])
    assert.equal(a.resolveAnchor('ws-doc-' + IDS[1], IDS), IDS[1])
    assert.equal(a.resolveAnchor('#ws%2Ddoc%2D' + IDS[0], IDS), IDS[0])
  })
  it('form D: the 8-hex id suffix, whatever number and title precede it', () => {
    assert.equal(a.resolveAnchor('#1.2.3-title-words~3f2a91c0', IDS), IDS[0])
    assert.equal(a.resolveAnchor('#9.9-a-stale-title~3F2A91C0', IDS), IDS[0])
    assert.equal(a.resolveAnchor('#~7b00aa12', IDS), IDS[1])
  })
  it('an unknown anchor is "": a deleted id, an unmatched suffix, a bare number (B) or slug (C)', () => {
    for (const h of ['#ws-doc-' + IDS[0].replace('3f', '00'), '#1.2.3-title~deadbeef', '#1.2.3', '#1-2-3-title-words', '#title-words', '', '#', '#%E0%A4%A']) {
      assert.equal(a.resolveAnchor(h, IDS), '', h)
    }
  })
  it('a suffix two ids share resolves to neither', () => {
    assert.equal(a.resolveAnchor('#x~7b00aa1', IDS), '')
    assert.equal(a.resolveAnchor('#x~7b00aa13', [...IDS, '7b00aa13-ffff-4fff-8fff-ffffffffffff']), '')
  })
})

describe('docLink', () => {
  const resolve = (to) => ({ href: to.path + '?' + new URLSearchParams(to.query) + to.hash })
  it('writes form A, the stable id, when an item is given', () => {
    assert.equal(a.docLink(resolve, 'https://x.example', 'd1', IDS[0]), 'https://x.example/workspace/docs?doc=d1&view=doc#ws-doc-' + IDS[0])
  })
  it('the document alone without one', () => {
    assert.equal(a.docLink(resolve, 'https://x.example', 'd1'), 'https://x.example/workspace/docs?doc=d1&view=doc')
  })
})
