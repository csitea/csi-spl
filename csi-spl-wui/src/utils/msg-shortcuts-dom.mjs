// The DOM side of the message shortcuts (composables/useMsgShortcuts.ts):
// moving the selection along a feed, the Shift + B / U jumps between the
// panels, the focus hold after a shortcut and Enter's walk into the topic
// pane. Moved out of the composable whole (spec 011 round 13 row 05); what a
// key means is decided in msg-shortcuts-dispatch.mjs.
import { backJump, listRowFor, parentJump, replyBack } from './msg-shortcuts.mjs'
import { requestMessageJump } from './msg-jump.mjs'
import { stepRow } from './row-keys.mjs'
import { scrollRowIntoPane } from './pane-scroll.mjs'
import { scrollerOf } from './scroll-anchor.mjs'

/** A menu, a dialog or a sheet is open: no shortcut fires under it, and
    holdPanelFocus waits for it to close. The kind menu (Shift + K) is teleported
    to <body>, outside every panel: unlisted, the hold took the focus out of it
    50 ms after it opened (HUM-10, t1 e47e0e7e). */
export const OVERLAY_OPEN = '.point-menu, .kind-picker, [role="dialog"][aria-modal="true"], dialog[open]'
/** The three panels: the channel rail (left), the list (centre), the topic pane (right). */
export const PANEL = 'nav.sidebar, .spool-main, aside.live-pane'
/** The topic pane (the 3rd panel). */
export const TOPIC_PANE = 'aside.topic'
/** How long the focus is held once it is settled: an archive waits on the hub. */
const HOLD_MS = 4000
const HOLD_EVERY_MS = 50
const PANE_WAIT_MS = 3000

/* a TransitionGroup row on its way out is still in the DOM (LiveFeed) */
const leaving = (el) => Boolean(el.closest('[class*="-leave-active"]'))
const shown = (el) => el.isConnected && el.getClientRects().length > 0 && !leaving(el)
const typing = (el) => Boolean(el?.closest('input, textarea, select, [contenteditable="true"]'))

/** The cards of `row`'s own feed, in feed order (a nested feed's cards are not its). */
function feedCards(row) {
  const feed = row?.closest('[role="feed"]')
  return feed ? [...feed.querySelectorAll('article.msg')].filter((r) => r.closest('[role="feed"]') === feed) : []
}

/** Select `row`: it takes the focus and its pane scrolls it into view. */
function selectRow(row) {
  row.focus({ preventScroll: true })
  /* the feed's own scroller, never the document (pane-scroll.mjs) */
  const scroller = scrollerOf(row)
  if (scroller !== document.scrollingElement && scroller !== document.documentElement) scrollRowIntoPane(scroller, row)
}

/** Move the selection (the focus) `step` messages along `row`'s feed. True when it moved. */
export function stepFeedSelection(row, step) {
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
let jumpMemo = null
let listMemo = null

const listKey = (el) => el.getAttribute('data-msg-id') || el.getAttribute('data-key') || ''
const listTask = (el) => el.getAttribute('data-task-id') || el.getAttribute('data-key') || ''

/** The rows of the centre list (the 2nd panel): its cards, and the topic view's topic rows. */
function listRows() {
  const main = document.querySelector('.spool-main')
  if (!main) return []
  return [...main.querySelectorAll('article.msg, a.topic-row')]
    .filter((el) => !el.closest(TOPIC_PANE) && el.getClientRects().length > 0)
}

const feedRow = (el) => ({
  id: el.getAttribute('data-msg-id') || '',
  task: el.getAttribute('data-task-id') || '',
  opener: el.getAttribute('data-opener') === 'true',
  ts: el.getAttribute('data-sent') || '',
})

/** Shift + B on a reply in the topic pane: select its topic's row in the centre list. */
function upToList(card) {
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
export function backToPane(row) {
  if (row.closest(TOPIC_PANE)) return false
  const pane = document.querySelector(TOPIC_PANE)
  if (!pane) return false
  const cards = [...pane.querySelectorAll('article.msg')].filter((el) => el.getClientRects().length > 0)
  const rows = cards.map(feedRow)
  const topic = [listKey(row), listTask(row)].find((id) => id && rows.some((r) => r.task === id)) || ''
  const to = replyBack(rows, topic, listMemo)
  const el = to ? cards.find((e) => e.getAttribute('data-msg-id') === to) : undefined
  if (!el) return false
  selectRow(el)
  return true
}

/**
 * Shift + B / U on `card`. `openerFallback(task)` names the topic's first
 * message when the feed does not hold it. True when the selection moved.
 * @param {HTMLElement} card
 * @param {'B' | 'U'} key
 * @param {(task: string) => string} openerFallback
 */
export function jumpInTopic(card, key, openerFallback) {
  const els = feedCards(card)
  const rows = els.map(feedRow)
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

let held = null

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
 * @param {HTMLElement | null} origin
 */
export function holdPanelFocus(origin) {
  held?.()
  const panel = origin?.closest(PANEL)
  if (!origin || !panel) return
  const row = origin.closest('article.msg')
  const feed = row?.closest('[role="feed"]') || null
  const inFeed = (r) => shown(r) && r.closest('[role="feed"]') === feed
  const rows = feed ? [...feed.querySelectorAll('article.msg')].filter(inFeed) : []
  const at = row ? rows.indexOf(row) : -1
  let settled = Date.now()
  let timer = null
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
    const next = self && shown(self) && panel.contains(self)
      ? self
      : rows.slice(at + 1).find(inFeed) || rows.slice(0, Math.max(at, 0)).reverse().find(inFeed)
    const to = next || panel
    if (!next && !to.hasAttribute('tabindex')) to.setAttribute('tabindex', '-1')
    to.focus({ preventScroll: true })
    if (!next) return
    const scroller = scrollerOf(next)
    if (scroller !== document.scrollingElement && scroller !== document.documentElement) scrollRowIntoPane(scroller, next)
  }
  function tick() {
    if (!panel.isConnected) return stop()
    if (document.querySelector(OVERLAY_OPEN)) {
      settled = Date.now()
      return
    }
    const a = document.activeElement
    const fine = a && a !== document.body && panel.contains(a) && !leaving(a)
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

/** The vim ring (vim-nav.css) on `el`, the one ring on screen, and the focus. */
function vimRing(el) {
  for (const old of document.querySelectorAll('[data-vim-selected]')) if (old !== el) old.removeAttribute('data-vim-selected')
  el.setAttribute('data-vim-selected', 'true')
  selectRow(el)
}

/**
 * Spec 103 T006: after Enter opened `from`'s topic, its first card in the
 * topic pane takes the focus once drawn.
 * @param {HTMLElement} from
 */
export function intoPane(from) {
  const want = from.getAttribute('data-task-id') || ''
  const t0 = Date.now()
  const tick = () => {
    /* the reader moved on (a click, another key): not ours any more */
    const a = document.activeElement
    if (a && a !== from && a !== document.body) return
    const pane = document.querySelector(TOPIC_PANE)
    const rows = pane ? [...pane.querySelectorAll('article.msg')].filter(shown) : []
    const late = Date.now() - t0 >= PANE_WAIT_MS
    /* a pane still on the topic it showed before is not this one's yet */
    const to = rows.find((el) => !want || el.getAttribute('data-task-id') === want) || (late ? rows[0] : undefined)
    if (to) return vimRing(to)
    if (!late) setTimeout(tick, HOLD_EVERY_MS)
  }
  setTimeout(tick, 0)
}
