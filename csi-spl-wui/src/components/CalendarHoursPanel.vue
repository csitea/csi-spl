<!-- Spec 107 v1.2 T011 (owner R11, t1 a28dc5c9 msg 5134bd6b: "the right side
     of the calendar will have tabs for hours"). The calendar page's third
     column on a desktop, a sheet from the calendar menu on a phone. Tabs:
     Mine (every member) - the period holding the shown day, its banner and
     its days newest first with their total and state; a click on a day
     opens that day's Working hours dialog (`open-day`). Team and Download
     show only to a holder of hours.read (T015, on T008 / T009:
     CalendarHoursTeam, CalendarHoursDownload). T013: [Approve N
     days] in Mine's banner, Approve week (closed days only) and a returned
     period's Resubmit. Its own lazy chunk. -->
<template>
  <section class="hours-panel" data-test="hours-panel" :data-tab="tab" :data-state="hours.state.value">
    <header class="hours-panel__head">
      <h3 class="hours-panel__title">{{ t('hours_cal.panel_title') }}</h3>
      <button
        v-if="closable"
        type="button"
        class="icon-btn"
        data-test="hours-panel-close"
        :aria-label="t('common.close')"
        :title="t('common.close')"
        @click="emit('close')"
      ><UiIcon name="x" :size="16" /></button>
    </header>
    <div v-if="tabs.length > 1" class="hours-panel__tabs" role="tablist" :aria-label="t('hours_cal.panel_title')">
      <button
        v-for="id in tabs"
        :key="id"
        type="button"
        role="tab"
        class="hours-panel__tab"
        :class="{ 'hours-panel__tab--on': tab === id }"
        :data-test="'hours-panel-tab-' + id"
        :aria-selected="tab === id ? 'true' : 'false'"
        @click="tab = id"
      >{{ t('hours_cal.tab_' + id) }}</button>
    </div>
    <div v-if="tab === 'mine'" class="hours-panel__body" role="tabpanel" data-test="hours-panel-mine">
      <div v-if="banner" class="hours-panel__banner" data-test="hours-panel-banner" :data-open="banner.openDays.length">
        <span>{{ bannerText }}</span>
        <button v-if="periodOpen && banner.openDays.length" type="button" class="btn primary hours-panel__btn" data-test="hours-panel-approve-open" :disabled="w.busy.value" @click="approveClosed">{{ t('hours_cal.approve_open', { n: banner.openDays.length }) }}</button>
      </div>
      <div v-if="banner && banner.state === 'returned'" class="hours-panel__banner" data-test="hours-panel-returned">
        <span>{{ t('hours_cal.banner_returned', { note: banner.note }) }}</span>
        <button type="button" class="btn primary hours-panel__btn" data-test="hours-panel-resubmit" :disabled="w.busy.value" @click="resubmit">{{ t('hours_cal.resubmit') }}</button>
      </div>
      <p v-if="w.error.value" class="hours-panel__error" role="alert" data-test="hours-panel-error">{{ t(w.error.value) }}</p>
      <p v-if="hours.state.value === 'failed'" class="muted" role="alert" data-test="hours-panel-failed">{{ t('hours_cal.load_failed') }}</p>
      <ul class="hours-panel__days">
        <li v-for="d in days" :key="d.date">
          <button
            type="button"
            class="hours-panel__day"
            :class="{ 'hours-panel__day--today': d.today }"
            data-test="hours-panel-day"
            :data-day="d.date"
            :data-total="d.total"
            :data-state="d.state"
            @click="emit('open-day', d.date)"
          >
            <span class="hours-panel__date" dir="ltr">{{ dayHead(d.date) }}</span>
            <span class="hours-panel__mark">
              <UiIcon v-if="d.state === 'frozen' || d.state === 'final'" name="lock" :size="12" />
              <span v-else-if="d.state === 'open' || d.state === 'returned'" class="hours-panel__dot" aria-hidden="true" />
              <span v-if="d.state" class="muted">{{ t('hours_cal.state_' + d.state) }}</span>
            </span>
            <span class="hours-panel__total" dir="ltr">{{ hoursHhmm(d.total) }}</span>
          </button>
        </li>
      </ul>
      <p v-if="periodTotal >= 0" class="hours-panel__sum" data-test="hours-panel-sum">
        <span>{{ t('hours_cal.period_total') }}</span>
        <strong dir="ltr">{{ hoursHhmm(periodTotal) }}</strong>
      </p>
      <button
        v-if="periodOpen"
        type="button"
        class="btn primary hours-panel__week"
        data-test="hours-panel-approve-week"
        :data-open="openCount"
        :disabled="w.busy.value || openCount === 0"
        @click="approveClosed"
      >{{ t('hours_cal.approve_week', { n: openCount }) }}</button>
    </div>
    <!-- T015: Team and Download, each its own lazy chunk, fetched when its tab shows -->
    <div v-else class="hours-panel__body" role="tabpanel" :data-test="'hours-panel-' + tab">
      <LazyCalendarHoursTeam v-if="tab === 'team'" :focus="focus" :today="today" :can-approve="canApprove" />
      <LazyCalendarHoursDownload v-else :focus="focus" :today="today" />
    </div>
  </section>
</template>

<script setup lang="ts">
import { calWeekday } from '~/utils/calendar-year.mjs'
import { hoursBanner, hoursFreezeText, hoursHhmm, hoursLineState, hoursShowsLine } from '~/utils/hours-calendar.mjs'
import { hoursApproveEntries, hoursOpenCount } from '~/utils/hours-mine.mjs'
import { useCalendarHours, useHoursWrite } from '~/composables/useCalendarHours'
import { useAccessStore } from '~/stores/access'

const props = defineProps<{ focus: string, today: string, closable?: boolean }>()
const emit = defineEmits<{ 'open-day': [day: string], close: [] }>()
const { t } = useI18n({ useScope: 'global' })
const access = useAccessStore()

/* the period holding the shown day: one answer */
const hours = useCalendarHours(() => ({ first: props.focus, last: props.focus }), () => props.today)
const body = computed(() => hours.bodies.value[0] || null)
const banner = computed(() => (body.value ? hoursBanner(body.value) : null))
const bannerText = computed(() => {
  const b = banner.value
  if (!b) return ''
  const at = hoursFreezeText(b.freezesAt, hours.tz.value)
  return b.openDays.length ? t('hours_cal.banner_open', { n: b.openDays.length, at }) : t('hours_cal.banner_none', { at })
})

/* T013 (spec 4.1, 5.4): Approve N days / Approve week approve the closed
   days only; a returned period's Resubmit. The panel re-reads on the write's
   HOURS_CHANGED_EVENT, as every calendar view does. */
const w = useHoursWrite(() => String(body.value?.today || props.today))
const periodOpen = computed(() => Boolean(body.value) && ['open', 'returned'].includes(String(body.value?.period?.state || 'open')))
const openCount = computed(() => (body.value ? hoursOpenCount(body.value) : 0))
async function approveClosed() {
  const entries = body.value ? hoursApproveEntries(body.value, 'closed') : []
  if (entries.length) await w.write({ entries })
}
async function resubmit() {
  const d = String(body.value?.period?.start || '')
  if (d) await w.write({ resubmit: d })
}

/* spec 5.4: Team and Download for a holder of hours.read only (never fail open) */
const holds = (perm: string) => Boolean(access.me && Array.isArray(access.me.permissions) && access.me.permissions.includes(perm))
const canRead = computed(() => holds('hours.read'))
/* T015: Approve / Return for a holder of hours.approve (the hub re-checks) */
const canApprove = computed(() => holds('hours.approve'))
const tabs = computed(() => (canRead.value ? ['mine', 'team', 'download'] : ['mine']))
const tab = ref('mine')
watch(tabs, (ids) => { if (!ids.includes(tab.value)) tab.value = 'mine' })
onMounted(() => { if (!access.me) void access.load() })

/* the period's days up to the member's today, newest first; a day after
   today has nothing to show yet */
const days = computed(() => {
  const idx = hours.index.value
  const out = []
  for (const d of [...idx.values()].sort((a, b) => (a.date < b.date ? 1 : -1))) {
    if (d.date > props.today || !hoursShowsLine(d.date, idx)) continue
    out.push({ date: d.date, today: d.today || d.date === props.today, total: d.total, state: hoursLineState(d) })
  }
  return out
})
const periodTotal = computed(() => (hours.state.value === 'ready' ? days.value.reduce((n, d) => n + d.total, 0) : -1))

function dayHead(iso: string) {
  return `${t('calendar.weekdays.d' + calWeekday(iso))} ${iso.slice(5)}`
}
</script>

<style scoped>
.hours-panel { display: flex; flex-direction: column; min-block-size: 0; min-inline-size: 0; gap: 8px; padding: 8px 12px; }
.hours-panel__head { display: flex; align-items: center; gap: 8px; }
.hours-panel__title { flex: 1 1 auto; margin: 0; font-size: 1rem; }
.hours-panel__tabs { display: flex; gap: 4px; border-block-end: 1px solid var(--color-border); }
.hours-panel__tab {
  min-block-size: 44px;
  padding: 0 12px;
  border: 0;
  border-block-end: 2px solid transparent;
  background: transparent;
  color: inherit;
  font: inherit;
  cursor: pointer;
}
.hours-panel__tab--on { border-block-end-color: var(--color-accent); font-weight: 600; }
.hours-panel__body { display: flex; flex-direction: column; gap: 8px; min-block-size: 0; overflow: auto; }
.hours-panel__banner { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0; padding: 8px 10px; border-radius: var(--radius-sm); background: var(--color-selected); }
.hours-panel__banner > span { flex: 1 1 10rem; min-inline-size: 0; overflow-wrap: anywhere; }
.hours-panel__btn { min-block-size: 44px; }
.hours-panel__error { margin: 0; font-weight: 600; }
.hours-panel__week { min-block-size: 44px; }
.hours-panel__btn:disabled,
.hours-panel__week:disabled { opacity: 0.5; cursor: default; }
.hours-panel__days { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.hours-panel__day {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 8px;
  inline-size: 100%;
  min-block-size: 44px;
  padding: 4px 8px;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.hours-panel__day:hover { background: var(--color-selected); }
.hours-panel__day--today .hours-panel__date { font-weight: 600; }
.hours-panel__mark { display: inline-flex; align-items: center; gap: 4px; min-inline-size: 0; font-size: 0.75rem; }
.hours-panel__dot { inline-size: 8px; block-size: 8px; border-radius: 50%; background: var(--color-accent); }
.hours-panel__total { font-variant-numeric: tabular-nums; font-weight: 600; }
.hours-panel__sum { display: flex; justify-content: space-between; margin: 0; padding: 8px; border-block-start: 1px solid var(--color-border); }
</style>
