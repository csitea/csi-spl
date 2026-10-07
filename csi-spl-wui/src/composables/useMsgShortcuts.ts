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
import { useTopicStore } from '~/stores/topic'
import { usePhone } from '~/composables/useTouchUi'
import { useArchiveUndo } from '~/composables/useArchiveUndo'
import { backJump, listRowFor, offeredItems, parentJump, replyBack, shortcutFor, shortcutItem, shortcutsOn } from '~/utils/msg-shortcuts.mjs'
import { requestMessageJump } from '~/utils/msg-jump.mjs'
import { stepRow } from '~/utils/row-keys.mjs'
import { scrollRowIntoPane } from '~/utils/pane-scroll.mjs'
import { scrollerOf } from '~/utils/scroll-anchor.mjs'
import { COMPOSER_FOCUS_EVENT } from '~/utils/touch-ui.mjs'
import type { Ref } from 'vue'

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

/** The cards of `row`'s own feed, in feed order (a nested feed's cards are not its). */
function feedCards(row: HTMLElement | null): HTMLElement[] {
  const feed = row?.closest('[role="feed"]')
  return feed ? [...feed.querySelectorAll<HTMLElement>('article.msg')].filter((r) => r.closest('[role="feed"]') === feed) : []
}

/** Select `row`: it takes the focus and its pane scrolls it into view. */
function selectRow(row: HTMLElement) {
  row.focus({ preventScroll: true })
  /* the feed's own scroller, never the document (pane-scroll.mjs) */
  const scroller = scrollerOf(row)
  if (scroller !== document.scrollingElement && scroller !== document.documentElement) scrollRowIntoPane(scroller as HTMLElement, row)
}

/** Move the selection (the focus) `step` messages along `row`'s feed. True when it moved. */
export function stepSelection(row: HTMLElement | null, step: number): boolean {
  const next = row ? stepRow(feedCards(row), row, step) : null
  if (!next) return false
  selectRow(next)
  return true
}

/* HUM-10 (t1 29c3b055), owner: "a shortcut and it's respective shortcut to
   jump directly from the selected reply msg and the parent topic msg", then
   "it should select the topics first msg, but in the 2nd panel" and, on the
   panels read as rail = 1, centre list = 2, topic pane = 3, "yes , do it that
   way", then "Shift + B , should have been the one to jump from the 3d panel
   to the 2nd panel and not vice versa". Shift + B on a reply in the topic
   pane selects that topic's row in the centre list (the channel or DM card,
   the topic view's topic row); Shift + U there goes back to the reply (else the topic's latest reply in the pane).
   With no such row, or outside the pane, both keys stay in the same feed. A
   first message the feed does not hold (an old topic, paged out) is read in
   the way a message link does (requestMessageJump): never a reload. */
let jumpMemo: { parent: string, reply: string } | null = null
let listMemo: { topic: string, reply: string } | null = null

/** The topic pane (the 3rd panel). */
const TOPIC_PANE = 'aside.topic'
const listKey = (el: HTMLElement) => el.getAttribute('data-msg-id') || el.getAttribute('data-key') || ''
const listTask = (el: HTMLElement) => el.getAttribute('data-task-id') || el.getAttribute('data-key') || ''

/** The rows of the centre list (the 2nd panel): its cards, and the topic view's topic rows. */
function listRows(): HTMLElement[] {
  const main = document.querySelector('.spool-main')
  if (!main) return []
  return [...main.querySelectorAll<HTMLElement>('article.msg, a.topic-row')]
    .filter((el) => !el.closest(TOPIC_PANE) && el.getClientRects().length > 0)
}

const feedRow = (el: HTMLElement) => ({
  id: el.getAttribute('data-msg-id') || '',
  task: el.getAttribute('data-task-id') || '',
  opener: el.getAttribute('data-opener') === 'true',
  ts: el.getAttribute('data-sent') || '',
})

/** Shift + B on a reply in the topic pane: select its topic's row in the centre list. */
function upToList(card: HTMLElement): boolean {
  const topic = card.getAttribute('data-task-id') || ''
  if (!card.closest(TOPIC_PANE) || !topic) return false
  const rows = listRows()
  const key = listRowFor(rows.map((el) => ({ key: listKey(el), task: listTask(el) })), topic)
  const el = key ? rows.find((e) => listKey(e) === key) : undefined
  if (!el) return false
  listMemo = { topic, reply: card.getAttribute('data-msg-id') || '' }
  selectRow(el)
  return true
}

/** Shift + U on a centre-list row whose topic the pane shows: back to the reply. */
function backToPane(row: HTMLElement): boolean {
  if (row.closest(TOPIC_PANE)) return false
  const pane = document.querySelector<HTMLElement>(TOPIC_PANE)
  if (!pane) return false
  const cards = [...pane.querySelectorAll<HTMLElement>('article.msg')].filter((el) => el.getClientRects().length > 0)
  const rows = cards.map(feedRow)
  const topic = [listKey(row), listTask(row)].find((id) => id && rows.some((r) => r.task === id)) || ''
  const to = replyBack(rows, topic, listMemo)
  const el = to ? cards.find((e) => e.getAttribute('data-msg-id') === to) : undefined
  if (!el) return false
  selectRow(el)
  return true
}

/** The topic's first message when the feed does not hold it: the open topic's root, else the task id. */
function openerFallback(task: string): string {
  const topic = useTopicStore()
  if (task && String(topic.parentTaskId || '') === task) {
    return String(topic.rootMsg?.msg_id || topic.target?.rootMsgId || task)
  }
  return task
}

function jumpInTopic(card: HTMLElement, key: string): boolean {
  const els = feedCards(card)
  const rows = els.map((el) => ({
    id: el.getAttribute('data-msg-id') || '',
    task: el.getAttribute('data-task-id') || '',
    opener: el.getAttribute('data-opener') === 'true',
    ts: el.getAttribute('data-sent') || '',
  }))
  const id = card.getAttribute('data-msg-id') || ''
  let to = ''
  if (key === 'B') {
    const hit = parentJump(rows, id, openerFallback(card.getAttribute('data-task-id') || ''))
    /* a reply (hit): its topic's row in the 2nd panel first */
    if (hit && upToList(card)) return true
    if (hit) jumpMemo = { parent: hit.parent, reply: id }
    to = hit?.parent || ''
  } else {
    if (backToPane(card)) return true
    to = backJump(rows, id, jumpMemo)
  }
  if (!to) return false
  const el = els.find((e) => e.getAttribute('data-msg-id') === to)
  if (!el) return requestMessageJump(to)
  selectRow(el)
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
  /* one controller per hold: abort() removes both reader listeners */
  const listeners = new AbortController()
  const stop = () => {
    if (timer) clearInterval(timer)
    timer = null
    listeners.abort()
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
    const opts = { capture: true, signal: listeners.signal }
    document.addEventListener('keydown', onUser, opts)
    document.addEventListener('pointerdown', onUser, opts)
    timer = setInterval(tick, HOLD_EVERY_MS)
  }, 0)
}

/* Spec 103 T006 (t1 7d9e1681, owner: "jumping between the panels doesn't
   work"): Enter in the channel and DM panels. The global vim layer
   (useVimNavigation) leaves Enter to the row; on a card it means:
     Panel 2  the card opens its topic (MessageCard's own Enter) and the
              focus follows it into the topic pane, Panel 3, on its first card
     Panel 3  the caret goes to the reply composer (as the menu's Reply)
   Behind the same Keyboard shortcuts switch as every key here. */
const PANE_WAIT_MS = 3000

/** The vim ring (vim-nav.css) on `el`, the one ring on screen, and the focus. */
function vimRing(el: HTMLElement) {
  for (const old of document.querySelectorAll<HTMLElement>('[data-vim-selected]')) if (old !== el) old.removeAttribute('data-vim-selected')
  el.setAttribute('data-vim-selected', 'true')
  selectRow(el)
}

/** After Enter opened `from`'s topic: its first card in the pane takes the focus once drawn. */
function intoPane(from: HTMLElement) {
  const want = from.getAttribute('data-task-id') || ''
  const t0 = Date.now()
  const tick = () => {
    /* the reader moved on (a click, another key): not ours any more */
    const a = document.activeElement
    if (a && a !== from && a !== document.body) return
    const pane = document.querySelector<HTMLElement>(TOPIC_PANE)
    const rows = pane ? [...pane.querySelectorAll<HTMLElement>('article.msg')].filter(shown) : []
    const late = Date.now() - t0 >= PANE_WAIT_MS
    /* a pane still on the topic it showed before is not this one's yet */
    const to = rows.find((el) => !want || el.getAttribute('data-task-id') === want) || (late ? rows[0] : undefined)
    if (to) return vimRing(to)
    if (!late) setTimeout(tick, HOLD_EVERY_MS)
  }
  setTimeout(tick, 0)
}

/** Enter on a card, Panel 2 or 3. True when the key was this. */
function vimEnter(ev: KeyboardEvent, on: boolean): boolean {
  if (ev.key !== 'Enter' || !on || ev.shiftKey || ev.ctrlKey || ev.metaKey || ev.altKey || ev.isComposing || ev.repeat) return false
  if (document.querySelector(OVERLAY_OPEN)) return false
  const card = ev.target as HTMLElement | null
  /* only the row itself: Enter on a button or link inside it is that control's */
  if (!card || !cards.has(card)) return false
  if (card.closest(TOPIC_PANE)) {
    if (ev.defaultPrevented || cards.get(card)?.busy()) return false
    ev.preventDefault()
    window.dispatchEvent(new CustomEvent(COMPOSER_FOCUS_EVENT))
    return true
  }
  /* defaultPrevented: the card took its Enter and opened its topic */
  if (!ev.defaultPrevented || !card.closest('.spool-main')) return false
  intoPane(card)
  return true
}

function install() {
  listening = (ev: KeyboardEvent) => {
    const live = cards.values().next().value
    if (!live) return
    if (vimEnter(ev, live.on.value)) return
    const hit = shortcutFor(ev, { enabled: live.on.value, overlayOpen: Boolean(document.querySelector(OVERLAY_OPEN)) })
    if (!hit) return
    if (hit.type === 'help') {
      ev.preventDefault()
      holdPanel(document.activeElement as HTMLElement | null)
      helpOpen.value = true
      return
    }
    let card = targetCard()
    /* HUM-10 t1 ffc3b83c: Shift + K in the middle (or any pane) opens the
       kind menu of the selected card there, even when the focus is the
       heading rather than the card. */
    if (!card && hit.type === 'action' && hit.key === 'K') card = kindCardInPanel()
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
    /* Shift + R opens the row's menu (first item focused by the menu).
       It is not an item id, so it does not go through shortcutItem.
       A focused topic-list row (no message card) gets the same key: its
       own contextmenu handler opens that row's menu. */
    if (hit.key === 'R') {
      if (entry && !entry.busy()) {
        ev.preventDefault()
        entry.openMenu()
        return
      }
      const active = document.activeElement as HTMLElement | null
      const topicRow = !entry && active ? active.closest<HTMLElement>('a.topic-row') : null
      if (topicRow) {
        ev.preventDefault()
        const rect = topicRow.getBoundingClientRect()
        topicRow.dispatchEvent(new MouseEvent('contextmenu', {
          bubbles: true, cancelable: true,
          clientX: Math.round(rect.left + 16),
          clientY: Math.round(rect.top + 20),
          button: 2, buttons: 2,
        }))
      }
      return
    }
    /* the topic view's focused topic row (no card): Shift + U back to the reply */
    if (!entry && hit.key === 'U') {
      const topicRow = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>('a.topic-row')
      if (topicRow && backToPane(topicRow)) ev.preventDefault()
      return
    }
    if (!entry || entry.busy()) return
    if (hit.key === 'U' || hit.key === 'B') {
      if (card && jumpInTopic(card, hit.key)) ev.preventDefault()
      return
    }
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
