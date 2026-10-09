<!-- spec 106 T008: the phone calendar's add / edit sheet (spec 4.4, FR-007),
     its own lazy chunk (CalendarPhone.vue loads it on first open).

     A bottom sheet with a sticky header: Cancel (start), the heading, Save
     (end) - S2-1: a 300-350 px virtual keyboard covers the sheet's bottom,
     never its header, so a title typed and one tap on Save adds the event.
     The quick part (half height): the title (focused), the date chip, the
     start and end chips, the All-day switch. More grows the same sheet to
     full height with 097's fields in 097's order (time zone, location,
     reminders, colour, private, description; 097 T015 / T016 add repeat
     and guests where the event dialog has them). Edit opens full height on
     the event; Delete sits at the bottom start, and its confirm question
     never moves Save. Duplicate (`copy`, 097 G11) opens a new event full
     height, filled from its source as the 089 dialog's: calFormFromEvent.

     The chips are WUI controls showing ISO dates and the 24-hour clock: the
     native date / time input lies transparent over the chip text (the
     phone's own picker opens on a tap) and never shows its locale format.

     A mobile-stack overlay (Back closes it; the composer dock yields to it).
     Drag-down closes it, but only from the grab bar / header, or from the
     body while it is scrolled to the top (9.4 #4); overscroll is contained.
     The rules are utils/calendar-event-form.mjs's and the writes
     utils/calendar-events-api.mjs's, both read only, as the 089 dialog. -->
<template>
  <Teleport to="body">
    <div
      v-if="open"
      class="calsheet-back"
      data-test="calphone-sheet-backdrop"
      @mousedown.self="cancel"
    >
      <div
        ref="sheetEl"
        class="calsheet"
        :class="{ 'calsheet--full': full, 'calsheet--drag': dragging }"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="headId"
        data-test="calphone-sheet"
        :data-mode="event ? 'edit' : copy ? 'copy' : 'create'"
        :data-full="full ? 'true' : 'false'"
        :style="sheetStyle"
        @keydown="onKeydown"
      >
        <header
          class="calsheet__head"
          data-test="calphone-sheet-head"
          @touchstart.passive="dragStart($event, true)"
          @touchmove="dragMove"
          @touchend.passive="dragEnd"
          @touchcancel.passive="dragEnd"
        >
          <span class="calsheet__grab" aria-hidden="true" data-test="calphone-sheet-grab" />
          <div class="calsheet__bar">
            <button type="button" class="calsheet__btn" data-test="calphone-sheet-cancel" :disabled="busy" @click="cancel">{{ t('common.cancel') }}</button>
            <h2 :id="headId" ref="headEl" class="calsheet__heading" tabindex="-1">{{ event ? t('calendar_event.edit_title') : t('calendar_event.new_title') }}</h2>
            <button
              type="submit"
              :form="formId"
              class="calsheet__btn calsheet__save"
              data-test="calphone-sheet-save"
              :disabled="busy || !form.title.trim()"
            >{{ busy ? t('calendar_event.saving') : t('calendar_event.save') }}</button>
          </div>
        </header>
        <form
          :id="formId"
          ref="bodyEl"
          class="calsheet__body"
          data-test="calphone-sheet-body"
          @submit.prevent="save"
          @touchstart.passive="dragStart($event, false)"
          @touchmove="dragMove"
          @touchend.passive="dragEnd"
          @touchcancel.passive="dragEnd"
        >
          <p v-if="error" class="calsheet__error" role="alert" data-test="calphone-sheet-error">{{ t(error) }}</p>
          <input
            ref="titleEl"
            v-model="form.title"
            class="calsheet__title"
            data-test="calphone-sheet-title"
            :aria-label="t('calendar_event.field_title')"
            :maxlength="CAL_TITLE_MAX"
            :placeholder="t('calendar_event.title_placeholder')"
            :disabled="busy"
          >
          <div class="calsheet__row">
            <label class="calsheet__chip" data-test="calphone-sheet-date" :data-value="form.date">
              <UiIcon name="calendar" :size="16" />
              <span class="calsheet__chip-text">{{ form.date }}</span>
              <input
                v-model="form.date"
                class="calsheet__native"
                type="date"
                required
                data-test="calphone-sheet-date-input"
                :aria-label="`${t('calendar_event.field_date')} ${form.date}`"
                :disabled="busy"
                @click="pick"
              >
            </label>
          </div>
          <div v-if="!form.allDay" class="calsheet__row">
            <label class="calsheet__chip" data-test="calphone-sheet-start" :data-value="form.start">
              <span class="calsheet__chip-text">{{ form.start }}</span>
              <input
                v-model="form.start"
                class="calsheet__native"
                type="time"
                required
                data-test="calphone-sheet-start-input"
                :aria-label="`${t('calendar_event.field_start')} ${form.start}`"
                :disabled="busy"
                @click="pick"
                @change="startMoved"
              >
            </label>
            <span class="calsheet__dash" aria-hidden="true">-</span>
            <label class="calsheet__chip" data-test="calphone-sheet-end" :data-value="form.end">
              <span class="calsheet__chip-text">{{ form.end }}</span>
              <input
                v-model="form.end"
                class="calsheet__native"
                type="time"
                required
                data-test="calphone-sheet-end-input"
                :aria-label="`${t('calendar_event.field_end')} ${form.end}`"
                :disabled="busy"
                @click="pick"
              >
            </label>
          </div>
          <label class="calsheet__switch" data-test="calphone-sheet-all-day">
            <span>{{ t('calendar_event.field_all_day') }}</span>
            <input
              v-model="form.allDay"
              type="checkbox"
              role="switch"
              :aria-checked="form.allDay ? 'true' : 'false'"
              data-test="calphone-sheet-all-day-input"
              :disabled="busy"
            >
          </label>
          <button
            v-if="!full"
            type="button"
            class="calsheet__more"
            data-test="calphone-sheet-more"
            aria-expanded="false"
            @click="grow"
          >
            <UiIcon name="chevron-down" :size="16" />{{ t('mobile.more') }}
          </button>

          <template v-if="full">
            <label v-if="!form.allDay" class="calsheet__field">
              <span>{{ t('calendar_event.field_time_zone') }}</span>
              <select v-model="form.timeZone" data-test="calphone-sheet-time-zone" :disabled="busy">
                <option v-for="z in zones" :key="z" :value="z">{{ z }}</option>
              </select>
            </label>
            <!-- 097 T015: repeat goes here -->
            <label class="calsheet__field">
              <span>{{ t('calendar_event.field_location') }}</span>
              <input
                v-model="form.location"
                data-test="calphone-sheet-location"
                :maxlength="CAL_LOCATION_MAX"
                :placeholder="t('calendar_event.location_placeholder')"
                :disabled="busy"
              >
            </label>
            <!-- 097 T016: guests go here -->
            <fieldset class="calsheet__field calsheet__set" data-test="calphone-sheet-reminders">
              <legend>{{ t('calendar_event.field_reminders') }}</legend>
              <div v-for="(r, i) in form.reminders" :key="i" class="calsheet__rem" data-test="calphone-sheet-reminder">
                <input
                  :value="r.amount"
                  type="text"
                  inputmode="numeric"
                  pattern="[0-9]*"
                  maxlength="5"
                  required
                  data-test="calphone-sheet-reminder-amount"
                  :aria-label="t('calendar_event.reminder_amount')"
                  :aria-invalid="calReminderError(r) ? 'true' : 'false'"
                  :disabled="busy"
                  @input="typed($event, r)"
                >
                <select v-model="r.unit" data-test="calphone-sheet-reminder-unit" :aria-label="t('calendar_event.reminder_unit')" :disabled="busy">
                  <option v-for="u in UNITS" :key="u" :value="u">{{ t('calendar_event.unit_' + u) }}</option>
                </select>
                <button
                  type="button"
                  class="calsheet__icon"
                  data-test="calphone-sheet-reminder-remove"
                  :aria-label="t('calendar_event.reminder_remove')"
                  :title="t('calendar_event.reminder_remove')"
                  :disabled="busy"
                  @click="form.reminders.splice(i, 1)"
                ><UiIcon name="x" :size="16" /></button>
                <small v-if="calReminderError(r)" class="calsheet__error calsheet__rem-error">{{ t(calReminderError(r)) }}</small>
              </div>
              <button
                v-if="form.reminders.length < CAL_REMINDERS_MAX"
                type="button"
                class="calsheet__more"
                data-test="calphone-sheet-reminder-add"
                :disabled="busy"
                @click="addReminder"
              ><UiIcon name="plus" :size="16" />{{ t('calendar_event.reminder_add') }}</button>
            </fieldset>
            <fieldset class="calsheet__field calsheet__set" data-test="calphone-sheet-colors">
              <legend>{{ t('calendar_event.field_color') }}</legend>
              <div class="calsheet__swatches" role="radiogroup" :aria-label="t('calendar_event.field_color')">
                <label
                  v-for="c in SWATCHES"
                  :key="c || 'default'"
                  class="calsheet__swatch"
                  :class="{ 'calsheet__swatch--default': !c }"
                  :style="c ? { '--swatch': `var(--cal-color-${c})` } : undefined"
                  :title="t('calendar_event.color_' + (c || 'default'))"
                  data-test="calphone-sheet-color"
                  :data-color="c"
                >
                  <input
                    type="radio"
                    name="calsheet-color"
                    :value="c"
                    :checked="form.color === c"
                    :aria-label="t('calendar_event.color_' + (c || 'default'))"
                    :disabled="busy"
                    @change="form.color = c"
                  >
                </label>
              </div>
            </fieldset>
            <div v-if="canPrivate" class="calsheet__field" data-test="calphone-sheet-audience">
              <label class="calsheet__switch">
                <span>{{ t('calendar_event.field_private') }}</span>
                <input
                  v-model="form.private"
                  type="checkbox"
                  role="switch"
                  :aria-checked="form.private ? 'true' : 'false'"
                  data-test="calphone-sheet-private"
                  :disabled="busy"
                >
              </label>
              <small class="calsheet__hint">{{ form.private ? t('calendar_event.private_hint') : t('calendar_event.public_hint') }}</small>
            </div>
            <label class="calsheet__field">
              <span>{{ t('calendar_event.field_description') }}</span>
              <textarea v-model="form.description" rows="3" data-test="calphone-sheet-description" :maxlength="CAL_DESCRIPTION_MAX" :disabled="busy" />
            </label>
            <div v-if="event" class="calsheet__foot">
              <button
                type="button"
                class="calsheet__btn calsheet__delete"
                data-test="calphone-sheet-delete"
                :data-confirm="confirmDelete ? 'true' : 'false'"
                :disabled="busy"
                @click="remove"
              >{{ confirmDelete ? t('calendar_event.delete_confirm') : t('calendar_event.delete') }}</button>
            </div>
          </template>
        </form>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import {
  CAL_COLORS, CAL_DESCRIPTION_MAX, CAL_LOCATION_MAX, CAL_REMINDERS_MAX, CAL_REMINDER_UNITS, CAL_TITLE_MAX,
  calCanSetPrivate, calFormBody, calFormFromEvent, calHourAfter, calNewReminder, calReminderAmount, calReminderError,
} from '~/utils/calendar-event-form.mjs'
import type { CalForm, CalReminderRow } from '~/utils/calendar-event-form.mjs'
import { calPhoneHourPreset, calPhoneNextFullHour } from '~/utils/calendar-phone-nav.mjs'
import { knownTimeZones } from '~/utils/date-iso.mjs'
import { calendarCreate, calendarDelete, calendarUpdate } from '~/utils/calendar-events-api.mjs'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useMobileStack } from '~/composables/useMobileStack'
import { useLive } from '~/composables/useLive'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'

const props = defineProps<{
  open: boolean
  /** the event to edit; null = a new event on `day` */
  event: CalendarItem | null
  /** a new event's day (YYYY-MM-DD) */
  day: string
  today: string
  /** a new event's tapped hour 0..23 (Day's empty time, AC-04); -1 / unset = the next full hour */
  hour?: number
  /** Duplicate (097 G11): a new event (`event` null) filled from this one */
  copy?: CalendarItem | null
}>()
const emit = defineEmits<{ 'update:open': [boolean], saved: [CalendarItem], deleted: [CalendarItem] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const live = useLive()
const access = useAccessStore()
const roster = useRosterStore()

const viewerId = computed(() => String(access.me?.humanId || live.identity.value || roster.me?.id || ''))
const canPrivate = computed(() => calCanSetPrivate(props.event, viewerId.value))

const headId = useId()
const formId = useId()
const UNITS = Object.keys(CAL_REMINDER_UNITS)
const SWATCHES = ['', ...CAL_COLORS]
const allZones = import.meta.client ? knownTimeZones() : []

const form = ref<CalForm>(calFormFromEvent(null, props.day || props.today))
const zones = computed(() => (allZones.includes(form.value.timeZone) ? allZones : [form.value.timeZone, ...allZones]))
const full = ref(false)
const busy = ref(false)
const error = ref('')
const confirmDelete = ref(false)

const sheetEl = ref<HTMLElement | null>(null)
const bodyEl = ref<HTMLElement | null>(null)
const titleEl = ref<HTMLInputElement | null>(null)
const headEl = ref<HTMLElement | null>(null)

/* the new event's times: the tapped hour, else the next full hour of now
   (on the shown day when that is not today) - one hour long either way */
function preset(): { date: string, start: string, end: string, endDays: number } | null {
  const day = props.day || props.today
  const h = Number(props.hour)
  let p = Number.isInteger(h) && h >= 0 ? calPhoneHourPreset(day, h) : null
  if (!p) {
    const next = calPhoneNextFullHour(Date.now(), form.value.timeZone)
    p = next && day !== props.today ? calPhoneHourPreset(day, Number(next.start.slice(0, 2))) : next
  }
  if (!p) return null
  return { date: p.date, start: p.start, end: p.end, endDays: p.endDate === p.date ? 0 : 1 }
}

/* every opening starts clean from the event, or from a new one */
function reset() {
  const from = props.event || props.copy || null
  form.value = calFormFromEvent(from, props.day || props.today)
  if (!from) {
    const p = preset()
    if (p) form.value = { ...form.value, ...p }
  }
  full.value = Boolean(from)
  error.value = ''
  confirmDelete.value = false
  dy.value = 0
}

/* focus: the title (add) or the heading (edit, no keyboard over the event),
   and back to the control that opened the sheet on close (S4-2 e) */
let returnFocusTo: HTMLElement | null = null
async function opened() {
  returnFocusTo = document.activeElement as HTMLElement | null
  reset()
  window.addEventListener('keydown', onWindowKey)
  window.visualViewport?.addEventListener('resize', onViewport)
  window.visualViewport?.addEventListener('scroll', onViewport)
  onViewport()
  /* the first open mounts the sheet after a suspense resolve, so its
     elements may land a frame or two later */
  for (let i = 0; i < 20 && props.open; i++) {
    await nextTick()
    const el = props.event ? headEl.value : titleEl.value
    el?.focus()
    if (el && document.activeElement === el) return
    await new Promise((r) => requestAnimationFrame(r))
  }
}
function closed() {
  window.removeEventListener('keydown', onWindowKey)
  window.visualViewport?.removeEventListener('resize', onViewport)
  window.visualViewport?.removeEventListener('scroll', onViewport)
  returnFocusTo?.focus?.()
  returnFocusTo = null
}
function cancel() {
  if (!busy.value) emit('update:open', false)
}
function grow() {
  full.value = true
}

/* the native picker opens on a tap of the chip (a desktop browser needs the call) */
function pick(e: Event) {
  const el = e.currentTarget as HTMLInputElement & { showPicker?: () => void }
  try { el.showPicker?.() } catch { /* not allowed here: the input still edits */ }
}
function startMoved() {
  if (form.value.end <= form.value.start && !form.value.endDays) form.value.end = calHourAfter(form.value.start)
}
function typed(e: Event, r: CalReminderRow) {
  const el = e.target as HTMLInputElement
  r.amount = calReminderAmount(el.value)
  if (el.value !== r.amount) el.value = r.amount
}
function addReminder() {
  const r = calNewReminder(form.value.reminders)
  if (r) form.value.reminders.push(r)
}

/* ---- keyboard safety: a keyboard that overlays the page (the visual
   viewport shrinks, the layout one does not) lifts the sheet above it ---- */
const lift = ref(0)
function onViewport() {
  const vv = window.visualViewport
  lift.value = vv ? Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop)) : 0
}

/* ---- drag-down to close (9.4 #4) ---- */
const dy = ref(0)
const dragging = ref(false)
let y0 = 0
let x0 = 0
let armed = false
let lock: '' | 'x' | 'y' = ''
const sheetStyle = computed(() => {
  const s: Record<string, string> = {}
  if (lift.value) {
    /* the lifted sheet fits above the keyboard: a full-height one (Edit)
       lifted whole slid its header and title off the top (t1 650cec31) */
    const room = `calc(100% - ${lift.value}px - env(safe-area-inset-top, 0px))`
    s.bottom = `${lift.value}px`
    s.maxHeight = room
    s.minHeight = `min(50%, ${room})`
  }
  if (dy.value > 0) s.transform = `translateY(${dy.value}px)`
  return s
})
function dragStart(e: TouchEvent, fromHead: boolean) {
  const p = e.touches[0]
  if (!p || e.touches.length !== 1 || busy.value) {
    armed = false
    return
  }
  armed = fromHead || (bodyEl.value?.scrollTop || 0) <= 0
  y0 = p.clientY
  x0 = p.clientX
  lock = ''
}
function dragMove(e: TouchEvent) {
  const p = e.touches[0]
  if (!armed || !p) return
  const d = p.clientY - y0
  if (!lock) {
    if (Math.abs(p.clientX - x0) >= 10) lock = 'x'
    else if (Math.abs(d) >= 10) lock = d > 0 ? 'y' : 'x'
    if (lock === 'x') armed = false
    if (lock !== 'y') return
  }
  if (e.cancelable) e.preventDefault()
  dragging.value = true
  dy.value = Math.max(0, d)
}
function dragEnd() {
  const was = dy.value
  armed = false
  lock = ''
  if (!dragging.value) return
  dragging.value = false
  const h = sheetEl.value?.offsetHeight || 0
  dy.value = 0
  if (was > Math.min(160, Math.max(80, h * 0.25))) cancel()
}

/* ---- Escape, and Tab kept inside the sheet ---- */
function onWindowKey(e: KeyboardEvent) {
  if (e.key !== 'Escape' || e.defaultPrevented || e.isComposing) return
  e.preventDefault()
  cancel()
}
function onKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') {
    e.preventDefault()
    e.stopPropagation()
    cancel()
    return
  }
  if (e.key !== 'Tab' || !sheetEl.value) return
  const sel = 'button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'
  const items = [...sheetEl.value.querySelectorAll<HTMLElement>(sel)].filter((el) => el.offsetParent !== null)
  const first = items[0]
  const last = items[items.length - 1]
  if (!first || !last) return
  const active = document.activeElement as HTMLElement | null
  if (!e.shiftKey && (active === last || !sheetEl.value.contains(active))) {
    e.preventDefault()
    first.focus()
  } else if (e.shiftKey && (active === first || !sheetEl.value.contains(active))) {
    e.preventDefault()
    last.focus()
  }
}

/* ---- the writes, as the 089 dialog's ---- */
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

/* the first tap asks (in place: Save does not move), the second deletes */
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

/* last: an already-open mount runs opened() at once, after every ref above */
watch(() => props.open, (v) => {
  if (!import.meta.client) return
  if (v) void opened()
  else closed()
}, { immediate: true })
watch(() => [props.event, props.copy, props.day, props.hour], () => { if (props.open) reset() })
onBeforeUnmount(() => { if (props.open) closed() })
onMounted(() => { void access.load() })

useMobileStack().overlay(() => props.open, () => emit('update:open', false))
</script>

<style scoped>
.calsheet-back {
  position: fixed;
  inset: 0;
  z-index: var(--z-modal);
  background: color-mix(in srgb, var(--color-bg) 62%, transparent);
  overflow: hidden;
  overscroll-behavior: contain;
}
.calsheet {
  position: absolute;
  inset-inline: 0;
  bottom: 0;
  display: flex;
  flex-direction: column;
  max-width: 100%;
  /* half height at least: the header stays above a 300-350 px keyboard (S2-1) */
  min-height: 50%;
  max-height: calc(100% - env(safe-area-inset-top, 0px));
  box-sizing: border-box;
  padding-bottom: env(safe-area-inset-bottom, 0px);
  border-radius: var(--radius-lg) var(--radius-lg) 0 0;
  background: var(--color-surface);
  color: var(--color-fg);
  box-shadow: var(--focus-3d), var(--bevel-shine);
  overscroll-behavior-y: contain;
  animation: calsheet-up 200ms ease-out;
}
.calsheet--full { height: calc(100% - env(safe-area-inset-top, 0px)); }
.calsheet--drag { animation: none; }
@keyframes calsheet-up {
  from { transform: translateY(40%); opacity: 0.4; }
  to { transform: none; opacity: 1; }
}

/* ---- the sticky header: grab bar, Cancel | heading | Save ---- */
.calsheet__head {
  flex: 0 0 auto;
  border-bottom: 1px solid var(--color-border);
  touch-action: none;
}
.calsheet__grab {
  display: block;
  width: 36px;
  height: 4px;
  margin: 6px auto 0;
  border-radius: var(--radius-pill);
  background: var(--color-border-strong);
}
.calsheet__bar {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 48px;
  padding: 0 8px;
  min-width: 0;
}
.calsheet__heading {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
  color: var(--color-heading);
  text-align: center;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  outline: none;
}
.calsheet__btn {
  flex: 0 0 auto;
  min-width: var(--tap);
  min-height: var(--tap);
  max-width: 40%;
  padding: 0 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.9375rem;
  line-height: 1.2;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
}
.calsheet__save {
  border-color: var(--color-accent);
  background: var(--color-accent);
  color: var(--color-on-accent);
  font-weight: 600;
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
}
.calsheet__btn:disabled { opacity: 0.55; cursor: default; }
.calsheet__btn:not(:disabled):active {
  transform: translateY(1px);
  box-shadow: var(--bevel-shade);
}

/* ---- the body: vertical scroll only ---- */
.calsheet__body {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 12px 16px 16px;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior-y: contain;
  box-sizing: border-box;
}
.calsheet__title,
.calsheet__body select,
.calsheet__body input:not([type='checkbox'], [type='radio'], .calsheet__native),
.calsheet__body textarea {
  box-sizing: border-box;
  width: 100%;
  min-width: 0;
  min-height: var(--tap);
  padding: 0 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-bg);
  color: var(--color-fg);
  font-family: inherit;
  /* 1 rem: a phone does not zoom into the field */
  font-size: 1rem;
}
.calsheet__title { font-weight: 600; }
.calsheet__body textarea { padding: 10px 12px; resize: vertical; }
.calsheet__row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.calsheet__dash { color: var(--color-muted); }

/* a chip: the ISO text, the native input transparent over it */
.calsheet__chip {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: var(--tap);
  min-height: var(--tap);
  padding: 0 14px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  background: var(--color-bg-2);
  color: var(--color-fg);
  font-size: 1rem;
  font-variant-numeric: tabular-nums;
  box-shadow: var(--bevel-shine), var(--bevel-shade);
  cursor: pointer;
}
.calsheet__chip-text { white-space: nowrap; }
.calsheet__native {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  margin: 0;
  padding: 0;
  border: 0;
  opacity: 0;
  cursor: pointer;
}
.calsheet__chip:focus-within {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}

/* a switch: the whole row is the target */
.calsheet__switch {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: var(--tap);
  font-size: 0.9375rem;
  cursor: pointer;
}
.calsheet__switch input {
  appearance: none;
  position: relative;
  flex: 0 0 auto;
  width: 44px;
  height: 26px;
  margin: 0;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-pill);
  background: var(--color-bg-3);
  cursor: pointer;
}
.calsheet__switch input::after {
  content: '';
  position: absolute;
  top: 2px;
  inset-inline-start: 2px;
  width: 20px;
  height: 20px;
  border-radius: var(--radius-pill);
  background: var(--color-fg);
  box-shadow: var(--bevel-shade);
}
.calsheet__switch input:checked {
  border-color: var(--color-accent);
  background: var(--color-accent);
}
.calsheet__switch input:checked::after {
  inset-inline-start: 20px;
  background: var(--color-on-accent);
}

.calsheet__more {
  display: inline-flex;
  align-items: center;
  align-self: flex-start;
  gap: 6px;
  min-height: var(--tap);
  min-width: var(--tap);
  padding: 0 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.9375rem;
  cursor: pointer;
}

.calsheet__field {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
  margin: 0;
  font-size: 0.8125rem;
}
.calsheet__set { border: 0; padding: 0; }
.calsheet__set legend { padding: 0; margin-bottom: 4px; }
.calsheet__rem {
  display: grid;
  grid-template-columns: 5.5em minmax(0, 1fr) auto;
  gap: 6px;
  align-items: center;
  min-width: 0;
  margin-bottom: 6px;
}
.calsheet__rem-error { grid-column: 1 / -1; }
.calsheet__icon {
  display: inline-grid;
  place-items: center;
  width: var(--tap);
  height: var(--tap);
  padding: 0;
  border: 0;
  border-radius: var(--radius-pill);
  background: transparent;
  color: var(--color-fg);
  cursor: pointer;
}
.calsheet__swatches { display: flex; flex-wrap: wrap; gap: 6px; }
.calsheet__swatch {
  position: relative;
  display: inline-grid;
  place-items: center;
  width: var(--tap);
  height: var(--tap);
  box-sizing: border-box;
  border-radius: var(--radius-pill);
  background: var(--swatch, transparent);
  border: 2px solid var(--swatch, var(--color-border));
  box-shadow: var(--cal-dot-ring);
  cursor: pointer;
}
.calsheet__swatch--default { background: linear-gradient(135deg, transparent 45%, var(--color-muted) 45% 55%, transparent 55%); }
.calsheet__swatch input { position: absolute; inset: 0; margin: 0; opacity: 0; cursor: pointer; }
.calsheet__swatch:has(input:checked) { outline: 2px solid var(--color-fg); outline-offset: 2px; }
.calsheet__swatch:has(input:focus-visible) { outline: var(--focus-ring-w) solid var(--focus-ring); outline-offset: 2px; }
.calsheet__hint { color: var(--color-muted); }
.calsheet__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; font-size: 0.875rem; }

/* Delete at the bottom start; its confirm text never moves Save */
.calsheet__foot {
  display: flex;
  justify-content: flex-start;
  padding-top: 8px;
}
.calsheet__delete { color: var(--color-danger); }
.calsheet__delete[data-confirm='true'] { border-color: var(--color-danger); }

.calsheet button:focus-visible,
.calsheet__body input:focus-visible,
.calsheet__body select:focus-visible,
.calsheet__body textarea:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}

/* S4-7: no sheet slide under reduced motion */
@media (prefers-reduced-motion: reduce) {
  .calsheet { animation: none; }
  .calsheet__btn:not(:disabled):active { transform: none; }
}
</style>
