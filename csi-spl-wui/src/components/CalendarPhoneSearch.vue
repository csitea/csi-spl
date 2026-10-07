<!-- spec 106 T010: the phone calendar's search (spec 4.6, FR-010). The search
     button turns the header into a search field (one tap, spec 5); the
     answer of GET /v1/calendar/search (097 4.7) over 089's 3-year range is a
     vertical list grouped by day, all-day events on their UTC date (S4-3).
     A tap on a result emits `open` with its day and event: CalendarPhone opens
     that day in Day and T009's peek on the event. More results come by
     next_cursor. A dialog over the shell (S4-2 e): Escape or the close button
     emits `close`; focus returns to the control that opened it. -->
<template>
  <div
    class="calsearch"
    role="dialog"
    aria-modal="true"
    :aria-label="t('calendar_phone.search')"
    data-test="calphone-searchbox"
    :data-state="state"
  >
    <div class="calsearch__head">
      <button
        type="button"
        class="calsearch__btn"
        data-test="calphone-search-close"
        :aria-label="t('common.close')"
        :title="t('common.close')"
        @click="emit('close')"
      >
        <UiIcon name="x" :size="20" />
      </button>
      <input
        ref="inputEl"
        v-model="q"
        type="search"
        class="calsearch__input"
        data-test="calphone-search-input"
        enterkeyhint="search"
        autocomplete="off"
        maxlength="200"
        :aria-label="t('calendar_phone.search')"
        :placeholder="t('calendar_phone.search')"
        @keydown.enter.prevent="run(true)"
      >
    </div>
    <div class="calsearch__body" aria-live="polite">
      <p v-if="state === 'loading' && !groups.length" class="calsearch__note">{{ t('search.loading') }}</p>
      <p v-else-if="state === 'failed'" class="calsearch__note" data-test="calphone-search-failed">{{ t('calendar.load_failed') }}</p>
      <p v-else-if="state === 'ready' && !groups.length" class="calsearch__note" data-test="calphone-search-empty">{{ t('search.no_results') }}</p>
      <section v-for="g in groups" :key="g.day" class="calsearch__day" data-test="calphone-search-day" :data-day="g.day">
        <h3 class="calsearch__day-title">{{ g.title }}</h3>
        <ul class="calsearch__list">
          <li v-for="ev in g.items" :key="ev.id">
            <button
              type="button"
              class="calsearch__row"
              data-test="calphone-search-row"
              :data-id="ev.id"
              :data-day="g.day"
              @click="emit('open', g.day, ev)"
            >
              <span
                class="calsearch__dot"
                aria-hidden="true"
                :style="ev.color && CAL_COLORS.includes(ev.color) ? { background: `var(--cal-color-${ev.color})` } : undefined"
              />
              <span class="calsearch__time">{{ ev.all_day ? '' : isoClock(ev.starts_at) }}</span>
              <span class="calsearch__title">{{ ev.title }}</span>
            </button>
          </li>
        </ul>
      </section>
      <button
        v-if="cursor"
        type="button"
        class="calsearch__more"
        data-test="calphone-search-more"
        :disabled="state === 'loading'"
        @click="run(false)"
      >
        {{ t('search.load_more') }}
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { hubJsonHeaders } from '~/utils/hub-headers'
import { CAL_COLORS } from '~/utils/calendar-event-form.mjs'
import { calPhoneEventDays, calPhoneTitle } from '~/utils/calendar-phone-nav.mjs'
import { isoClock } from '~/utils/date-iso.mjs'

const props = defineProps<{ today: string }>()
const emit = defineEmits<{ open: [day: string, ev: CalendarItem], close: [] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const q = ref('')
const found = shallowRef<CalendarItem[]>([])
const cursor = ref('')
const state = ref<'idle' | 'loading' | 'ready' | 'failed'>('idle')

/* 089's range: 1 January of last year to 1 January in two years */
const year = Number(props.today.slice(0, 4))
const from = `${year - 1}-01-01T00:00:00Z`
const to = `${year + 2}-01-01T00:00:00Z`

const names = computed(() => ({
  months: Array.from({ length: 12 }, (_, i) => t(`calendar.months.m${i + 1}`)),
  weekdays: Array.from({ length: 7 }, (_, i) => t(`calendar.weekdays.d${i + 1}`)),
}))
const groups = computed(() => {
  const byDay = new Map<string, CalendarItem[]>()
  for (const ev of found.value) {
    const day = calPhoneEventDays(ev)[0]
    if (!day) continue
    const list = byDay.get(day) || []
    list.push(ev)
    byDay.set(day, list)
  }
  return [...byDay.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([day, items]) => ({ day, title: calPhoneTitle('day', day, names.value), items }))
})

async function fetchPage(text: string, after: string, signal: AbortSignal): Promise<{ events: CalendarItem[], next: string }> {
  if (api.mock) {
    const { mockCalendarItems } = await import('~/utils/calendar-mock.mjs')
    const needle = text.toLowerCase()
    const s = Date.parse(from)
    const e = Date.parse(to)
    const events = mockCalendarItems(props.today)
      .filter((x) => [x.title, x.description, x.location].some((v) => String(v || '').toLowerCase().includes(needle)))
      .filter((x) => Date.parse(x.starts_at) >= s && Date.parse(x.starts_at) < e)
      .sort((a, b) => a.starts_at.localeCompare(b.starts_at) || a.id.localeCompare(b.id))
    return { events, next: '' }
  }
  const p = new URLSearchParams({ q: text, from, to, limit: '50' })
  if (after) p.set('cursor', after)
  const res = await fetch(`${api.base}/v1/calendar/search?${p}`, { credentials: api.credentials, headers: hubJsonHeaders(api.token), signal })
  if (!res.ok) throw new Error('calendar search ' + res.status)
  const body = await res.json() as { events?: CalendarItem[], next_cursor?: string }
  return { events: Array.isArray(body?.events) ? body.events : [], next: String(body?.next_cursor || '') }
}

/* a newer query aborts the older one; `fresh` starts over, else the next page */
let ctl: AbortController | null = null
async function run(fresh: boolean) {
  const text = q.value.trim()
  ctl?.abort()
  if (!text) {
    found.value = []
    cursor.value = ''
    state.value = 'idle'
    return
  }
  const mine = new AbortController()
  ctl = mine
  const timer = setTimeout(() => mine.abort(), DOC_READ_TIMEOUT_MS)
  state.value = 'loading'
  try {
    const page = await fetchPage(text, fresh ? '' : cursor.value, mine.signal)
    if (mine.signal.aborted) return
    found.value = fresh ? page.events : [...found.value, ...page.events]
    cursor.value = page.next
    state.value = 'ready'
  } catch {
    if (mine.signal.aborted) return
    state.value = 'failed'
  } finally {
    clearTimeout(timer)
  }
}

/* the list follows the typing, 250 ms after the last key */
let debounce: ReturnType<typeof setTimeout> | undefined
watch(q, () => {
  clearTimeout(debounce)
  debounce = setTimeout(() => { void run(true) }, 250)
})

/* focus in on open, back to the opener on close (S4-2 e); Escape closes
   wherever focus is (a button disabled under it drops focus to the body) */
function onKey(e: KeyboardEvent) {
  if (e.key !== 'Escape') return
  e.preventDefault()
  e.stopPropagation()
  emit('close')
}
const inputEl = ref<HTMLInputElement | null>(null)
let opener: HTMLElement | null = null
onMounted(() => {
  opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
  inputEl.value?.focus()
  window.addEventListener('keydown', onKey, true)
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey, true)
  clearTimeout(debounce)
  ctl?.abort()
  if (opener?.isConnected) opener.focus()
})
</script>

<style scoped>
.calsearch {
  position: absolute;
  inset: 0;
  z-index: 5;
  display: flex;
  flex-direction: column;
  min-width: 0;
  padding-bottom: var(--composer-dock-h, 0px);
  box-sizing: border-box;
  overflow-x: clip;
  background: var(--color-bg);
}
.calsearch__head {
  display: flex;
  align-items: center;
  gap: 4px;
  min-height: 48px;
  padding: 1px 8px 1px 4px;
  box-sizing: border-box;
  min-width: 0;
  border-bottom: 1px solid var(--color-border);
}
.calsearch__btn {
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
.calsearch__input {
  flex: 1 1 auto;
  min-width: 0;
  min-height: var(--tap);
  padding: 0 12px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-surface);
  color: var(--color-fg);
  font-family: inherit;
  font-size: 1rem;
}
.calsearch__body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior-y: contain;
  padding: 8px 16px 72px;
}
.calsearch__note {
  margin: 12px 0;
  font-size: 0.875rem;
  color: var(--color-muted);
}
.calsearch__day { margin-bottom: 8px; }
.calsearch__day-title {
  margin: 8px 0 4px;
  font-size: 0.875rem;
  font-weight: 600;
  color: var(--color-heading);
}
.calsearch__list {
  margin: 0;
  padding: 0;
  list-style: none;
}
.calsearch__row {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-width: 0;
  min-height: var(--tap);
  margin-bottom: 6px;
  padding: 0 12px;
  box-sizing: border-box;
  border: 0;
  border-radius: var(--radius-md);
  background: var(--color-surface);
  color: var(--color-fg);
  font-family: inherit;
  font-size: 0.875rem;
  text-align: start;
  cursor: pointer;
  box-shadow: var(--bevel-shine), var(--bevel-shade);
}
.calsearch__dot {
  flex: 0 0 auto;
  width: 10px;
  height: 10px;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
  box-shadow: var(--cal-dot-ring);
}
.calsearch__time {
  flex: 0 0 auto;
  min-width: 3em;
  color: var(--color-muted);
  font-variant-numeric: tabular-nums;
}
.calsearch__title {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.calsearch__more {
  min-height: var(--tap);
  padding: 0 16px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-surface);
  color: var(--color-fg);
  font-family: inherit;
  font-size: 0.875rem;
  cursor: pointer;
}
.calsearch button:focus-visible,
.calsearch__input:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
</style>
