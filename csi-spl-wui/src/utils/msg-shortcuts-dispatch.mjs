// Spec 011 round 13 row 05: what one keydown means to the message shortcut
// listener (composables/useMsgShortcuts.ts), decided from plain flags. The
// listener reads the page into those flags and does what this returns; nothing
// here touches the DOM, so every branch is a unit test
// (tests/unit/msg-shortcuts-dispatch.test.mjs).
import { shortcutItem } from './msg-shortcuts.mjs'

/**
 * Spec 103 T006: Enter on a card in Panel 2 or 3. Only the row itself: Enter
 * on a button or link inside it is that control's (`isCard` false).
 * Panel 3: the caret goes to the reply composer, unless the card took the key
 * or is being edited. Panel 2: the card opened its topic (it took the key,
 * `defaultPrevented`) and the focus follows it into the pane.
 * @param {{ key: string, shiftKey?: boolean, ctrlKey?: boolean, metaKey?: boolean, altKey?: boolean, isComposing?: boolean, repeat?: boolean, defaultPrevented?: boolean }} ev
 * @param {{ on: boolean, overlayOpen: boolean, isCard: boolean, inTopicPane: boolean, inMain: boolean, busy: boolean }} s
 * @returns {'composer' | 'into-pane' | null}
 */
export function cardEnterAction(ev, s) {
  if (ev.key !== 'Enter' || !s.on || ev.shiftKey || ev.ctrlKey || ev.metaKey || ev.altKey || ev.isComposing || ev.repeat) return null
  if (s.overlayOpen || !s.isCard) return null
  if (s.inTopicPane) return ev.defaultPrevented || s.busy ? null : 'composer'
  return ev.defaultPrevented && s.inMain ? 'into-pane' : null
}

/**
 * HUM-10 t1 ffc3b83c: Shift + K with no focused or selected card looks for
 * the selected card of the panel holding the focus.
 * @param {{ type: string, key?: string } | null} hit shortcutFor's answer
 * @param {boolean} hasCard
 */
export function wantsPanelCard(hit, hasCard) {
  return !hasCard && hit?.type === 'action' && hit.key === 'K'
}

/**
 * @typedef {{ do: 'help' } | { do: 'step', step: number } | { do: 'undo' } | { do: 'menu' }
 *   | { do: 'row-menu' } | { do: 'row-back' } | { do: 'jump', key: 'U' | 'B' } | { do: 'run', id: string }} KeyAction
 */

/**
 * The action a matched shortcut takes, in this order:
 *   help      Shift + ?  the list of keys
 *   step      j / k      move the selection, from a card only
 *   undo      Shift + A  while "Archived · Undo" is up (and not busy): bring it back
 *   menu      Shift + R  the card's right-click menu (card not busy)
 *   row-menu  Shift + R  a focused topic-list row with no card: that row's menu
 *   row-back  Shift + U  a focused topic-list row with no card: back to the reply
 *   jump      Shift + U / B on a card: parent and reply jumps
 *   run       Shift + letter: the menu item the card offers for it, else nothing
 * A card being edited (`busy`) takes none of the card keys.
 * @param {{ type: 'help' } | { type: 'step', step: number } | { type: 'action', key: string } | null} hit shortcutFor's answer
 * @param {{ hasCard: boolean, hasEntry: boolean, busy: boolean, undoUp: boolean, onTopicRow: boolean, offered: () => Set<string> | string[] }} s
 * @returns {KeyAction | null}
 */
export function shortcutAction(hit, s) {
  if (!hit) return null
  if (hit.type === 'help') return { do: 'help' }
  if (hit.type === 'step') return s.hasCard ? { do: 'step', step: hit.step } : null
  if (hit.key === 'A' && s.undoUp) return { do: 'undo' }
  if (hit.key === 'R') {
    if (s.hasEntry) return s.busy ? null : { do: 'menu' }
    return s.onTopicRow ? { do: 'row-menu' } : null
  }
  if (!s.hasEntry) return hit.key === 'U' && s.onTopicRow ? { do: 'row-back' } : null
  if (s.busy) return null
  if (hit.key === 'U' || hit.key === 'B') return s.hasCard ? { do: 'jump', key: hit.key } : null
  const id = shortcutItem(hit.key, s.offered())
  return id ? { do: 'run', id } : null
}
