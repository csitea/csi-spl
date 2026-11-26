// SPL-6605 (owner HUM-10, t1 topic 0e00285a, msg 01140272: "this label should
// be just a small 1.5 s appearing snabar ... but not a permanent lable"): the
// topic list's loaded-topics line ("Sorted: the {n} topics loaded") is a
// 1.5 s snackbar, never a line that stays above the cards.
//
//   • MessageFeed renders no permanent element for it: the only place the
//     line shows is the shared UndoSnackbar (role=status, aria-live=polite,
//     position fixed, so the list never shifts), keyed per flash, no Undo
//   • the snackbar's clock with WINDOW_FLASH_MS dismisses at 1.5 s, on a
//     desktop AND on a touch UI (no Undo, so no 6 s touch minimum)
//   • a change of sort, filter or loaded count flashes it again, even when
//     the words stay the same; the defaults (or no older page) flash nothing
//
// Run: node --test tests/unit/topic-list-window-flash.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { importTs } from './lib/load-ts.mjs'
import { WINDOW_FLASH_MS, windowFlashKey } from '../../src/utils/topic-list-window-flash.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const FEED = readFileSync(join(WUI, 'src/components/MessageFeed.vue'), 'utf8')
const TEMPLATE = FEED.slice(FEED.indexOf('<template>'), FEED.lastIndexOf('</template>'))
const SNACK = readFileSync(join(WUI, 'src/components/UndoSnackbar.vue'), 'utf8')
const { createUndoTimer } = await importTs('src/utils/undo-timer.ts')

/** the opening tag of the element that carries testid="topic-list-window" */
function windowTag() {
  const at = TEMPLATE.search(/testid="topic-list-window"/)
  assert.ok(at > 0, 'MessageFeed still offers the loaded-topics line under testid topic-list-window')
  const open = TEMPLATE.lastIndexOf('<', at)
  return TEMPLATE.slice(open, TEMPLATE.indexOf('/>', at) + 2)
}

/** a fake clock over createUndoTimer: advance(ms) fires what is due */
function rig(opts) {
  let now = 0
  let next = 1
  const timers = new Map()
  let expired = 0
  const clock = createUndoTimer({
    ...opts,
    onExpire: () => { expired++ },
    set: (fn, ms) => { const id = next++; timers.set(id, { fn, at: now + ms }); return id },
    clear: (id) => { timers.delete(id) },
  })
  return {
    clock,
    get expired() { return expired },
    advance(ms) {
      now += ms
      for (const [id, t] of [...timers]) if (t.at <= now) { timers.delete(id); t.fn() }
    },
  }
}

describe('SPL-6605: the loaded-topics line is not permanent', () => {
  it('no plain element renders the line (the old <p class="topic-list-window">)', () => {
    assert.doesNotMatch(TEMPLATE, /<p[^>]*topic-list-window/)
    assert.doesNotMatch(TEMPLATE, /\{\{\s*windowLine\s*\}\}/)
  })
  it('it is the shared UndoSnackbar, keyed per flash, no Undo, WINDOW_FLASH_MS', () => {
    const tag = windowTag()
    assert.match(tag, /^<UndoSnackbar\b/)
    assert.match(tag, /v-if="windowFlash"/)
    assert.match(tag, /:key="windowFlash\.id"/)
    assert.match(tag, /:show-undo="false"/)
    assert.match(tag, /:duration="WINDOW_FLASH_MS"/)
    assert.match(tag, /@dismiss="windowFlash = null"/)
  })
  it('the snackbar is a polite status, fixed (no layout shift of the list)', () => {
    assert.match(SNACK, /role="status"/)
    assert.match(SNACK, /aria-live="polite"/)
    assert.match(SNACK, /\.undo-snackbar\s*\{[^}]*position:\s*fixed/)
  })
})

describe('SPL-6605: the snackbar hides after 1.5 s', () => {
  it('WINDOW_FLASH_MS is 1.5 s', () => {
    assert.equal(WINDOW_FLASH_MS, 1500)
  })
  for (const touch of [false, true]) {
    it(`${touch ? 'touch' : 'desktop'}: still shown at 1499 ms, gone at 1500 ms`, () => {
      const r = rig({ duration: WINDOW_FLASH_MS, undo: false, touch })
      r.clock.arm()
      r.advance(1499)
      assert.equal(r.expired, 0)
      r.advance(1)
      assert.equal(r.expired, 1)
    })
  }
})

describe('SPL-6605: windowFlashKey (when it flashes)', () => {
  const at = { line: 'Sorted: the 10 topics loaded', filter: 'all', sort: 'messages', n: 10 }
  it('no line (no older page, or the defaults): no flash', () => {
    assert.equal(windowFlashKey({ ...at, line: '' }), '')
  })
  it('another sort with the same words flashes again', () => {
    assert.notEqual(windowFlashKey(at), windowFlashKey({ ...at, sort: 'priority' }))
  })
  it('a new filter or a new loaded count flashes again', () => {
    assert.notEqual(windowFlashKey(at), windowFlashKey({ ...at, filter: 'new' }))
    assert.notEqual(windowFlashKey(at), windowFlashKey({ ...at, n: 20 }))
  })
  it('nothing changed: the same key, no second flash', () => {
    assert.equal(windowFlashKey(at), windowFlashKey({ ...at }))
  })
})
