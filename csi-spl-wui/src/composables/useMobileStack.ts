import { computed, getCurrentScope, onScopeDispose, ref, shallowRef, toValue, watch, type MaybeRefOrGetter, type Ref, type ShallowRef } from 'vue'
import { isNavigationFailure, NavigationFailureType } from 'vue-router'
import {
  MOBILE_STACK_QUERY,
  isMobileBackSwipe,
  isStaleLoginStep,
  mobileAfterNavStep,
  mobileBackStep,
  mobileHasBelow,
  mobileInitialLevel,
  mobileLevelOf,
  mobileLoginFrontDoor,
  mobileOverlayCloseStep,
  mobileOverlayOf,
  mobileOverlayPop,
  mobileOverlayState,
  mobilePopDropsTopic,
  mobilePushPlan,
  mobileRecordStep,
  mobileStaleLoginLoad,
  mobileStaleTopicUrl,
  mobileStatePosition,
  mobileSwipeStart,
  mobileTagState,
  mobileTaggedLevel,
  type MobileLevel,
} from '~/utils/mobile-stack.mjs'
import { useSessionStore } from '~/stores/session'

/**
 * SPL-989 (epic SPL-988) — the phone / small-tablet navigation stack: THE one
 * place that decides which panel is on screen at <= 820 px; no other file
 * writes its own stack or history logic. The owner's model (levels 1 left,
 * 2 middle, 3 right) and every pure decision of it live in
 * utils/mobile-stack.mjs; this file applies them to the DOM, history and the
 * router. Back (the chevron `pop()`, a swipe, browser Back) pops one level:
 * every push leaves an entry tagged with its level (history.state.splLevel)
 * and a popstate restores the level its entry says.
 *
 * Usage (any component; each call's own doc says more):
 *   const stack = useMobileStack()
 *   stack.isMobile.value / stack.level.value   // <= 820 px? / 1 | 2 | 3 on screen
 *   stack.push(2)       // the middle panel without a route change (a tap on the
 *                       // row for the page already behind)
 *   stack.pop()         // Back one level (the chevron's click handler)
 *   stack.home()        // straight to level 1 (a "sections" button)
 *   stack.rightPanel(() => detailOpen.value, closeDetail)   // a page's own level 3
 *   stack.overlay(() => sheetOpen.value, closeSheet)        // SPL-994: the TOP level
 *   stack.up(() => stepUp())   // t1 3b8891e0: a page level above its deep link
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
/* SPL-2785: one more each Back on a phone (pop() in place, or any popstate):
   components/MobileBackWait.vue shows its dots while the screen it returns to loads */
const backs = ref(0)
/* CLE-77882: an open-in-place is navigating (utils/mobile-stack.mjs mobileInPlaceStep) */
let inPlaceUntil = 0

function tag(lv: MobileLevel, below?: number) {
  window.history.replaceState(mobileTagState(window.history.state, lv, below), '')
}

/** The level went UP on the same entry: add one (utils mobilePushPlan, c78fb3ec). */
function pushLevel(next: MobileLevel, tagged: MobileLevel | null) {
  const plan = mobilePushPlan(window.location.href, window.history.state, next, tagged)
  if (plan.under) window.history.replaceState(window.history.state, '', plan.under)
  window.history.pushState(plan.state, '', plan.url)
}

/** Show `lv` without touching history (a popstate already moved it). */
function applyLevel(lv: MobileLevel) {
  if (lv < 3 && topicOpen.value) closeTopic()
  if (lv < 3) for (const p of panels.value) if (toValue(p.open)) p.close()
  home.value = lv === 1
}

/** Add `item` to `list`; the returned off removes it, also when the calling scope ends (`scoped`). */
function enlist<T>(list: ShallowRef<T[]>, item: T, scoped = true) {
  list.value = [...list.value, item]
  const off = () => { list.value = list.value.filter((x) => x !== item) }
  if (scoped && getCurrentScope()) onScopeDispose(off)
  return off
}

/** A page's own right panel (the issue detail): level 3 while `open`; Back calls `close`. */
const rightPanel = (open: MaybeRefOrGetter<boolean>, close: () => void) => enlist<RightPanel>(panels, { open, close })

/*
 * SPL-994 — overlays (the entry model: utils/mobile-stack.mjs). A CAPTURE-phase
 * popstate listener runs before vue-router's, closes the overlay and stops the
 * event: route and level never move. An overlay entry the router replaced (a
 * filter sheet writing its query) is copied onto the entry under it, so the
 * router's "current" and the address bar agree. Every history move runs through
 * one queue: history.back() is async, and a pushState issued before it lands
 * would be the entry it removes.
 */
type Overlay = { id: number, open: () => boolean, close: () => void, state: Record<string, unknown> | null, url: string }
const overlays: Overlay[] = []
let overlaySeq = 0
/* SPL-1005: the open-state of every overlay the composer dock yields to (a page
   sheet, a dialog, a menu is modal over it); the dock's own pickers opt out */
const dockSheets = shallowRef<Array<() => boolean>>([])
const sheetOpen = computed(() => dockSheets.value.some((g) => g()))
let queue: Promise<void> = Promise.resolve()
let queued = 0
let popWaiter: (() => void) | null = null
let skipPops = 0
let lastPos: number | null = null

function enqueue(op: () => void | Promise<void>): Promise<void> {
  queued++
  /* one failed history op must not reject the shared chain, or every later move would be skipped;
     the failed op leaves the overlays as they were, and stepBack never rejects (it times out) */
  queue = queue.then(op).catch(() => {}).finally(() => { queued-- })
  return queue
}

const statePosition = () => mobileStatePosition(window.history.state)

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

const wake = () => popWaiter?.()
/* no overlay entry and no history move queued: a move can run at once */
const historyIdle = () => !overlays.length && !queued

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
  if (mobilePopDropsTopic(step)) dropStaleTopic(e.state)
  if (step.kind === 'none') return
  /* a dead entry we came down onto: the router follows onto it, then one more step down */
  if (step.kind === 'dead' && step.back) return void setTimeout(() => window.history.back(), 0)
  if (step.kind === 'dead') {
    e.stopImmediatePropagation()
    skipPops++
    return void window.history.back()
  }
  const top = overlays[overlays.length - 1]
  const keep = step.kind === 'leave' ? 0 : step.keep
  const gone = overlays.splice(keep).reverse()
  const under = overlays[keep - 1]
  if (step.kind === 'close') {
    e.stopImmediatePropagation()
    const state = mobileOverlayState(top.state, under ? under.id : null)
    window.history.replaceState(state, '', top.url)
    if (under) Object.assign(under, { state, url: top.url })
  }
  for (const o of gone) if (o.open()) o.close()
  wake()
  if (step.kind === 'leave') return
  /* an overlay under it that closed while this one was open: step over its entry too */
  if (under && !under.open()) void enqueue(() => (overlays[overlays.length - 1] === under ? stepBack(1) : undefined))
}

/** c78fb3ec (utils mobilePopDropsTopic): the popped entry forgets its stale topic. */
function dropStaleTopic(state: unknown) {
  const url = isMobile.value && mobileStaleTopicUrl(window.location.href, mobileTaggedLevel(state))
  if (url) window.history.replaceState(state, '', url)
}

/*
 * 087 T003 (FR-001, utils isStaleLoginStep): a stale /login is left from a popstate
 * (capture, before vue-router renders it), a bfcache restore (pageshow hides it
 * first) or a back_forward load (mobileStaleLoginLoad, after the session probe).
 * Armed by plugins/mobile-stale-login.client.ts on every document; phones only.
 */
let staleArmed = false
let staleLeft = false
let staleTimer: ReturnType<typeof setTimeout> | undefined

const onPhone = () => window.matchMedia(MOBILE_STACK_QUERY).matches

/** Replace the stale entry with the front door and step back past it. */
function leaveStaleLogin(state: unknown, hide: boolean) {
  const door = mobileLoginFrontDoor(window.location.pathname)
  if (hide) document.documentElement.style.visibility = 'hidden'
  staleLeft = hide
  window.history.replaceState(state, '', door)
  window.history.back()
  /* nothing under it (the tab's first entry): the front door here, then */
  clearTimeout(staleTimer)
  staleTimer = setTimeout(() => window.location.replace(door), 800)
}

function guardStaleLogin() {
  if (!import.meta.client || staleArmed) return
  staleArmed = true
  const session = useSessionStore()
  const stale = () => onPhone() && isStaleLoginStep(window.location.pathname, session.state)
  window.addEventListener('popstate', (e) => {
    /* the step back landed in this document: no fallback */
    clearTimeout(staleTimer)
    if (stale()) { e.stopImmediatePropagation(); leaveStaleLogin(e.state, false) }
  }, { capture: true })
  window.addEventListener('pagehide', () => clearTimeout(staleTimer))
  window.addEventListener('pageshow', (e) => {
    if (!e.persisted) return
    /* the document we stepped off, restored at the front door's URL: load it */
    if (staleLeft) return void window.location.reload()
    if (stale()) leaveStaleLogin(window.history.state, true)
  })
  const nav = performance.getEntriesByType?.('navigation')[0] as PerformanceNavigationTiming | undefined
  if (!mobileStaleLoginLoad(nav?.type, onPhone(), window.location.pathname)) return
  const stop = watch(() => session.state, (s) => {
    if (s === 'loading') return
    stop()
    if (stale()) leaveStaleLogin(window.history.state, true)
  }, { immediate: true })
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
    const step = mobileOverlayCloseStep(overlays.map((x) => x.id), o.id, mobileOverlayOf(window.history.state))
    if (step === 'back') await stepBack(1)
    else if (step === 'drop') overlays.splice(overlays.indexOf(o), 1)
  })
}

/** A dialog or bottom sheet: the top level while `open` (on a phone); Back calls `close`. */
function overlay(open: MaybeRefOrGetter<boolean>, close: () => void, opts: { keepsDock?: boolean, history?: boolean } = {}) {
  if (!import.meta.client) return () => {}
  /* CLE-77853: `history: false` - its open state is a route of its own (Settings'
     ?settings=), so Back is the router's; it still covers the dock */
  const o: Overlay = { id: ++overlaySeq, open: opts.history === false ? () => false : () => toValue(open), close, state: null, url: '' }
  const stop = watch(o.open, (v) => { if (v) overlayOpened(o); else overlayClosed(o) }, { immediate: true, flush: 'sync' })
  const undock = opts.keepsDock ? () => {} : enlist(dockSheets, () => toValue(open), false)
  const off = () => { stop(); o.open = () => false; undock(); overlayClosed(o) }
  if (getCurrentScope()) onScopeDispose(off)
  return off
}

/** CLE-77882: the next topic open (within `ms`) lands on the current entry: Back returns to the list. */
const landInPlace = (ms = 5000) => { if (isMobile.value) inPlaceUntil = Date.now() + ms }

const push = (lv: 2 | 3) => { if (lv >= 2) home.value = false }

function pop() {
  const stepsUp = () => ups.value.some((u) => u())
  const step = mobileBackStep({ mobile: isMobile.value, overlays: overlays.length, level: level.value, hasBelow: mobileHasBelow(window.history.state), up: stepsUp })
  if (step === 'overlay') void enqueue(() => (overlays.length ? stepBack(1) : undefined))
  else if (step === 'history') window.history.back()
  else if (step === 'down') { applyLevel((level.value - 1) as MobileLevel); backs.value++ }
}

/* t1 3b8891e0: pages whose deep link has levels of its own above it */
const ups = shallowRef<Array<() => boolean>>([])

/**
 * A page with levels of its own inside level 2 (Documents' ?in=): Back on its
 * deep link calls `up` first (utils mobileBackStep); true = it stepped up in place.
 */
const up = (handler: () => boolean) => enlist(ups, handler)

const toHome = () => { if (isMobile.value) applyLevel(1) }

/* swipe right = Back (utils isMobileBackSwipe) */
let touch: { x: number, y: number } | null = null
function onTouchStart(e: TouchEvent) {
  touch = mobileSwipeStart(isMobile.value && level.value > 1, e.touches)
}
/* CLE-77906: a card's swipe-to-archive took this gesture - it is not a Back */
const claimSwipe = () => { touch = null }
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
    if (historyIdle()) return routerPush(to)
    return enqueue(() => (overlays.length ? stepBack(overlays.length) : undefined)).then(() => routerPush(to))
  }) as typeof router.push

  /* the entry the app was loaded on */
  const first = mobileTaggedLevel(window.history.state) ?? mobileInitialLevel(route.path, route.query as Record<string, unknown>)
  home.value = first === 1
  tag(first)

  /* a route navigation: a fresh entry is a push from the level we were on */
  router.afterEach((_to, _from, failure) => {
    lastPos = statePosition()
    const kind = failure ? (isNavigationFailure(failure, NavigationFailureType.duplicated) ? 'duplicated' : 'other') : null
    const step = mobileAfterNavStep(kind, isMobile.value, mobileTaggedLevel(window.history.state))
    if (step === 'push') return push(2)
    if (step !== 'tag') return
    const below = level.value
    home.value = false
    tag(level.value, below)
  })

  /* browser Back / Forward, and pop() -> history.back() */
  window.addEventListener('popstate', (e) => {
    lastPos = statePosition()
    inPlaceUntil = 0
    if (isMobile.value) backs.value++
    const tagged = mobileTaggedLevel(e.state)
    if (tagged !== null) applyLevel(tagged)
  })

  /* the level moved without a popstate: record it so Back comes down again */
  watch(level, (next) => {
    if (!isMobile.value) return
    const record = () => {
      const tagged = mobileTaggedLevel(window.history.state)
      const { step, clearInPlace } = mobileRecordStep(tagged, next, inPlaceUntil > Date.now())
      if (clearInPlace) inPlaceUntil = 0
      if (step === 'tag') tag(next)
      else if (step === 'push') pushLevel(next, tagged)
    }
    /* SPL-994: a level pushed from inside an overlay (a menu opening a thread) lands after
       the overlay's entry is gone; one queued to open after the move (/releases/<ref>) stays */
    if (historyIdle()) return record()
    const above = overlays.length
    void enqueue(async () => {
      if (above && overlays.length) await stepBack(overlays.length)
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
    /** t1 3b8891e0: a page's own level above its deep link, for Back */
    up,
    /** CLE-77882: the next topic open lands on the current entry (open in place) */
    landInPlace,
    /** SPL-2785: counts every Back on a phone (MobileBackWait.vue) */
    backs,
    /** SPL-1005: a page sheet / dialog / menu is open - the composer dock yields */
    sheetOpen,
    /** bind on the shell: @touchstart.passive / @touchend.passive */
    swipe: { onTouchStart, onTouchEnd, claim: claimSwipe },
    install,
    /** 087 T003: plugins/mobile-stale-login.client.ts only */
    guardStaleLogin,
  }
}
