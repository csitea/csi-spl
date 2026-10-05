<!-- Spec 089 T006 (owner D4): the calendar reminder pop-up, Google Calendar
     style: the event's title and time, Open and Dismiss. Mounted by
     plugins/calendar-reminders.client.ts the first time a reminder is due
     (its own chunk, never in the initial JS); the plugin hands it the due
     list with set(). Open and Dismiss both close the reminder for good. -->
<template>
  <div
    v-if="items.length"
    class="cal-remind"
    role="region"
    :aria-label="t('calendar_reminder.region')"
    data-test="calendar-reminders"
    data-build-watch-ignore
  >
    <div
      v-for="ev in items"
      :key="ev.id + '@' + ev.remind_at"
      class="cal-remind__card"
      role="alert"
      data-test="calendar-reminder"
      :data-event-id="ev.id"
    >
      <div class="cal-remind__label">{{ t('calendar_reminder.label') }}</div>
      <div class="cal-remind__title" data-test="calendar-reminder-title">{{ ev.title }}</div>
      <div class="cal-remind__time" data-test="calendar-reminder-time">{{ when(ev) }}</div>
      <div class="cal-remind__actions">
        <button
          v-if="canOpen"
          type="button"
          class="btn cal-remind__btn"
          data-test="calendar-reminder-open"
          @click="open(ev)"
        >
          {{ t('calendar_reminder.open') }}
        </button>
        <button
          type="button"
          class="btn cal-remind__btn"
          data-test="calendar-reminder-dismiss"
          @click="emit('dismiss', ev)"
        >
          {{ t('calendar_reminder.dismiss') }}
        </button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { isoDate, isoDateTime, isoClock } from '~/utils/date-iso.mjs'

type Reminder = { id: string, title: string, starts_at: string, ends_at: string, all_day: boolean, remind_at: string }

const emit = defineEmits<{ dismiss: [ev: Reminder] }>()
const { t } = useI18n()
const router = useRouter()
const localePath = useLocalePath()
const items = ref<Reminder[]>([])

/* the calendar section (T007) may not be in this build yet: no Open then */
const calendarPath = computed(() => localePath('/calendar'))
const canOpen = computed(() => router.resolve(calendarPath.value).matched.some((r) => !String(r.path).includes(':')))

/** Start, and the end's clock on the same day: "2026-10-05 09:00 - 10:00". */
function when(ev: Reminder): string {
  if (ev.all_day) return `${isoDate(ev.starts_at)} · ${t('calendar_reminder.all_day')}`
  const start = isoDateTime(ev.starts_at)
  if (!ev.ends_at || ev.ends_at === ev.starts_at) return start
  const end = isoDate(ev.ends_at) === isoDate(ev.starts_at) ? isoClock(ev.ends_at) : isoDateTime(ev.ends_at)
  return `${start} - ${end}`
}

function open(ev: Reminder) {
  void router.push({ path: calendarPath.value, query: { event: ev.id } })
  emit('dismiss', ev)
}

defineExpose({ set(list: Reminder[]) { items.value = list.slice() } })
</script>

<style scoped>
.cal-remind {
  position: fixed;
  right: 1rem;
  bottom: 1rem;
  z-index: var(--z-snackbar);
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  width: min(22rem, calc(100vw - 2rem));
  max-height: calc(100vh - 2rem);
  overflow-y: auto;
}
.cal-remind__card {
  box-sizing: border-box;
  padding: 0.75rem 0.875rem;
  border: 1px solid var(--color-accent);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  color: var(--color-fg);
  box-shadow: var(--focus-3d);
}
.cal-remind__label {
  font-size: 0.75rem;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.cal-remind__title {
  margin-top: 0.125rem;
  font-weight: 600;
  overflow-wrap: anywhere;
}
.cal-remind__time {
  margin-top: 0.125rem;
  font-size: 0.875rem;
  font-variant-numeric: tabular-nums;
}
.cal-remind__actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 0.625rem;
}
.cal-remind__btn { min-height: 2.25rem; }
@media (pointer: coarse) {
  .cal-remind__btn { min-height: 2.75rem; }
}
</style>
