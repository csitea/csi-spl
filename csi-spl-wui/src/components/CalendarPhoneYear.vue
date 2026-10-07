<!-- spec 106 T010: the phone calendar's month picker (spec 4.6, FR-009).
     A tap on the title opens it: the 12 months of one year as a 3x4 grid,
     the year changed by < / > or a sideways swipe, within 089's 3-year
     range (the previous, this and the next year). A tap on a month emits
     `pick` with that month's first day (today when it is this month), and
     CalendarPhone opens Month on it - title, month, day: AC-03's 3 taps.
     A dialog over the shell (S4-2 e): Escape or the close button emits
     `close`; focus returns to the control that opened it. -->
<template>
  <div
    ref="rootEl"
    class="calyear"
    role="dialog"
    aria-modal="true"
    :aria-label="t('calendar_phone.pick_month')"
    data-test="calphone-picker"
    :data-year="year"
    @touchstart.passive="onTouchStart"
    @touchend.passive="onTouchEnd"
  >
    <div class="calyear__head">
      <button
        type="button"
        class="calyear__btn"
        data-test="calphone-picker-close"
        :aria-label="t('common.close')"
        :title="t('common.close')"
        @click="emit('close')"
      >
        <UiIcon name="x" :size="20" />
      </button>
      <button
        type="button"
        class="calyear__btn"
        data-test="calphone-picker-prev"
        :aria-label="String(year - 1)"
        :disabled="year <= first"
        @click="step(-1)"
      >
        <UiIcon name="chevron-left" :size="20" class="calyear__glyph" />
      </button>
      <h2 class="calyear__year" aria-live="polite" data-test="calphone-picker-year">{{ year }}</h2>
      <button
        type="button"
        class="calyear__btn"
        data-test="calphone-picker-next"
        :aria-label="String(year + 1)"
        :disabled="year >= last"
        @click="step(1)"
      >
        <UiIcon name="chevron-right" :size="20" class="calyear__glyph" />
      </button>
    </div>
    <div class="calyear__grid" data-test="calphone-picker-grid">
      <button
        v-for="(name, i) in months"
        :key="i"
        type="button"
        class="calyear__month"
        :class="{ 'calyear__month--on': monthKey(i) === shownMonth, 'calyear__month--today': monthKey(i) === today.slice(0, 7) }"
        :data-test="`calphone-picker-month-${monthKey(i)}`"
        :aria-current="monthKey(i) === shownMonth ? 'date' : undefined"
        :aria-label="`${name} ${year}`"
        @click="pick(i)"
      >
        {{ name }}
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useMobileStack } from '~/composables/useMobileStack'
import { calSwipeClaims, calSwipeClassify } from '~/utils/calendar-swipe.mjs'

const props = defineProps<{ day: string, today: string }>()
const emit = defineEmits<{ pick: [iso: string], close: [] }>()
const { t } = useI18n({ useScope: 'global' })
const stack = useMobileStack()

/* 089's range: the previous, this and the next year */
const thisYear = Number(props.today.slice(0, 4))
const first = thisYear - 1
const last = thisYear + 1
const clampYear = (y: number) => Math.min(last, Math.max(first, y))
const year = ref(clampYear(Number(props.day.slice(0, 4)) || thisYear))
const shownMonth = computed(() => props.day.slice(0, 7))

const months = computed(() => Array.from({ length: 12 }, (_, i) => t(`calendar.months.m${i + 1}`)))
const monthKey = (i: number) => `${year.value}-${String(i + 1).padStart(2, '0')}`

function step(dir: 1 | -1) { year.value = clampYear(year.value + dir) }
function pick(i: number) {
  const key = monthKey(i)
  emit('pick', key === props.today.slice(0, 7) ? props.today : `${key}-01`)
}

/* a sideways swipe turns the year (T002's classifier, rtl aware); like the
   view, the picker keeps its swipes, one from the Back edge stays the stack's */
let pts: { x: number, y: number, t: number }[] = []
function onTouchStart(e: TouchEvent) {
  const p = e.touches[0]
  pts = e.touches.length === 1 && p ? [{ x: p.clientX, y: p.clientY, t: e.timeStamp }] : []
}
function onTouchEnd(e: TouchEvent) {
  const p = e.changedTouches[0]
  if (!pts.length || !p) return
  pts.push({ x: p.clientX, y: p.clientY, t: e.timeStamp })
  const rtl = document.documentElement.dir === 'rtl'
  if (calSwipeClaims(pts[0]!.x, window.innerWidth, rtl)) stack.swipe.claim()
  const kind = calSwipeClassify({ points: pts, width: window.innerWidth, rtl })
  pts = []
  if (kind === 'next') step(1)
  else if (kind === 'prev') step(-1)
}

/* focus in on open, back to the opener on close (S4-2 e); Escape closes
   wherever focus is (a button disabled under it drops focus to the body) */
function onKey(e: KeyboardEvent) {
  if (e.key !== 'Escape') return
  e.preventDefault()
  e.stopPropagation()
  emit('close')
}
const rootEl = ref<HTMLElement | null>(null)
let opener: HTMLElement | null = null
onMounted(() => {
  opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
  rootEl.value?.querySelector<HTMLElement>('.calyear__month--on, .calyear__month')?.focus()
  window.addEventListener('keydown', onKey, true)
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey, true)
  if (opener?.isConnected) opener.focus()
})
</script>

<style scoped>
.calyear {
  position: absolute;
  inset: 0;
  z-index: 5;
  display: flex;
  flex-direction: column;
  min-width: 0;
  padding-bottom: var(--composer-dock-h, 0px);
  box-sizing: border-box;
  overflow-x: clip;
  overflow-y: auto;
  overscroll-behavior: contain;
  touch-action: pan-y;
  background: var(--color-bg);
}
.calyear__head {
  display: flex;
  align-items: center;
  gap: 2px;
  min-height: 48px;
  padding: 1px 4px;
  box-sizing: border-box;
  border-bottom: 1px solid var(--color-border);
}
.calyear__btn {
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
.calyear__btn:disabled { color: var(--color-muted); cursor: default; }
.calyear__year {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
  text-align: center;
  color: var(--color-heading);
}
.calyear__grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 8px;
  padding: 16px;
}
.calyear__month {
  min-width: 0;
  min-height: 56px;
  padding: 0 4px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  overflow-wrap: anywhere;
  cursor: pointer;
  box-shadow: var(--bevel-shine), var(--bevel-shade);
}
.calyear__month--today { border-color: var(--color-accent); font-weight: 700; }
.calyear__month--on {
  background: var(--color-selected);
  color: var(--color-heading);
  font-weight: 600;
  border-color: var(--color-border-strong);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
}
.calyear__month:active { transform: translateY(1px); box-shadow: var(--bevel-shade); }
[dir="rtl"] .calyear__glyph { transform: scaleX(-1); }
.calyear button:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
@media (prefers-reduced-motion: reduce) {
  .calyear__month:active { transform: none; }
}
</style>
