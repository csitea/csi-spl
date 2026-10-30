// SPL-4392 (owner HUM-10, t1 d3bb743c, msg 4491ddee rule 3): after a code
// block is copied, the "next step" is the next heading after it that has a
// code block of its own before the next heading of the same or a higher
// level; the last block has none, and nothing scrolls.
//
// Run: node tests/unit/doc-next-step.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const tmp = mkdtempSync(join(tmpdir(), 'doc-next-step-'))
let a
try {
  const src = readFileSync(join(WUI, 'src/components/workspace-docs/-doc-next-step.ts'), 'utf8')
  const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
  writeFileSync(join(tmp, 'a.mjs'), js)
  a = await import(pathToFileURL(join(tmp, 'a.mjs')).href)
} finally {
  rmSync(tmp, { recursive: true, force: true })
}

const H = (level) => ({ kind: 'heading', level })
const C = { kind: 'code' }

describe('nextStepIndex', () => {
  it('2.1 -> 2.2: the code under 2.1 leads to the heading 2.2', () => {
    /* 2, 2.1, code, 2.2, code */
    assert.equal(a.nextStepIndex([H(2), H(3), C, H(3), C], 2), 3)
  })
  it('a heading without a code block is skipped', () => {
    /* 2.1, code, 2.2 (prose only), 2.3, code */
    assert.equal(a.nextStepIndex([H(3), C, H(3), H(3), C], 1), 3)
  })
  it('a parent heading counts when a sub-heading under it holds the code', () => {
    /* 1.1, code, 2, 2.1, code: 2 is followed by code before the next level-2 heading */
    assert.equal(a.nextStepIndex([H(3), C, H(2), H(3), C], 1), 2)
  })
  it('a same-or-higher heading ends the search for that heading\'s code', () => {
    /* 1.1, code, 1.2, 2, code: 1.2 has no code of its own (2 closes it), 2 does */
    assert.equal(a.nextStepIndex([H(3), C, H(3), H(2), C], 1), 3)
  })
  it('the last block: no next step, -1 (no scroll)', () => {
    assert.equal(a.nextStepIndex([H(2), C], 1), -1)
    assert.equal(a.nextStepIndex([H(2), C, H(2), H(3)], 1), -1)
  })
  it('a second block under the same heading leads to the next heading too', () => {
    assert.equal(a.nextStepIndex([H(3), C, C, H(3), C], 1), 3)
  })
})
