<!-- Spec 107 E3, T083 (owner Q31..Q34 cut, 23.7): the one-tap week strip on
     top of the phone calendar (CalendarPhone places it first in the current
     page's scroll, so it covers nothing and the view keeps its height). While the period holding today is open (or
     returned) and has closed days with open rows, it reads "N days to
     approve · [Approve]"; one tap writes what the banner's Approve N days
     writes (T013): hoursApproveEntries(body, 'closed') in one PUT
     /v1/me/hours (useHoursWrite). The write sends HOURS_CHANGED_EVENT,
     every view re-reads, and the strip goes once nothing is open. No open
     day: no strip. Its own lazy chunk (CalendarPhone mounts it as
     LazyCalendarHoursWeekStrip). -->
<template>
  <div v-if="count > 0" class="hours-strip" role="region" :aria-label="text" data-test="hours-week-approve" :data-open="count" :data-state="hours.state.value">
    <span class="hours-strip__text" data-test="hours-week-approve-text">{{ text }}</span>
    <button
      type="button"
      class="btn primary hours-strip__btn"
      data-test="hours-week-approve-btn"
      :aria-label="t('hours_cal.approve_open', { n: count }, count)"
      :disabled="w.busy.value"
      @click="approve"
    >{{ t('hours_cal.strip_approve') }}</button>
    <p v-if="w.error.value" class="hours-strip__error" role="alert" data-test="hours-week-approve-error">{{ t(w.error.value) }}</p>
  </div>
  <!-- no open day: no strip; the read's state stays readable so a test can wait for it -->
  <span v-else hidden data-test="hours-week-approve" data-open="0" :data-state="hours.state.value" />
</template>

<script setup lang="ts">
import { hoursBanner } from '~/utils/hours-calendar.mjs'
import { hoursApproveEntries } from '~/utils/hours-mine.mjs'
import { useCalendarHours, useHoursWrite } from '~/composables/useCalendarHours'

const props = defineProps<{ today: string }>()
const { t } = useI18n({ useScope: 'global' })

/* the period holding today, whatever period the calendar shows */
const hours = useCalendarHours(() => ({ first: props.today, last: props.today }), () => props.today)
const body = computed(() => hours.bodies.value[0] || null)
const writable = computed(() => ['open', 'returned'].includes(String(body.value?.period?.state || 'open')))
const count = computed(() => (body.value && writable.value ? hoursBanner(body.value).openDays.length : 0))
const text = computed(() => t('hours_cal.strip_open', { n: count.value }, count.value))

const w = useHoursWrite(() => String(body.value?.today || props.today))
async function approve() {
  const entries = body.value ? hoursApproveEntries(body.value, 'closed') : []
  if (entries.length) await w.write({ entries })
}
</script>

<style scoped>
.hours-strip {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  box-sizing: border-box;
  padding: 6px 6px 6px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-selected);
  color: var(--color-heading);
}
.hours-strip__text {
  flex: 1 1 auto;
  min-width: 0;
  font-weight: 600;
}
.hours-strip__btn {
  flex: 0 0 auto;
  min-height: var(--tap);
}
.hours-strip__error {
  flex: 1 1 100%;
  margin: 0;
  color: var(--color-danger);
}
</style>
