// HUM-10 (topic ae2e5093): Shift + letter message shortcuts - the key matcher.
// Run: node tests/unit/msg-shortcuts.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MSG_SHORTCUTS, NAV_SHORTCUTS, TOPIC_LIST_SHORTCUTS, backJump, inTypingOrOverlay, listRowFor, messageShortcutsSection, offeredItems, parentJump, replyBack, shortcutFor, shortcutHint, shortcutItem, shortcutsOn,
} from '../../src/utils/msg-shortcuts.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

/* a stand-in element: `closest(sel)` hits when one of the selector's parts names a tag it carries */
function el(...tags) {
  return {
    closest(sel) {
      return sel.split(',').map((s) => s.trim()).some((s) => tags.includes(s)) ? this : null
    },
  }
}
const row = el('article')
const key = (k, o = {}) => ({ key: k, code: /^[a-z]$/i.test(k) ? 'Key' + k.toUpperCase() : '', target: row, ...o })
const shift = (k, o = {}) => key(k, { shiftKey: true, ...o })

describe('shortcutFor', () => {
  it('Shift + a mapped letter is that action', () => {
    for (const s of MSG_SHORTCUTS) assert.deepEqual(shortcutFor(shift(s.key)), { type: 'action', key: s.key })
  })

  it('a plain letter, or an unmapped Shift letter, is nothing (capitals still type)', () => {
    assert.equal(shortcutFor(key('h')), null)
    assert.equal(shortcutFor(shift('Z')), null)
    assert.equal(shortcutFor(shift('J')), null)
  })

  it('never with Ctrl, Cmd or Alt held (the browser / OS chords)', () => {
    for (const mod of ['ctrlKey', 'metaKey', 'altKey']) {
      assert.equal(shortcutFor(shift('A', { [mod]: true })), null, mod)
      assert.equal(shortcutFor(key('j', { [mod]: true })), null, mod)
      assert.equal(shortcutFor(key('?', { shiftKey: true, [mod]: true })), null, mod)
    }
  })

  it('never while the caret is in an input, a textarea, a contenteditable or a menu / dialog', () => {
    for (const tag of ['input', 'textarea', 'select', '[contenteditable="true"]', '[role="textbox"]', '[role="menu"]', '[role="dialog"]', 'dialog']) {
      assert.equal(shortcutFor(shift('A', { target: el(tag) })), null, tag)
      assert.equal(shortcutFor(key('j', { target: el(tag) })), null, tag)
    }
    assert.equal(shortcutFor(shift('A', { target: { isContentEditable: true, closest: () => null } })), null)
    assert.equal(shortcutFor(shift('A'), { overlayOpen: true }), null)
  })

  it('the setting off, a phone width, an IME, a handled or a repeated key: nothing fires', () => {
    assert.equal(shortcutFor(shift('A'), { enabled: false }), null)
    assert.equal(shortcutFor(key('j'), { enabled: false }), null)
    assert.equal(shortcutFor(key('?', { shiftKey: true }), { enabled: false }), null)
    assert.equal(shortcutFor(shift('A'), { phone: true }), null)
    assert.equal(shortcutFor(shift('A', { isComposing: true })), null)
    assert.equal(shortcutFor(key('j', { defaultPrevented: true })), null)
    assert.equal(shortcutFor(shift('D', { repeat: true })), null)
  })

  it('j / ArrowDown step to the next message, k / ArrowUp to the previous; Shift+Arrow stays the browser\'s', () => {
    assert.deepEqual(shortcutFor(key('j')), { type: 'step', step: 1 })
    assert.deepEqual(shortcutFor(key('ArrowDown')), { type: 'step', step: 1 })
    assert.deepEqual(shortcutFor(key('k')), { type: 'step', step: -1 })
    assert.deepEqual(shortcutFor(key('ArrowUp')), { type: 'step', step: -1 })
    assert.equal(shortcutFor(shift('ArrowDown')), null)
  })

  it('Shift + ? opens the list', () => {
    assert.deepEqual(shortcutFor(key('?', { shiftKey: true })), { type: 'help' })
  })

  it('a non-Latin layout still reads the physical key', () => {
    assert.deepEqual(shortcutFor({ key: 'Ф', code: 'KeyA', shiftKey: true, target: row }), { type: 'action', key: 'A' })
  })
})

describe('inTypingOrOverlay', () => {
  it('no element, or a plain row, is not typing', () => {
    assert.equal(inTypingOrOverlay(null), false)
    assert.equal(inTypingOrOverlay(row), false)
  })
})

describe('shortcutItem / offeredItems: the menu decides', () => {
  it('a key runs its item only when the message offers it', () => {
    assert.equal(shortcutItem('E', new Set(['open', 'copy'])), '')
    assert.equal(shortcutItem('E', new Set(['open', 'edit'])), 'edit')
    assert.equal(shortcutItem('A', ['archive']), 'archive')
    assert.equal(shortcutItem('Q', ['archive']), '')
  })

  it('Shift + R opens the menu: it names no item, so Reply keeps no key', () => {
    const row = MSG_SHORTCUTS.find((s) => s.key === 'R')
    assert.equal(row.labelKey, 'feed.shortcuts.open_menu')
    assert.deepEqual([...row.items], [])
    assert.equal(shortcutItem('R', offeredItems({ editable: true })), '')
    assert.equal(shortcutHint('reply'), '')
  })

  it('Move or merge takes whichever picker the message offers; Delete the topic\'s first', () => {
    assert.equal(shortcutItem('M', new Set(['move-topic'])), 'move-topic')
    assert.equal(shortcutItem('M', new Set(['merge-topic', 'move-channel'])), 'move-channel')
    assert.equal(shortcutItem('D', new Set(['delete', 'delete-topic'])), 'delete-topic')
    assert.equal(shortcutItem('D', new Set(['delete'])), 'delete')
  })

  it('the offer is the desktop menu and the phone sheet together, never a locked entry', () => {
    const own = offeredItems({ editable: true })
    for (const id of ['open', 'copy', 'edit', 'delete', 'reply', 'copy-text']) assert.ok(own.has(id), id)
    assert.equal(own.has('kind'), false)
    assert.ok(offeredItems({ kind: true }).has('kind'))
    assert.ok(offeredItems({ hide: true }).has('hide-flow'))
    assert.equal(offeredItems({}).has('edit'), false)
    const locked = offeredItems({ locks: { archive: 'x', delete: 'y' } })
    assert.equal(locked.has('archive'), false)
    assert.equal(locked.has('delete-topic'), false)
  })
})

describe('hints, the setting, the catalogue', () => {
  it('a menu item shows ⇧ + its letter, an item with no key shows nothing', () => {
    assert.equal(shortcutHint('hide-flow'), '⇧H')
    assert.equal(shortcutHint('copy'), '⇧L')
    assert.equal(shortcutHint('delete-topic'), '⇧D')
    assert.equal(shortcutHint('merge-topic'), '⇧M')
    assert.equal(shortcutHint('merge-prev'), '')
  })

  it('only a literal false turns them off (never picked = on)', () => {
    assert.equal(shortcutsOn(undefined), true)
    assert.equal(shortcutsOn(null), true)
    assert.equal(shortcutsOn(true), true)
    assert.equal(shortcutsOn(false), false)
  })

  it('every key is one letter, used once', () => {
    const keys = MSG_SHORTCUTS.map((s) => s.key)
    assert.equal(new Set(keys).size, keys.length)
    for (const k of keys) assert.match(k, /^[A-Z]$/)
  })

  it('every label is in every locale', () => {
    const dir = join(WUI, 'i18n/locales')
    const labels = [...MSG_SHORTCUTS, ...NAV_SHORTCUTS].map((s) => s.labelKey)
      .concat(['feed.shortcuts.title', 'settings.keyboard_shortcuts.label', 'settings.keyboard_shortcuts.hint'])
    for (const f of readdirSync(dir).filter((n) => n.endsWith('.json'))) {
      const cat = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      for (const k of labels) {
        const v = k.split('.').reduce((o, p) => (o && typeof o === 'object' ? o[p] : undefined), cat)
        assert.equal(typeof v, 'string', `${f}: ${k}`)
      }
    }
  })
})

/** The help section, from the "## 7" heading up to the next heading or the version footer. */
function helpSection(md) {
  const at = md.indexOf('## 7. Message shortcuts')
  if (at < 0) return ''
  const rest = md.slice(at)
  const cut = rest.slice(1).search(/\n(?:## |<!-- version:)/)
  return (cut < 0 ? rest : rest.slice(0, cut + 1)).replace(/\s+$/, '')
}

describe('help page: the Message shortcuts section is this map', () => {
  const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
  const label = (key) => key.split('.').reduce((o, p) => (o && typeof o === 'object' ? o[p] : undefined), en)
  const want = messageShortcutsSection(label)

  it('doc/help and the served copy both equal messageShortcutsSection', () => {
    for (const rel of ['../csi-spl-doc/doc/help/keyboard-shortcuts.md', 'src/public/help-md/keyboard-shortcuts.md']) {
      const md = readFileSync(join(WUI, rel), 'utf8')
      assert.equal(helpSection(md), want, rel)
    }
  })

  it('a section that drops a key no longer matches, and every Shift + letter is one map key', () => {
    const keys = [...want.matchAll(/Shift \+ ([A-Z])/g)].map((m) => m[1])
    assert.deepEqual(keys, [...MSG_SHORTCUTS, ...TOPIC_LIST_SHORTCUTS].map((s) => s.key))
    const dropped = want.replace(/\| \*\*`Shift \+ H`\*\*[^\n]*\n/, '')
    assert.notEqual(dropped, want)
    assert.equal(helpSection('## 6. Earlier\n\n' + dropped + '\n\n<!-- version: x -->'), dropped)
  })
})


describe('Topics view: Shift + A on a focused topic row (t1 topic 2627084c)', () => {
  it('the list takes A and runs Archive, the same item the channel card runs', () => {
    assert.deepEqual(TOPIC_LIST_SHORTCUTS.map((s) => s.key), ['A'])
    assert.deepEqual([...TOPIC_LIST_SHORTCUTS[0].items], ['archive'])
    assert.equal(shortcutItem('A', offeredItems({ topicArchive: true })), 'archive')
  })
  it('a role the row menu locks Archive for gets nothing', () => {
    const locked = offeredItems({ topicArchive: false, locks: { archive: 'feed.msg_menu.why.archive_admins' } })
    assert.equal(shortcutItem('A', locked), '')
  })
  it('the help section names the Topics view row', () => {
    const md = messageShortcutsSection(() => 'Archive the focused topic (Topics view)')
    assert.match(md, /\| \*\*`Shift \+ A`\*\* \| Focused topic, Topics view, desktop \| Archive the focused topic \(Topics view\) \|/)
  })
})

describe('Shift + B / Shift + U: reply to its topic\'s first message and back (t1 29c3b055)', () => {
  /* a topic pane: the opener, two replies, newest first as the pane draws them */
  const P = { id: 'p', task: 't', opener: true, ts: '2026-10-07T10:00:00Z' }
  const R1 = { id: 'r1', task: 't', opener: false, ts: '2026-10-07T10:01:00Z' }
  const R2 = { id: 'r2', task: 't', opener: false, ts: '2026-10-07T10:02:00Z' }
  const pane = [R2, R1, P]

  it('both keys resolve, name no menu item, and are labelled', () => {
    assert.deepEqual(shortcutFor(shift('U')), { type: 'action', key: 'U' })
    assert.deepEqual(shortcutFor(shift('B')), { type: 'action', key: 'B' })
    assert.equal(MSG_SHORTCUTS.find((s) => s.key === 'B').labelKey, 'feed.shortcuts.to_parent')
    assert.equal(MSG_SHORTCUTS.find((s) => s.key === 'U').labelKey, 'feed.shortcuts.back_to_reply')
    assert.equal(shortcutItem('U', offeredItems({ editable: true })), '')
    assert.equal(shortcutItem('B', offeredItems({ editable: true })), '')
    assert.equal(shortcutFor(shift('U'), { enabled: false }), null)
    assert.equal(shortcutFor(shift('B'), { phone: true }), null)
  })

  it('U from a reply selects the opener held in the same feed', () => {
    assert.deepEqual(parentJump(pane, 'r1'), { parent: 'p', held: true })
    assert.deepEqual(parentJump(pane, 'r2', 'zzz'), { parent: 'p', held: true })
  })

  it('U on the opener, on a message with no topic, or an unknown row: nothing', () => {
    assert.equal(parentJump(pane, 'p'), null)
    assert.equal(parentJump([{ id: 'x', task: '', opener: true }], 'x', 'y'), null)
    assert.equal(parentJump(pane, 'nope'), null)
    /* a channel feed holds topic roots only: each is its own opener */
    assert.equal(parentJump([P, { id: 'q', task: 'u', opener: true }], 'q'), null)
  })

  it('U with the opener paged out names the fallback, read in like a link', () => {
    assert.deepEqual(parentJump([R2, R1], 'r1', 'p'), { parent: 'p', held: false })
    assert.equal(parentJump([R2, R1], 'r1', ''), null)
    assert.equal(parentJump([R2, R1], 'r1', 'r1'), null)
  })

  it('the earliest level-1 row is the opener, not a later is_parent 1 line', () => {
    const late = { id: 'l', task: 't', opener: true, ts: '2026-10-07T10:03:00Z' }
    assert.deepEqual(parentJump([late, R1, P], 'l'), { parent: 'p', held: true })
  })

  it('B from the opener returns to the reply U left, else the latest reply', () => {
    assert.equal(backJump(pane, 'p', { parent: 'p', reply: 'r1' }), 'r1')
    assert.equal(backJump(pane, 'p', null), 'r2')
    assert.equal(backJump(pane, 'p', { parent: 'other', reply: 'r1' }), 'r2')
  })

  it('B on a reply, or an opener with no reply: nothing', () => {
    assert.equal(backJump(pane, 'r1', { parent: 'p', reply: 'r1' }), '')
    assert.equal(backJump([P], 'p'), '')
    assert.equal(backJump(pane, 'nope'), '')
  })
})

describe('Shift + B / Shift + U: the 2nd panel, the centre list (t1 29c3b055, owner "yes , do it that way")', () => {
  const P = { id: 't', task: 't', opener: true, ts: '2026-10-07T10:00:00Z' }
  const R1 = { id: 'r1', task: 't', opener: false, ts: '2026-10-07T10:01:00Z' }
  const R2 = { id: 'r2', task: 't', opener: false, ts: '2026-10-07T10:02:00Z' }
  const pane = [P, R1, R2]

  it('U from a reply names the topic\'s card in the channel / DM list', () => {
    const list = [{ key: 'other', task: 'other' }, { key: 't', task: 't' }]
    assert.equal(listRowFor(list, 't'), 't')
  })

  it('a card whose own id is the topic wins over one of the same task (a #lobby message topic)', () => {
    const lobby = [{ key: 'm1', task: 'lobby' }, { key: 'm2', task: 'lobby' }]
    assert.equal(listRowFor(lobby, 'm2'), 'm2')
    assert.equal(listRowFor(lobby, 'lobby'), 'm1')
  })

  it('the topic view\'s topic rows (key = task id) are matched too', () => {
    assert.equal(listRowFor([{ key: 'a', task: 'a' }, { key: 't', task: 't' }], 't'), 't')
  })

  it('no row in the list, or no topic: nothing (the caller stays in the same feed)', () => {
    assert.equal(listRowFor([{ key: 'a', task: 'a' }], 't'), '')
    assert.equal(listRowFor([{ key: 'a', task: 'a' }], ''), '')
    assert.equal(listRowFor(null, 't'), '')
  })

  it('B from the list row goes back to the reply U left, while the pane holds it', () => {
    assert.equal(replyBack(pane, 't', { topic: 't', reply: 'r1' }), 'r1')
    assert.equal(replyBack([P, R2], 't', { topic: 't', reply: 'r1' }), 'r2')
  })

  it('B with no memo, or a memo of another topic: the topic\'s latest reply', () => {
    assert.equal(replyBack(pane, 't', null), 'r2')
    assert.equal(replyBack(pane, 't', { topic: 'x', reply: 'r1' }), 'r2')
  })

  it('B: never the opener, nothing for a topic with no reply or not in the pane', () => {
    assert.equal(replyBack([P], 't'), '')
    assert.equal(replyBack(pane, 'x'), '')
    assert.equal(replyBack(pane, ''), '')
  })
})
