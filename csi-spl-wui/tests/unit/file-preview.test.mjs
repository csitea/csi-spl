// Owner, 2026-09-25: a picture previews, a click opens it at 90% of the
// screen, every other file shows an icon for its type. And a tall draft stays
// open while the reader clicks Attach.
//
// Run: node tests/unit/file-preview.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fileKind, fileExt, isPreviewableImage, PREVIEW_MAX_BYTES } from '../../src/utils/file-preview.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('attach keeps the draft open', () => {
  const box = read('src/components/MessageComposer.vue')
  it('Attach and Send keep focus in the box on mousedown, so a tall draft does not collapse', () => {
    assert.match(box, /data-testid="attach"\s+@mousedown\.prevent\s+@click="openFiles"/)
    assert.match(box, /data-testid="send"\s+@mousedown\.prevent/)
  })
})

describe('picture preview', () => {
  it('raster pictures preview; svg and big files do not', () => {
    for (const n of ['a.png', 'b.JPG', 'c.jpeg', 'd.gif', 'e.webp']) assert.equal(isPreviewableImage(n, 10), true, n)
    assert.equal(isPreviewableImage('x.svg', 10), false, 'svg can carry script')
    assert.equal(isPreviewableImage('x.pdf', 10), false)
    assert.equal(isPreviewableImage('big.png', PREVIEW_MAX_BYTES + 1), false)
    assert.equal(isPreviewableImage('nosize.png', undefined), true)
  })

  it('the card shows a data: URL (the deployed CSP admits no blob:) and opens it in the 90% dialog', () => {
    const card = read('src/components/FileAttachment.vue')
    assert.match(card, /bytesToDataUri\(buf, type\)/)
    assert.doesNotMatch(card, /createObjectURL\(new Blob\(\[buf\]\)\)\s*\n\s*previewUrl/)
    assert.match(card, /<UiDialog[^>]*size="xl"/)
    const dialog = read('src/components/UiDialog.vue')
    assert.match(dialog, /\.ui-dialog\.xl \{[^}]*width: 90vw;[^}]*height: 90vh;/)
  })

  it('a card handed a picked File (optimistic row) or a ref later previews either way', () => {
    const card = read('src/components/FileAttachment.vue')
    assert.match(card, /watch\(\(\) => \[props\.file, props\.file\.file_id, props\.file\.sha256\], loadPreview, \{ immediate: true \}\)/)
    assert.match(card, /f instanceof Blob/)
  })

  it('the mock send uploads too, so a mock card has a file_id', () => {
    assert.match(read('src/stores/channel.ts'), /files: await toFileRefs\(files\),\n    \}\)\n    const row = body/)
  })

  it('the composer thumbnail is a data: URL too', () => {
    const box = read('src/components/MessageComposer.vue')
    assert.match(box, /readDataUrl\(f\)/)
    assert.doesNotMatch(box, /URL\.createObjectURL/)
  })
})

describe('file type icons', () => {
  it('names the kind from the extension, case-insensitively', () => {
    assert.equal(fileKind('Q3.XLSX').kind, 'sheet')
    assert.equal(fileKind('report.pdf').kind, 'pdf')
    assert.equal(fileKind('memo.docx').kind, 'doc')
    assert.equal(fileKind('deck.pptx').kind, 'slides')
    assert.equal(fileKind('logs.tar.gz').kind, 'archive')
    assert.equal(fileKind('README').kind, 'other')
    assert.equal(fileExt('a.b.CSV'), 'csv')
  })

  it('every icon a kind can name exists in UiIcon', () => {
    const icons = read('src/utils/uiIcons.ts')
    for (const n of ['a.pdf', 'a.docx', 'a.xlsx', 'a.pptx', 'a.png', 'a.zip', 'a.py', 'a.mp4', 'a.bin']) {
      const { icon } = fileKind(n)
      assert.ok(icons.includes(`"${icon}": [`) || icons.includes(`  ${icon}: [`), `${n}: ${icon}`)
    }
  })
})
