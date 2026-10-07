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
     (the Private switch); description.

     097 T014 (G6..G9, G11; spec 5.1.2, 5.1.6, 5.1.9): time zone, location,
     reminders (up to 5, a whole number and minutes / hours / days) and the
     colour swatches; `copy` opens a new event filled from another
     (Duplicate). On a phone the dialog is the full screen, one column, and
     Save / Cancel / Delete sit in UiDialog's footer, the bottom bar a thumb
     reaches. -->
<template>
  <UiDialog :open="open" :title="event ? t('calendar_event.edit_title') : t('calendar_event.new_title')" size="md" @update:open="emit('update:open', $event)">
    <form :id="formId" class="cal-dlg" data-test="calendar-event-form" :data-mode="event ? 'edit' : copy ? 'copy' : 'create'" @submit.prevent="save">
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
      <label v-if="!form.allDay" class="cal-dlg__field cal-dlg__field--wide">
        <span>{{ t('calendar_event.field_time_zone') }}</span>
        <select v-model="form.timeZone" class="cal-dlg__tap" data-test="calendar-event-time-zone" :disabled="busy">
          <option v-for="z in zones" :key="z" :value="z">{{ z }}</option>
        </select>
      </label>
      <!-- 097 T015: repeat goes here -->
      <label class="cal-dlg__field cal-dlg__field--wide">
        <span>{{ t('calendar_event.field_location') }}</span>
        <input
          v-model="form.location"
          data-test="calendar-event-location"
          :maxlength="CAL_LOCATION_MAX"
          :placeholder="t('calendar_event.location_placeholder')"
          :disabled="busy"
        >
      </label>
      <!-- 097 T016: guests go here -->
      <fieldset class="cal-dlg__field cal-dlg__field--wide cal-dlg__set" data-test="calendar-event-reminders">
        <legend>{{ t('calendar_event.field_reminders') }}</legend>
        <div v-for="(r, i) in form.reminders" :key="i" class="cal-dlg__rem" data-test="calendar-event-reminder">
          <input
            :value="r.amount"
            class="cal-dlg__tap cal-dlg__amount"
            type="text"
            inputmode="numeric"
            pattern="[0-9]*"
            maxlength="5"
            required
            data-test="calendar-event-reminder-amount"
            :aria-label="t('calendar_event.reminder_amount')"
            :aria-invalid="calReminderError(r) ? 'true' : 'false'"
            :disabled="busy"
            @input="typed($event, r)"
          >
          <select v-model="r.unit" class="cal-dlg__tap" data-test="calendar-event-reminder-unit" :aria-label="t('calendar_event.reminder_unit')" :disabled="busy">
            <option v-for="u in UNITS" :key="u" :value="u">{{ t('calendar_event.unit_' + u) }}</option>
          </select>
          <span class="cal-dlg__before">{{ t('calendar_event.reminder_before') }}</span>
          <button
            type="button"
            class="icon-btn cal-dlg__tap"
            data-test="calendar-event-reminder-remove"
            :aria-label="t('calendar_event.reminder_remove')"
            :title="t('calendar_event.reminder_remove')"
            :disabled="busy"
            @click="form.reminders.splice(i, 1)"
          ><UiIcon name="x" :size="16" /></button>
          <small v-if="calReminderError(r)" class="cal-dlg__error cal-dlg__rem-error" data-test="calendar-event-reminder-error">{{ t(calReminderError(r)) }}</small>
        </div>
        <button
          v-if="form.reminders.length < CAL_REMINDERS_MAX"
          type="button"
          class="btn ghost cal-dlg__tap cal-dlg__add"
          data-test="calendar-event-reminder-add"
          :disabled="busy"
          @click="addReminder"
        ><UiIcon name="plus" :size="16" />{{ t('calendar_event.reminder_add') }}</button>
      </fieldset>
      <fieldset class="cal-dlg__field cal-dlg__field--wide cal-dlg__set" data-test="calendar-event-colors">
        <legend>{{ t('calendar_event.field_color') }}</legend>
        <div class="cal-dlg__swatches" role="radiogroup" :aria-label="t('calendar_event.field_color')">
          <label
            v-for="c in SWATCHES"
            :key="c || 'default'"
            class="cal-dlg__swatch"
            :class="{ 'cal-dlg__swatch--default': !c }"
            :style="c ? { '--swatch': `var(--cal-color-${c})` } : undefined"
            :title="t('calendar_event.color_' + (c || 'default'))"
            data-test="calendar-event-color"
            :data-color="c"
          >
            <!-- :checked + @change, not v-model: a radio v-model pulls Vue's
                 vModelRadio into the first-screen runtime chunk (~50 B) -->
            <input
              type="radio"
              name="cal-color"
              :value="c"
              :checked="form.color === c"
              :aria-label="t('calendar_event.color_' + (c || 'default'))"
              :disabled="busy"
              @change="form.color = c"
            >
          </label>
        </div>
      </fieldset>
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
    </form>
    <template #footer>
      <div class="cal-dlg__actions" data-test="calendar-event-actions">
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
        <button type="submit" :form="formId" class="btn" data-test="calendar-event-save" :disabled="busy || !form.title.trim()">{{ busy ? t('calendar_event.saving') : t('calendar_event.save') }}</button>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import {
  CAL_COLORS, CAL_DESCRIPTION_MAX, CAL_LOCATION_MAX, CAL_REMINDERS_MAX, CAL_REMINDER_UNITS, CAL_TITLE_MAX,
  calCanSetPrivate, calFormBody, calFormFromEvent, calHourAfter, calNewReminder, calReminderAmount, calReminderError,
} from '~/utils/calendar-event-form.mjs'
import type { CalReminderRow } from '~/utils/calendar-event-form.mjs'
import { knownTimeZones } from '~/utils/date-iso.mjs'
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
  /** 097 T013: the HH:MM start and end a drag on empty time picked (a new event only) */
  span?: { start: string, end: string } | null
  /** 097 T014 (G11): Duplicate - a new event (`event` null) filled from this one */
  copy?: CalendarItem | null
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
const formId = useId()
const UNITS = Object.keys(CAL_REMINDER_UNITS)
const SWATCHES = ['', ...CAL_COLORS]
/* every zone this browser knows, and the form's own when it does not */
const allZones = import.meta.client ? knownTimeZones() : []
const zones = computed(() => (allZones.includes(form.value.timeZone) ? allZones : [form.value.timeZone, ...allZones]))

/* a keystroke keeps digits only, no leading 0: 1.5 or 0 cannot be typed (owner E2) */
function typed(e: Event, r: CalReminderRow) {
  const el = e.target as HTMLInputElement
  r.amount = calReminderAmount(el.value)
  if (el.value !== r.amount) el.value = r.amount
}
function addReminder() {
  const r = calNewReminder(form.value.reminders)
  if (r) form.value.reminders.push(r)
}
const busy = ref(false)
const error = ref('')
const confirmDelete = ref(false)

/* every opening starts from the event (or a clean new one): a dialog
   closed half-typed is a cancel */
function reset() {
  form.value = !props.event && props.copy ? calFormFromEvent(props.copy, props.day) : calFormFromEvent(props.event, props.day || props.today)
  if (!props.event && props.span) form.value = { ...form.value, start: props.span.start, end: props.span.end }
  error.value = ''
  confirmDelete.value = false
}
watch(() => [props.open, props.event, props.copy, props.day], () => { if (props.open) reset() }, { immediate: true })
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
.cal-dlg__actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; width: 100%; }
.cal-dlg__field select { min-width: 0; width: 100%; }
.cal-dlg__set { border: 0; padding: 0; }
.cal-dlg__set legend { padding: 0; margin-bottom: 4px; }
/* a reminder: amount, unit, "before", remove - one row even at 360 px */
.cal-dlg__rem { display: grid; grid-template-columns: 5.5em minmax(0, 8em) auto auto; justify-content: start; gap: 6px; align-items: center; min-width: 0; }
.cal-dlg__rem select { width: auto; min-width: 0; }
.cal-dlg__before { color: var(--color-muted); white-space: nowrap; }
.cal-dlg__rem-error { grid-column: 1 / -1; font-size: 0.75rem; }
.cal-dlg__add { justify-self: start; align-self: flex-start; display: inline-flex; align-items: center; gap: 4px; }
.cal-dlg__swatches { display: flex; flex-wrap: wrap; gap: 6px; }
.cal-dlg__swatch {
  position: relative;
  display: inline-grid; place-items: center;
  width: 32px; height: 32px;
  border-radius: 50%;
  background: var(--swatch, transparent);
  border: 2px solid var(--swatch, var(--color-border));
  cursor: pointer;
}
.cal-dlg__swatch--default { background: linear-gradient(135deg, transparent 45%, var(--color-muted) 45% 55%, transparent 55%); }
.cal-dlg__swatch input { position: absolute; inset: 0; margin: 0; opacity: 0; cursor: pointer; }
.cal-dlg__swatch:has(input:checked) { outline: 2px solid var(--color-text); outline-offset: 2px; }
.cal-dlg__swatch:has(input:focus-visible) { outline: 2px solid var(--color-accent); outline-offset: 2px; }
.cal-dlg__spacer { flex: 1 1 auto; }
.cal-dlg__delete { color: var(--color-danger); }
.cal-dlg__delete[data-confirm='true'] { border-color: var(--color-danger); }
/* a phone (097 5.1.6): the full screen (UiDialog), one column, 44 px targets */
@media (max-width: 600px) {
  .cal-dlg { grid-template-columns: minmax(0, 1fr); }
}
@media (max-width: 820px) {
  .cal-dlg__tap { min-height: var(--tap, 44px); min-width: var(--tap, 44px); }
  .cal-dlg__swatch { width: var(--tap, 44px); height: var(--tap, 44px); }
  .cal-dlg__check { min-height: var(--tap, 44px); }
}
</style>
