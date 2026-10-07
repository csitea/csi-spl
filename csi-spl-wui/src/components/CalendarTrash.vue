<!-- spec 097 T017 (G13, spec 4.8 and 5.1.4): the calendar's trash, opened from
     the calendar menu. It lists the events the viewer deleted in the last 30
     days, newest first (GET /v1/calendar/trash), each with Restore (POST
     .../restore: back with the same id). A UiDialog, so at <= 600 px it is a
     full-screen view; each row is full width and Restore a 44 px target.
     Loaded lazily (LazyCalendarTrash) the first time the menu opens it. -->
<template>
  <UiDialog :open="open" :title="t('calendar_trash.title')" size="md" @update:open="emit('update:open', $event)">
    <div class="cal-trash" data-test="calendar-trash" :data-state="state">
      <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
      <p v-else-if="state === 'failed'" class="muted" role="alert" data-test="calendar-trash-failed">{{ t('calendar_trash.load_failed') }}</p>
      <p v-else-if="!list.length" class="muted" data-test="calendar-trash-empty">{{ t('calendar_trash.empty') }}</p>
      <ul v-else class="cal-trash__list">
        <li v-for="ev in list" :key="ev.id" class="cal-trash__row" data-test="calendar-trash-item" :data-id="ev.id">
          <span class="cal-trash__what">
            <span class="cal-trash__title">{{ ev.title }}</span>
            <span class="muted cal-trash__when" dir="ltr">{{ when(ev) }}</span>
          </span>
          <button
            type="button"
            class="btn cal-trash__restore"
            data-test="calendar-trash-restore"
            :disabled="busy !== ''"
            @click="restore(ev)"
          >{{ t('calendar_trash.restore') }}</button>
        </li>
      </ul>
      <p v-if="error" class="cal-trash__error" role="alert" data-test="calendar-trash-error">{{ t(error) }}</p>
      <p class="muted cal-trash__hint">{{ t('calendar_trash.hint') }}</p>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calendarRestore, calendarTrash } from '~/utils/calendar-events-api.mjs'
import { calEventDay } from '~/utils/calendar-drag.mjs'
import { isoClock } from '~/utils/date-iso.mjs'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

const props = defineProps<{ open: boolean, today: string }>()
const emit = defineEmits<{ 'update:open': [boolean], restored: [CalendarItem] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const list = shallowRef<CalendarItem[]>([])
const state = ref<'loading' | 'ready' | 'failed'>('loading')
const busy = ref('')
const error = ref('')

const when = (ev: CalendarItem) => (ev.all_day ? calEventDay(ev) : `${calEventDay(ev)} ${isoClock(ev.starts_at)}`)

async function load() {
  state.value = 'loading'
  error.value = ''
  try {
    list.value = await withSessionRetry(api, () => calendarTrash(api))
    state.value = 'ready'
  } catch {
    list.value = []
    state.value = 'failed'
  }
}
watch(() => props.open, (o) => { if (o) void load() }, { immediate: true })

async function restore(ev: CalendarItem) {
  busy.value = ev.id
  error.value = ''
  try {
    const back = await withSessionRetry(api, () => calendarRestore(api, ev.id, props.today))
    list.value = list.value.filter((x) => x.id !== ev.id)
    window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
    emit('restored', back as CalendarItem)
  } catch {
    error.value = 'calendar_trash.restore_failed'
  } finally {
    busy.value = ''
  }
}
</script>

<style scoped>
.cal-trash { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.cal-trash__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.cal-trash__row {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 6px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
}
.cal-trash__what { display: flex; flex-direction: column; flex: 1 1 auto; min-width: 0; }
.cal-trash__title { font-weight: 600; overflow-wrap: anywhere; }
.cal-trash__when { font-size: 0.8125rem; }
.cal-trash__restore { flex: none; min-height: var(--tap); min-width: var(--tap); }
.cal-trash__error { margin: 0; color: var(--color-danger); }
.cal-trash__hint { margin: 0; font-size: 0.8125rem; }
</style>
