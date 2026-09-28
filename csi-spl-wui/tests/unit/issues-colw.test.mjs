// owner, topic beb4024f: "the columns of the issues grid should be
// resizeable" - utils/issues-colw.mjs (widths, keys, storage) and the sheet
// wiring in pages/issues.vue.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  COLW_MAX, COLW_MIN, COLW_MIN_BY_COL, COLW_STEP, colMin, ISSUES_COLW_COLS, ISSUES_COLW_KEY,
  clampColWidth, cleanColWidths, colWidthClasses, colWidthVars, dragWidth, keyWidth, loadColWidths, saveColWidths, withColWidth,
} from '../../src/utils/issues-colw.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

describe('issues column widths', () => {
  it('clamps to [min, max] whole px; junk is null', () => {
    assert.equal(clampColWidth(10), COLW_MIN)
    assert.equal(clampColWidth(5000), COLW_MAX)
    assert.equal(clampColWidth(120.6), 121)
    assert.equal(clampColWidth('x'), null)
    assert.equal(clampColWidth(undefined), null)
    assert.equal(clampColWidth(''), null)
  })

  it('Key and Title keep their own floor; every other column the common one', () => {
    assert.equal(clampColWidth(10, 'title'), COLW_MIN_BY_COL.title)
    assert.equal(clampColWidth(10, 'key'), COLW_MIN_BY_COL.key)
    assert.equal(clampColWidth(10, 'status'), COLW_MIN)
    assert.equal(colMin('title'), 160)
    assert.deepEqual(withColWidth({}, 'title', 50), { title: 160 })
    assert.equal(keyWidth(170, 'ArrowLeft', false, 'title'), 160)
    assert.equal(dragWidth(200, -300, false, 'key'), 56)
  })

  it('a drag adds the pointer travel, mirrored right-to-left', () => {
    assert.equal(dragWidth(100, 40), 140)
    assert.equal(dragWidth(100, 40, true), 60)
    assert.equal(dragWidth(100, -500), COLW_MIN)
  })

  it('arrow keys step, Delete / Backspace mean automatic, other keys do nothing', () => {
    assert.equal(keyWidth(100, 'ArrowRight'), 100 + COLW_STEP)
    assert.equal(keyWidth(100, 'ArrowLeft'), 100 - COLW_STEP)
    assert.equal(keyWidth(100, 'ArrowLeft', true), 100 + COLW_STEP)
    assert.equal(keyWidth(100, 'Delete'), 0)
    assert.equal(keyWidth(100, 'Backspace'), 0)
    assert.equal(keyWidth(100, 'Enter'), null)
    assert.equal(keyWidth(100, 'ArrowUp'), null)
  })

  it('set / unset one column returns a new object; unknown columns are refused', () => {
    const a = { status: 120 }
    const b = withColWidth(a, 'title', 300)
    assert.deepEqual(b, { status: 120, title: 300 })
    assert.deepEqual(a, { status: 120 })
    assert.deepEqual(withColWidth(b, 'status', 0), { title: 300 })
    assert.deepEqual(withColWidth(b, 'bogus', 200), b)
  })

  it('storage keeps only known columns with sane widths', () => {
    const store = memoryStore()
    assert.deepEqual(loadColWidths(store), {})
    saveColWidths({ status: 130, nope: 50, label: 'wide' }, store)
    assert.deepEqual(JSON.parse(store.getItem(ISSUES_COLW_KEY)), { status: 130 })
    assert.deepEqual(loadColWidths(memoryStore({ [ISSUES_COLW_KEY]: '{bad json' })), {})
    assert.deepEqual(loadColWidths(memoryStore({ [ISSUES_COLW_KEY]: '[1,2]' })), {})
    assert.deepEqual(cleanColWidths({ key: 20 }), { key: COLW_MIN_BY_COL.key })
  })

  it('the table gets one custom property and one class per set column', () => {
    assert.deepEqual(colWidthVars({ status: 120, title: 300 }), { '--iw-status': '120px', '--iw-title': '300px' })
    assert.deepEqual(colWidthClasses({ status: 120 }), ['issues-w-status'])
    assert.deepEqual(colWidthVars({}), {})
  })

  it('the sheet wires every column: a grip per header, data-col per cell, a CSS rule per column', () => {
    const vue = readFileSync(join(SRC, 'pages/issues.vue'), 'utf8')
    assert.match(vue, /class="issues-col-grip"[\s\S]{0,700}@pointerdown="onGripDown\(\$event, c\.col\)"/)
    assert.match(vue, /lastGripDown\.col === col && now - lastGripDown\.at < 400\)[\s\S]{0,80}void fitColumn\(col\)/)
    assert.match(vue, /@keydown\.alt\.left="onGripKey\(\$event, c\.col\)"/)
    assert.match(vue, /@keydown\.alt\.right="onGripKey\(\$event, c\.col\)"/)
    assert.match(vue, /:class="colWidthClasses\(colWidths\)" :style="colWidthVars\(colWidths\)"/)
    for (const col of ISSUES_COLW_COLS) {
      assert.match(vue, new RegExp(`\\.issues-table\\.issues-w-${col} \\[data-col="${col}"\\] \\{ width: var\\(--iw-${col}\\)`), col)
      assert.ok((vue.match(new RegExp(`<th data-col="${col}"|<th class="issues-c-key" data-col="${col}"`, 'g')) || []).length >= 1 || col === 'key', 'filter row ' + col)
    }
  })
})
