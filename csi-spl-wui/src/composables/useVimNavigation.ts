// Spec 103 T005 (t1 7d9e1681): the ONE global vim key listener. The layout
// (layouts/default.vue) imports this file on window idle, so it, the vim
// store and the ring css ride in a lazy chunk and the initial one does not
// grow (160 KB ceiling).
//
// vim-nav.mjs says what a key means, vim-panels.mjs where the panels and
// their rows are, stores/vim-nav.ts where we stand. This file only acts:
//   h / l / Esc    move the focus to the nearest shown panel that way
//   j / k / gg / G step the rows of the panel the focus is in
//
// Who goes first:
//   - a text field, the Omnibox and the composer get their keys literally
//     (vimNavMatch: inTypingOrOverlay);
//   - an open overlay (a menu, UiDialog, the command palette) suspends the
//     layer, and a dialog with its own vim keys (ReleaseNotesDialog) keeps them;
//   - a key a row or a page already took (defaultPrevented) is left alone;
//   - j / k / arrows on a message card stay useMsgShortcuts' (its step is the
//     feed's walk, spec 103 section 5), as do keys pressed with the focus
//     nowhere (<body>), where it steps the selected card;
//   - Enter is the row's own (links, ChannelSidebar, cards) until the view
//     adapters (T006+) give it a meaning.
// The Keyboard shortcuts setting off, or a phone width: nothing.
import '~/assets/css/vim-nav.css'
import { VIM_SEQ_IDLE, vimNavMatch, vimNavOn } from '~/utils/vim-nav.mjs'
import { activePanelOf, panelEntry, panelItems, panelRoot, resolveNextPanel, visiblePanels, vimStepItem } from '~/utils/vim-panels.mjs'
import { scrollRowIntoPane } from '~/utils/pane-scroll.mjs'
import { scrollerOf } from '~/utils/scroll-anchor.mjs'
import { useVimNav } from '~/stores/vim-nav'
import type { Router } from 'vue-router'

/** Open overlays: the global layer is suspended under any of them. */
export const VIM_OVERLAY_OPEN = '.point-menu, .kind-picker, [role="dialog"][aria-modal="true"], dialog[open], [data-testid="command-palette"]'

/** Set on <html> while the listener is installed (the e2e proof that it mounted). */
export const VIM_MOUNTED_ATTR = 'data-vim-nav'

type VimOpts = {
  /** the session's `keyboard_shortcuts` claim, read on every key */
  claim: () => unknown
  /** a phone width (useMobileStack().isMobile) */
  phone: () => boolean
  /** a route change forgets the per-panel rows (spec 4.1) */
  router?: Router
}

const SELECTED = 'data-vim-selected'

let uninstall: (() => void) | null = null

function mark(el: HTMLElement | null) {
  for (const old of document.querySelectorAll<HTMLElement>(`[${SELECTED}]`)) if (old !== el) old.removeAttribute(SELECTED)
  el?.setAttribute(SELECTED, 'true')
}

function land(el: HTMLElement) {
  if (!el.hasAttribute('tabindex') && !el.matches('a[href], button, input, select, textarea')) el.setAttribute('tabindex', '-1')
  el.focus({ preventScroll: true })
  mark(el)
  const scroller = scrollerOf(el)
  if (scroller !== document.scrollingElement && scroller !== document.documentElement) scrollRowIntoPane(scroller as HTMLElement, el)
}

/** The row holding `active` (or being it), else null (the panel root, a heading). */
function rowOf(items: unknown[], active: Element | null): HTMLElement | null {
  const hit = items.find((el) => el === active || (el as HTMLElement).contains?.(active))
  return (hit as HTMLElement) || null
}

/** h / l / Esc: into the nearest shown panel that way. True when the focus moved. */
function movePanel(from: number, dir: 'left' | 'right' | 'back'): boolean {
  const store = useVimNav()
  const shown = visiblePanels(document)
  /* from nowhere, l enters the panel we were last in, else the leftmost */
  const start = from >= 0 ? from : dir === 'right' && shown.includes(store.activePanel) ? store.activePanel - 1 : -1
  const to = resolveNextPanel(start, dir, shown)
  if (to === from || to < 0) return false
  const root = panelRoot(document, to) as HTMLElement | null
  if (!root) return false
  if (from >= 0) {
    const fromRoot = panelRoot(document, from)
    const row = fromRoot ? rowOf(panelItems(fromRoot, from), document.activeElement) : null
    if (row) store.select(from, row)
  }
  const items = panelItems(root, to)
  const entry = (panelEntry(items, { remembered: store.remembered(to) }) as HTMLElement | null) || root
  store.setPanel(to)
  land(entry)
  return true
}

/** j / k / gg / G inside the panel the focus is in. True when a row took the focus. */
function stepRow(panel: number, action: 'down' | 'up' | 'first' | 'last'): boolean {
  const root = panelRoot(document, panel)
  if (!root) return false
  const items = panelItems(root, panel)
  const current = rowOf(items, document.activeElement)
  const next = vimStepItem(items, current, action) as HTMLElement | null
  if (!next || next === current) return false
  const store = useVimNav()
  store.setPanel(panel)
  store.select(panel, next)
  panelItems(root, panel, { current: next })
  land(next)
  return true
}

/** Install the listener once; returns its uninstall. A second call returns the first one's. */
export function installVimNavigation(opts: VimOpts): () => void {
  if (uninstall) return uninstall
  let seq: { g: number | null } = VIM_SEQ_IDLE
  const onKey = (ev: KeyboardEvent) => {
    const enabled = vimNavOn({ claim: opts.claim(), phone: opts.phone() })
    const overlayOpen = Boolean(document.querySelector(VIM_OVERLAY_OPEN))
    const hit = vimNavMatch(ev, seq, { enabled, overlayOpen })
    seq = hit.seq
    const action = hit.action
    if (!action || action === 'open') return
    const active = document.activeElement as HTMLElement | null
    const nowhere = !active || active === document.body || active === document.documentElement
    const panel = nowhere ? -1 : activePanelOf(active)
    let done = false
    if (action === 'left' || action === 'right' || action === 'back') {
      /* Esc with the focus nowhere is the page's */
      if (action === 'back' && panel < 0) return
      done = movePanel(panel, action)
    } else {
      /* useMsgShortcuts walks the feeds: a card, or the selected card from <body> */
      if (panel < 0 || active?.closest('article.msg')) return
      done = stepRow(panel, action)
    }
    if (done) ev.preventDefault()
  }
  /* a click or Tab elsewhere: the vim ring goes, so only one ring shows */
  const onFocus = (ev: FocusEvent) => {
    const t = ev.target as Element | null
    if (t && !t.hasAttribute?.(SELECTED)) mark(null)
  }
  const offRoute = opts.router?.afterEach((to, from) => {
    if (to.path !== from.path) useVimNav().resetRoute()
  })
  window.addEventListener('keydown', onKey)
  document.addEventListener('focusin', onFocus)
  document.documentElement.setAttribute(VIM_MOUNTED_ATTR, 'on')
  uninstall = () => {
    window.removeEventListener('keydown', onKey)
    document.removeEventListener('focusin', onFocus)
    offRoute?.()
    mark(null)
    document.documentElement.removeAttribute(VIM_MOUNTED_ATTR)
    uninstall = null
  }
  return uninstall
}
