/*
 * The doc view's deep-link landing (r16-08, out of WorkspaceDocView; spec 138
 * G1): the heading of the location's anchor at the top, under the sticky bar,
 * kept there while the layout above it grows; a contents link or a permalink
 * scrolls its heading in and carries its anchor in the URL.
 */
import type { Ref, ShallowRef } from 'vue'
import type { DocItem } from '~/components/workspace-docs/-doctree-api'
import { resolveAnchor } from '~/components/workspace-docs/-doc-anchor'

/* spec 138 G1: how long a deep link keeps its heading at the top while the layout above it grows */
const SETTLE_MS = 2000

/* spec 138 G1: a deep link's heading at the top, scrolled again on every
   resize of the document (pictures loading, textareas growing above it) for
   SETTLE_MS, or until the user scrolls, types or taps; no fixed sleep */
const USER_INPUT = ['wheel', 'touchstart', 'keydown', 'pointerdown'] as const

type LandingView = {
  rootEl: Ref<HTMLElement | null>
  barEl: Ref<HTMLElement | null>
  items: ShallowRef<DocItem[]>
  anchor: (id: string) => string
  say: (text: string, transient?: boolean) => void
  narrow: () => boolean
  tocOpen: Ref<boolean>
}

export function useDocLanding({ rootEl, barEl, items, anchor, say, narrow, tocOpen }: LandingView) {
  const { t } = useI18n({ useScope: 'global' })
  /* the running landing's stop, while it settles */
  let settling: (() => void) | null = null

  /** the element the document scrolls in: the nearest scrolling ancestor, else the page */
  function scroller(): HTMLElement {
    for (let el = rootEl.value?.parentElement; el; el = el.parentElement) {
      if (/(auto|scroll)/.test(getComputedStyle(el).overflowY) && el.scrollHeight > el.clientHeight) return el
    }
    return document.scrollingElement as HTMLElement ?? document.documentElement
  }

  /** the headings' scroll margin: where the sticky bar ends, measured (a phone's
      bar too), not a fixed 4rem: the bar sticks inside the scroller's top
      padding, so the margin is that padding plus the bar's height */
  function measureBar() {
    const h = barEl.value?.getBoundingClientRect().height
    if (!h) return
    const pad = parseFloat(getComputedStyle(scroller()).paddingTop) || 0
    rootEl.value?.style.setProperty('--wsdoc-bar-h', Math.ceil(h + pad) + 'px')
  }

  /** end a landing still settling (a new landing, a user's scroll, the view closing) */
  function settleStop() {
    settling?.()
  }

  function landOn(id: string) {
    settleStop()
    const el = document.getElementById(anchor(id))
    if (!el) return
    measureBar()
    el.scrollIntoView({ block: 'start' })
    const doc = rootEl.value?.querySelector('.wsdoc__doc')
    if (typeof ResizeObserver === 'undefined' || !doc) return
    const grows = new ResizeObserver(() => {
      measureBar()
      el.scrollIntoView({ block: 'start' })
    })
    const stop = () => {
      grows.disconnect()
      clearTimeout(timer)
      for (const e of USER_INPUT) window.removeEventListener(e, stop, true)
      settling = null
    }
    const timer = setTimeout(stop, SETTLE_MS)
    for (const e of USER_INPUT) window.addEventListener(e, stop, { capture: true, passive: true })
    grows.observe(doc)
    settling = stop
  }

  /** the location's anchor on open: its section (spec 138 form A or D), else the top and one status line */
  function openAnchor() {
    if (location.hash.length < 2) return
    const id = resolveAnchor(location.hash, items.value.map((it) => it.id))
    if (id) return landOn(id)
    scroller().scrollTo({ top: 0 })
    say(t('ws_doctree.anchor_unknown'), false)
  }

  /** a contents link or a permalink: scroll the heading in, the URL carries its anchor */
  function goTo(id: string) {
    const el = document.getElementById(anchor(id))
    if (!el) return
    settleStop()
    measureBar()
    el.scrollIntoView({ block: 'start' })
    history.replaceState(history.state, '', '#' + anchor(id))
    if (narrow()) tocOpen.value = false
  }

  return { settleStop, openAnchor, goTo }
}
