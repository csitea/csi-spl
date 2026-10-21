// HUM-10 (topic ae2e5093): the message keyboard shortcuts, desktop only.
// utils/msg-shortcuts.mjs matches a key to a shortcut; this is the ONE window
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
//
// What a key means: utils/msg-shortcuts-dispatch.mjs (unit tested). The DOM
// side it acts through (selection, panel jumps, the focus hold, Enter into
// the topic pane): utils/msg-shortcuts-dom.mjs.
import { useSessionStore } from '~/stores/session'
import { useTopicStore } from '~/stores/topic'
import { usePhone } from '~/composables/useTouchUi'
import { useArchiveUndo } from '~/composables/useArchiveUndo'
import { offeredItems, shortcutFor, shortcutsOn } from '~/utils/msg-shortcuts.mjs'
import { cardEnterAction, shortcutAction, wantsPanelCard } from '~/utils/msg-shortcuts-dispatch.mjs'
import { OVERLAY_OPEN, PANEL, TOPIC_PANE, backToPane, holdPanelFocus, intoPane, jumpInTopic, stepFeedSelection } from '~/utils/msg-shortcuts-dom.mjs'
import { COMPOSER_FOCUS_EVENT } from '~/utils/touch-ui'
import type { Ref } from 'vue'

export { holdPanelFocus as holdPanel, stepFeedSelection as stepSelection }

type CardEntry = {
  /* each card's own switch and undo: the listener reads a live card's, so a
     card unmounted (its computed stopped) never leaves it reading a stale one */
  on: Ref<boolean>
  archiveUndo: ReturnType<typeof useArchiveUndo>
  flags: () => Parameters<typeof offeredItems>[0]
  run: (itemId: string) => unknown
  /** Shift + R: open this card's right-click menu, anchored on the row */
  openMenu: () => void
  busy: () => boolean
}

const cards = new Map<HTMLElement, CardEntry>()
/** Shift + ? : the list of every key (MsgShortcutsHelp in the layout) */
const helpOpen = ref(false)
let listening: ((ev: KeyboardEvent) => void) | null = null

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

/* A heading, a skip, or the pane itself holds the focus after a route change
   (focusPane, firstRow false). Shift + K still means the selected card of
   THAT pane, else its first card. Topic rows, the flow list and issue rows
   have their own kind key (KindKeyHost); a card must not steal it. */
const KIND_ELSEWHERE = 'a.topic-row, .topic-browse__list, #sidebar-panel-topics, [data-testid="left-list"], tr.issues-row, .issues-card, [data-test="issues-heading"], .omnibox-dock, .top-bar__omnibox, dialog, [role="dialog"]'

function kindCardInPanel(): HTMLElement | null {
  const active = document.activeElement as HTMLElement | null
  if (!active || active === document.body || active === document.documentElement) return null
  if (active.closest(KIND_ELSEWHERE)) return null
  const panel = active.closest<HTMLElement>(PANEL)
  if (!panel) return null
  const visible = (el: HTMLElement) => cards.has(el) && el.getClientRects().length > 0
  const selected = panel.querySelector<HTMLElement>('article.msg[data-selected="true"]')
  if (selected && visible(selected)) return selected
  return [...panel.querySelectorAll<HTMLElement>('article.msg')].find(visible) || null
}

/** The topic's first message when the feed does not hold it: the open topic's root, else the task id. */
function openerFallback(task: string): string {
  const topic = useTopicStore()
  if (task && String(topic.parentTaskId || '') === task) {
    return String(topic.rootMsg?.msg_id || topic.target?.rootMsgId || task)
  }
  return task
}

/* Spec 103 T006 (t1 7d9e1681, owner: "jumping between the panels doesn't
   work"): Enter in the channel and DM panels. The global vim layer
   (useVimNavigation) leaves Enter to the row; on a card it means:
     Panel 2  the card opens its topic (MessageCard's own Enter) and the
              focus follows it into the topic pane, Panel 3, on its first card
     Panel 3  the caret goes to the reply composer (as the menu's Reply)
   Behind the same Keyboard shortcuts switch as every key here. True when the
   key was this. */
function vimEnter(ev: KeyboardEvent, on: boolean, overlayOpen: boolean): boolean {
  const card = ev.target as HTMLElement | null
  const entry = card ? cards.get(card) : undefined
  const act = cardEnterAction(ev, {
    on, overlayOpen, isCard: Boolean(entry),
    inTopicPane: Boolean(card?.closest(TOPIC_PANE)),
    inMain: Boolean(card?.closest('.spool-main')),
    busy: Boolean(entry?.busy()),
  })
  if (act === 'composer') {
    ev.preventDefault()
    window.dispatchEvent(new CustomEvent(COMPOSER_FOCUS_EVENT))
  } else if (act === 'into-pane') intoPane(card!)
  return act !== null
}

/** Shift + R on a focused topic-list row: its own contextmenu handler opens that row's menu. */
function openRowMenu(topicRow: HTMLElement) {
  const rect = topicRow.getBoundingClientRect()
  topicRow.dispatchEvent(new MouseEvent('contextmenu', {
    bubbles: true, cancelable: true,
    clientX: Math.round(rect.left + 16),
    clientY: Math.round(rect.top + 20),
    button: 2, buttons: 2,
  }))
}

function onKeydown(ev: KeyboardEvent) {
  const live = cards.values().next().value
  if (!live) return
  const overlayOpen = Boolean(document.querySelector(OVERLAY_OPEN))
  if (vimEnter(ev, live.on.value, overlayOpen)) return
  const hit = shortcutFor(ev, { enabled: live.on.value, overlayOpen })
  if (!hit) return
  const active = document.activeElement as HTMLElement | null
  let card = targetCard()
  /* HUM-10 t1 ffc3b83c: Shift + K in the middle (or any pane) opens the
     kind menu of the selected card there, even when the focus is the
     heading rather than the card. */
  if (wantsPanelCard(hit, Boolean(card))) card = kindCardInPanel()
  const entry = card ? cards.get(card) : undefined
  /* the card just archived is gone; while its "Archived · Undo" is up, Shift + A again brings it back */
  const toast = live.archiveUndo.toast.value
  const topicRow = entry ? null : active?.closest?.<HTMLElement>('a.topic-row') || null
  const act = shortcutAction(hit, {
    hasCard: Boolean(card), hasEntry: Boolean(entry), busy: Boolean(entry?.busy()),
    undoUp: Boolean(toast && !toast.busy), onTopicRow: Boolean(topicRow),
    offered: () => offeredItems(entry!.flags()),
  })
  if (!act) return
  if (act.do === 'step' || act.do === 'row-back' || act.do === 'jump') {
    const moved = act.do === 'step' ? stepFeedSelection(card, act.step)
      : act.do === 'row-back' ? backToPane(topicRow!)
        : jumpInTopic(card!, act.key, openerFallback)
    if (moved) ev.preventDefault()
    return
  }
  ev.preventDefault()
  if (act.do === 'help') {
    holdPanelFocus(active)
    helpOpen.value = true
  } else if (act.do === 'undo') {
    holdPanelFocus(card || active)
    void live.archiveUndo.undo()
  } else if (act.do === 'menu') entry!.openMenu()
  else if (act.do === 'row-menu') openRowMenu(topicRow!)
  else {
    holdPanelFocus(card)
    void entry!.run(act.id)
  }
}

function install() {
  listening = onKeydown
  window.addEventListener('keydown', listening)
}

/**
 * Register one message card. `row` is its <article>; `flags` the props its
 * MessageMenu gets; `run` the handler of one menu item id; `busy` true while
 * it is being edited.
 */
export function useMsgShortcuts(opts: Pick<CardEntry, 'flags' | 'run' | 'busy' | 'openMenu'> & { row: Ref<HTMLElement | null> }) {
  const on = useMsgShortcutsOn()
  const archiveUndo = useArchiveUndo()
  let el: HTMLElement | null = null
  onMounted(() => {
    el = opts.row.value
    if (!el) return
    cards.set(el, { on, archiveUndo, flags: opts.flags, run: opts.run, busy: opts.busy, openMenu: opts.openMenu })
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
