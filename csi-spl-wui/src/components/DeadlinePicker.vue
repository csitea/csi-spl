<!-- owner, topic 778ad161: "it should be a calendar control with the
     yyyy-mm-dd HH:MM DEADLINE time format". A text field that shows and takes
     YYYY-MM-DD HH:MM in every locale, and a button that opens a month grid
     (Monday first) plus a 24-hour time. Never a native type=date input: the
     browser draws those in its own locale (mm/dd/yyyy for the owner).
     v-model is the LOCAL 'YYYY-MM-DDTHH:MM' ('' = none); the page converts
     to and from the RFC 3339 UTC the hub stores (utils/issues-view.mjs). -->
<template>
  <div ref="root" class="dlp">
    <input
      type="text"
      class="dlp__text"
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
      <div class="dlp__head">
        <button type="button" class="btn ghost dlp__nav" data-test="deadline-picker-prev" :aria-label="t('picker.prev_month')" :title="t('picker.prev_month')" @click="month = shiftMonth(month, -1)">‹</button>
        <span class="dlp__month" data-test="deadline-picker-month" aria-live="polite">{{ month }}</span>
        <button type="button" class="btn ghost dlp__nav" data-test="deadline-picker-next" :aria-label="t('picker.next_month')" :title="t('picker.next_month')" @click="month = shiftMonth(month, 1)">›</button>
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
        <button type="button" class="btn" data-test="deadline-picker-done" @click="close(true)">{{ t('picker.done') }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { isoDate } from '~/utils/date-iso.mjs'
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

function place() {
  const r = root.value?.getBoundingClientRect()
  if (!r) return
  const w = 280
  const left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8))
  const below = window.innerHeight - r.bottom
  const style: Record<string, string> = { left: `${Math.round(left)}px` }
  if (below < 360 && r.top > below) style.bottom = `${Math.round(window.innerHeight - r.top + 4)}px`
  else style.top = `${Math.round(r.bottom + 4)}px`
  popStyle.value = style
}

async function openPop() {
  today.value = isoDate(new Date())
  month.value = monthOf(props.modelValue, today.value)
  focusDate.value = picked.value.date || today.value
  place()
  open.value = true
  await nextTick()
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
.dlp__text { width: 11.5rem; max-width: 100%; font-variant-numeric: tabular-nums; }
.dlp__text[aria-invalid="true"] { border-color: var(--color-danger); }
.dlp__open { display: inline-flex; align-items: center; justify-content: center; padding: 4px 6px; }
.dlp__pop {
  position: fixed;
  z-index: 40;
  width: 280px;
  max-width: calc(100vw - 16px);
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  padding: 8px;
  box-shadow: var(--focus-3d);
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.dlp__head { display: flex; align-items: center; justify-content: space-between; gap: 4px; }
.dlp__month { font-weight: 600; font-variant-numeric: tabular-nums; }
.dlp__nav { padding: 2px 10px; font-size: 1rem; line-height: 1; }
.dlp__grid { width: 100%; border-collapse: collapse; table-layout: fixed; }
.dlp__grid td { padding: 1px; text-align: center; }
.dlp__wd { font-size: 0.75rem; font-weight: 500; color: var(--color-muted); padding: 2px 0; }
.dlp__day {
  width: 100%;
  padding: 4px 0;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: inherit;
  font: inherit;
  font-size: 0.8125rem;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
}
.dlp__day:hover { background: var(--color-surface-hover); }
.dlp__day--out { color: var(--color-muted); }
.dlp__day--today { border-color: var(--color-border-strong); }
.dlp__day--on { background: var(--color-accent); color: var(--color-on-accent); }
.dlp__time { display: flex; align-items: center; gap: 8px; }
.dlp__time select { min-width: 5.5rem; }
.dlp__foot { display: flex; justify-content: flex-end; gap: 6px; flex-wrap: wrap; }
</style>
