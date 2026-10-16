/*
 * ChannelSidebar's row keys (r13-04): the focus a click leaves on a channel
 * row, the arrows / j / k / Home / End that open the next channel, and Enter
 * into a channel's or a DM's messages.
 */
import type { Ref } from 'vue'
import { useSessionStore } from '~/stores/session'
import { scrollRowIntoPane } from '~/utils/pane-scroll.mjs'
import { listRowKey, stepRow } from '~/utils/row-keys.mjs'
import { focusPane } from '~/composables/useGlobalKeys'
import { MIDDLE } from '~/utils/pane-focus.mjs'

/* the feed reads its cards after the route: the old channel's cards are
   drawn again for a moment (new elements, old messages) and one of them
   taking the focus loses it when they go. So wait until the cards on screen
   have stayed the same for a little while, then focus the first; with none
   by then, the pane (its heading). Not when the reader moved on. */
const CARDS_WAIT_MS = 3000
const CARDS_SETTLED_MS = 300
const cardsNow = () => [...document.querySelectorAll<HTMLElement>('.spool-main article.msg')]
  .filter((el) => el.getClientRects().length > 0 && !el.closest('[class*="-leave-active"]'))
async function openIntoMessages(path: string, localePath: ReturnType<typeof useLocalePath>) {
  const from = document.activeElement
  await navigateTo(localePath(path))
  const t0 = Date.now()
  let seen: HTMLElement[] = []
  let since = Date.now()
  while (Date.now() - t0 < CARDS_WAIT_MS) {
    await new Promise((r) => setTimeout(r, 50))
    if (document.activeElement !== from) return
    const now = cardsNow()
    if (now.length !== seen.length || now.some((el, k) => el !== seen[k])) {
      seen = now
      since = Date.now()
    } else if (now.length && Date.now() - since >= CARDS_SETTLED_MS) {
      break
    }
  }
  if (document.activeElement !== from) return
  if (seen[0]?.isConnected) seen[0].focus({ preventScroll: true })
  else focusPane(MIDDLE)
}

export function useSidebarRowKeys(phone: Ref<boolean>) {
  const session = useSessionStore()
  const localePath = useLocalePath()
  /* HUM-10 (t1 7d9e1681): after a click on a channel the focus stays on its
     row (layouts/default.vue keeps it: routeTakesFocus channelList), and
     ArrowDown / ArrowUp (j / k with the keyboard shortcuts switch on) open the
     next / previous channel at once - the focus follows, like a list box -,
     Home / End the first / last. The ends do not wrap (the feed's rows do not).
     Enter on a channel goes into its messages. Desktop only. j / k
     read the switch the way utils/msg-shortcuts.mjs shortcutsOn does (never
     picked = on), without pulling the lazy message-shortcut code in here. */
  function keepRowFocus(e: MouseEvent) {
    /* Safari leaves the focus on <body> after a click on a link */
    if (!phone.value) (e.currentTarget as HTMLElement | null)?.focus({ preventScroll: true })
  }
  function onChannelRowKey(e: KeyboardEvent) {
    if (phone.value) return
    const what = listRowKey(e, { letters: session.claims?.keyboard_shortcuts !== false })
    if (!what) return
    const row = e.currentTarget as HTMLElement
    if (what === 'enter') {
      /* spec 103 T006: Enter on another channel's row (the lobby row on /lobby)
         opens it and goes into its messages too; with the keyboard shortcuts
         off it is the link's own Enter */
      if (!row.classList.contains('active')) {
        if (session.claims?.keyboard_shortcuts === false) return
        e.preventDefault()
        void openIntoMessages('/channel/' + row.dataset.key, localePath)
        return
      }
      e.preventDefault()
      focusPane(MIDDLE)
      return
    }
    e.preventDefault()
    const rows = Array.from(document.querySelectorAll<HTMLElement>('#sidebar-panel-channels a.nav-item[data-key]'))
      .filter((el) => el.getClientRects().length > 0)
    const to = what === 'first' ? rows[0] : what === 'last' ? rows[rows.length - 1] : stepRow(rows, row, what === 'next' ? 1 : -1)
    if (!to || to === row) return
    to.focus({ preventScroll: true })
    const scroller = to.closest<HTMLElement>('.sidebar-scroll')
    if (scroller) scrollRowIntoPane(scroller, to)
    void navigateTo(localePath('/channel/' + to.dataset.key))
  }
  /* spec 103 T006: Enter on the open DM goes into its messages, Panel 2, as
     on the open channel (another DM's row opens it: the route then moves the
     focus to its messages, layouts/default.vue) */
  function onDmRowKey(e: KeyboardEvent) {
    if (phone.value || e.key !== 'Enter' || e.shiftKey || e.ctrlKey || e.metaKey || e.altKey) return
    if (session.claims?.keyboard_shortcuts === false) return
    if (!(e.currentTarget as HTMLElement).classList.contains('active')) return
    e.preventDefault()
    focusPane(MIDDLE)
  }
  return { keepRowFocus, onChannelRowKey, onDmRowKey }
}
