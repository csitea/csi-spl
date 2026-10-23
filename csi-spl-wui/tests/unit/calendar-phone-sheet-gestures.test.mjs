// r18-02 (SPL-2903, epic SPL-2402): CalendarPhoneSheet's gestures and keys,
// in composables/useCalendarPhoneSheetGestures.ts, run on fake events:
//
//   • Escape (sheet keydown and window keydown) calls cancel
//   • Tab on the last focusable wraps to the first, Shift+Tab on the first
//     to the last
//   • a 200 px pull down from a scrolled body does not cancel; from the body
//     at scrollTop 0, or from the head, it does
//   • the keyboard lift: a visual viewport 300 px short lifts the sheet
//
// The e2e calendar-phone-sheet.test.mjs drives the drag in Chrome; this file
// covers what it does not (Escape, Tab, the lift).
//
// Run: node --test tests/unit/calendar-phone-sheet-gestures.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { computed, ref } from 'vue'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText

/* Nuxt auto-imports ref and computed */
Object.assign(globalThis, { ref, computed })
const { useCalendarPhoneSheetGestures } = await import(dataUrl(tsToJs(read('src/composables/useCalendarPhoneSheetGestures.ts'))))

/* ---------- fakes ---------- */

function focusable(name) {
  return { name, offsetParent: {}, focus() { globalThis.document.activeElement = this } }
}
function sheet(items) {
  return {
    offsetHeight: 600,
    querySelectorAll: () => items,
    contains: (el) => items.includes(el),
  }
}
function key(k, extra = {}) {
  const e = { key: k, shiftKey: false, defaultPrevented: false, isComposing: false, prevented: 0, stopped: 0, ...extra }
  e.preventDefault = () => { e.prevented++ }
  e.stopPropagation = () => { e.stopped++ }
  return e
}
function touch(x, y) {
  return { touches: [{ clientX: x, clientY: y }], cancelable: true, preventDefault() {} }
}
function setup({ scrollTop = 0, items = [] } = {}) {
  let cancels = 0
  const g = useCalendarPhoneSheetGestures({
    sheetEl: ref(sheet(items)),
    bodyEl: ref({ scrollTop }),
    busy: ref(false),
    cancel: () => { cancels++ },
  })
  return { g, cancels: () => cancels }
}
function pull(g, dy, fromHead = false) {
  g.dragStart(touch(100, 100), fromHead)
  for (let y = 110; y <= 100 + dy; y += 10) g.dragMove(touch(100, y))
  g.dragEnd()
}

globalThis.document = { activeElement: null }

/* ---------- Escape ---------- */

describe('Escape closes the sheet', () => {
  it('Escape in the sheet calls cancel, once, and stops the event', () => {
    const { g, cancels } = setup()
    const e = key('Escape')
    g.onKeydown(e)
    assert.equal(cancels(), 1)
    assert.equal(e.prevented, 1)
    assert.equal(e.stopped, 1)
  })
  it('Escape on the window calls cancel; not when already handled or composing', () => {
    const { g, cancels } = setup()
    g.onWindowKey(key('Escape'))
    g.onWindowKey(key('Escape', { defaultPrevented: true }))
    g.onWindowKey(key('Escape', { isComposing: true }))
    g.onWindowKey(key('a'))
    assert.equal(cancels(), 1)
  })
})

/* ---------- Tab trap ---------- */

describe('Tab stays inside the sheet', () => {
  it('Tab on the last focusable wraps to the first', () => {
    const items = [focusable('a'), focusable('b'), focusable('c')]
    const { g, cancels } = setup({ items })
    globalThis.document.activeElement = items[2]
    const e = key('Tab')
    g.onKeydown(e)
    assert.equal(globalThis.document.activeElement.name, 'a')
    assert.equal(e.prevented, 1)
    assert.equal(cancels(), 0)
  })
  it('Shift+Tab on the first wraps to the last; Tab in the middle is left to the browser', () => {
    const items = [focusable('a'), focusable('b'), focusable('c')]
    const { g } = setup({ items })
    globalThis.document.activeElement = items[0]
    g.onKeydown(key('Tab', { shiftKey: true }))
    assert.equal(globalThis.document.activeElement.name, 'c')
    globalThis.document.activeElement = items[1]
    const e = key('Tab')
    g.onKeydown(e)
    assert.equal(globalThis.document.activeElement.name, 'b')
    assert.equal(e.prevented, 0)
  })
})

/* ---------- drag-down to close (9.4 #4) ---------- */

describe('drag down to close', () => {
  it('a 200 px pull from a scrolled body does not cancel', () => {
    const { g, cancels } = setup({ scrollTop: 50 })
    pull(g, 200)
    assert.equal(cancels(), 0)
    assert.equal(g.dy.value, 0)
  })
  it('a 200 px pull from the body at scrollTop 0 cancels', () => {
    const { g, cancels } = setup({ scrollTop: 0 })
    pull(g, 200)
    assert.equal(cancels(), 1)
    assert.equal(g.dy.value, 0)
    assert.equal(g.dragging.value, false)
  })
  it('a 200 px pull from the head cancels even when the body is scrolled', () => {
    const { g, cancels } = setup({ scrollTop: 50 })
    pull(g, 200, true)
    assert.equal(cancels(), 1)
  })
  it('a 40 px pull springs back without cancel; the sheet follows the finger meanwhile', () => {
    const { g, cancels } = setup()
    g.dragStart(touch(100, 100), false)
    g.dragMove(touch(100, 140))
    assert.equal(g.dragging.value, true)
    assert.equal(g.sheetStyle.value.transform, 'translateY(40px)')
    g.dragEnd()
    assert.equal(cancels(), 0)
    assert.equal(g.sheetStyle.value.transform, undefined)
  })
})

/* ---------- keyboard lift ---------- */

describe('keyboard lift', () => {
  it('a visual viewport 300 px short lifts the sheet by 300 px', () => {
    const { g } = setup()
    globalThis.window = { innerHeight: 800, visualViewport: { height: 500, offsetTop: 0 } }
    g.onViewport()
    assert.equal(g.sheetStyle.value.bottom, '300px')
    globalThis.window = { innerHeight: 800, visualViewport: { height: 800, offsetTop: 0 } }
    g.onViewport()
    assert.equal(g.sheetStyle.value.bottom, undefined)
  })
})
