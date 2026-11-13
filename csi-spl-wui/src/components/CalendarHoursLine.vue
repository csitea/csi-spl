<!-- Spec 107 v1.2 T011 (owner R9, t1 a28dc5c9 msg 37805fdf): "a simple line in
     the calendar by default for every working day". One button per day: the
     words Working hours, the day's total when there are minutes, and a dot
     when the day has suggestions or deltas to approve (frozen / final days a
     lock). A click opens the event dialog of type Working hours (`open`).
     Not a calendar event: drawn from GET /v1/me/hours (useCalendarHours).
     FR-41 (SPL-5440): a day above the workspace's average hours per day
     shows a warning mark and says so in its label; nothing is refused. -->
<template>
  <button
    type="button"
    class="cal-hours-line"
    :class="{ 'cal-hours-line--compact': compact }"
    data-test="calendar-hours-line"
    :data-day="day"
    :data-total="data ? data.total : 0"
    :data-state="lineState"
    :data-over="over > 0 ? over : undefined"
    :aria-label="label"
    :title="label"
    @click.stop="emit('open', day)"
    @pointerdown.stop
  >
    <UiIcon :name="lineState === 'frozen' || lineState === 'final' ? 'lock' : 'history'" :size="14" />
    <span class="cal-hours-line__name">{{ t('hours_cal.line') }}</span>
    <span v-if="data && data.total > 0" class="cal-hours-line__total" data-test="calendar-hours-total" dir="ltr">{{ hoursHhmm(data.total) }}</span>
    <UiIcon v-if="over > 0" name="alert-triangle" :size="14" class="cal-hours-line__over" data-test="calendar-hours-over" />
    <span v-if="lineState === 'open' || lineState === 'returned'" class="cal-hours-line__dot" data-test="calendar-hours-open" aria-hidden="true" />
  </button>
</template>

<script setup lang="ts">
import { hoursHhmm, hoursLineState } from '~/utils/hours-calendar.mjs'
import { hoursOverNorm } from '~/utils/hours-norm.mjs'
import type { HoursDay } from '~/composables/useCalendarHours'

const props = defineProps<{ day: string, data?: HoursDay, compact?: boolean }>()
const emit = defineEmits<{ open: [day: string] }>()
const { t } = useI18n({ useScope: 'global' })

const lineState = computed(() => hoursLineState(props.data))
const over = computed(() => (props.data ? hoursOverNorm(props.data.total, props.data.norm) : 0))
const label = computed(() => {
  const total = props.data && props.data.total > 0 ? ` ${hoursHhmm(props.data.total)}` : ''
  const st = lineState.value ? ` · ${t('hours_cal.state_' + lineState.value)}` : ''
  const ov = over.value > 0 && props.data ? ` · ${t('hours_cal.norm_over_short', { over: hoursHhmm(over.value), norm: hoursHhmm(props.data.norm) })}` : ''
  return `${t('hours_cal.line')}${total}${st}${ov}`
})
</script>

<style scoped>
.cal-hours-line {
  display: flex;
  align-items: center;
  gap: 6px;
  inline-size: 100%;
  min-block-size: 28px;
  padding: 2px 8px;
  border: 1px dashed var(--color-border);
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  font: inherit;
  font-size: 0.8125rem;
  text-align: start;
  cursor: pointer;
}
.cal-hours-line:hover { background: var(--color-selected); color: var(--color-fg); }
.cal-hours-line--compact { min-block-size: 44px; }
.cal-hours-line__name { flex: 1 1 auto; min-inline-size: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.cal-hours-line__total { font-variant-numeric: tabular-nums; color: var(--color-fg); font-weight: 600; }
.cal-hours-line__over { color: var(--color-warn); flex-shrink: 0; }
.cal-hours-line__dot { inline-size: 8px; block-size: 8px; border-radius: 50%; background: var(--color-accent); flex-shrink: 0; }
</style>
