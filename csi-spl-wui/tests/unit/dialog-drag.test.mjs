// Spec 182 v0.11 changes 4 and 5 (HUM-10, t1 6e8c1cdb msgs e68509d5 and
// ac0a7377; SPL-6583, SPL-6584): a draggable UiDialog stays on screen, and
// the `wide` size is 70% of the width with its top 10% down the screen. The
// browser proof is tests/e2e/topic-loops-dialog.test.mjs.
// Run: node tests/unit/dialog-drag.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dialogDragOffset } from '../../src/utils/dialog-drag.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const view = { width: 1440, height: 900 }
const base = { left: 216, top: 90, width: 1008, height: 300 }

describe('dialogDragOffset: the panel stays on screen', () => {
  it('a drag inside the screen goes where the pointer asks', () => {
    assert.deepEqual(dialogDragOffset({ x: -150, y: 80 }, base, view), { x: -150, y: 80 })
  })

  it('past an edge it stops at that edge, on every side', () => {
    assert.deepEqual(dialogDragOffset({ x: -5000, y: -5000 }, base, view), { x: -216, y: -90 })
    assert.deepEqual(dialogDragOffset({ x: 5000, y: 5000 }, base, view), { x: 1440 - 1008 - 216, y: 900 - 300 - 90 })
  })

  it('a panel larger than the screen keeps its top left corner on it', () => {
    const tall = { left: 10, top: 10, width: 2000, height: 1200 }
    assert.deepEqual(dialogDragOffset({ x: 300, y: 300 }, tall, view), { x: -10, y: -10 })
    assert.deepEqual(dialogDragOffset({ x: -300, y: -300 }, tall, view), { x: -10, y: -10 })
  })

  it('a missing number is no move', () => {
    assert.deepEqual(dialogDragOffset({ x: undefined, y: Number.NaN }, base, view), { x: 0, y: 0 })
  })
})

describe('UiDialog: draggable, and the wide size', () => {
  const ui = readFileSync(join(root, 'src/components/UiDialog.vue'), 'utf8')
  const loops = readFileSync(join(root, 'src/components/TopicLoopsDialog.vue'), 'utf8')

  it('the header is the drag handle, off unless asked', () => {
    assert.match(ui, /draggable\?: boolean/)
    assert.match(ui, /draggable: false/)
    assert.match(ui, /class="ui-dialog__head"[\s\S]{0,120}@pointerdown="drag\.onDown"/)
    assert.match(ui, /useDialogDrag\(panelEl, \(\) => props\.draggable\)/)
  })

  it('wide is 70% of the width and starts 10% from the top; a phone keeps the full screen', () => {
    assert.match(ui, /\.ui-dialog\.wide \{ width: 70vw; max-width: 70vw;/)
    assert.match(ui, /\.ui-dialog-backdrop--wide \{ align-items: flex-start; padding-top: 10vh; \}/)
    assert.match(ui, /\.ui-dialog\.xl,\n {2}\.ui-dialog\.wide,\n {2}\.ui-dialog\.card \{/)
  })

  it('the Discussion loops dialog uses both', () => {
    assert.match(loops, /<UiDialog [^>]*size="wide" draggable/)
  })
})
