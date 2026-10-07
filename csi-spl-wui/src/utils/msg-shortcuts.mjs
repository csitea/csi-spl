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
// Shift + R is the exception (HUM-10 t1 4c5161e3): it opens that menu on the
// selected row instead of running an item. Reply stays on the phone sheet.
//
// Shift + U and Shift + B are not menu items either (HUM-10 t1 29c3b055):
// they move the selection from a reply in the topic pane (3rd panel) to its
// topic's row in the centre list (2nd panel) and back (listRowFor /
// replyBack); outside the pane, or with no such row, inside the same feed
// (parentJump / backJump).
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
  { key: 'R', items: [], labelKey: 'feed.shortcuts.open_menu' },
  { key: 'E', items: ['edit'], labelKey: 'feed.msg_menu.edit' },
  { key: 'A', items: ['archive'], labelKey: 'feed.shortcuts.archive' },
  { key: 'O', items: ['open'], labelKey: 'feed.msg_menu.open' },
  { key: 'P', items: ['parent'], labelKey: 'feed.msg_menu.open_parent' },
  { key: 'U', items: [], labelKey: 'feed.shortcuts.to_parent' },
  { key: 'B', items: [], labelKey: 'feed.shortcuts.back_to_reply' },
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
 * @typedef {{ id: string, task: string, opener: boolean, ts?: string }} FeedRow
 * One card of a feed, in feed order: its msg_id, its task_id, whether it is
 * a level-1 line (is_parent not 0) and its timestamp.
 */

/** The topic's first message among `rows`: the earliest level-1 row of `task` ('' when none is held). */
function openerIn(rows, task) {
  let best = null
  for (const r of rows) {
    if (!r || !r.opener || r.task !== task) continue
    if (!best || String(r.ts || '') < String(best.ts || '')) best = r
  }
  return best ? best.id : ''
}

/**
 * Shift + U (HUM-10 t1 29c3b055): from a reply, the id of its topic's first
 * message. `fallbackId` is that opener's id when the feed does not hold it
 * (an old topic, paged out): the caller then reads it in the way a message
 * link does. null = nothing to do (the selected row is the opener, or has no
 * topic).
 *
 * @param {FeedRow[]} rows
 * @param {string} fromId
 * @param {string} [fallbackId]
 * @returns {{ parent: string, held: boolean } | null}
 */
export function parentJump(rows, fromId, fallbackId = '') {
  const list = Array.isArray(rows) ? rows : []
  const from = list.find((r) => r && r.id === fromId)
  if (!from || !from.task) return null
  const held = openerIn(list, from.task)
  if (held) return held === from.id ? null : { parent: held, held: true }
  /* no level-1 row held: a row that is one itself is taken as the opener */
  if (from.opener) return null
  const want = String(fallbackId || '')
  return want && want !== from.id ? { parent: want, held: false } : null
}

/**
 * Shift + B, the way back: from a topic's first message, the reply Shift + U
 * left (`memo`, while it names this opener), else the topic's latest reply
 * in the feed. '' = nothing to do (not an opener, or no reply).
 *
 * @param {FeedRow[]} rows
 * @param {string} fromId
 * @param {{ parent: string, reply: string } | null} [memo]
 * @returns {string}
 */
export function backJump(rows, fromId, memo = null) {
  const list = Array.isArray(rows) ? rows : []
  const from = list.find((r) => r && r.id === fromId)
  if (!from || !from.task || openerIn(list, from.task) !== from.id) return ''
  if (memo && memo.parent === from.id && memo.reply && memo.reply !== from.id) return String(memo.reply)
  let latest = null
  for (const r of list) {
    if (!r || r.task !== from.task || r.id === from.id) continue
    if (!latest || String(r.ts || '') >= String(latest.ts || '')) latest = r
  }
  return latest ? latest.id : ''
}

/**
 * @typedef {{ key: string, task: string }} ListRow
 * One row of the centre list (the 2nd panel): a message card (key = its
 * msg_id) or, in the topic view, a topic row (key = its task id).
 */

/**
 * Shift + U, corrected (HUM-10 t1 29c3b055): "it should select the topics
 * first msg, but in the 2nd panel". From a reply in the topic pane (the 3rd
 * panel) the target is the topic's own row in the centre list: the row whose
 * key is the topic (a #lobby message is the root of its own topic), else one
 * whose task is. '' = the list does not hold it.
 *
 * @param {ListRow[]} rows
 * @param {string} topic the reply's task id
 * @returns {string}
 */
export function listRowFor(rows, topic) {
  const list = Array.isArray(rows) ? rows : []
  const id = String(topic || '')
  if (!id) return ''
  const hit = list.find((r) => r && r.key === id) || list.find((r) => r && r.task === id)
  return hit ? hit.key : ''
}

/**
 * Shift + B from that centre row: back to the reply in the topic pane that
 * Shift + U left (`memo`, while it names this topic and the pane still holds
 * it), else the topic's latest reply there. '' = nothing to do.
 *
 * @param {FeedRow[]} paneRows
 * @param {string} topic
 * @param {{ topic: string, reply: string } | null} [memo]
 * @returns {string}
 */
export function replyBack(paneRows, topic, memo = null) {
  const list = Array.isArray(paneRows) ? paneRows : []
  const id = String(topic || '')
  if (!id) return ''
  if (memo && memo.topic === id && list.some((r) => r && r.id === memo.reply)) return String(memo.reply)
  const opener = openerIn(list, id)
  let latest = null
  for (const r of list) {
    if (!r || r.task !== id || r.id === opener || r.id === id) continue
    if (!latest || String(r.ts || '') >= String(latest.ts || '')) latest = r
  }
  return latest ? latest.id : ''
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
