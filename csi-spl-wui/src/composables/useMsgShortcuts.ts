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
//
// After a shortcut the focus stays in the panel it was pressed in (holdPanel).
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

/** A menu, a dialog or a sheet is open: no shortcut fires under it, and
    holdPanel waits for it to close. The kind menu (Shift + K) is teleported
    to <body>, outside every panel: unlisted, the hold took the focus out of it
    50 ms after it opened (HUM-10, t1 e47e0e7e). */
const OVERLAY_OPEN = '.point-menu, .kind-picker, [role="dialog"][aria-modal="true"], dialog[open]'

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

/** The three panels: the channel rail (left), the list (centre), the topic pane (right). */
const PANEL = 'nav.sidebar, .spool-main, aside.live-pane'
/** How long the focus is held once it is settled: an archive waits on the hub. */
const HOLD_MS = 4000
const HOLD_EVERY_MS = 50

/* a TransitionGroup row on its way out is still in the DOM (LiveFeed) */
const leaving = (el: Element) => Boolean(el.closest('[class*="-leave-active"]'))
const shown = (el: HTMLElement) => el.isConnected && el.getClientRects().length > 0 && !leaving(el)
const typing = (el: Element | null) => Boolean(el?.closest('input, textarea, select, [contenteditable="true"]'))

let held: (() => void) | null = null

/**
 * HUM-10 (t1 c13e8023), owner: "the focus after hitting Shift + H goes to the
 * second panel, when it should stay in the 3rd panel" and "on every keyboard
 * shortcut ... the focus should go back to this panel", in the left-most, the
 * centre and the right panel alike. Call it as a shortcut runs, with the
 * element it was pressed on. For a while after, a focus that falls out of
 * that panel (to <body> as a card leaves, or anywhere else) is put back: on
 * the same card when it is still there, else on its neighbour in the same
 * feed (the next one, the previous one when it was the last), else on the
 * panel. A dialog or picker the key opened is waited for and the focus comes
 * back once it closes. A text field the action put the caret in (Reply's
 * composer, Edit's editor) is the action's own aim and is left alone, as is
 * the reader's next key or click.
 */
export function holdPanel(origin: HTMLElement | null) {
  held?.()
  const panel = origin?.closest<HTMLElement>(PANEL)
  if (!origin || !panel) return
  const row = origin.closest<HTMLElement>('article.msg')
  const feed = row?.closest('[role="feed"]') || null
  const inFeed = (r: HTMLElement) => shown(r) && r.closest('[role="feed"]') === feed
  const rows = feed ? [...feed.querySelectorAll<HTMLElement>('article.msg')].filter(inFeed) : []
  const at = row ? rows.indexOf(row) : -1
  let settled = Date.now()
  let timer: ReturnType<typeof setInterval> | null = null
  const stop = () => {
    if (timer) clearInterval(timer)
    timer = null
    document.removeEventListener('keydown', onUser, true)
    document.removeEventListener('pointerdown', onUser, true)
    if (held === stop) held = null
  }
  /* the reader moves on: no longer ours to hold (keys typed into an open dialog are its own) */
  function onUser() {
    if (!document.querySelector(OVERLAY_OPEN)) stop()
  }
  function place() {
    const self = row || origin
    const next = self && shown(self) && panel!.contains(self)
      ? self
      : rows.slice(at + 1).find(inFeed) || rows.slice(0, Math.max(at, 0)).reverse().find(inFeed)
    const to = next || panel!
    if (!next && !to.hasAttribute('tabindex')) to.setAttribute('tabindex', '-1')
    to.focus({ preventScroll: true })
    if (!next) return
    const scroller = scrollerOf(next)
    if (scroller !== document.scrollingElement && scroller !== document.documentElement) scrollRowIntoPane(scroller as HTMLElement, next)
  }
  function tick() {
    if (!panel!.isConnected) return stop()
    if (document.querySelector(OVERLAY_OPEN)) {
      settled = Date.now()
      return
    }
    const a = document.activeElement as HTMLElement | null
    const fine = a && a !== document.body && panel!.contains(a) && !leaving(a)
    if (!fine && typing(a)) return stop()
    if (!fine) {
      place()
      settled = Date.now()
      return
    }
    if (Date.now() - settled > HOLD_MS) stop()
  }
  held = stop
  /* after this key's own dispatch, so the key itself does not end the hold */
  setTimeout(() => {
    if (held !== stop) return
    document.addEventListener('keydown', onUser, true)
    document.addEventListener('pointerdown', onUser, true)
    timer = setInterval(tick, HOLD_EVERY_MS)
  }, 0)
}

function install() {
  listening = (ev: KeyboardEvent) => {
    const live = cards.values().next().value
    if (!live) return
    const hit = shortcutFor(ev, { enabled: live.on.value, overlayOpen: Boolean(document.querySelector(OVERLAY_OPEN)) })
    if (!hit) return
    if (hit.type === 'help') {
      ev.preventDefault()
      holdPanel(document.activeElement as HTMLElement | null)
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
      holdPanel(card || (document.activeElement as HTMLElement | null))
      void undo.undo()
      return
    }
    if (!entry || entry.busy()) return
    const id = shortcutItem(hit.key, offeredItems(entry.flags()))
    if (!id) return
    ev.preventDefault()
    holdPanel(card)
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

/**
 * 081 T005 (FR-004): the card the command palette's actions mode acts on, read
 * as the palette opens (the focus is still where the reader was): the focused
 * card, else the selected one. `flags` are its MessageMenu props and `run` its
 * menu items' handler, so a palette row runs what that menu item would.
 */
export function paletteCard(): { row: HTMLElement, flags: CardEntry['flags'], run: CardEntry['run'] } | null {
  const active = document.activeElement as HTMLElement | null
  const row = active?.closest?.<HTMLElement>('article.msg') || document.querySelector<HTMLElement>('article.msg[data-selected="true"]')
  const entry = row ? cards.get(row) : undefined
  if (!row || !entry || entry.busy()) return null
  return { row, flags: entry.flags, run: entry.run }
}
