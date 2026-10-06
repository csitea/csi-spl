<!-- spec 089 T008 v1 (owner msgs 12938ef0 + 72db6282): the calendar's event
     dialog - create and edit in one modal, "a bit more simple than the google
     calendar". UiDialog owns the modal behaviour; this owns the form, and
     utils/calendar-event-form.mjs owns its rules (pure, unit tested).

     Any member adds an event (the hub's `notes.send`). It is public unless
     the Private switch is on, and the switch shows only to the event's
     creator - for a new event, the viewer. The hub's `private_owner_only`
     is the rule; the hidden switch is convenience (089 4.2).

     The fields stand in spec 097 section 5's order, so 097 T014..T016 add
     theirs between them without a rewrite: title; date, time, all-day
     [097: time zone, repeat, location, guests, reminders, colour]; audience
     (the Private switch); description. -->
<template>
  <UiDialog :open="open" :title="event ? t('calendar_event.edit_title') : t('calendar_event.new_title')" size="md" @update:open="emit('update:open', $event)">
    <form class="cal-dlg" data-test="calendar-event-form" :data-mode="event ? 'edit' : 'create'" @submit.prevent="save">
      <label class="cal-dlg__field cal-dlg__field--wide">
        <span>{{ t('calendar_event.field_title') }}</span>
        <input
          v-model="form.title"
          data-autofocus
          data-test="calendar-event-title"
          :maxlength="CAL_TITLE_MAX"
          :placeholder="t('calendar_event.title_placeholder')"
          :disabled="busy"
        >
      </label>
      <label class="cal-dlg__field">
        <span>{{ t('calendar_event.field_date') }}</span>
        <input v-model="form.date" type="date" required data-test="calendar-event-date" :disabled="busy">
      </label>
      <template v-if="!form.allDay">
        <label class="cal-dlg__field">
          <span>{{ t('calendar_event.field_start') }}</span>
          <input v-model="form.start" type="time" required data-test="calendar-event-start" :disabled="busy" @change="startMoved">
        </label>
        <label class="cal-dlg__field">
          <span>{{ t('calendar_event.field_end') }}</span>
          <input v-model="form.end" type="time" required data-test="calendar-event-end" :disabled="busy">
        </label>
      </template>
      <label class="cal-dlg__check cal-dlg__check--cell">
        <input v-model="form.allDay" type="checkbox" data-test="calendar-event-all-day" :disabled="busy">
        <span>{{ t('calendar_event.field_all_day') }}</span>
      </label>
      <!-- 097 T014..T016: time zone, repeat, location, guests, reminders, colour go here -->
      <div v-if="canPrivate" class="cal-dlg__field cal-dlg__field--wide" data-test="calendar-event-audience">
        <label class="cal-dlg__check">
          <input
            v-model="form.private"
            type="checkbox"
            role="switch"
            :aria-checked="form.private ? 'true' : 'false'"
            data-test="calendar-event-private"
            :disabled="busy"
          >
          <span>{{ t('calendar_event.field_private') }}</span>
        </label>
        <small class="muted" data-test="calendar-event-audience-hint">{{ form.private ? t('calendar_event.private_hint') : t('calendar_event.public_hint') }}</small>
      </div>
      <label class="cal-dlg__field cal-dlg__field--wide">
        <span>{{ t('calendar_event.field_description') }}</span>
        <textarea v-model="form.description" rows="3" data-test="calendar-event-description" :maxlength="CAL_DESCRIPTION_MAX" :disabled="busy" />
      </label>
      <p v-if="error" class="cal-dlg__error cal-dlg__field--wide" role="alert" data-test="calendar-event-error">{{ t(error) }}</p>
      <div class="cal-dlg__actions cal-dlg__field--wide">
        <button
          v-if="event"
          type="button"
          class="btn ghost cal-dlg__delete"
          data-test="calendar-event-delete"
          :data-confirm="confirmDelete ? 'true' : 'false'"
          :disabled="busy"
          @click="remove"
        >{{ confirmDelete ? t('calendar_event.delete_confirm') : t('calendar_event.delete') }}</button>
        <span class="cal-dlg__spacer" />
        <button type="button" class="btn ghost" data-test="calendar-event-cancel" :disabled="busy" @click="emit('update:open', false)">{{ t('common.cancel') }}</button>
        <button type="submit" class="btn" data-test="calendar-event-save" :disabled="busy || !form.title.trim()">{{ busy ? t('calendar_event.saving') : t('calendar_event.save') }}</button>
      </div>
    </form>
  </UiDialog>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { CAL_DESCRIPTION_MAX, CAL_TITLE_MAX, calCanSetPrivate, calFormBody, calFormFromEvent, calHourAfter } from '~/utils/calendar-event-form.mjs'
import type { CalForm } from '~/utils/calendar-event-form.mjs'
import { calendarCreate, calendarDelete, calendarUpdate } from '~/utils/calendar-events-api.mjs'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { withSessionRetry } from '~/utils/live-follow.mjs'

const props = defineProps<{
  open: boolean
  /** the event to edit; null = a new event on `day` */
  event: CalendarItem | null
  day: string
  today: string
}>()
const emit = defineEmits<{ 'update:open': [boolean], saved: [CalendarItem], deleted: [CalendarItem] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const live = useLive()
const access = useAccessStore()
const roster = useRosterStore()

/* who the viewer is: the chain of useMessageEdit (the session's me, the WS
   welcome, the roster's me - HUM-1 in the mock workspace) */
const viewerId = computed(() => String(access.me?.humanId || live.identity.value || roster.me?.id || ''))
const canPrivate = computed(() => calCanSetPrivate(props.event, viewerId.value))

const form = ref<CalForm>(calFormFromEvent(null, props.day))
const busy = ref(false)
const error = ref('')
const confirmDelete = ref(false)

/* every opening starts from the event (or a clean new one): a dialog
   closed half-typed is a cancel */
function reset() {
  form.value = calFormFromEvent(props.event, props.day || props.today)
  error.value = ''
  confirmDelete.value = false
}
watch(() => [props.open, props.event, props.day], () => { if (props.open) reset() }, { immediate: true })
onMounted(() => { void access.load() })

/* a new start keeps the event's length at one hour when the end would fall before it */
function startMoved() {
  if (form.value.end <= form.value.start && !form.value.endDays) form.value.end = calHourAfter(form.value.start)
}

function errorKey(e: { status?: number, token?: string }) {
  const code = Number(e?.status) || 0
  const token = String(e?.token || '')
  if (code === 401) return 'calendar_event.error_signed_out'
  if (token === 'private_owner_only') return 'calendar_event.error_private_owner'
  if (token === 'demo_read_only') return 'calendar_event.error_demo'
  if (code === 403) return 'calendar_event.error_forbidden'
  if (code === 404) return 'calendar_event.error_not_found'
  if (code === 400) return 'calendar_event.error_bad'
  return 'calendar_event.error_save'
}

function changed() {
  window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
}

async function save() {
  if (busy.value) return
  const out = calFormBody(form.value, props.event)
  if (out.error !== undefined) {
    error.value = out.error
    return
  }
  if (out.body === null) {
    emit('update:open', false)
    return
  }
  const body = out.body
  busy.value = true
  error.value = ''
  try {
    const ev = props.event
      ? await withSessionRetry(api, () => calendarUpdate(api, props.event!.id, body, props.today))
      : await withSessionRetry(api, () => calendarCreate(api, body))
    changed()
    emit('saved', ev as CalendarItem)
    emit('update:open', false)
  } catch (e) {
    error.value = errorKey(e as { status?: number, token?: string })
  } finally {
    busy.value = false
  }
}

/* the first click asks, the second deletes (097 T017 brings Undo) */
async function remove() {
  if (!props.event || busy.value) return
  if (!confirmDelete.value) {
    confirmDelete.value = true
    return
  }
  busy.value = true
  error.value = ''
  try {
    const ev = await withSessionRetry(api, () => calendarDelete(api, props.event!.id, props.today))
    changed()
    emit('deleted', ev as CalendarItem)
    emit('update:open', false)
  } catch (e) {
    error.value = errorKey(e as { status?: number, token?: string })
    confirmDelete.value = false
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.cal-dlg {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 10px 12px;
  padding: 14px;
  min-width: 0;
}
.cal-dlg__field { display: flex; flex-direction: column; gap: 4px; min-width: 0; margin: 0; font-size: 0.8125rem; }
.cal-dlg__field--wide { grid-column: 1 / -1; }
.cal-dlg__field input:not([type='checkbox']),
.cal-dlg__field textarea { min-width: 0; width: 100%; }
.cal-dlg__field textarea { resize: vertical; }
.cal-dlg__check { display: flex; align-items: center; gap: 8px; min-width: 0; margin: 0; font-size: 0.8125rem; min-height: 32px; }
.cal-dlg__check--cell { align-self: end; }
.cal-dlg__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.cal-dlg__actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.cal-dlg__spacer { flex: 1 1 auto; }
.cal-dlg__delete { color: var(--color-danger); }
.cal-dlg__delete[data-confirm='true'] { border-color: var(--color-danger); }
/* a phone: two fields a row (date + start, end + all day) */
@media (max-width: 600px) {
  .cal-dlg { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
</style>
