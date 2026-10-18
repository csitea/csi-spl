// Spec 011 round 13 row 05: the keydown decisions of the message shortcut
// listener (key + page state -> action), moved out of useMsgShortcuts.ts.
// Run: node tests/unit/msg-shortcuts-dispatch.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { cardEnterAction, shortcutAction, wantsPanelCard } from '../../src/utils/msg-shortcuts-dispatch.mjs'

const enter = (over = {}) => ({ key: 'Enter', defaultPrevented: false, ...over })
const cardIn = (over = {}) => ({ on: true, overlayOpen: false, isCard: true, inTopicPane: false, inMain: true, busy: false, ...over })

describe('cardEnterAction: Enter on a card', () => {
  it('Panel 3: the caret goes to the composer', () => {
    assert.equal(cardEnterAction(enter(), cardIn({ inTopicPane: true, inMain: false })), 'composer')
  })
  it('Panel 3: not when the card took the key or is being edited', () => {
    assert.equal(cardEnterAction(enter({ defaultPrevented: true }), cardIn({ inTopicPane: true })), null)
    assert.equal(cardEnterAction(enter(), cardIn({ inTopicPane: true, busy: true })), null)
  })
  it('Panel 2: the card opened its topic, the focus follows into the pane', () => {
    assert.equal(cardEnterAction(enter({ defaultPrevented: true }), cardIn()), 'into-pane')
  })
  it('Panel 2: nothing when the card did not take the key, or outside the centre list', () => {
    assert.equal(cardEnterAction(enter(), cardIn()), null)
    assert.equal(cardEnterAction(enter({ defaultPrevented: true }), cardIn({ inMain: false })), null)
  })
  it('nothing with the switch off, an overlay open, or on a control inside the row', () => {
    assert.equal(cardEnterAction(enter({ defaultPrevented: true }), cardIn({ on: false })), null)
    assert.equal(cardEnterAction(enter({ defaultPrevented: true }), cardIn({ overlayOpen: true })), null)
    assert.equal(cardEnterAction(enter({ defaultPrevented: true }), cardIn({ isCard: false })), null)
  })
  it('nothing for another key, a modifier, an IME composition or a repeat', () => {
    assert.equal(cardEnterAction(enter({ key: 'a', defaultPrevented: true }), cardIn()), null)
    for (const mod of ['shiftKey', 'ctrlKey', 'metaKey', 'altKey', 'isComposing', 'repeat']) {
      assert.equal(cardEnterAction(enter({ [mod]: true, defaultPrevented: true }), cardIn()), null, mod)
    }
  })
})

describe('wantsPanelCard: Shift + K with no card', () => {
  it('looks for the panel card only for K and only with no card', () => {
    assert.equal(wantsPanelCard({ type: 'action', key: 'K' }, false), true)
    assert.equal(wantsPanelCard({ type: 'action', key: 'K' }, true), false)
    assert.equal(wantsPanelCard({ type: 'action', key: 'A' }, false), false)
    assert.equal(wantsPanelCard({ type: 'help' }, false), false)
    assert.equal(wantsPanelCard(null, false), false)
  })
})

const act = (key) => ({ type: 'action', key })
const state = (over = {}) => ({
  hasCard: true, hasEntry: true, busy: false, undoUp: false, onTopicRow: false,
  offered: () => ['archive', 'reply', 'kind'],
  ...over,
})

describe('shortcutAction: a matched shortcut -> what the listener does', () => {
  it('no hit: nothing', () => {
    assert.equal(shortcutAction(null, state()), null)
  })
  it('Shift + ? opens the help, card or not, busy or not', () => {
    assert.deepEqual(shortcutAction({ type: 'help' }, state({ hasCard: false, hasEntry: false })), { do: 'help' })
    assert.deepEqual(shortcutAction({ type: 'help' }, state({ busy: true })), { do: 'help' })
  })
  it('j / k steps the selection from a card only', () => {
    assert.deepEqual(shortcutAction({ type: 'step', step: 1 }, state()), { do: 'step', step: 1 })
    assert.deepEqual(shortcutAction({ type: 'step', step: -1 }, state()), { do: 'step', step: -1 })
    assert.equal(shortcutAction({ type: 'step', step: 1 }, state({ hasCard: false, hasEntry: false })), null)
  })
  it('Shift + A undoes the archive while its toast is up, even with no card', () => {
    assert.deepEqual(shortcutAction(act('A'), state({ undoUp: true })), { do: 'undo' })
    assert.deepEqual(shortcutAction(act('A'), state({ undoUp: true, hasCard: false, hasEntry: false })), { do: 'undo' })
  })
  it('Shift + A with no toast runs the archive item', () => {
    assert.equal(shortcutAction(act('A'), state()).do, 'run')
  })
  it('Shift + R opens the card menu, not while it is busy', () => {
    assert.deepEqual(shortcutAction(act('R'), state()), { do: 'menu' })
    assert.equal(shortcutAction(act('R'), state({ busy: true })), null)
  })
  it('Shift + R on a topic-list row with no card opens that row menu', () => {
    assert.deepEqual(shortcutAction(act('R'), state({ hasCard: false, hasEntry: false, onTopicRow: true })), { do: 'row-menu' })
    assert.equal(shortcutAction(act('R'), state({ hasCard: false, hasEntry: false })), null)
  })
  it('Shift + U on a topic-list row with no card goes back to the reply', () => {
    assert.deepEqual(shortcutAction(act('U'), state({ hasCard: false, hasEntry: false, onTopicRow: true })), { do: 'row-back' })
    assert.equal(shortcutAction(act('U'), state({ hasCard: false, hasEntry: false })), null)
  })
  it('Shift + B on a topic-list row with no card: nothing', () => {
    assert.equal(shortcutAction(act('B'), state({ hasCard: false, hasEntry: false, onTopicRow: true })), null)
  })
  it('Shift + U / B on a card jump, not while it is busy', () => {
    assert.deepEqual(shortcutAction(act('U'), state()), { do: 'jump', key: 'U' })
    assert.deepEqual(shortcutAction(act('B'), state()), { do: 'jump', key: 'B' })
    assert.equal(shortcutAction(act('B'), state({ busy: true })), null)
  })
  it('a card not registered (no entry) takes no card key', () => {
    assert.equal(shortcutAction(act('B'), state({ hasEntry: false })), null)
    assert.equal(shortcutAction(act('A'), state({ hasEntry: false })), null)
  })
  it('a letter runs the menu item the card offers for it', () => {
    assert.deepEqual(shortcutAction(act('A'), state()), { do: 'run', id: 'archive' })
  })
  it('a letter whose item the card does not offer: nothing', () => {
    assert.equal(shortcutAction(act('A'), state({ offered: () => ['reply'] })), null)
  })
  it('a busy card runs no item, and its menu is never read', () => {
    let read = 0
    assert.equal(shortcutAction(act('A'), state({ busy: true, offered: () => { read++; return ['archive'] } })), null)
    assert.equal(read, 0)
  })
})
