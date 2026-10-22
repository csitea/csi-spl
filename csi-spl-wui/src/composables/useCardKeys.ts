/*
 * MessageCard's keyboard (r17-03, split out of the card like r13-01's parts):
 * `e` edits, ArrowUp / ArrowDown walk the selection, Delete / Backspace
 * delete, Enter / Space open the topic, and Shift + letter runs the menu item
 * offered by the same flags (composables/useMsgShortcuts.ts). The card decides
 * what its menu offers; these keys run the same handlers.
 */
import type { Ref } from 'vue'
import { wantsEdit } from '~/utils/msg-edit.mjs'
import { holdPanel, stepSelection, useMsgShortcuts } from '~/composables/useMsgShortcuts'
import { deleteKeyAction, rowStep } from '~/utils/row-keys.mjs'
import type { useDeleteUndo } from '~/composables/useDeleteUndo'
import type { SpoolMessage } from '~/types/spool'

type KeyProps = { msg: SpoolMessage, editable?: boolean, clickable?: boolean }
type KeyEmit = ((e: 'open-topic', msg: SpoolMessage) => void) & ((e: 'deleted', msg: SpoolMessage) => void)
type Flags = NonNullable<ReturnType<Parameters<typeof useMsgShortcuts>[0]['flags']>>
type Handler = () => unknown

/** The menu handlers Shift + letter runs, by the card's names for them. */
interface CardKeyActions {
  onMenuOpen: Handler, onMenuParent: Handler, onMenuEdit: Handler, copyMessageLink: Handler, copyBody: Handler,
  onMenuReply: Handler, onMenuKind: Handler, onMenuArchive: Handler, onMenuDelete: Handler, onMenuDeleteTopic: Handler,
  openMovePicker: (mode: 'channel' | 'topic' | 'merge') => unknown, onPromote: Handler, onMenuHide: Handler,
}

/** The card's menu flags, which useMsgShortcuts offers the same way. */
interface CardKeyFlags {
  showParent: Ref<boolean>, parentKind: Ref<Flags['parentKind']>, showTopicArchive: Ref<boolean>, paneArchiveReply: Ref<boolean>,
  showTopicDelete: Ref<boolean>, kindSettable: Ref<boolean>, canMoveTopic: Ref<boolean>, canMoveMsg: Ref<boolean>,
  canPromoteMsg: Ref<boolean>, menuHide: Ref<boolean>, menuLocks: Ref<Flags['locks']>,
}

/** What the card hands its keyboard: the row, its edit and delete state, and its menu. */
interface CardKeyDeps {
  props: KeyProps
  emit: KeyEmit
  rowEl: Ref<HTMLElement | null>
  editing: Ref<boolean>
  removing: Ref<boolean>
  startEdit: () => void
  canEdit: (msg: SpoolMessage) => boolean
  msgDeleteOpen: Ref<boolean>
  deleteUndo: ReturnType<typeof useDeleteUndo>
  openMenuAt: (x: number, y: number) => void
  actions: CardKeyActions
  flags: CardKeyFlags
}

/* HUM-10 ae2e5093: Shift + letter on the selected card runs the same handler
   as its menu item, offered by the same flags (composables/useMsgShortcuts.ts) */
function shortcutRunOf(a: CardKeyActions): Record<string, () => unknown> {
  return {
    open: a.onMenuOpen, parent: a.onMenuParent, edit: a.onMenuEdit, copy: a.copyMessageLink, 'copy-text': a.copyBody,
    reply: a.onMenuReply, kind: a.onMenuKind, archive: a.onMenuArchive, delete: a.onMenuDelete, 'delete-topic': a.onMenuDeleteTopic,
    'move-channel': () => a.openMovePicker('channel'), 'move-topic': () => a.openMovePicker('topic'),
    'merge-topic': () => a.openMovePicker('merge'), 'promote-topic': a.onPromote, 'hide-flow': a.onMenuHide,
  }
}

/* HUM-10 t1 4c5161e3: Shift + R opens this card's menu at the row, the
   same point as the … button, so the first item can take the focus. */
function openMenuFromShortcutOf(rowEl: Ref<HTMLElement | null>, openMenuAt: (x: number, y: number) => void) {
  return function openMenuFromShortcut() {
    const row = rowEl.value
    if (!row) return
    const btn = row.querySelector<HTMLElement>('[data-testid="msg-menu-btn"]')
    const anchor = btn ?? row
    const r = anchor.getBoundingClientRect()
    row.focus({ preventScroll: true })
    if (btn) openMenuAt(r.left, r.bottom + 4)
    else openMenuAt(r.left + 12, r.top + 12)
  }
}

/** Registers the card's Shift + letter shortcuts (call once, in setup) and
    returns `onKey`, the row's own keydown handler. */
export function useCardKeys(deps: CardKeyDeps) {
  const { props, emit, rowEl, editing, removing, startEdit, canEdit, msgDeleteOpen, deleteUndo, actions } = deps
  const {
    showParent, parentKind, showTopicArchive, paneArchiveReply, showTopicDelete, kindSettable,
    canMoveTopic, canMoveMsg, canPromoteMsg, menuHide, menuLocks,
  } = deps.flags

  /* Delete / Backspace on the selected row. A topic-level message
     (is_parent 1) asks first, with the same confirm as the menu; a reply goes
     at once and the "Deleted · Undo" snackbar offers it back. Who may delete
     is the menu's gate, unchanged. preventDefault stops Backspace from
     walking the browser history. True when the key was a delete. */
  function onDeleteKey(ev: KeyboardEvent): boolean {
    const del = editing.value || removing.value
      ? ''
      : deleteKeyAction(ev, props.msg, { topicDelete: showTopicDelete.value, editable: Boolean(props.editable) && canEdit(props.msg) })
    if (!del) return false
    ev.preventDefault()
    /* HUM-10 c13e8023: the focus stays in this card's panel (useMsgShortcuts) */
    holdPanel(rowEl.value)
    if (del === 'confirm-topic') void actions.onMenuDeleteTopic()
    else if (del === 'confirm-message') msgDeleteOpen.value = true
    else {
      /* the host drops it from its own rows; Undo hands it back (onDeleteRestore) */
      deleteUndo.offer(props.msg)
      emit('deleted', props.msg)
    }
    return true
  }

  function onKey(ev: KeyboardEvent) {
    /* `e` on the focused row opens the editor. Checked BEFORE the
       open-topic keys so a row that is editable but not clickable still takes
       it, and guarded by the same target === currentTarget rule. */
    if (wantsEdit(ev, { editable: props.editable && !editing.value })) {
      ev.preventDefault()
      startEdit()
      return
    }
    /* CLE-77840 (owner, topic bc1fd547): ArrowDown / ArrowUp walk the focus,
       which is the selection, to the next / previous message of this feed. */
    const step = editing.value ? 0 : rowStep(ev)
    if (step) {
      if (stepSelection(rowEl.value, step)) ev.preventDefault()
      return
    }
    if (onDeleteKey(ev)) return
    if (!props.clickable) return
    if (ev.key !== 'Enter' && ev.key !== ' ' && ev.key !== 'Spacebar') return
    /* only the row itself: Enter inside a child control is that control's */
    if (ev.target !== ev.currentTarget) return
    ev.preventDefault()
    emit('open-topic', props.msg)
  }

  const shortcutRun = shortcutRunOf(actions)
  useMsgShortcuts({
    row: rowEl,
    busy: () => editing.value || removing.value,
    run: (id) => shortcutRun[id]?.(),
    openMenu: openMenuFromShortcutOf(rowEl, deps.openMenuAt),
    flags: () => ({
      editable: !!props.editable && !editing.value, parent: showParent.value, parentKind: parentKind.value,
      topicArchive: showTopicArchive.value, paneArchive: paneArchiveReply.value, topicDelete: showTopicDelete.value, kind: kindSettable.value,
      moveChannel: canMoveTopic.value, mergeTopic: canMoveTopic.value, moveTopic: canMoveMsg.value,
      promoteTopic: canPromoteMsg.value, hide: menuHide.value, locks: menuLocks.value,
    }),
  })

  return { onKey }
}
