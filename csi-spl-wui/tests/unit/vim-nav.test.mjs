// Spec 103 T002 (t1 7d9e1681): vim navigation - the pure key matcher and the g g sequence.
// Run: node tests/unit/vim-nav.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { VIM_ACTIONS, VIM_GG_MS, VIM_SEQ_IDLE, vimNavMatch, vimNavOn } from '../../src/utils/vim-nav.mjs'

/* a stand-in element: `closest(sel)` hits when one of the selector's parts names a tag it carries */
function el(...tags) {
  return {
    closest(sel) {
      return sel.split(',').map((s) => s.trim()).some((s) => tags.includes(s)) ? this : null
    },
  }
}
const row = el('article')
const key = (k, o = {}) => ({ key: k, target: row, ...o })
const act = (ev, seq, ctx) => vimNavMatch(ev, seq, ctx).action

describe('vimNavMatch: the keys', () => {
  it('h j k l are left, down, up, right', () => {
    assert.equal(act(key('h')), 'left')
    assert.equal(act(key('j')), 'down')
    assert.equal(act(key('k')), 'up')
    assert.equal(act(key('l')), 'right')
  })

  it('arrow keys and Home / End mirror j, k, g g and G', () => {
    assert.equal(act(key('ArrowDown')), 'down')
    assert.equal(act(key('ArrowUp')), 'up')
    assert.equal(act(key('Home')), 'first')
    assert.equal(act(key('End')), 'last')
  })

  it('ArrowLeft / ArrowRight stay unmapped (columns and dividers own them)', () => {
    assert.equal(act(key('ArrowLeft')), null)
    assert.equal(act(key('ArrowRight')), null)
  })

  it('Shift + G is last; a bare G (Caps Lock) is nothing', () => {
    assert.equal(act(key('G', { shiftKey: true })), 'last')
    assert.equal(act(key('G')), null)
  })

  it('Enter opens, Esc goes back (both key names)', () => {
    assert.equal(act(key('Enter')), 'open')
    assert.equal(act(key('Escape')), 'back')
    assert.equal(act(key('Esc')), 'back')
  })

  it('Shift + h j k l stays the message actions, not navigation', () => {
    for (const k of ['h', 'j', 'k', 'l', 'H', 'J', 'K', 'L']) assert.equal(act(key(k, { shiftKey: true })), null, k)
    assert.equal(act(key('Enter', { shiftKey: true })), null)
    assert.equal(act(key('Escape', { shiftKey: true })), null)
  })

  it('other keys are nothing', () => {
    for (const k of ['a', 'x', '/', '?', 'Tab', ' ', '', 'toString', '__proto__']) assert.equal(act(key(k)), null, k)
  })

  it('every action it returns is listed in VIM_ACTIONS', () => {
    const seen = new Set()
    for (const k of ['h', 'j', 'k', 'l', 'ArrowDown', 'ArrowUp', 'Home', 'End', 'Enter', 'Escape']) seen.add(act(key(k)))
    seen.add(act(key('G', { shiftKey: true })))
    assert.deepEqual([...seen].sort(), [...VIM_ACTIONS].sort())
  })

  it('a held j / k / arrow repeats; a held Enter, Esc, G or g does not', () => {
    assert.equal(act(key('j', { repeat: true })), 'down')
    assert.equal(act(key('ArrowUp', { repeat: true })), 'up')
    assert.equal(act(key('Enter', { repeat: true })), null)
    assert.equal(act(key('Escape', { repeat: true })), null)
    assert.equal(act(key('G', { shiftKey: true, repeat: true })), null)
    const first = vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 0 })
    assert.equal(act(key('g', { repeat: true }), first.seq, { now: 10 }), null)
  })
})

describe('vimNavMatch: the gates', () => {
  it('never with Ctrl, Cmd or Alt held (browser and OS chords)', () => {
    for (const mod of ['ctrlKey', 'metaKey', 'altKey']) {
      for (const k of ['h', 'j', 'k', 'l', 'g', 'Enter', 'Escape', 'ArrowDown', 'Home']) {
        assert.equal(act(key(k, { [mod]: true })), null, `${mod} ${k}`)
      }
      assert.equal(act(key('G', { shiftKey: true, [mod]: true })), null, mod)
    }
  })

  it('never while typing: input, textarea, select, contenteditable, textbox, combobox', () => {
    for (const tag of ['input', 'textarea', 'select', '[contenteditable="true"]', '[role="textbox"]', '[role="combobox"]']) {
      for (const k of ['h', 'j', 'k', 'l', 'g', 'Enter', 'Escape']) assert.equal(act(key(k, { target: el(tag) })), null, `${tag} ${k}`)
    }
    assert.equal(act(key('j', { target: { isContentEditable: true, closest: () => null } })), null)
  })

  it('never inside an open menu or dialog (the overlay keeps its own keys)', () => {
    for (const tag of ['[role="menu"]', '[role="dialog"]', '[role="listbox"]', 'dialog']) {
      assert.equal(act(key('j', { target: el(tag) })), null, tag)
      assert.equal(act(key('Escape', { target: el(tag) })), null, tag)
    }
    assert.equal(act(key('j'), undefined, { overlayOpen: true }), null)
  })

  it('never on a phone width, nor with the setting off', () => {
    assert.equal(act(key('j'), undefined, { phone: true }), null)
    assert.equal(act(key('j'), undefined, { enabled: false }), null)
  })

  it('never during IME composition or after another handler took the key', () => {
    assert.equal(act(key('j', { isComposing: true })), null)
    assert.equal(act(key('j', { defaultPrevented: true })), null)
  })

  it('a target with no closest (window, document) is not typing', () => {
    assert.equal(act(key('j', { target: null })), 'down')
    assert.equal(act(key('j', { target: {} })), 'down')
  })

  it('a missing event is nothing', () => {
    assert.deepEqual(vimNavMatch(null), { action: null, seq: VIM_SEQ_IDLE })
    assert.deepEqual(vimNavMatch(undefined, undefined), { action: null, seq: VIM_SEQ_IDLE })
  })
})

describe('vimNavMatch: the g g sequence', () => {
  it('the first g arms the buffer and does nothing; the second within 500 ms is first', () => {
    const one = vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 1000 })
    assert.equal(one.action, null)
    assert.equal(one.seq.g, 1000)
    const two = vimNavMatch(key('g'), one.seq, { now: 1000 + VIM_GG_MS })
    assert.equal(two.action, 'first')
    assert.deepEqual(two.seq, VIM_SEQ_IDLE)
  })

  it('a second g after 500 ms re-arms instead (a fresh first g)', () => {
    const one = vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 0 })
    const late = vimNavMatch(key('g'), one.seq, { now: VIM_GG_MS + 1 })
    assert.equal(late.action, null)
    assert.equal(late.seq.g, VIM_GG_MS + 1)
    assert.equal(act(key('g'), late.seq, { now: VIM_GG_MS + 100 }), 'first')
  })

  it('a third g starts over: g g g is first, then armed', () => {
    let seq = VIM_SEQ_IDLE
    const got = []
    for (const t of [0, 100, 200]) {
      const r = vimNavMatch(key('g'), seq, { now: t })
      got.push(r.action)
      seq = r.seq
    }
    assert.deepEqual(got, [null, 'first', null])
    assert.equal(seq.g, 200)
  })

  it('any other key in between drops the pending g (and still does its own action)', () => {
    const one = vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 0 })
    const j = vimNavMatch(key('j'), one.seq, { now: 50 })
    assert.equal(j.action, 'down')
    assert.deepEqual(j.seq, VIM_SEQ_IDLE)
    assert.equal(act(key('g'), j.seq, { now: 100 }), null)
    const x = vimNavMatch(key('x'), one.seq, { now: 50 })
    assert.equal(x.action, null)
    assert.equal(act(key('g'), x.seq, { now: 100 }), null)
  })

  it('a gated key drops the pending g too (typing in between, Ctrl + g)', () => {
    const one = vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 0 })
    const typed = vimNavMatch(key('g', { target: el('input') }), one.seq, { now: 50 })
    assert.equal(typed.action, null)
    assert.equal(act(key('g'), typed.seq, { now: 100 }), null)
    const chord = vimNavMatch(key('g', { ctrlKey: true }), one.seq, { now: 50 })
    assert.equal(act(key('g'), chord.seq, { now: 100 }), null)
  })

  it('Shift + g (G) is last, never the 2nd half of g g', () => {
    const one = vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 0 })
    const big = vimNavMatch(key('G', { shiftKey: true }), one.seq, { now: 50 })
    assert.equal(big.action, 'last')
    assert.deepEqual(big.seq, VIM_SEQ_IDLE)
  })

  it('without ctx.now it reads the event timeStamp', () => {
    const one = vimNavMatch(key('g', { timeStamp: 5000 }), VIM_SEQ_IDLE)
    assert.equal(one.seq.g, 5000)
    assert.equal(act(key('g', { timeStamp: 5400 }), one.seq), 'first')
    assert.equal(act(key('g', { timeStamp: 5600 }), one.seq), null)
  })

  it('a clock that went backwards is not a 2nd g', () => {
    const one = vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 1000 })
    assert.equal(act(key('g'), one.seq, { now: 900 }), null)
  })

  it('never changes the state it was given', () => {
    const seq = Object.freeze({ g: 0 })
    vimNavMatch(key('g'), seq, { now: 10 })
    vimNavMatch(key('j'), seq, { now: 10 })
    assert.deepEqual(seq, { g: 0 })
    assert.equal(Object.isFrozen(vimNavMatch(key('g'), VIM_SEQ_IDLE, { now: 1 }).seq), true)
  })

  it('a missing or junk state is idle', () => {
    for (const seq of [undefined, null, {}, { g: 'x' }, { g: NaN }]) assert.equal(act(key('g'), seq, { now: 10 }), null, String(seq))
  })
})

describe('vimNavOn', () => {
  it('follows the keyboard_shortcuts claim: only a literal false turns it off', () => {
    assert.equal(vimNavOn(), true)
    assert.equal(vimNavOn({ claim: null }), true)
    assert.equal(vimNavOn({ claim: true }), true)
    assert.equal(vimNavOn({ claim: false }), false)
  })

  it('is off on a phone width', () => {
    assert.equal(vimNavOn({ claim: true, phone: true }), false)
  })
})
