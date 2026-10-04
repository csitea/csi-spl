// HUM-10 (topic ae2e5093): the message keyboard shortcuts, desktop only.
// utils/msg-shortcuts.mjs decides what a key means; this is the ONE window
// listener and the card registry it acts through.
//
// A MessageCard registers its row with the menu flags it would hand
// MessageMenu (`flags`) and the function its menu items run (`run`), so a
// Shift + letter runs exactly what that menu item would, and only when the
// menu would offer it. The target is the card holding the focus (a click or
// the arrows put it there); with the focus nowhere (<body>), the card marked
// selected. The window listener is added with the first card and removed with
// the last one; it acts after every element handler, so a key a row or a page
// (the Issues sheet's j / k) already took (defaultPrevented) is left alone.
import { useSessionStore } from '~/stores/session'
import { usePhone } from '~/composables/useTouchUi'
import { useArchiveUndo } from '~/composables/useArchiveUndo'
import { offeredItems, shortcutFor, shortcutItem, shortcutsOn } from '~/utils/msg-shortcuts.mjs'
import { stepRow } from '~/utils/row-keys.mjs'
import { scrollRowIntoPane } from '~/utils/pane-scroll.mjs'
import { scrollerOf } from '~/utils/scroll-anchor.mjs'
import type { Ref } from 'vue'

type CardEntry = {
  /* each card's own switch and undo: the listener reads a live card's, so a
     card unmounted (its computed stopped) never leaves it reading a stale one */
  on: Ref<boolean>
  archiveUndo: ReturnType<typeof useArchiveUndo>
  flags: () => Parameters<typeof offeredItems>[0]
  run: (itemId: string) => unknown
  busy: () => boolean
}

const cards = new Map<HTMLElement, CardEntry>()
/** Shift + ? : the list of every key (MsgShortcutsHelp in the layout) */
const helpOpen = ref(false)
let listening: ((ev: KeyboardEvent) => void) | null = null

/** A menu, a dialog or a sheet is open: no shortcut fires under it. */
const OVERLAY_OPEN = '.point-menu, [role="dialog"][aria-modal="true"], dialog[open]'

/** Is the switch on (Settings -> Behaviour; never picked = on)? */
export function useMsgShortcutsOn() {
  const session = useSessionStore()
  const phone = usePhone()
  return computed(() => shortcutsOn(session.claims?.keyboard_shortcuts) && !phone.value)
}

export function useMsgShortcutsHelp() {
  return helpOpen
}

/** The card the keys act on: the focused one, else (focus on <body>) the selected one. */
function targetCard(): HTMLElement | null {
  const active = document.activeElement as HTMLElement | null
  const focused = active?.closest?.<HTMLElement>('article.msg') || null
  if (focused) return focused
  if (active && active !== document.body) return null
  return document.querySelector<HTMLElement>('article.msg[data-selected="true"]')
}

/** Move the selection (the focus) `step` messages along `row`'s feed. True when it moved. */
export function stepSelection(row: HTMLElement | null, step: number): boolean {
  const feed = row?.closest('[role="feed"]')
  const rows = feed ? [...feed.querySelectorAll<HTMLElement>('article.msg')].filter((r) => r.closest('[role="feed"]') === feed) : []
  const next = row ? stepRow(rows, row, step) : null
  if (!next) return false
  next.focus({ preventScroll: true })
  /* the feed's own scroller, never the document (pane-scroll.mjs) */
  const scroller = scrollerOf(next)
  if (scroller !== document.scrollingElement && scroller !== document.documentElement) scrollRowIntoPane(scroller as HTMLElement, next)
  return true
}

function install() {
  listening = (ev: KeyboardEvent) => {
    const live = cards.values().next().value
    if (!live) return
    const hit = shortcutFor(ev, { enabled: live.on.value, overlayOpen: Boolean(document.querySelector(OVERLAY_OPEN)) })
    if (!hit) return
    if (hit.type === 'help') {
      ev.preventDefault()
      helpOpen.value = true
      return
    }
    const card = targetCard()
    const entry = card ? cards.get(card) : undefined
    if (hit.type === 'step') {
      if (card && stepSelection(card, hit.step)) ev.preventDefault()
      return
    }
    /* Archive / Unarchive: the card just archived is gone; while its
       "Archived · Undo" is up, Shift + A again brings it back */
    const undo = live.archiveUndo
    if (hit.key === 'A' && undo.toast.value && !undo.toast.value.busy) {
      ev.preventDefault()
      void undo.undo()
      return
    }
    if (!entry || entry.busy()) return
    const id = shortcutItem(hit.key, offeredItems(entry.flags()))
    if (!id) return
    ev.preventDefault()
    void entry.run(id)
  }
  window.addEventListener('keydown', listening)
}

/**
 * Register one message card. `row` is its <article>; `flags` the props its
 * MessageMenu gets; `run` the handler of one menu item id; `busy` true while
 * it is being edited.
 */
export function useMsgShortcuts(opts: Pick<CardEntry, 'flags' | 'run' | 'busy'> & { row: Ref<HTMLElement | null> }) {
  const on = useMsgShortcutsOn()
  const archiveUndo = useArchiveUndo()
  let el: HTMLElement | null = null
  onMounted(() => {
    el = opts.row.value
    if (!el) return
    cards.set(el, { on, archiveUndo, flags: opts.flags, run: opts.run, busy: opts.busy })
    if (!listening) install()
  })
  onBeforeUnmount(() => {
    if (el) cards.delete(el)
    el = null
    if (cards.size === 0 && listening) {
      window.removeEventListener('keydown', listening)
      listening = null
    }
  })
}
