<!-- Spec 107 v1.2 T011 (owner R9, R10): the body of the calendar entry dialog
     of type Working hours - one day. The period's banner (open days, the
     freeze, a returned note), the day's total, then its rows: the day's
     discussions first, each a link to its topic with its time and blocks
     (R10: "each time a user participates in a discussion those discussion
     links will be shown in the description of the hours"), then meetings,
     channels and "other". Read only here: T013 adds approve, T014 the
     stepper, + Add, why and the note per line. Its own lazy chunk; the
     desktop dialog (CalendarEventDialog) and the phone sheet
     (CalendarPhoneSheet) both host it. -->
<template>
  <div class="hours-day" data-test="hours-day" :data-day="day" :data-state="state">
    <p v-if="banner" class="hours-day__banner" data-test="hours-day-banner" :data-open="banner.openDays.length">{{ bannerText }}</p>
    <p v-if="banner && banner.state === 'returned' && banner.note" class="hours-day__note" data-test="hours-day-returned">{{ t('hours_cal.banner_returned', { note: banner.note }) }}</p>
    <p class="hours-day__total" data-test="hours-day-total">
      <span>{{ t('hours_cal.total') }}</span>
      <strong dir="ltr">{{ hoursHhmm(data ? data.total : 0) }}</strong>
      <span v-if="data && data.frozen" class="hours-day__tag" data-test="hours-day-frozen"><UiIcon name="lock" :size="12" />{{ t('hours_cal.state_frozen') }}</span>
    </p>
    <p v-if="state === 'loading' && !data" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'failed' && !data" class="muted" role="alert" data-test="hours-day-failed">{{ t('hours_cal.load_failed') }}</p>
    <p v-else-if="!rows.length" class="muted" data-test="hours-day-empty">{{ t('hours_cal.empty') }}</p>
    <ul v-else class="hours-day__rows" :aria-label="t('hours_cal.rows')">
      <li
        v-for="r in rows"
        :key="r.target"
        class="hours-day__row"
        :class="{ 'hours-day__row--rejected': r.state === 'rejected' }"
        data-test="hours-day-row"
        :data-target="r.target"
        :data-kind="r.view.kind"
        :data-row-state="r.state"
      >
        <span class="hours-day__what">
          <NuxtLink v-if="r.view.href" class="hours-day__link" data-test="hours-day-link" :to="localePath(r.view.href)" @click="emit('navigate')">{{ r.name }}</NuxtLink>
          <span v-else class="hours-day__name">{{ r.name }}</span>
          <small v-if="r.blocks" class="muted hours-day__blocks" dir="ltr">{{ r.blocks }}</small>
          <small v-if="r.note" class="hours-day__rownote" data-test="hours-day-note">{{ r.note }}</small>
        </span>
        <span class="hours-day__min" dir="ltr">{{ hoursHhmm(r.minutes) }}</span>
        <span class="hours-day__state muted">{{ t('hours_cal.row_' + (r.state === 'approved' || r.state === 'rejected' ? r.state : 'suggested')) }}</span>
      </li>
    </ul>
  </div>
</template>

<script setup lang="ts">
import { hoursBanner, hoursFreezeText, hoursBlocksText, hoursHhmm, hoursSortRows, hoursTarget } from '~/utils/hours-calendar.mjs'
import type { HoursDay, HoursRow } from '~/composables/useCalendarHours'
import { useChannelStore } from '~/stores/channel'
import { useViewerStore } from '~/stores/viewer'

const props = defineProps<{
  day: string
  data?: HoursDay
  /** the GET /v1/me/hours answer holding the day (banner), and its zone */
  body?: Record<string, any> | null
  tz?: string
  state?: string
  /** known names per target: topic subjects, '#channel' */
  names?: Record<string, string>
}>()
const emit = defineEmits<{ navigate: [] }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const viewer = useViewerStore()
const channel = useChannelStore()

/* a topic's subject and a channel's name from what the app already holds;
   an unknown topic shows its short id (hoursTarget) */
const known = computed(() => {
  const out: Record<string, string> = {}
  for (const tp of viewer.topics as { task_id?: string, subject?: string }[]) {
    if (tp.task_id && tp.subject) out[`t:${tp.task_id}`] = tp.subject
  }
  for (const c of channel.channels) {
    if (c.channel_id && c.name) out[`ch:${c.channel_id}`] = `#${c.name}`
  }
  return { ...out, ...(props.names || {}) }
})
/* a phone opens the calendar first: read the topic list once so a
   discussion shows its subject, not its short id */
let topicsAsked = false
watch(() => props.data, (d) => {
  if (topicsAsked || viewer.topics.length > 0 || !(d?.rows || []).some((r) => r.target.startsWith('t:'))) return
  topicsAsked = true
  void viewer.loadTopics()
}, { immediate: true })

const banner = computed(() => (props.body ? hoursBanner(props.body) : null))
const bannerText = computed(() => {
  const b = banner.value
  if (!b) return ''
  const at = hoursFreezeText(b.freezesAt, props.tz)
  return b.openDays.length
    ? t('hours_cal.banner_open', { n: b.openDays.length, at })
    : t('hours_cal.banner_none', { at })
})

const rows = computed(() => (hoursSortRows(props.data?.rows || []) as HoursRow[]).map((r) => {
  const view = hoursTarget(r.target, known.value)
  const name = view.label || t(view.kind === 'meeting' ? 'hours_cal.meeting' : 'hours_cal.other')
  return { ...r, view, name, blocks: hoursBlocksText(r.blocks, props.tz), note: String(r.note || '') }
}))
</script>

<style scoped>
.hours-day { display: flex; flex-direction: column; gap: 10px; min-inline-size: 0; }
.hours-day__banner,
.hours-day__note { margin: 0; padding: 8px 10px; border-radius: var(--radius-sm); background: var(--color-selected); }
.hours-day__total { display: flex; align-items: center; gap: 8px; margin: 0; }
.hours-day__total strong { font-variant-numeric: tabular-nums; }
.hours-day__tag { display: inline-flex; align-items: center; gap: 4px; font-size: 0.75rem; }
.hours-day__rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.hours-day__row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto auto;
  align-items: center;
  gap: 8px;
  min-block-size: 44px;
  padding: 4px 0;
  border-block-end: 1px solid var(--color-border);
}
.hours-day__row--rejected .hours-day__what,
.hours-day__row--rejected .hours-day__min { text-decoration: line-through; opacity: 0.7; }
.hours-day__what { display: flex; flex-direction: column; min-inline-size: 0; }
.hours-day__link,
.hours-day__name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hours-day__blocks,
.hours-day__rownote { overflow-wrap: anywhere; }
.hours-day__min { font-variant-numeric: tabular-nums; font-weight: 600; }
.hours-day__state { font-size: 0.75rem; }
</style>
