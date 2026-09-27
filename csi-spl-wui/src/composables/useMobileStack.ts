import { computed, getCurrentScope, onScopeDispose, ref, shallowRef, toValue, watch, type MaybeRefOrGetter, type Ref } from 'vue'
import { isNavigationFailure, NavigationFailureType } from 'vue-router'
import {
  MOBILE_STACK_QUERY,
  isMobileBackSwipe,
  mobileHasBelow,
  mobileHistoryStep,
  mobileInitialLevel,
  mobileLevelOf,
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

function tag(lv: MobileLevel, below?: number) {
  window.history.replaceState(mobileTagState(window.history.state, lv, below), '')
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

function push(lv: 2 | 3) {
  if (lv >= 2) home.value = false
}

function pop() {
  if (!isMobile.value || level.value === 1) return
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
  const first = mobileTaggedLevel(window.history.state) ?? mobileInitialLevel(route.path, route.query as Record<string, unknown>)
  home.value = first === 1
  tag(first)

  /* a route navigation: a fresh entry is a push from the level we were on */
  router.afterEach((_to, _from, failure) => {
    if (failure) {
      /* a tap on the link to the page already behind level 1 */
      if (isNavigationFailure(failure, NavigationFailureType.duplicated) && isMobile.value) push(2)
      return
    }
    const tagged = mobileTaggedLevel(window.history.state)
    if (tagged !== null) return void applyLevel(tagged)
    const below = level.value
    home.value = false
    tag(level.value, below)
  })

  /* browser Back / Forward, and pop() -> history.back() */
  window.addEventListener('popstate', (e) => {
    const tagged = mobileTaggedLevel(e.state)
    if (tagged !== null) applyLevel(tagged)
  })

  /* the level moved without a popstate: record it so Back comes down again */
  watch(level, (next) => {
    if (!isMobile.value) return
    const tagged = mobileTaggedLevel(window.history.state)
    const step = mobileHistoryStep(tagged, next)
    if (step === 'tag') tag(next)
    else if (step === 'push') window.history.pushState(mobileTagState(window.history.state, next, tagged ?? 1), '')
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
    /** bind on the shell: @touchstart.passive / @touchend.passive */
    swipe: { onTouchStart, onTouchEnd },
    install,
  }
}
