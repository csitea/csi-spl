<!-- spec 106 T004: the phone calendar's shell (<= 820 px), its own lazy chunk
     (pages/calendar.vue mounts it through defineAsyncComponent). Spec 4.1:
     one header row (Back, the title = month picker, search, menu), the view
     between, one bottom bar (Today, Month | Week | Day, < >) and the round
     + button in the thumb corner. Spec 4.3: a sideways swipe turns the
     period like a page - the page follows the finger 1:1 and flat, and only
     the release snap tilts it (rotateY <= 8deg, scale 0.98, 220 ms); the
     view clips sideways (overflow-x: clip), so nothing ever scrolls
     sideways (H3). Neighbour periods are prefetched once a period settles;
     a newer settle aborts the older fetches.
     The three views are placeholder slots until T005 (Month), T006 (Week)
     and T007 (Day) replace them; the title picker, search, menu and the +
     sheet open T008..T010's parts (`panel`). Gestures and dates are T002's
     utils/calendar-swipe.mjs and utils/calendar-phone-nav.mjs. -->
<template>
  <section
    class="calphone"
    data-test="calendar-phone"
    :data-view="view"
    :data-day="shownDay"
    :data-period="period"
    :data-state="state"
  >
    <header class="calphone__head" data-test="calphone-head">
      <MobileBack />
      <button
        type="button"
        class="calphone__title"
        data-test="calphone-title"
        :aria-label="`${title} - ${t('calendar_phone.pick_month')}`"
        :title="t('calendar_phone.pick_month')"
        @click="openPanel('picker')"
      >
        <span class="calphone__title-text">{{ title }}</span>
        <UiIcon name="chevron-down" :size="16" />
      </button>
      <button
        type="button"
        class="calphone__icon"
        data-test="calphone-search"
        :aria-label="t('calendar_phone.search')"
        :title="t('calendar_phone.search')"
        @click="openPanel('search')"
      >
        <UiIcon name="search" :size="20" />
      </button>
      <button
        type="button"
        class="calphone__icon"
        data-test="calphone-menu"
        :aria-label="t('calendar_phone.menu')"
        :title="t('calendar_phone.menu')"
        @click="openPanel('menu')"
      >
        <UiIcon name="more" :size="20" />
      </button>
      <!-- the one period announcement (S4-2), outside the turning pages -->
      <span class="sr-only" aria-live="polite" data-test="calphone-live">{{ announced }}</span>
    </header>

    <div
      ref="viewEl"
      class="calphone__view"
      data-test="calphone-view"
      @touchstart.passive="onTouchStart"
      @touchmove.passive="onTouchMove"
      @touchend.passive="onTouchEnd"
      @touchcancel.passive="onTouchCancel"
    >
      <div ref="trackEl" class="calphone__track" :class="{ 'calphone__track--moving': moving }" data-test="calphone-track">
        <div
          v-for="pg in pages"
          :key="pg.key"
          class="calphone__page"
          :class="{ 'calphone__page--side': pg.dir !== 0 }"
          :style="pg.dir !== 0 ? { insetInlineStart: `${pg.dir * 100}%` } : undefined"
          :inert="pg.inert"
          :aria-hidden="pg.inert ? 'true' : undefined"
          data-test="calphone-page"
          :data-dir="pg.dir"
          :data-period="pg.period"
        >
          <!-- T005 / T006 / T007 replace these slots with CalendarPhoneMonth,
               CalendarPhoneWeek and CalendarPhoneDay (each async on first show) -->
          <div class="calphone__scroll">
            <CalendarPhoneWeek
              v-if="view === 'week'"
              :day="pg.period"
              :today="today"
              :items="pg.dir === 0 ? items : []"
              :state="pg.dir === 0 ? state : 'loading'"
              @add="openSheet({ day: $event })"
            />
            <div v-else class="calphone__slot" :data-test="`calphone-slot-${view}`" :data-period="pg.period">
              <p class="calphone__slot-title">{{ pg.title }}</p>
              <p class="calphone__slot-note">{{ t('calendar_phone.placeholder') }}</p>
              <ul v-if="pg.dir === 0 && state === 'ready'" class="calphone__slot-list">
                <li v-for="ev in items" :key="ev.id" class="calphone__slot-row" data-test="calphone-slot-row">
                  {{ ev.title }}
                </li>
              </ul>
              <p v-else-if="pg.dir === 0 && state === 'failed'" class="calphone__slot-note">{{ t('calendar.load_failed') }}</p>
            </div>
          </div>
        </div>
      </div>
      <button
        type="button"
        class="calphone__add"
        data-test="calphone-add"
        :aria-label="t('calendar_phone.add')"
        :title="t('calendar_phone.add')"
        @click="openSheet()"
      >
        <UiIcon name="plus" :size="26" />
      </button>
    </div>

    <nav class="calphone__bar" data-test="calphone-bar">
      <button
        type="button"
        class="calphone__btn calphone__today"
        data-test="calphone-today"
        :aria-label="t('calendar_phone.today')"
        @click="goToday"
      >
        <span class="calphone__long">{{ t('calendar_phone.today') }}</span>
        <span class="calphone__short calphone__today-num" aria-hidden="true">{{ Number(today.slice(8)) }}</span>
      </button>
      <div
        class="calphone__seg"
        role="radiogroup"
        data-test="calphone-views"
        :aria-label="t('calendar_phone.views')"
        @keydown="onSegKey"
      >
        <button
          v-for="v in VIEWS"
          :key="v"
          type="button"
          role="radio"
          class="calphone__btn calphone__seg-btn"
          :class="{ 'calphone__seg-btn--on': v === view }"
          :data-test="`calphone-view-${v}`"
          :data-view="v"
          :aria-checked="v === view ? 'true' : 'false'"
          :aria-label="t(`calendar_phone.view_${v}`)"
          :tabindex="v === view ? 0 : -1"
          @click="setView(v)"
        >
          <span class="calphone__long">{{ t(`calendar_phone.view_${v}`) }}</span>
          <span class="calphone__short" aria-hidden="true">{{ t(`calendar_phone.view_short_${v}`) }}</span>
        </button>
      </div>
      <button
        type="button"
        class="calphone__btn calphone__step"
        data-test="calphone-prev"
        :aria-label="t(`calendar_phone.prev_${view}`)"
        :title="t(`calendar_phone.prev_${view}`)"
        @click="turn(-1)"
      >
        <UiIcon name="chevron-left" :size="20" class="calphone__glyph" />
      </button>
      <button
        type="button"
        class="calphone__btn calphone__step"
        data-test="calphone-next"
        :aria-label="t(`calendar_phone.next_${view}`)"
        :title="t(`calendar_phone.next_${view}`)"
        @click="turn(1)"
      >
        <UiIcon name="chevron-right" :size="20" class="calphone__glyph" />
      </button>
    </nav>
    <!-- T008 (add sheet), T009 (peek), T010 (picker, search) open here -->
    <div v-if="panel" hidden data-test="calphone-panel" :data-panel="panel" />
    <CalendarPhoneSheet
      v-if="sheetUsed || panel === 'add'"
      :open="panel === 'add'"
      :event="sheetFor.event"
      :day="sheetFor.day || shownDay"
      :today="today"
      :hour="sheetFor.hour"
      @update:open="(v: boolean) => { if (!v && panel === 'add') panel = '' }"
    />
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useMobileStack } from '~/composables/useMobileStack'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { hubJsonHeaders } from '~/utils/hub-headers'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { CAL_PHONE_VIEWS, calPhoneRange, calPhoneStep, calPhoneTitle } from '~/utils/calendar-phone-nav.mjs'
import { calSwipeClaims, calSwipeClassify, calSwipeInEdge, calSwipeLock } from '~/utils/calendar-swipe.mjs'

const CalendarPhoneWeek = defineAsyncComponent(() => import('./CalendarPhoneWeek.vue'))

type View = 'month' | 'week' | 'day'
type Point = { x: number, y: number, t: number }

const props = defineProps<{ focus: string, today: string }>()
const emit = defineEmits<{ move: [iso: string] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const stack = useMobileStack()

/* FR-002: Week first, then the view last used in this browser */
const VIEW_KEY = 'spool-calendar-phone-view'
function storedView(): View {
  try {
    const v = window.localStorage.getItem(VIEW_KEY)
    return v === 'month' || v === 'day' ? v : 'week'
  } catch { return 'week' }
}
const VIEWS = CAL_PHONE_VIEWS as View[]
const view = ref<View>(storedView())
function setView(v: View) {
  if (v === view.value) return
  view.value = v
  try { window.localStorage.setItem(VIEW_KEY, v) } catch { /* storage off: Week next time */ }
}
function onSegKey(e: KeyboardEvent) {
  const steps: Record<string, number> = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }
  const step = steps[e.key]
  if (!step) return
  e.preventDefault()
  /* rtl: the row runs right to left, so Left is forward */
  const dir = isRtl() && (e.key === 'ArrowLeft' || e.key === 'ArrowRight') ? -step : step
  const n = VIEWS.length
  setView(VIEWS[(VIEWS.indexOf(view.value) + dir + n) % n]!)
  void nextTick(() => (e.currentTarget as HTMLElement | null)?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus())
}

/* the shown day: follows the route, but a finished page turn shows its
   target at once instead of waiting for the router's round trip */
const shownDay = ref(props.focus)
watch(() => props.focus, (d) => { shownDay.value = d })

const names = computed(() => ({
  months: Array.from({ length: 12 }, (_, i) => t(`calendar.months.m${i + 1}`)),
  weekdays: Array.from({ length: 7 }, (_, i) => t(`calendar.weekdays.d${i + 1}`)),
}))
const titleOf = (day: string) => calPhoneTitle(view.value, day, names.value)
const title = computed(() => titleOf(shownDay.value))
const period = computed(() => calPhoneRange(view.value, shownDay.value)?.from || '')

/* S4-2: the new period is announced once, never on first paint */
const announced = ref('')
watch(title, (v) => { announced.value = v })

const panel = ref<'' | 'picker' | 'search' | 'menu' | 'add'>('')
function openPanel(kind: 'picker' | 'search' | 'menu' | 'add') { panel.value = kind }

/* T008: the add / edit sheet, its own chunk on first open. The views and
   the peek open it with inject('calphone-sheet'): a new event on a day (at a
   tapped hour), or an event to edit */
const CalendarPhoneSheet = defineAsyncComponent(() => import('~/components/CalendarPhoneSheet.vue'))
type SheetFor = { event: CalendarItem | null, day: string, hour: number }
const sheetFor = shallowRef<SheetFor>({ event: null, day: '', hour: -1 })
const sheetUsed = ref(false)
function openSheet(o: Partial<SheetFor> = {}) {
  sheetFor.value = { event: o.event ?? null, day: o.day ?? '', hour: o.hour ?? -1 }
  sheetUsed.value = true
  panel.value = 'add'
}
provide('calphone-sheet', openSheet)

function goToday() {
  if (shownDay.value === props.today) return
  shownDay.value = props.today
  emit('move', props.today)
}

/* ---- events: GET /v1/calendar/events for the shown range, the two
   neighbours prefetched; a newer settle aborts the older fetches ---- */
const items = shallowRef<CalendarItem[]>([])
const state = ref<'loading' | 'ready' | 'failed'>('loading')
const cache = new Map<string, CalendarItem[]>()
let ctl: AbortController | null = null

async function fetchRange(r: { from: string, to: string }, signal: AbortSignal): Promise<CalendarItem[]> {
  const key = `${r.from}/${r.to}`
  const hit = cache.get(key)
  if (hit) return hit
  const start = `${r.from}T00:00:00Z`
  const end = `${r.to}T00:00:00Z`
  let body: { events?: CalendarItem[] }
  if (api.mock) {
    const { mockCalendarEvents } = await import('~/utils/calendar-mock.mjs')
    body = mockCalendarEvents(start, end, props.today)
  } else {
    const q = new URLSearchParams({ start, end })
    const res = await fetch(`${api.base}/v1/calendar/events?${q}`, { credentials: api.credentials, headers: hubJsonHeaders(api.token), signal })
    if (!res.ok) throw new Error('calendar events ' + res.status)
    body = await res.json()
  }
  const list = Array.isArray(body?.events) ? body.events : []
  if (!signal.aborted) cache.set(key, list)
  return list
}

async function settle() {
  ctl?.abort()
  const mine = new AbortController()
  ctl = mine
  const timer = setTimeout(() => mine.abort(), DOC_READ_TIMEOUT_MS)
  const day = shownDay.value
  const v = view.value
  const r = calPhoneRange(v, day)
  if (!r) return
  state.value = cache.has(`${r.from}/${r.to}`) ? state.value : 'loading'
  try {
    const list = await fetchRange(r, mine.signal)
    if (mine.signal.aborted) return
    items.value = list
    state.value = 'ready'
    for (const dir of [1, -1]) {
      const n = calPhoneRange(v, calPhoneStep(v, day, dir))
      if (n && !mine.signal.aborted) await fetchRange(n, mine.signal).catch(() => [])
    }
  } catch {
    if (mine.signal.aborted) return
    items.value = []
    state.value = 'failed'
  } finally {
    clearTimeout(timer)
  }
}
watch([view, shownDay], () => { void settle() })
function onChanged() {
  cache.clear()
  void settle()
}
onMounted(() => {
  void settle()
  window.addEventListener(CALENDAR_CHANGED_EVENT, onChanged)
})
onBeforeUnmount(() => {
  ctl?.abort()
  window.removeEventListener(CALENDAR_CHANGED_EVENT, onChanged)
  cancelAnimationFrame(raf)
})

/* ---- the page turn (spec 4.3, H2, H6) ---- */
const viewEl = ref<HTMLElement | null>(null)
const trackEl = ref<HTMLElement | null>(null)
/** the neighbour on screen: 1 = the next period, -1 = the previous, 0 = none */
const side = ref<0 | 1 | -1>(0)
const turning = ref(false)
const moving = ref(false)

const pages = computed(() => {
  const cur = { key: `p:${shownDay.value}`, dir: 0, period: period.value, title: title.value, inert: turning.value }
  if (side.value === 0) return [cur]
  const day = calPhoneStep(view.value, shownDay.value, side.value)
  const r = calPhoneRange(view.value, day)
  return [cur, { key: `n:${day}`, dir: side.value, period: r?.from || '', title: titleOf(day), inert: !turning.value }]
})

const isRtl = () => document.documentElement.dir === 'rtl'
const reducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true
const flat = (x: number) => `perspective(1200px) translateX(${x}px) rotateY(0deg) scale(1)`

let pts: Point[] = []
let lock: 'none' | 'x' | 'y' = 'none'
let dx = 0
let raf = 0
function paint() {
  raf = 0
  if (trackEl.value) trackEl.value.style.transform = `translateX(${dx}px)`
}

function onTouchStart(e: TouchEvent) {
  const p = e.touches[0]
  pts = !turning.value && e.touches.length === 1 && p ? [{ x: p.clientX, y: p.clientY, t: e.timeStamp }] : []
  lock = 'none'
  dx = 0
}
function onTouchMove(e: TouchEvent) {
  const p = e.touches[0]
  const p0 = pts[0]
  if (!p || !p0) return
  const pt = { x: p.clientX, y: p.clientY, t: e.timeStamp }
  pts.push(pt)
  lock = calSwipeLock(p0, pt, lock)
  if (lock !== 'x') return
  const d = pt.x - p0.x
  const rtl = isRtl()
  /* a track toward Back from the edge zone is the stack's Back, not a turn */
  if ((rtl ? d < 0 : d > 0) && calSwipeInEdge(p0.x, window.innerWidth, rtl)) return
  dx = d
  side.value = (rtl ? d > 0 : d < 0) ? 1 : -1
  moving.value = true
  if (!raf) raf = requestAnimationFrame(paint)
}
function onTouchEnd() {
  const p0 = pts[0]
  const rtl = isRtl()
  /* the view keeps its swipes; one from the Back edge stays the stack's */
  if (p0 && calSwipeClaims(p0.x, window.innerWidth, rtl)) stack.swipe.claim()
  const kind = p0 ? calSwipeClassify({ points: pts, width: window.innerWidth, rtl }) : 'none'
  const from = dx
  pts = []
  if (kind === 'next' || kind === 'prev') void turn(kind === 'next' ? 1 : -1, from)
  else if (moving.value) void snapBack(from)
}
function onTouchCancel() {
  const from = dx
  pts = []
  if (moving.value) void snapBack(from)
}

function rest() {
  cancelAnimationFrame(raf)
  raf = 0
  dx = 0
  moving.value = false
  if (trackEl.value) trackEl.value.style.transform = ''
}

async function snapBack(from: number) {
  const el = trackEl.value
  if (el && !reducedMotion() && typeof el.animate === 'function') {
    /* a cancelled animation (unmount, a new touch) still rests the page below */
    await el.animate([{ transform: flat(from) }, { transform: flat(0) }], { duration: 150, easing: 'ease-out' }).finished.catch(() => undefined)
  }
  rest()
  side.value = 0
}

/** turn one period: a swipe's release (from its offset) or < / > (from 0) */
async function turn(dir: 1 | -1, from = 0) {
  if (turning.value) return
  const target = calPhoneStep(view.value, shownDay.value, dir)
  if (!target) return
  side.value = dir
  turning.value = true
  moving.value = true
  await nextTick()
  const el = trackEl.value
  const w = viewEl.value?.clientWidth || window.innerWidth
  const s = isRtl() ? -1 : 1
  const to = -dir * s * w
  if (el && !reducedMotion() && typeof el.animate === 'function') {
    cancelAnimationFrame(raf)
    raf = 0
    el.style.transform = ''
    const tilt = `perspective(1200px) translateX(${(from + to) / 2}px) rotateY(${dir * s * 8}deg) scale(0.98)`
    /* a cancelled animation still lands the turn below */
    await el.animate(
      [{ transform: flat(from) }, { transform: tilt, offset: 0.5 }, { transform: flat(to) }],
      { duration: 220, easing: 'ease-out' },
    ).finished.catch(() => undefined)
  }
  shownDay.value = target
  rest()
  side.value = 0
  turning.value = false
  emit('move', target)
}
</script>

<style scoped>
.calphone {
  position: relative;
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-width: 0;
  min-height: 0;
  max-width: 100%;
  overflow-x: clip;
  /* the page ends where the composer dock starts (H8 measures to it) */
  padding-bottom: var(--composer-dock-h, 0px);
  box-sizing: border-box;
  background: var(--color-bg);
}

/* ---- header: one row, <= 48 px at level 3 ---- */
.calphone__head {
  display: flex;
  align-items: center;
  gap: 2px;
  min-height: 48px;
  padding: 1px 4px;
  box-sizing: border-box;
  min-width: 0;
  border-bottom: 1px solid var(--color-border);
}
.calphone__head :deep(.mobile-back) {
  min-width: var(--tap);
  min-height: var(--tap);
  flex: 0 0 auto;
}
.calphone__title {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex: 1 1 auto;
  min-width: 0;
  min-height: var(--tap);
  padding: 0 8px;
  border: 0;
  border-radius: var(--radius);
  background: transparent;
  color: var(--color-heading);
  font: inherit;
  font-size: 1rem;
  font-weight: 600;
  text-align: start;
  cursor: pointer;
}
.calphone__title-text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.calphone__icon {
  display: inline-grid;
  place-items: center;
  flex: 0 0 auto;
  width: var(--tap);
  height: var(--tap);
  border: 0;
  border-radius: var(--radius-pill);
  background: transparent;
  color: var(--color-fg);
  cursor: pointer;
}

/* ---- the view: vertical scroll only, a page turn clips sideways ---- */
.calphone__view {
  position: relative;
  flex: 1 1 auto;
  min-height: 0;
  overflow-x: clip;
  overflow-y: hidden;
  touch-action: pan-y;
  overscroll-behavior: contain;
}
.calphone__track {
  position: relative;
  height: 100%;
}
.calphone__track--moving { will-change: transform; }
.calphone__page {
  position: absolute;
  inset-block: 0;
  inset-inline-start: 0;
  width: 100%;
  backface-visibility: hidden;
}
.calphone__scroll {
  height: 100%;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior-y: contain;
  box-sizing: border-box;
  /* the + button (56 px) and its 16 px never cover the last row (S4-9) */
  padding: 12px 16px 72px;
}
.calphone__slot { min-width: 0; }
.calphone__slot-title {
  margin: 0 0 4px;
  font-size: 1rem;
  font-weight: 600;
  color: var(--color-heading);
  overflow-wrap: anywhere;
}
.calphone__slot-note {
  margin: 0 0 12px;
  font-size: 0.875rem;
  color: var(--color-muted);
}
.calphone__slot-list {
  margin: 0;
  padding: 0;
  list-style: none;
}
.calphone__slot-row {
  min-height: var(--tap);
  display: flex;
  align-items: center;
  padding: 0 12px;
  margin-bottom: 6px;
  border-radius: var(--radius-md);
  background: var(--color-surface);
  box-shadow: var(--bevel-shine), var(--bevel-shade);
  font-size: 0.875rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* ---- the round + : 56 px, thumb corner, outside the turning pages ---- */
.calphone__add {
  position: absolute;
  inset-inline-end: 16px;
  bottom: calc(16px + env(safe-area-inset-bottom, 0px));
  z-index: 2;
  display: inline-grid;
  place-items: center;
  width: 56px;
  height: 56px;
  padding: 0;
  border: 0;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
  color: var(--color-on-accent);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
  cursor: pointer;
}
.calphone__add:active {
  transform: translateY(1px);
  background: var(--color-accent-pressed);
  box-shadow: var(--bevel-shade);
}

/* ---- bottom bar: one row, <= 48 px at level 3 ---- */
.calphone__bar {
  display: flex;
  align-items: center;
  gap: 6px;
  min-height: 48px;
  padding: 1px 16px;
  box-sizing: border-box;
  min-width: 0;
  border-top: 1px solid var(--color-border);
  background: var(--color-bg-2);
}
.calphone__btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
  min-width: var(--tap);
  min-height: var(--tap);
  padding: 0 10px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  line-height: 1.2;
  white-space: nowrap;
  cursor: pointer;
}
.calphone__today { box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade); }
.calphone__btn:active {
  transform: translateY(1px);
  background: var(--color-selected);
  box-shadow: var(--bevel-shade);
}
.calphone__seg {
  display: inline-flex;
  flex: 1 1 auto;
  justify-content: center;
  min-width: 0;
  gap: 2px;
}
.calphone__seg-btn { flex: 1 1 0; min-width: var(--tap); padding: 0 6px; }
.calphone__seg-btn--on {
  background: var(--color-selected);
  color: var(--color-heading);
  font-weight: 600;
  border-color: var(--color-border-strong);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
}
.calphone__step { padding: 0; }
[dir="rtl"] .calphone__glyph { transform: scaleX(-1); }

.calphone__short { display: none; }
.calphone__today-num {
  min-width: 1.6em;
  padding: 1px 2px;
  border: 1px solid currentColor;
  border-radius: var(--radius);
  font-weight: 600;
  text-align: center;
}
/* S4-1: under 400 px, or at font level 4 and 5, Today is its day number in a
   frame and the segments are M / W / D (the full word stays the name) */
@media (max-width: 399.98px) {
  .calphone__long { display: none; }
  .calphone__short { display: inline-block; }
  .calphone__today { padding: 0; }
}
:root[data-font-size="4"] .calphone__long,
:root[data-font-size="5"] .calphone__long { display: none; }
:root[data-font-size="4"] .calphone__short,
:root[data-font-size="5"] .calphone__short { display: inline-block; }

.calphone button:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}

/* S4-7: no tilt, no scale, no smooth scroll; the swipe still swaps pages */
@media (prefers-reduced-motion: reduce) {
  .calphone__scroll { scroll-behavior: auto; }
  .calphone__add:active,
  .calphone__btn:active { transform: none; }
}
</style>
