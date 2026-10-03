import { computed, getCurrentScope, onScopeDispose, ref, shallowRef, toValue, watch, type MaybeRefOrGetter, type Ref } from 'vue'
import { isNavigationFailure, NavigationFailureType } from 'vue-router'
import {
  MOBILE_STACK_QUERY,
  isMobileBackSwipe,
  mobileHasBelow,
  mobileHistoryStep,
  mobileInPlaceStep,
  mobileInitialLevel,
  mobileLevelOf,
  mobileOverlayOf,
  mobileOverlayPop,
  mobileOverlayState,
  mobileStaleTopicUrl,
  mobileTagState,
  mobileTaggedLevel,
  type MobileLevel,
} from '~/utils/mobile-stack.mjs'

/**
 * SPL-989 (epic SPL-988) — the phone / small-tablet navigation stack. THE one
 * place that decides which panel is on screen at <= 820 px; no other file
 * writes its own stack or history logic (lanes M2..M5 build on this).
 *
 * The owner's model, fixed: at <= 820 px exactly ONE of the desktop's three
 * panels shows, full screen.
 *   level 1 — the LEFT panel: the section chooser (Channels, DMs, Issues,
 *             Topics, Flow, Event log, ...) and the chosen section's list.
 *             The app opens here (`/`).
 *   level 2 — the MIDDLE panel: whatever page the route shows (a channel /
 *             DM / lobby feed, /issues, /events, /settings ...).
 *   level 3 — the RIGHT panel: the open topic / thread (either topic store).
 * A tap pushes one level; Back pops one — the chevron (`pop()`), a swipe
 * right (`swipe` handlers) and browser Back all do the same, because every
 * push leaves a history entry tagged with its level (history.state.splLevel)
 * and a popstate restores the level its entry says. Deep links open where
 * they point (`/channel/x` at 2, `?topic=` at 3) and Back still walks 3 -> 2
 * -> 1 inside the app. 600..820 px tablets get the same ONE panel (decision:
 * a 600 px topic beside a 220 px feed reads worse than two full screens).
 * Above 820 px nothing here does anything: `isMobile` is false, `level` is
 * still computed but no CSS reads it, and no history entry is written.
 *
 * Usage (any component):
 *   const stack = useMobileStack()
 *   stack.isMobile.value        // true at <= 820 px
 *   stack.level.value           // 1 | 2 | 3, the panel on screen
 *   stack.push(2)               // show the middle panel without a route change
 *                               // (a tap on the row for the page already behind)
 *   stack.pop()                 // Back one level (the chevron's click handler)
 *   stack.home()                // straight to level 1 (a "sections" button)
 *   stack.rightPanel(() => detailOpen.value, closeDetail)
 *                               // a page's own right panel (not a topic store)
 *                               // counts as level 3; Back calls closeDetail
 *   stack.overlay(() => sheetOpen.value, closeSheet)
 *                               // SPL-994: a dialog / bottom sheet is the TOP
 *                               // level while open; Back calls closeSheet and
 *                               // the level under it stays where it was
 * A route navigation (NuxtLink, router.push) needs NO call: leaving level 1 by
 * a link is noticed in router.afterEach. Opening a topic needs no call either:
 * level 3 follows the topic stores. Only layouts/default.vue calls install().
 * CSS: the layout sets `data-mobile-level` on `.spool-shell`; hide/show panels
 * under `@media (max-width: 820px)` with `[data-mobile-level="N"]` selectors
 * (tokens in assets/css/base.css: --mobile-max, --tap).
 */

const isMobile = ref(false)
const home = ref(true)
const topicOpen = ref(false)
/* pages with a right panel that is not a topic store (the issue detail, ...) */
type RightPanel = { open: MaybeRefOrGetter<boolean>, close: () => void }
const panels = shallowRef<RightPanel[]>([])
const rightOpen = computed(() => topicOpen.value || panels.value.some((p) => toValue(p.open)))
const level = computed<MobileLevel>(() => mobileLevelOf({ home: home.value, topicOpen: rightOpen.value }))
let closeTopic: () => void = () => {}
let installed = false
/* CLE-77882: an open-in-place is navigating (utils/mobile-stack.mjs mobileInPlaceStep) */
let inPlaceUntil = 0

function tag(lv: MobileLevel, below?: number) {
  window.history.replaceState(mobileTagState(window.history.state, lv, below), '')
}

/**
 * The level went UP on the same entry: add one, so Back comes down again.
 * c78fb3ec: the entry left below must not keep the topic's URL (a link to
 * ?topic= wrote it there before the topic opened), or Back onto it opens the
 * topic again - stuck on level 3. It keeps its page; the new entry takes the
 * topic URL.
 */
function pushLevel(next: MobileLevel, tagged: MobileLevel | null) {
  const href = window.location.href
  const under = mobileStaleTopicUrl(href, tagged)
  if (under) window.history.replaceState(window.history.state, '', under)
  window.history.pushState(mobileTagState(mobileOverlayState(window.history.state, null), next, tagged ?? 1), '', under ? href : undefined)
}

/** Show `lv` without touching history (a popstate already moved it). */
function applyLevel(lv: MobileLevel) {
  if (lv < 3 && topicOpen.value) closeTopic()
  if (lv < 3) for (const p of panels.value) if (toValue(p.open)) p.close()
  home.value = lv === 1
}

/**
 * A page whose own right panel is level 3 (the issue detail): while `open`
 * is true the stack is at 3, and Back (chevron, swipe, browser) calls
 * `close`. Unregisters itself when the calling component's scope ends.
 */
function rightPanel(open: MaybeRefOrGetter<boolean>, close: () => void) {
  const entry: RightPanel = { open, close }
  panels.value = [...panels.value, entry]
  const off = () => { panels.value = panels.value.filter((p) => p !== entry) }
  if (getCurrentScope()) onScopeDispose(off)
  return off
}

/*
 * SPL-994 — overlays. A dialog or a bottom sheet is the TOP level while it is
 * open: opening it pushes a history entry (a copy of the one under it, tagged
 * with the overlay's id), and Back - browser, Android gesture, the chevron,
 * the swipe - comes down onto the entry under it. A popstate listener in the
 * CAPTURE phase sees that first (at the target, capture listeners run before
 * vue-router's and the level's own), closes the overlay and stops the event:
 * the route and the level never move. Closing by the overlay's own X, backdrop
 * or Escape steps back over its entry the same way, so history never drifts.
 * The router may have replaced the overlay's entry meanwhile (a filter sheet
 * writing its query): the entry under it is rewritten with that URL and state,
 * so the router's idea of "current" and the address bar agree.
 * A router.push while an overlay has an entry first steps back over the
 * overlay entries (closing them), then pushes: the new page lands on top of
 * the page, not on top of a sheet. Every history move runs through one queue,
 * because history.back() is asynchronous and a pushState issued before it
 * lands would be the entry it removes.
 */
type Overlay = { id: number, open: () => boolean, close: () => void, state: Record<string, unknown> | null, url: string }
const overlays: Overlay[] = []
let overlaySeq = 0
/* SPL-1005: the open-state of every overlay that the bottom composer dock
   must yield to - a page sheet (the Issues filters, a dialog, a menu) is
   modal over it. The dock's own pickers (the @ list) opt out. Reactive, so
   `sheetOpen` follows each overlay's own `open`. */
const dockSheets = shallowRef<Array<() => boolean>>([])
const sheetOpen = computed(() => dockSheets.value.some((g) => g()))
let queue: Promise<void> = Promise.resolve()
let queued = 0
let popWaiter: (() => void) | null = null
let skipPops = 0
let lastPos: number | null = null

function enqueue(op: () => void | Promise<void>): Promise<void> {
  queued++
  queue = queue.then(op).catch(() => {}).finally(() => { queued-- })
  return queue
}

function statePosition(): number | null {
  const s = window.history.state as { position?: unknown } | null
  return s && typeof s.position === 'number' ? s.position : null
}

/** history.go(-n), resolved when its popstate has been handled (or after a timeout). */
function stepBack(n: number): Promise<void> {
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer)
      if (popWaiter === done) popWaiter = null
      resolve()
    }
    const timer = setTimeout(done, 1000)
    popWaiter = done
    window.history.go(-n)
  })
}

function wake() {
  popWaiter?.()
}

/** the top overlay's entry changed under us (the router replaced it, a level tag) */
function snapTop() {
  const top = overlays[overlays.length - 1]
  if (top && mobileOverlayOf(window.history.state) === top.id) {
    top.state = window.history.state as Record<string, unknown>
    top.url = window.location.href
  }
}

function onPopCapture(e: PopStateEvent) {
  if (skipPops > 0) {
    skipPops--
    e.stopImmediatePropagation()
    wake()
    return
  }
  const step = mobileOverlayPop(overlays.map((o) => o.id), e.state, lastPos)
  /* c78fb3ec: the router is about to read this entry's URL. One tagged below
     3 that still names a topic (an older build wrote them) would open it
     again - level 3, a new push, the same entry on the next Back, stuck until
     the app restarts: drop the topic from it first */
  if (step.kind !== 'close' && !(step.kind === 'dead' && !step.back)) dropStaleTopic(e.state)
  if (step.kind === 'none') return
  if (step.kind === 'dead') {
    if (step.back) {
      /* the router follows onto it; then one more step down */
      setTimeout(() => window.history.back(), 0)
      return
    }
    e.stopImmediatePropagation()
    skipPops++
    window.history.back()
    return
  }
  if (step.kind === 'leave') {
    const gone = overlays.splice(0)
    for (const o of gone.reverse()) if (o.open()) o.close()
    wake()
    return
  }
  e.stopImmediatePropagation()
  const top = overlays[overlays.length - 1]
  const gone = overlays.splice(step.keep)
  const under = overlays[step.keep - 1]
  const state = mobileOverlayState(top.state, under ? under.id : null)
  window.history.replaceState(state, '', top.url)
  if (under) {
    under.state = state
    under.url = top.url
  }
  for (const o of gone.reverse()) if (o.open()) o.close()
  wake()
  /* an overlay under it that closed while this one was open: step over its entry too */
  if (under && !under.open()) void enqueue(() => (overlays[overlays.length - 1] === under ? stepBack(1) : undefined))
}

function dropStaleTopic(state: unknown) {
  if (!isMobile.value) return
  const url = mobileStaleTopicUrl(window.location.href, mobileTaggedLevel(state))
  if (url) window.history.replaceState(state, '', url)
}

function overlayOpened(o: Overlay) {
  void enqueue(() => {
    if (!installed || !isMobile.value || !o.open() || overlays.includes(o)) return
    const state = mobileOverlayState(window.history.state, o.id)
    window.history.pushState(state, '')
    o.state = state
    o.url = window.location.href
    overlays.push(o)
  })
}

function overlayClosed(o: Overlay) {
  void enqueue(async () => {
    const i = overlays.indexOf(o)
    if (i < 0) return
    /* one under another open overlay: its entry goes when the one above goes */
    if (i < overlays.length - 1) return
    if (mobileOverlayOf(window.history.state) === o.id) await stepBack(1)
    else overlays.splice(i, 1)
  })
}

/**
 * A dialog or bottom sheet: while `open` is true (and the viewport is a
 * phone's) it is the top level, and Back calls `close` instead of popping the
 * panel under it. Closing it any other way steps back over its history entry.
 * Unregisters itself when the calling component's scope ends.
 */
function overlay(open: MaybeRefOrGetter<boolean>, close: () => void, opts: { keepsDock?: boolean, history?: boolean } = {}) {
  if (!import.meta.client) return () => {}
  /* CLE-77853: `history: false` - the overlay's open state is a route of its
     own (Settings' ?settings=), so the router already gave it an entry and
     Back is the router's; it still covers the dock */
  const o: Overlay = { id: ++overlaySeq, open: opts.history === false ? () => false : () => toValue(open), close, state: null, url: '' }
  const stop = watch(o.open, (v) => { if (v) overlayOpened(o); else overlayClosed(o) }, { immediate: true, flush: 'sync' })
  const covers = () => toValue(open)
  if (!opts.keepsDock) dockSheets.value = [...dockSheets.value, covers]
  const off = () => {
    stop()
    o.open = () => false
    dockSheets.value = dockSheets.value.filter((g) => g !== covers)
    overlayClosed(o)
  }
  if (getCurrentScope()) onScopeDispose(off)
  return off
}

/**
 * CLE-77882: the next topic that opens (within `ms`) lands on the entry the
 * open-in-place route push made, instead of pushing one more: Back from the
 * opened message returns to the list it was opened from.
 */
function landInPlace(ms = 5000) {
  if (!isMobile.value) return
  inPlaceUntil = Date.now() + ms
}

function push(lv: 2 | 3) {
  if (lv >= 2) home.value = false
}

function pop() {
  if (!isMobile.value) return
  /* SPL-994: the top overlay first */
  if (overlays.length) return void enqueue(() => (overlays.length ? stepBack(1) : undefined))
  if (level.value === 1) return
  if (mobileHasBelow(window.history.state)) return void window.history.back()
  /* a deep link: nothing of ours below, so step down in place */
  applyLevel((level.value - 1) as MobileLevel)
}

function toHome() {
  if (!isMobile.value) return
  applyLevel(1)
}

/* swipe right = Back */
let touch: { x: number, y: number } | null = null
function onTouchStart(e: TouchEvent) {
  const p = e.touches[0]
  touch = isMobile.value && level.value > 1 && e.touches.length === 1 && p ? { x: p.clientX, y: p.clientY } : null
}
/* CLE-77906: a card's swipe-to-archive took this gesture - it is not a Back */
function claimSwipe() {
  touch = null
}
function onTouchEnd(e: TouchEvent) {
  const p = e.changedTouches[0]
  const start = touch
  touch = null
  if (!start || !p) return
  const rtl = document.documentElement.dir === 'rtl'
  if (isMobileBackSwipe({ x0: start.x, y0: start.y, x1: p.clientX, y1: p.clientY, width: window.innerWidth, rtl })) pop()
}

/** layouts/default.vue only: wire the stack to the topic stores, the router and the window. */
function install(opts: { topicOpen: Ref<boolean>, closeTopic: () => void }) {
  closeTopic = opts.closeTopic
  watch(opts.topicOpen, (v) => { topicOpen.value = v }, { immediate: true, flush: 'sync' })
  if (!import.meta.client || installed) return
  installed = true
  const router = useRouter()
  const route = useRoute()

  const mq = window.matchMedia(MOBILE_STACK_QUERY)
  isMobile.value = mq.matches
  mq.addEventListener('change', (e) => { isMobile.value = e.matches })

  /* the entry the app was loaded on */
  /* SPL-994: before vue-router's popstate listener (capture runs first at the target) */
  window.addEventListener('popstate', onPopCapture, { capture: true })
  /* the overlay's entry can be rewritten by anyone (vue-router, a page writing
     ?sort= with replaceState): keep its URL + state, which Back restores */
  const replaceState = window.history.replaceState.bind(window.history)
  window.history.replaceState = (data: unknown, unused: string, url?: string | URL | null) => {
    replaceState(data, unused, url)
    snapTop()
  }
  lastPos = statePosition()
  const routerPush = router.push.bind(router)
  router.push = ((to) => {
    if (!overlays.length && !queued) return routerPush(to)
    return enqueue(() => (overlays.length ? stepBack(overlays.length) : undefined)).then(() => routerPush(to))
  }) as typeof router.push

  const first = mobileTaggedLevel(window.history.state) ?? mobileInitialLevel(route.path, route.query as Record<string, unknown>)
  home.value = first === 1
  tag(first)

  /* a route navigation: a fresh entry is a push from the level we were on */
  router.afterEach((_to, _from, failure) => {
    lastPos = statePosition()
    if (failure) {
      /* a tap on the link to the page already behind level 1 */
      if (isNavigationFailure(failure, NavigationFailureType.duplicated) && isMobile.value) push(2)
      return
    }
    /* an entry we tagged already: a replace (?topic= written) or a popstate,
       which the popstate listener has applied. Re-applying here would race a
       topic that opened before its entry was pushed, and close it. */
    if (mobileTaggedLevel(window.history.state) !== null) return
    const below = level.value
    home.value = false
    tag(level.value, below)
  })

  /* browser Back / Forward, and pop() -> history.back() */
  window.addEventListener('popstate', (e) => {
    lastPos = statePosition()
    inPlaceUntil = 0
    const tagged = mobileTaggedLevel(e.state)
    if (tagged !== null) applyLevel(tagged)
  })

  /* the level moved without a popstate: record it so Back comes down again */
  watch(level, (next) => {
    if (!isMobile.value) return
    const record = () => {
      const tagged = mobileTaggedLevel(window.history.state)
      const inPlace = inPlaceUntil > Date.now()
      const step = mobileInPlaceStep(mobileHistoryStep(tagged, next), next, inPlace)
      if (inPlace && next === 3) inPlaceUntil = 0
      if (step === 'tag') tag(next)
      else if (step === 'push') pushLevel(next, tagged)
    }
    /* SPL-994: a level pushed from inside an overlay (a menu opening a
       thread) lands after the overlay's entry is gone, not on top of it */
    if (!overlays.length && !queued) return record()
    void enqueue(async () => {
      if (overlays.length) await stepBack(overlays.length)
      if (level.value === next) record()
    })
  }, { flush: 'post' })
}

export function useMobileStack() {
  return {
    /** true at <= 820 px (MOBILE_STACK_QUERY) */
    isMobile,
    /** the panel on screen: 1 left, 2 middle, 3 right */
    level,
    push,
    pop,
    home: toHome,
    rightPanel,
    overlay,
    /** CLE-77882: the next topic open lands on the current entry (open in place) */
    landInPlace,
    /** SPL-1005: a page sheet / dialog / menu is open - the composer dock yields */
    sheetOpen,
    /** bind on the shell: @touchstart.passive / @touchend.passive */
    swipe: { onTouchStart, onTouchEnd, claim: claimSwipe },
    install,
  }
}
