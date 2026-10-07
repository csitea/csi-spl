<!-- spec 106 T009 (4.5, FR-008): a tap on an event opens this peek, a bottom
     sheet as tall as its content - the colour, the title (it wraps, never
     widens anything: S4-5), the time in the viewer's zone with the event's
     own zone beside it when that differs (S4-6), the location, a Private
     badge, the guests - and Edit / Duplicate / Delete in its bottom row.
     Delete is one tap, no question: the event goes and 097 T017's
     "Event deleted · Undo" bar shows for 10 s (UndoSnackbar: role="status",
     its timer holds on focus and hover, WCAG 2.2.1); Undo restores it with the
     same id (AC-05). A repeating event asks 097's This / Following / All first.
     The sheet is role="dialog" aria-modal="true": focus goes to its heading
     and back to the control that opened it (S4-2). CalendarPhone mounts it
     lazily on the first peek; Edit and Duplicate go back to the shell, whose
     add / edit sheet is T008's. -->
<template>
  <div v-if="event" class="calpeek" data-test="calpeek-layer">
    <div class="calpeek__scrim" data-test="calpeek-scrim" aria-hidden="true" @click="close" />
    <section
      ref="sheetEl"
      class="calpeek__sheet"
      role="dialog"
      aria-modal="true"
      :aria-labelledby="headId"
      data-test="calpeek"
      :data-id="event.id"
      @keydown.esc.stop.prevent="close"
      @keydown.tab="trapTab"
    >
      <div class="calpeek__head">
        <span
          class="calpeek__dot"
          data-test="calpeek-dot"
          :style="{ background: event.color ? `var(--cal-color-${event.color})` : 'var(--color-accent)' }"
          aria-hidden="true"
        />
        <h2 :id="headId" ref="headEl" class="calpeek__title" tabindex="-1" data-test="calpeek-title">{{ event.title }}</h2>
        <button
          type="button"
          class="calpeek__icon"
          data-test="calpeek-close"
          :aria-label="t('common.close')"
          :title="t('common.close')"
          @click="close"
        >
          <UiIcon name="x" :size="20" />
        </button>
      </div>

      <p class="calpeek__line" data-test="calpeek-when" dir="ltr">
        <UiIcon name="calendar" :size="16" />
        <span>{{ when }}<span v-if="ownZone" class="calpeek__zone" data-test="calpeek-zone"> ({{ ownZone }})</span></span>
      </p>
      <p v-if="event.location" class="calpeek__line" data-test="calpeek-location">
        <UiIcon name="pin" :size="16" /><span>{{ event.location }}</span>
      </p>
      <p v-if="event.audience === 'private'" class="calpeek__line">
        <span class="calpeek__badge" data-test="calpeek-private">{{ t('calendar_event.private_badge') }}</span>
      </p>
      <div v-if="guests.length" class="calpeek__guests" data-test="calpeek-guests">
        <p class="calpeek__label">{{ t('calendar_phone_peek.guests') }}</p>
        <ul class="calpeek__guest-list">
          <li v-for="g in guests" :key="g.id" class="calpeek__guest">{{ g.id }}</li>
        </ul>
      </div>
      <p v-if="failed" class="calpeek__error" role="alert" data-test="calpeek-error">{{ t('calendar_phone_peek.delete_failed') }}</p>

      <!-- a repeating event: which ones go (097 4.4) -->
      <div v-if="asking" class="calpeek__scope" role="group" :aria-label="t('calendar_phone_peek.scope_title')" data-test="calpeek-scope">
        <p class="calpeek__label">{{ t('calendar_phone_peek.scope_title') }}</p>
        <button
          v-for="s in SCOPES"
          :key="s"
          type="button"
          class="calpeek__btn calpeek__btn--wide"
          :data-test="`calpeek-scope-${s}`"
          :disabled="busy"
          @click="remove(s)"
        >{{ t(`calendar_phone_peek.scope_${s}`) }}</button>
        <button type="button" class="calpeek__btn calpeek__btn--wide calpeek__btn--quiet" data-test="calpeek-scope-cancel" @click="asking = false">{{ t('common.cancel') }}</button>
      </div>

      <div v-else-if="editable" class="calpeek__actions" data-test="calpeek-actions">
        <button type="button" class="calpeek__btn" data-test="calpeek-edit" @click="act('edit')">{{ t('calendar_event.edit') }}</button>
        <button type="button" class="calpeek__btn" data-test="calpeek-duplicate" @click="act('duplicate')">{{ t('calendar_event.duplicate') }}</button>
        <button type="button" class="calpeek__btn calpeek__btn--danger" data-test="calpeek-delete" :disabled="busy" @click="onDelete">
          {{ t('calendar_event.delete') }}
        </button>
      </div>
    </section>
  </div>
  <UndoSnackbar
    v-if="undoEv"
    :key="undoEv.id"
    testid="calendar-undo"
    :data-id="undoEv.id"
    icon="trash"
    :text="t('calendar_trash.deleted')"
    :undo-label="t('calendar_trash.undo')"
    :close-label="t('common.close')"
    :busy="undoBusy"
    :duration="UNDO_MS"
    @undo="undo"
    @dismiss="undoEv = null"
  />
  <span class="sr-only" aria-live="polite" data-test="calpeek-say">{{ said }}</span>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calAddDays } from '~/utils/calendar-year.mjs'
import { isoClock, isoDate, isoDateTime, viewerTimeZone } from '~/utils/date-iso.mjs'
import { isoDateTimeIn } from '~/utils/date-iso-zone.mjs'
import { calEditable } from '~/utils/calendar-event-form.mjs'
import { calendarDelete, calendarRestore } from '~/utils/calendar-events-api.mjs'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { hubJsonHeaders } from '~/utils/hub-headers'
import { withSessionRetry } from '~/utils/live-follow.mjs'

type Scope = 'this' | 'following' | 'all'
type Peeked = CalendarItem & { rrule?: string, recurring_event_id?: string, guests?: { type: string, id: string }[] }

const props = defineProps<{ event: Peeked | null, today: string }>()
const emit = defineEmits<{ close: [], edit: [CalendarItem], duplicate: [CalendarItem] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const SCOPES: Scope[] = ['this', 'following', 'all']
const UNDO_MS = 10000
const headId = 'calpeek-head'

const editable = computed(() => calEditable(props.event))
const repeating = computed(() => Boolean(props.event?.rrule || props.event?.recurring_event_id))
const guests = computed(() => (Array.isArray(props.event?.guests) ? props.event!.guests! : []))

/* the viewer's wall time, as every calendar clock; an all-day event its UTC day(s) */
const when = computed(() => {
  const ev = props.event
  if (!ev) return ''
  if (ev.all_day) {
    const a = ev.starts_at.slice(0, 10)
    const b = calAddDays(ev.ends_at.slice(0, 10), -1)
    return b > a ? `${a} – ${b}` : a
  }
  const end = isoDate(ev.ends_at) === isoDate(ev.starts_at) ? isoClock(ev.ends_at) : isoDateTime(ev.ends_at)
  return `${isoDateTime(ev.starts_at)}–${end}`
})
/* S4-6: the event's own zone when it is not the viewer's - "Europe/Helsinki 16:00".
   An 089 event is stored UTC with no zone of its own, so UTC never shows. */
const ownZone = computed(() => {
  const ev = props.event
  const zone = ev?.time_zone || ''
  if (!ev || ev.all_day || !zone || zone === 'UTC' || zone === viewerTimeZone()) return ''
  const there = isoDateTimeIn(ev.starts_at, zone)
  if (!there) return ''
  return `${zone} ${there.slice(0, 10) === isoDate(ev.starts_at) ? there.slice(11) : there}`
})

/* ---- open, close, focus (S4-2 e) ---- */
const sheetEl = ref<HTMLElement | null>(null)
const headEl = ref<HTMLElement | null>(null)
const asking = ref(false)
const busy = ref(false)
const failed = ref(false)
let opener: HTMLElement | null = null

watch(() => props.event?.id, (id, was) => {
  asking.value = false
  failed.value = false
  if (!id) return
  if (!was) opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
  void nextTick(focusHead)
}, { immediate: true })
/* the first peek mounts this chunk: focus once its heading is in the page */
function focusHead() {
  requestAnimationFrame(() => headEl.value?.focus({ preventScroll: true }))
}
onMounted(() => { if (props.event) focusHead() })

function close() {
  emit('close')
  const back = opener
  opener = null
  if (back?.isConnected) void nextTick(() => back.focus())
}
function act(kind: 'edit' | 'duplicate') {
  const ev = props.event
  if (!ev) return
  opener = null
  if (kind === 'edit') emit('edit', ev)
  else emit('duplicate', ev)
}
/* aria-modal: Tab stays in the sheet */
function trapTab(e: KeyboardEvent) {
  const els = [...(sheetEl.value?.querySelectorAll<HTMLElement>('button:not([disabled])') || [])]
  if (!els.length) return
  const first = els[0]!
  const last = els[els.length - 1]!
  const at = document.activeElement
  if (e.shiftKey && (at === first || at === headEl.value)) { e.preventDefault(); last.focus() }
  else if (!e.shiftKey && at === last) { e.preventDefault(); first.focus() }
}

/* ---- delete with Undo (4.5, AC-05) ---- */
const undoEv = shallowRef<CalendarItem | null>(null)
const undoBusy = ref(false)
const said = ref('')

/* DELETE ?scope= of a series or an occurrence (097 4.4); the mock has no series */
async function deleteScoped(id: string, scope: Scope): Promise<CalendarItem> {
  if (api.mock) return calendarDelete(api, id, props.today)
  const q = new URLSearchParams({ scope })
  const r = await fetch(`${api.base}/v1/calendar/events/${encodeURIComponent(id)}?${q}`, {
    method: 'DELETE', credentials: api.credentials, headers: hubJsonHeaders(api.token),
  })
  if (!r.ok) throw Object.assign(new Error(`calendar delete ${r.status}`), { status: r.status })
  const out = await r.json()
  if (!out?.event?.id) throw new Error('calendar delete: no event')
  return out.event
}

function onDelete() {
  if (repeating.value) asking.value = true
  else void remove('')
}

async function remove(scope: Scope | '') {
  const ev = props.event
  if (!ev || busy.value) return
  busy.value = true
  failed.value = false
  try {
    const gone = await withSessionRetry(api, () => (scope ? deleteScoped(ev.id, scope) : calendarDelete(api, ev.id, props.today)))
    window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
    undoEv.value = { ...ev, ...gone, id: gone?.id || ev.id }
    opener = null
    emit('close')
  } catch {
    failed.value = true
  } finally {
    busy.value = false
    asking.value = false
  }
}

async function undo() {
  const ev = undoEv.value
  if (!ev || undoBusy.value) return
  undoBusy.value = true
  try {
    await withSessionRetry(api, () => calendarRestore(api, ev.id, props.today))
    window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
  } catch {
    said.value = t('calendar_trash.restore_failed')
  } finally {
    undoBusy.value = false
    undoEv.value = null
  }
}
</script>

<style scoped>
.calpeek {
  position: fixed;
  inset: 0;
  z-index: var(--z-modal);
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
}
.calpeek__scrim {
  position: absolute;
  inset: 0;
  background: color-mix(in srgb, var(--color-bg) 65%, transparent);
}
/* as tall as its content, never taller than the screen; above the dock */
.calpeek__sheet {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 8px;
  max-height: calc(100dvh - 48px);
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior-y: contain;
  box-sizing: border-box;
  min-width: 0;
  /* over the composer dock (z-modal): only the home-indicator inset below */
  padding: 8px 16px calc(12px + env(safe-area-inset-bottom, 0px));
  border-radius: var(--radius-md) var(--radius-md) 0 0;
  background: var(--color-bg-2, var(--color-surface));
  color: var(--color-fg);
  border-top: 1px solid var(--color-border-strong, var(--color-border));
  box-shadow: var(--bevel-shine), var(--bevel-shade);
}
.calpeek__head {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  min-width: 0;
}
.calpeek__dot {
  flex: 0 0 auto;
  width: 14px;
  height: 14px;
  margin-top: 15px;
  border-radius: 50%;
  box-shadow: var(--cal-dot-ring);
}
.calpeek__title {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  padding: 10px 0;
  font-size: 1.125rem;
  font-weight: 600;
  color: var(--color-heading);
  overflow-wrap: anywhere;
}
.calpeek__title:focus { outline: none; }
.calpeek__title:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
.calpeek__icon {
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
.calpeek__line {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  min-width: 0;
  margin: 0;
  font-size: 0.875rem;
}
.calpeek__line > span,
.calpeek__guest { min-width: 0; overflow-wrap: anywhere; }
.calpeek__zone { color: var(--color-muted); }
.calpeek__badge {
  padding: 1px 8px;
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-pill);
  font-size: 0.75rem;
  font-weight: 600;
}
.calpeek__label {
  margin: 0 0 4px;
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
}
.calpeek__guests { min-width: 0; }
.calpeek__guest-list {
  margin: 0;
  padding: 0;
  list-style: none;
  font-size: 0.875rem;
}
.calpeek__error { margin: 0; font-size: 0.875rem; color: var(--color-danger, var(--color-fg)); }
.calpeek__actions {
  display: flex;
  gap: 8px;
  min-width: 0;
  padding-top: 4px;
}
.calpeek__scope {
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 0;
  padding-top: 4px;
}
.calpeek__btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 1 1 0;
  min-width: var(--tap);
  min-height: var(--tap);
  max-height: 48px;
  padding: 0 10px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  line-height: 1.2;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  box-shadow: var(--bevel-shine), var(--bevel-shade);
  cursor: pointer;
}
.calpeek__btn--wide { flex: 0 0 auto; width: 100%; }
.calpeek__btn--quiet { box-shadow: none; background: transparent; }
.calpeek__btn--danger { color: var(--color-danger, var(--color-fg)); }
.calpeek__btn:active { transform: translateY(1px); box-shadow: var(--bevel-shade); }
.calpeek__btn:disabled { opacity: .6; cursor: default; }
.calpeek button:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
:root[data-font-size="4"] .calpeek__btn,
:root[data-font-size="5"] .calpeek__btn { max-height: none; }
@media (prefers-reduced-motion: reduce) {
  .calpeek__btn:active { transform: none; }
}
</style>
