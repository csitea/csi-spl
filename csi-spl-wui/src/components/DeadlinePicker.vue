<!-- owner, topic 778ad161: "it should be a calendar control with the
     yyyy-mm-dd HH:MM DEADLINE time format". A text field that shows and takes
     YYYY-MM-DD HH:MM in every locale, and a button that opens a month grid
     (Monday first) plus a 24-hour time. Never a native type=date input: the
     browser draws those in its own locale (mm/dd/yyyy for the owner).
     v-model is the LOCAL 'YYYY-MM-DDTHH:MM' ('' = none); the page converts
     to and from the RFC 3339 UTC the hub stores (utils/issues-view.mjs). -->
<template>
  <div ref="root" class="dlp">
    <!-- SPL-1147 (owner, topic f9b6c844): "the length of the white space
         after the date in the control should be 2 mm" - the field is as wide
         as what it shows (this hidden copy, measured) plus DLP_TRAIL_PX -->
    <span ref="measure" class="dlp__text dlp__measure" aria-hidden="true">{{ draft || 'YYYY-MM-DD HH:MM' }}</span>
    <input
      ref="field"
      type="text"
      class="dlp__text"
      :style="fieldStyle"
      inputmode="numeric"
      maxlength="16"
      spellcheck="false"
      placeholder="YYYY-MM-DD HH:MM"
      autocomplete="off"
      :data-test="testId"
      :aria-label="label"
      :aria-invalid="invalid ? 'true' : undefined"
      :title="invalid ? t('picker.invalid') : undefined"
      :value="draft"
      @input="draft = ($event.target as HTMLInputElement).value"
      @change="commitText"
      @keydown.enter.prevent="commitText"
      @keydown.down.alt.prevent="openPop"
      @keydown.esc="open && close()"
    >
    <button
      ref="opener"
      type="button"
      class="btn ghost dlp__open"
      :data-test="testId + '-open'"
      aria-haspopup="dialog"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-label="t('picker.open')"
      :title="t('picker.open')"
      @click="open ? close() : openPop()"
    >
      <UiIcon name="calendar" :size="16" />
    </button>
    <div
      v-if="open"
      ref="pop"
      class="dlp__pop"
      role="dialog"
      :aria-label="label"
      :style="popStyle"
      data-test="deadline-picker"
      @keydown.esc.stop.prevent="close(true)"
    >
      <!-- SPL-1147 (owner, topic f9b6c844): "the Done button is obsolete,
           add a simple x" - a picked day / time applies at once; the shared
           close X (SPL-1133: Mac = top left, the default; Windows = top
           right), Esc or an outside click closes -->
      <div class="dlp__head">
        <UiCloseButton side="start" class="dlp__close" :size="14" data-test="deadline-picker-close" @click="close(true)" />
        <button type="button" class="btn ghost dlp__nav" data-test="deadline-picker-prev" :aria-label="t('picker.prev_month')" :title="t('picker.prev_month')" @click="month = shiftMonth(month, -1)">‹</button>
        <span class="dlp__month" data-test="deadline-picker-month" aria-live="polite">{{ month }}</span>
        <button type="button" class="btn ghost dlp__nav" data-test="deadline-picker-next" :aria-label="t('picker.next_month')" :title="t('picker.next_month')" @click="month = shiftMonth(month, 1)">›</button>
        <UiCloseButton side="end" class="dlp__close" :size="14" data-test="deadline-picker-close" @click="close(true)" />
      </div>
      <table class="dlp__grid" role="grid" :aria-label="month">
        <thead>
          <tr>
            <th v-for="w in weekdays" :key="w" scope="col" class="dlp__wd">{{ w }}</th>
          </tr>
        </thead>
        <tbody @keydown="onGridKey">
          <tr v-for="(week, i) in grid" :key="i">
            <td v-for="d in week" :key="d.date" role="gridcell" :aria-selected="d.date === picked.date ? 'true' : 'false'">
              <button
                type="button"
                class="dlp__day"
                :class="{ 'dlp__day--out': !d.inMonth, 'dlp__day--today': d.date === today, 'dlp__day--on': d.date === picked.date }"
                :tabindex="d.date === focusDate ? 0 : -1"
                :data-date="d.date"
                data-test="deadline-picker-day"
                :aria-label="d.date"
                @click="pickDay(d.date)"
              >{{ d.day }}</button>
            </td>
          </tr>
        </tbody>
      </table>
      <label class="dlp__time">
        <span>{{ t('picker.time') }}</span>
        <select :data-test="timeTestId" :aria-label="t('picker.time')" :value="picked.time || defaultTime" @change="pickTime(($event.target as HTMLSelectElement).value)">
          <option v-for="tm in deadlineTimes(picked.time || defaultTime)" :key="tm" :value="tm">{{ tm }}</option>
        </select>
      </label>
      <div class="dlp__foot">
        <button type="button" class="btn ghost" data-test="deadline-picker-today" @click="pickDay(today)">{{ t('picker.today') }}</button>
        <button type="button" class="btn ghost" data-test="deadline-picker-clear" @click="clear">{{ t('picker.clear') }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { isoDate } from '~/utils/date-iso.mjs'
import { clampPopover } from '~/utils/popover-clamp.mjs'
import {
  DEADLINE_DEFAULT_TIME, deadlineText, deadlineTimes, joinLocal, monthGrid, monthOf, parseDeadlineText, shiftMonth, splitLocal,
} from '~/utils/issues-view.mjs'

const props = withDefaults(defineProps<{
  modelValue: string
  label: string
  testId: string
  timeTestId?: string
  defaultTime?: string
}>(), { timeTestId: 'deadline-picker-time', defaultTime: DEADLINE_DEFAULT_TIME })

const emit = defineEmits<{ 'update:modelValue': [local: string] }>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const opener = ref<HTMLElement | null>(null)
const pop = ref<HTMLElement | null>(null)
const field = ref<HTMLInputElement | null>(null)
const measure = ref<HTMLElement | null>(null)
const fieldStyle = ref<Record<string, string>>({})
const open = ref(false)
const invalid = ref(false)
const draft = ref(deadlineText(props.modelValue))
const today = ref(isoDate(new Date()))
const month = ref(monthOf(props.modelValue, today.value))
const focusDate = ref('')
const popStyle = ref<Record<string, string>>({})

/* A time chosen before any day waits here until a day is picked. */
const pendingTime = ref('')
const picked = computed(() => {
  const s = splitLocal(props.modelValue)
  return { date: s.date, time: s.time || pendingTime.value }
})
const grid = computed(() => monthGrid(month.value))
const weekdays = computed(() => t('picker.weekdays').split(' ').slice(0, 7))

watch(() => props.modelValue, (v) => { draft.value = deadlineText(v); invalid.value = false })

/* SPL-1147: 2 mm = ~8 CSS px of empty space after the text: the right
   padding is DLP_TRAIL_PX (the caret draws in it, so a full field never
   scrolls) and the width is the text + both paddings + borders. */
const DLP_TRAIL_PX = 8
function sizeField() {
  const el = field.value
  const m = measure.value
  if (!el || !m) return
  const cs = getComputedStyle(el)
  /* an input does not inherit the page font: measure in the field's own */
  m.style.fontFamily = cs.fontFamily
  m.style.fontSize = cs.fontSize
  m.style.fontWeight = cs.fontWeight
  m.style.fontStyle = cs.fontStyle
  m.style.letterSpacing = cs.letterSpacing
  m.style.fontVariantNumeric = cs.fontVariantNumeric
  const edge = ['paddingLeft', 'borderLeftWidth', 'borderRightWidth'].reduce((n, k) => n + (parseFloat(cs[k as 'paddingLeft']) || 0), 0)
  const text = m.getBoundingClientRect().width
  if (text > 0) fieldStyle.value = { width: `${(text + DLP_TRAIL_PX + edge).toFixed(2)}px`, paddingRight: `${DLP_TRAIL_PX}px` }
}
watch(draft, () => nextTick(sizeField))

function set(local: string) {
  invalid.value = false
  draft.value = deadlineText(local)
  if (local !== props.modelValue) emit('update:modelValue', local)
}

function commitText() {
  const local = parseDeadlineText(draft.value, props.defaultTime)
  if (local === null) { invalid.value = true; return }
  set(local)
  if (local) month.value = monthOf(local, today.value)
}

function pickDay(date: string) {
  month.value = monthOf(date, today.value)
  focusDate.value = date
  set(joinLocal(date, picked.value.time || props.defaultTime))
}

function pickTime(time: string) {
  if (!picked.value.date) { pendingTime.value = time; return }
  set(joinLocal(picked.value.date, time))
}

function clear() {
  pendingTime.value = ''
  set('')
  close(true)
}

/* SPL-1147: always fully inside the viewport (clampPopover). Measured from
   the drawn pop-up, so the numbers follow the CSS. */
function place() {
  const r = root.value?.getBoundingClientRect()
  if (!r) return
  const w = pop.value?.offsetWidth || 200
  const h = pop.value?.offsetHeight || 300
  const { left, top } = clampPopover({ anchor: r, w, h, vw: window.innerWidth, vh: window.innerHeight })
  popStyle.value = { left: `${Math.round(left)}px`, top: `${Math.round(top)}px` }
}

async function openPop() {
  today.value = isoDate(new Date())
  month.value = monthOf(props.modelValue, today.value)
  focusDate.value = picked.value.date || today.value
  place()
  open.value = true
  await nextTick()
  place()
  pop.value?.querySelector<HTMLElement>(`[data-date="${focusDate.value}"]`)?.focus()
}

function close(refocus = false) {
  open.value = false
  if (refocus) opener.value?.focus()
}

function addDays(date: string, n: number) {
  const [y, m, d] = date.split('-').map(Number)
  return isoDate(new Date(y, m - 1, d + n))
}

async function onGridKey(ev: KeyboardEvent) {
  const step: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }
  let next = ''
  if (ev.key in step) next = addDays(focusDate.value || today.value, step[ev.key])
  else if (ev.key === 'PageUp' || ev.key === 'PageDown') {
    const ym = shiftMonth(month.value, ev.key === 'PageUp' ? -1 : 1)
    next = `${ym}-${(focusDate.value || today.value).slice(8, 10)}`
    const last = monthGrid(ym).flat().filter((d) => d.inMonth).pop()?.date || next
    if (next > last) next = last
  } else return
  ev.preventDefault()
  focusDate.value = next
  month.value = next.slice(0, 7)
  await nextTick()
  pop.value?.querySelector<HTMLElement>(`[data-date="${next}"]`)?.focus()
}

function onOutside(ev: PointerEvent) {
  if (open.value && root.value && !root.value.contains(ev.target as Node)) close()
}
onMounted(() => {
  sizeField()
  /* re-measure once the web font lands; if it never does, the size measured above with the fallback font stands */
  document.fonts?.ready.then(sizeField).catch(() => {})
  document.addEventListener('pointerdown', onOutside, true)
  window.addEventListener('resize', place)
  window.addEventListener('scroll', place, true)
})
onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', onOutside, true)
  window.removeEventListener('resize', place)
  window.removeEventListener('scroll', place, true)
})
</script>

<style scoped>
.dlp { display: inline-flex; align-items: center; gap: 4px; min-width: 0; }
/* owner, topic 593a804a: as wide as "YYYY-MM-DD HH:MM", no wider; SPL-1147
   (topic f9b6c844): then exactly ~2 mm (8 px, the right padding) of space.
   The width is set from .dlp__measure (sizeField); calc() is the fallback. */
.dlp__text { box-sizing: border-box; width: calc(16ch + 18px); max-width: 100%; padding-right: 8px; font-variant-numeric: tabular-nums; }
.dlp__measure { position: absolute; visibility: hidden; pointer-events: none; white-space: pre; width: auto; padding: 0; border: 0; left: -9999px; top: 0; }
.dlp__text[aria-invalid="true"] { border-color: var(--color-danger); }
.dlp__open { display: inline-flex; align-items: center; justify-content: center; padding: 4px 6px; }
/* SPL-1147 (owner, topic f9b6c844: "the calendar control is too wide"):
   196 px = 30% narrower than the old 280, smaller cells, a tighter head, one
   compact button row */
.dlp__pop {
  position: fixed;
  z-index: var(--z-popover);
  width: 196px;
  max-width: calc(100vw - 16px);
  box-sizing: border-box;
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  padding: 6px;
  box-shadow: var(--focus-3d);
  display: flex;
  flex-direction: column;
  gap: 4px;
  font-size: 0.8125rem;
}
.dlp__head { display: flex; align-items: center; justify-content: space-between; gap: 2px; }
.dlp__month { flex: 1; text-align: center; font-weight: 600; font-variant-numeric: tabular-nums; }
.dlp__close { display: inline-flex; align-items: center; justify-content: center; padding: 2px; min-height: 0; border: 0; background: transparent; color: var(--color-muted); cursor: pointer; }
.dlp__close:hover { color: inherit; background: var(--color-surface-hover); }
.dlp__nav { padding: 0 6px; min-height: 0; font-size: 0.9375rem; line-height: 1.4; }
.dlp__grid { width: 100%; border-collapse: collapse; table-layout: fixed; }
.dlp__grid td { padding: 0; text-align: center; }
.dlp__wd { font-size: 0.6875rem; font-weight: 500; color: var(--color-muted); padding: 1px 0; }
.dlp__day {
  width: 100%;
  padding: 2px 0;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: inherit;
  font: inherit;
  font-size: 0.75rem;
  line-height: 1.4;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
}
.dlp__day:hover { background: var(--color-surface-hover); }
.dlp__day--out { color: var(--color-muted); }
.dlp__day--today { border-color: var(--color-border-strong); }
.dlp__day--on { background: var(--color-accent); color: var(--color-on-accent); }
.dlp__time { display: flex; align-items: center; gap: 6px; }
.dlp__time select { min-width: 5rem; font-size: 0.75rem; padding: 1px 4px; }
.dlp__foot { display: flex; justify-content: flex-end; gap: 4px; flex-wrap: nowrap; }
.dlp__foot .btn { padding: 2px 8px; min-height: 0; font-size: 0.75rem; line-height: 1.4; }
/* SPL-992 (epic SPL-988): on a phone every control is a >= 44 px touch target */
@media (max-width: 820px) {
  .dlp__text { min-height: var(--tap, 44px); font-size: 1rem; }
  .dlp__open, .dlp__nav, .dlp__close { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
  .dlp__pop { width: min(340px, calc(100vw - 16px)); }
  .dlp__day { min-height: 40px; font-size: 0.9375rem; }
  .dlp__time select, .dlp__foot .btn { min-height: var(--tap, 44px); }
}
</style>
