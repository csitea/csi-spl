// SPL-958 — Titles mode collapses every attachment to an icon on the title line.
// A picture is not an <img> preview there. The icon's title is the file name.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fileKind } from '../../src/utils/file-preview.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

describe('titles view file icon (SPL-958)', () => {
  it('a picture is the image icon and any other file is its own icon', () => {
    assert.equal(fileKind('shot.png').icon, 'file-image')
    assert.equal(fileKind('notes.pdf').icon, 'file-text')
    assert.equal(fileKind('blob.bin').icon, 'file')
  })

  it('the title line carries the icon and not an image preview', () => {
    const vue = read('src/components/MessageCard.vue')
    const start = vue.indexOf('v-if="titleOnly"')
    const end = vue.indexOf('v-else', start)
    const block = vue.slice(start, end)
    assert.ok(start > 0 && end > start)
    assert.match(block, /data-testid="card-title"/)
    assert.match(block, /class="msg-title__text"/)
    assert.match(block, /<FileAttachment/)
    assert.match(block, /icon-only/)
    assert.doesNotMatch(block, /<img/)
    assert.doesNotMatch(block, /file-preview/)
    assert.match(vue, /\.msg-title \{[^}]*display:\s*flex/)
    assert.match(vue, /\.msg-title \{[^}]*white-space:\s*nowrap/)
  })

  it('the icon is named with the file name and opens the attachment', () => {
    const card = read('src/components/FileAttachment.vue')
    const start = card.indexOf('v-if="iconOnly"')
    const end = card.indexOf('v-else', start)
    const icon = card.slice(start, end)
    assert.match(icon, /data-testid="card-title-file"/)
    assert.match(icon, /:title="file\.name"/)
    assert.match(icon, /:aria-label="file\.name"/)
    assert.match(icon, /:name="kind\.icon"/)
    assert.doesNotMatch(icon, /<img/)
    assert.match(card, /async function onIcon\(\)/)
    assert.match(card, /viewerOpen\.value = true/)
    assert.match(card, /await onDownload\(\)/)
  })
})
