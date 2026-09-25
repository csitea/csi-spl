// A pasted screenshot and a dropped file are attached, like 📎 Attach.
// Run: node --test tests/unit/transfer-files.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { carriesFiles, filesOf, pasteAttaches } from '../../src/utils/transfer-files.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const file = (name) => ({ name, size: 3 })

describe('filesOf', () => {
  it('reads files, then items of kind file', () => {
    const a = file('a.png')
    assert.deepEqual(filesOf({ files: [a], items: [] }), [a])
    const shot = file('image.png')
    const items = [{ kind: 'string', getAsFile: () => null }, { kind: 'file', getAsFile: () => shot }]
    assert.deepEqual(filesOf({ files: [], items }), [shot])
  })

  it('is empty for no transfer or no files', () => {
    assert.deepEqual(filesOf(null), [])
    assert.deepEqual(filesOf({ files: [], items: [{ kind: 'string', getAsFile: () => null }] }), [])
  })
})

describe('carriesFiles', () => {
  it('is true only when the drag lists Files', () => {
    assert.equal(carriesFiles({ types: ['Files'] }), true)
    assert.equal(carriesFiles({ types: ['text/plain'] }), false)
    assert.equal(carriesFiles(null), false)
  })
})

describe('pasteAttaches', () => {
  it('attaches a screenshot and a copied file', () => {
    assert.equal(pasteAttaches({ types: ['Files'], files: [file('image.png')] }), true)
    assert.equal(pasteAttaches({ types: ['text/plain', 'Files'], files: [file('report.pdf')] }), true)
  })

  it('leaves plain text and rich text from a document as a text paste', () => {
    assert.equal(pasteAttaches({ types: ['text/plain'], files: [] }), false)
    assert.equal(pasteAttaches({ types: ['text/html', 'text/plain', 'Files'], files: [file('image.png')] }), false)
  })
})

describe('the composer wires paste and drop', () => {
  it('attaches pasted and dropped files to picked', () => {
    const c = src('src/components/MessageComposer.vue')
    assert.match(c, /@paste="onPaste"/)
    assert.match(c, /window\.addEventListener\('drop', onWindowDrop\)/)
    assert.match(c, /window\.addEventListener\('dragover', onWindowDragOver\)/)
    assert.match(c, /window\.removeEventListener\('drop', onWindowDrop\)/)
    assert.match(c, /if \(!props\.global\) return\n  window\.addEventListener/)
  })
})
