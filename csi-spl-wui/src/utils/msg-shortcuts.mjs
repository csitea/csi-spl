// csi-spl-wui/src/utils/msg-shortcuts.mjs
//
// HUM-10 (t1 #spool-hub-devel topic ae2e5093): Shift + a letter runs a quick
// action on the SELECTED message, desktop only. Owner, verbatim: "shift seems
// good, as long as it does not interfere with other typical OS and browser
// options". So a shortcut never fires while the caret is in a text field, a
// menu or a dialog is open, or Ctrl / Cmd / Alt is also held (those chords
// belong to the browser and the OS), nor on a phone width.
//
// Each key runs the SAME handler as its right-click menu item, and only when
// that item would be offered for that message: shortcutItem() picks the item
// from msgMenuItems(), so the permission check is the menu's own. Reply,
// Copy text and Kind are phone-sheet items (the desktop has them on the row's
// own buttons), so the offer is the union of both menus.
//
// ArrowUp / ArrowDown and j / k move the selection; Shift + ? lists the keys.
// The key map and the matching rules live here so node can test them; the
// listener is composables/useMsgShortcuts.ts.
import { msgMenuItems } from './msg-menu.mjs'

/**
 * The keys, in the order the help list shows them. `items` are the menu item
 * ids the key may run, first offered wins (Move or merge: one picker,
 * whichever the message offers; Delete: the topic's or the message's - both
 * confirm first).
 */
export const MSG_SHORTCUTS = Object.freeze([
  { key: 'H', items: ['hide-flow'], labelKey: 'feed.msg_menu.hide_flow' },
  { key: 'R', items: ['reply'], labelKey: 'feed.msg_menu.reply' },
  { key: 'E', items: ['edit'], labelKey: 'feed.msg_menu.edit' },
  { key: 'A', items: ['archive'], labelKey: 'feed.shortcuts.archive' },
  { key: 'O', items: ['open'], labelKey: 'feed.msg_menu.open' },
  { key: 'P', items: ['parent'], labelKey: 'feed.msg_menu.open_parent' },
  { key: 'L', items: ['copy'], labelKey: 'feed.msg_menu.copy_link' },
  { key: 'C', items: ['copy-text'], labelKey: 'feed.msg_menu.copy_text' },
  { key: 'K', items: ['kind'], labelKey: 'feed.msg_menu.kind' },
  { key: 'T', items: ['promote-topic'], labelKey: 'feed.msg_menu.promote_topic' },
  { key: 'M', items: ['move-channel', 'move-topic', 'merge-topic'], labelKey: 'feed.shortcuts.move' },
  { key: 'D', items: ['delete-topic', 'delete'], labelKey: 'feed.msg_menu.delete' },
].map((s) => Object.freeze({ ...s, items: Object.freeze(s.items) })))

/**
 * HUM-10 (t1 topic 2627084c): the keys a focused topic row in the Topics view
 * (/t) takes. Same matching (shortcutFor) and the same offer check
 * (shortcutItem over the row menu's flags) as a message card.
 */
export const TOPIC_LIST_SHORTCUTS = Object.freeze([
  { key: 'A', items: ['archive'], labelKey: 'feed.shortcuts.archive_topic_row' },
].map((s) => Object.freeze({ ...s, items: Object.freeze(s.items) })))

/** The other keys the help list names (not message actions). */
export const NAV_SHORTCUTS = Object.freeze([
  Object.freeze({ keys: ['↑', '↓', 'j', 'k'], labelKey: 'feed.shortcuts.step' }),
  Object.freeze({ keys: ['⇧', '?'], labelKey: 'feed.shortcuts.help' }),
  Object.freeze({ keys: ['/'], labelKey: 'feed.shortcuts.search' }),
  Object.freeze({ keys: ['Esc'], labelKey: 'feed.shortcuts.close' }),
])

const BY_ITEM = new Map(MSG_SHORTCUTS.flatMap((s) => s.items.map((id) => [id, s.key])))

/** The hint a menu item shows on its right ("⇧H"), '' when it has no key. */
export function shortcutHint(itemId) {
  const k = BY_ITEM.get(String(itemId || ''))
  return k ? `⇧${k}` : ''
}

/** The `keyboard_shortcuts` session claim: only a literal false turns them off (null = never picked = on). */
export function shortcutsOn(claim) {
  return claim !== false
}

const TYPING = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], [role="combobox"]'
const OVERLAY = '[role="menu"], [role="dialog"], [role="alertdialog"], [role="listbox"], dialog'

/** Is the caret in a text field (or inside an open menu / dialog)? */
export function inTypingOrOverlay(el) {
  if (!el || typeof el.closest !== 'function') return false
  if (el.isContentEditable) return true
  return Boolean(el.closest(TYPING) || el.closest(OVERLAY))
}

/** The Latin letter a Shift + key press names, '' when none (layout-independent fallback on `code`). */
function letterOf(ev) {
  const key = String(ev.key || '')
  if (/^[A-Za-z]$/.test(key)) return key.toUpperCase()
  const m = /^Key([A-Z])$/.exec(String(ev.code || ''))
  return m ? m[1] : ''
}

/**
 * What one keydown means for the message feed.
 *
 * @param {{ key?: string, code?: string, shiftKey?: boolean, ctrlKey?: boolean, metaKey?: boolean,
 *           altKey?: boolean, isComposing?: boolean, repeat?: boolean, defaultPrevented?: boolean,
 *           target?: unknown } | null | undefined} ev
 * @param {{ enabled?: boolean, phone?: boolean, overlayOpen?: boolean }} [ctx]
 * @returns {{ type: 'action', key: string } | { type: 'step', step: 1 | -1 } | { type: 'help' } | null}
 */
export function shortcutFor(ev, { enabled = true, phone = false, overlayOpen = false } = {}) {
  if (!ev || !enabled || phone || overlayOpen) return null
  if (ev.isComposing || ev.defaultPrevented) return null
  if (ev.ctrlKey || ev.metaKey || ev.altKey) return null
  if (inTypingOrOverlay(ev.target)) return null
  const key = String(ev.key || '')
  if (key === '?') return { type: 'help' }
  if (!ev.shiftKey) {
    if (key === 'j' || key === 'ArrowDown') return { type: 'step', step: 1 }
    if (key === 'k' || key === 'ArrowUp') return { type: 'step', step: -1 }
    return null
  }
  if (ev.repeat) return null
  const letter = letterOf(ev)
  return letter && MSG_SHORTCUTS.some((s) => s.key === letter) ? { type: 'action', key: letter } : null
}

/**
 * The ids of every menu item offered for a message with these menu flags
 * (MessageMenu's props), enabled ones only: the desktop menu and the phone
 * sheet together.
 *
 * @param {Parameters<typeof msgMenuItems>[0]} flags
 * @returns {Set<string>}
 */
export function offeredItems(flags) {
  const f = flags && typeof flags === 'object' ? flags : {}
  const ids = new Set()
  for (const touch of [false, true]) {
    for (const it of msgMenuItems({ ...f, touch })) if (!it.disabled) ids.add(it.id)
  }
  return ids
}

/**
 * The menu item a Shift + `key` runs on a message offering `offered`, '' when
 * that message's menu would not show it (then nothing happens).
 *
 * @param {string} key
 * @param {Set<string> | string[]} offered
 */
export function shortcutItem(key, offered) {
  const s = MSG_SHORTCUTS.find((x) => x.key === String(key || '').toUpperCase())
  if (!s) return ''
  const has = offered instanceof Set ? (id) => offered.has(id) : (id) => Array.from(offered || []).includes(id)
  return s.items.find(has) || ''
}

/**
 * The "Message shortcuts" section of doc/help/keyboard-shortcuts.md.
 * The rows are MSG_SHORTCUTS, so the page cannot name a key the app does
 * not have, or miss one it does. `label(labelKey)` is the English action
 * name (the help pages are English). The unit test fails while the page
 * and this text disagree.
 *
 * @param {(labelKey: string) => string} label
 * @returns {string}
 */
export function messageShortcutsSection(label) {
  const name = typeof label === 'function' ? label : () => ''
  const rows = MSG_SHORTCUTS.map((s) => {
    const action = String(name(s.labelKey) ?? '').replace(/\|/g, '\\|')
    return `| **\`Shift + ${s.key}\`** | Selected message, desktop | ${action} |`
  })
  const topicRows = TOPIC_LIST_SHORTCUTS.map((s) => {
    const action = String(name(s.labelKey) ?? '').replace(/\|/g, '\\|')
    return `| **\`Shift + ${s.key}\`** | Focused topic, Topics view, desktop | ${action} |`
  })
  return [
    '## 7. Message shortcuts',
    '',
    'These keys act on the **selected message**; in the **Topics** view, the Archive key also acts on the focused topic. They work on a desktop. Turn them off under **Settings → Behaviour → Keyboard shortcuts**; while that setting is off, the keys do nothing.',
    '',
    '| Shortcut | Context | Action |',
    '|---|---|---|',
    ...rows,
    ...topicRows,
  ].join('\n')
}
