<!-- Spec 107 v1.2 T011 (owner R9, R10): the body of the calendar entry dialog
     of type Working hours - one day. The period's banner (open days, the
     freeze, a returned note), the day's total, then its rows: the day's
     discussions first, each a link to its topic with its time and blocks
     (R10: "each time a user participates in a discussion those discussion
     links will be shown in the description of the hours"), then meetings,
     channels and "other". Its own lazy chunk; the desktop dialog
     (CalendarEventDialog) and the phone sheet (CalendarPhoneSheet) both
     host it.
     T013 (spec 4.1, 5.2): [Approve N days] in the banner, Approve day on a
     closed day, Approve so far today, one-tap ✓ +h:mm for a delta, ✕ reject
     with a 10 s Undo, the frozen lock, Final, a returned note + Resubmit, and
     Approve week (sticky at the bottom of the phone sheet).
     T014 (spec 1.5, 5.2, 5.3; R10 "he / she would be able to modify
     additionally for those automatic entries more notes"): the minutes open
     a ±15 stepper in place (or type h:mm), +15 extends a row, + Add books a
     target (HoursTargetPicker) with 0:30, Why shows the row's blocks, and
     every line takes a note (<= 500) saved as the entry's note. -->
<template>
  <div class="hours-day" data-test="hours-day" :data-day="day" :data-state="state" :data-period="periodState" :data-editable="editable ? 'true' : 'false'">
    <div v-if="banner" class="hours-day__banner" data-test="hours-day-banner" :data-open="banner.openDays.length">
      <span>{{ bannerText }}</span>
      <button
        v-if="periodOpen && banner.openDays.length"
        type="button"
        class="btn primary hours-day__btn"
        data-test="hours-approve-open"
        :disabled="busy"
        @click="approve('closed')"
      >{{ t('hours_cal.approve_open', { n: banner.openDays.length }) }}</button>
    </div>
    <div v-if="periodState === 'returned'" class="hours-day__note" data-test="hours-day-returned">
      <span>{{ t('hours_cal.banner_returned', { note: banner?.note || '' }) }}</span>
      <button type="button" class="btn primary hours-day__btn" data-test="hours-resubmit" :disabled="busy" @click="resubmit">{{ t('hours_cal.resubmit') }}</button>
    </div>
    <div class="hours-day__total" data-test="hours-day-total">
      <span>{{ t('hours_cal.total') }}</span>
      <strong dir="ltr">{{ hoursHhmm(cur ? cur.total : 0) }}</strong>
      <span v-if="periodState === 'approved'" class="hours-day__tag" data-test="hours-day-final"><UiIcon name="lock" :size="12" />{{ t('hours_cal.state_final') }}</span>
      <span v-else-if="cur && cur.frozen" class="hours-day__tag" data-test="hours-day-frozen"><UiIcon name="lock" :size="12" />{{ t('hours_cal.state_frozen') }}</span>
      <span class="hours-day__spacer" />
      <button
        v-if="editable && isToday && dayOpen"
        type="button"
        class="btn hours-day__btn"
        data-test="hours-approve-today"
        :disabled="busy"
        @click="approve('today')"
      >{{ t('hours_cal.approve_today') }}</button>
      <button
        v-else-if="editable && isClosed && dayOpen"
        type="button"
        class="btn hours-day__btn"
        data-test="hours-approve-day"
        :disabled="busy"
        @click="approve(day)"
      >{{ t('hours_cal.approve_day') }}</button>
    </div>
    <p v-if="error" class="hours-day__error" role="alert" data-test="hours-day-error">{{ t(error) }}</p>
    <p v-if="undo" class="hours-day__undo" role="status" data-test="hours-undo">
      <span>{{ t('hours_cal.rejected', { name: undo.name }) }}</span>
      <button type="button" class="btn hours-day__btn" data-test="hours-undo-btn" :disabled="busy" @click="undoReject">{{ t('hours_cal.undo') }}</button>
    </p>
    <p v-if="state === 'loading' && !cur" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'failed' && !cur" class="muted" role="alert" data-test="hours-day-failed">{{ t('hours_cal.load_failed') }}</p>
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
        :data-minutes="r.minutes"
        :data-delta="r.delta || 0"
      >
        <div class="hours-day__line">
          <span class="hours-day__what">
            <NuxtLink v-if="r.view.href" class="hours-day__link" data-test="hours-day-link" :to="localePath(r.view.href)" @click="emit('navigate')">{{ r.name }}</NuxtLink>
            <span v-else class="hours-day__name">{{ r.name }}</span>
            <small v-if="r.blocks" class="muted hours-day__blocks" dir="ltr">{{ r.blocks }}</small>
            <small v-if="r.note" class="hours-day__rownote" data-test="hours-day-note">{{ r.note }}</small>
          </span>
          <button
            v-if="editable"
            type="button"
            class="hours-day__min hours-day__minbtn"
            data-test="hours-row-min"
            dir="ltr"
            :aria-label="t('hours_cal.edit_minutes', { name: r.name })"
            :aria-expanded="editing === r.target ? 'true' : 'false'"
            @click="openStepper(r)"
          >{{ hoursHhmm(r.minutes) }}</button>
          <span v-else class="hours-day__min" dir="ltr">{{ hoursHhmm(r.minutes) }}</span>
          <span v-if="!editable" class="hours-day__state muted">{{ t('hours_cal.row_' + (r.state === 'approved' || r.state === 'rejected' ? r.state : 'suggested')) }}</span>
          <template v-else>
            <button type="button" class="hours-day__icon" data-test="hours-row-plus" :disabled="busy" :aria-label="t('hours_cal.plus15', { name: r.name })" :title="t('hours_cal.plus15', { name: r.name })" @click="plus15(r)">+15</button>
            <button
              type="button"
              class="hours-day__icon"
              data-test="hours-row-reject"
              :disabled="busy || r.state === 'rejected'"
              :aria-label="t('hours_cal.reject', { name: r.name })"
              :title="t('hours_cal.reject', { name: r.name })"
              @click="reject(r)"
            ><UiIcon name="x" :size="16" /></button>
          </template>
        </div>
        <div class="hours-day__acts">
          <button
            v-if="editable && r.delta > 0"
            type="button"
            class="btn primary hours-day__act"
            data-test="hours-row-delta"
            :disabled="busy"
            @click="write({ entries: [hoursApproveRow(day, r)] })"
          >✓ +{{ hoursHhmm(r.delta) }}</button>
          <button type="button" class="hours-day__act hours-day__actlink" data-test="hours-row-why" :aria-expanded="why === r.target ? 'true' : 'false'" @click="why = why === r.target ? '' : r.target">{{ t('hours_cal.why') }}</button>
          <button
            v-if="editable"
            type="button"
            class="hours-day__act hours-day__actlink"
            data-test="hours-row-note-edit"
            :aria-expanded="noting === r.target ? 'true' : 'false'"
            @click="openNote(r)"
          >{{ t(r.note ? 'hours_cal.note_edit' : 'hours_cal.note_add') }}</button>
        </div>
        <div v-if="why === r.target" class="hours-day__why" data-test="hours-row-why-sheet">
          <template v-if="r.blockList.length">
            <p class="hours-day__whyhead">{{ t('hours_cal.why_blocks') }}</p>
            <ul class="hours-day__whylist">
              <li v-for="b in r.blockList" :key="b" dir="ltr">{{ b }}</li>
            </ul>
          </template>
          <p v-else>{{ t('hours_cal.why_added') }}</p>
          <p v-if="r.state === 'approved' && r.suggested_minutes !== r.minutes" class="muted">{{ t('hours_cal.why_suggested', { t: hoursHhmm(r.suggested_minutes || 0) }) }}</p>
        </div>
        <div v-if="editing === r.target" class="hours-day__stepper" data-test="hours-stepper">
          <button type="button" class="hours-day__icon" data-test="hours-stepper-minus" :aria-label="t('hours_cal.minus15')" @click="stepTo(-HOURS_STEP)">−15</button>
          <input
            v-model="draftText"
            class="hours-day__input"
            data-test="hours-stepper-input"
            inputmode="numeric"
            dir="ltr"
            :aria-label="t('hours_cal.minutes_label')"
            @keydown.enter.prevent="saveStepper(r)"
          >
          <button type="button" class="hours-day__icon" data-test="hours-stepper-plus" :aria-label="t('hours_cal.plus15_short')" @click="stepTo(HOURS_STEP)">+15</button>
          <button type="button" class="btn primary hours-day__btn" data-test="hours-stepper-save" :disabled="busy" @click="saveStepper(r)">{{ t('hours_cal.save') }}</button>
          <button type="button" class="btn hours-day__btn" @click="editing = ''">{{ t('common.cancel') }}</button>
        </div>
        <div v-if="noting === r.target" class="hours-day__noteedit">
          <label class="hours-day__notelabel">
            <span>{{ t('hours_cal.note_label') }}</span>
            <textarea v-model="noteText" rows="2" data-test="hours-note-input" :maxlength="HOURS_NOTE_MAX" />
          </label>
          <div class="hours-day__noteacts">
            <small class="muted" dir="ltr">{{ [...noteText].length }}/{{ HOURS_NOTE_MAX }}</small>
            <span class="hours-day__spacer" />
            <button type="button" class="btn primary hours-day__btn" data-test="hours-note-save" :disabled="busy" @click="saveNote(r)">{{ t('hours_cal.note_save') }}</button>
            <button type="button" class="btn hours-day__btn" @click="noting = ''">{{ t('common.cancel') }}</button>
          </div>
        </div>
      </li>
    </ul>
    <div v-if="editable" class="hours-day__add">
      <button v-if="!adding" type="button" class="btn hours-day__btn" data-test="hours-add" @click="openAdd">{{ t('hours_cal.add') }}</button>
      <div v-else class="hours-day__addbox" data-test="hours-add-box">
        <template v-if="!addTarget">
          <LazyHoursTargetPicker @pick="addTarget = $event" />
        </template>
        <template v-else>
          <p class="hours-day__addto" data-test="hours-add-target" :data-target="addTarget.target">
            <span>{{ addTarget.label }}</span>
            <button type="button" class="hours-day__act hours-day__actlink" @click="addTarget = null">{{ t('hours_cal.add_change') }}</button>
          </p>
          <div class="hours-day__stepper">
            <button type="button" class="hours-day__icon" data-test="hours-add-minus" :aria-label="t('hours_cal.minus15')" @click="addMinutes = hoursStep(addMinutes, -HOURS_STEP)">−15</button>
            <span class="hours-day__min" data-test="hours-add-minutes" dir="ltr">{{ hoursHhmm(addMinutes) }}</span>
            <button type="button" class="hours-day__icon" data-test="hours-add-plus" :aria-label="t('hours_cal.plus15_short')" @click="addMinutes = hoursStep(addMinutes, HOURS_STEP)">+15</button>
            <button type="button" class="btn primary hours-day__btn" data-test="hours-add-save" :disabled="busy || addMinutes <= 0" @click="saveAdd">{{ t('hours_cal.add_save') }}</button>
          </div>
        </template>
        <button type="button" class="btn hours-day__btn" data-test="hours-add-cancel" @click="adding = false">{{ t('common.cancel') }}</button>
      </div>
    </div>
    <div v-if="periodOpen" class="hours-day__week">
      <button
        type="button"
        class="btn primary hours-day__weekbtn"
        data-test="hours-approve-week"
        :data-open="openCount"
        :disabled="busy || openCount === 0"
        @click="approve('closed')"
      >{{ t('hours_cal.approve_week', { n: openCount }) }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { hoursBanner, hoursFreezeText, hoursBlocksText, hoursHhmm, hoursIndex, hoursSortRows, hoursTarget } from '~/utils/hours-calendar.mjs'
import {
  HOURS_ADD_DEFAULT, HOURS_NOTE_MAX, HOURS_STEP, HOURS_UNDO_MS,
  hoursAddEntry, hoursApproveEntries, hoursApproveRow, hoursDayEditable, hoursEditEntry, hoursOpenCount,
  hoursParseMinutes, hoursRejectEntry, hoursRowOpen, hoursStep, hoursUndoBody,
} from '~/utils/hours-mine.mjs'
import { isoDateTimeIn } from '~/utils/date-iso-zone.mjs'
import { useHoursWrite } from '~/composables/useCalendarHours'
import type { HoursBody, HoursDay, HoursRow } from '~/composables/useCalendarHours'
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

/* the answer of the last write shows at once; the host's re-read (on
   HOURS_CHANGED_EVENT) replaces it */
const local = shallowRef<HoursBody | null>(null)
watch(() => props.body, () => { local.value = null })
const curBody = computed(() => (local.value || props.body || null) as Record<string, any> | null)
const cur = computed<HoursDay | undefined>(() => (local.value ? (hoursIndex([local.value]) as Map<string, HoursDay>).get(props.day) : props.data))
const today = computed(() => String(curBody.value?.today || ''))
const { busy, error, write: put } = useHoursWrite(() => today.value || props.day)

async function write(b: { entries?: unknown[], remove?: unknown[], resubmit?: string }) {
  const out = await put(b)
  if (out) local.value = out
  return out
}

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

const banner = computed(() => (curBody.value ? hoursBanner(curBody.value) : null))
const bannerText = computed(() => {
  const b = banner.value
  if (!b) return ''
  const at = hoursFreezeText(b.freezesAt, props.tz)
  return b.openDays.length
    ? t('hours_cal.banner_open', { n: b.openDays.length, at })
    : t('hours_cal.banner_none', { at })
})

/* T013: what the member may do here (spec 4.1, 4.2) */
const periodState = computed(() => String(curBody.value?.period?.state || 'open'))
const periodOpen = computed(() => Boolean(curBody.value) && (periodState.value === 'open' || periodState.value === 'returned'))
const editable = computed(() => Boolean(curBody.value) && hoursDayEditable({ date: props.day, frozen: Boolean(cur.value?.frozen) }, curBody.value?.period, today.value))
const isToday = computed(() => props.day === today.value)
const isClosed = computed(() => Boolean(today.value) && props.day < today.value)
const dayOpen = computed(() => (cur.value?.rows || []).some(hoursRowOpen))
const openCount = computed(() => (curBody.value ? hoursOpenCount(curBody.value) : 0))

const rows = computed(() => (hoursSortRows(cur.value?.rows || []) as HoursRow[]).map((r) => {
  const view = hoursTarget(r.target, known.value)
  const name = view.label || t(view.kind === 'meeting' ? 'hours_cal.meeting' : 'hours_cal.other')
  const tz = props.tz || 'UTC'
  const blockList = (r.blocks || []).map((b) => `${isoDateTimeIn(b.start, tz).slice(11, 16)}-${isoDateTimeIn(b.end, tz).slice(11, 16)}`)
  return { ...r, delta: Number(r.delta) || 0, view, name, blocks: hoursBlocksText(r.blocks, props.tz), blockList, note: String(r.note || '') }
}))
type ViewRow = (typeof rows.value)[number]

async function approve(which: string) {
  if (!curBody.value) return
  const entries = hoursApproveEntries(curBody.value, which)
  if (entries.length) await write({ entries })
}
async function resubmit() {
  await write({ resubmit: props.day })
}

/* ✕ reject, Undo for 10 s (spec 4.1) */
const undo = shallowRef<{ name: string, prev: HoursRow } | null>(null)
let undoTimer: ReturnType<typeof setTimeout> | null = null
function clearUndo() {
  if (undoTimer) clearTimeout(undoTimer)
  undoTimer = null
  undo.value = null
}
async function reject(r: ViewRow) {
  const prev: HoursRow = { target: r.target, state: r.state, minutes: r.minutes, note: r.note }
  if (!(await write({ entries: [hoursRejectEntry(props.day, r)] }))) return
  clearUndo()
  undo.value = { name: r.name, prev }
  undoTimer = setTimeout(clearUndo, HOURS_UNDO_MS)
}
async function undoReject() {
  const u = undo.value
  if (!u) return
  if (await write(hoursUndoBody(props.day, u.prev))) clearUndo()
}
onBeforeUnmount(clearUndo)

/* T014: +15, the stepper in place, the note per line */
async function plus15(r: ViewRow) {
  await write({ entries: [hoursEditEntry(props.day, r, { minutes: hoursStep(r.minutes, HOURS_STEP) })] })
}
const editing = ref('')
const draftText = ref('')
function openStepper(r: ViewRow) {
  editing.value = editing.value === r.target ? '' : r.target
  draftText.value = hoursHhmm(r.minutes)
}
function stepTo(by: number) {
  const m = hoursParseMinutes(draftText.value)
  draftText.value = hoursHhmm(hoursStep(m < 0 ? 0 : m, by))
}
async function saveStepper(r: ViewRow) {
  const m = hoursParseMinutes(draftText.value)
  if (m < 0) { error.value = 'hours_cal.err_minutes'; return }
  /* a typed number above the cap goes to the hub as typed: its 400 day_cap is the answer shown */
  if (await write({ entries: [{ ...hoursEditEntry(props.day, r, {}), minutes: m, state: 'approved' }] })) editing.value = ''
}
const noting = ref('')
const noteText = ref('')
function openNote(r: ViewRow) {
  noting.value = noting.value === r.target ? '' : r.target
  noteText.value = r.note
}
async function saveNote(r: ViewRow) {
  if (await write({ entries: [hoursEditEntry(props.day, r, { note: noteText.value })] })) noting.value = ''
}
const why = ref('')

/* + Add (spec 5.3): pick a target, 0:30 by default */
const adding = ref(false)
const addTarget = shallowRef<{ target: string, label: string } | null>(null)
const addMinutes = ref(HOURS_ADD_DEFAULT)
function openAdd() {
  adding.value = true
  addTarget.value = null
  addMinutes.value = HOURS_ADD_DEFAULT
}
async function saveAdd() {
  const a = addTarget.value
  if (!a) return
  const had = (cur.value?.rows || []).find((r) => r.target === a.target)
  const entry = had ? hoursEditEntry(props.day, had, { minutes: (had.state === 'rejected' ? 0 : had.minutes) + addMinutes.value }) : hoursAddEntry(props.day, a.target, addMinutes.value)
  if (await write({ entries: [entry] })) adding.value = false
}
</script>

<style scoped>
.hours-day { display: flex; flex-direction: column; gap: 10px; min-inline-size: 0; }
.hours-day__banner,
.hours-day__note,
.hours-day__undo {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin: 0;
  padding: 8px 10px;
  border-radius: var(--radius-sm);
  background: var(--color-selected);
}
.hours-day__banner > span,
.hours-day__note > span,
.hours-day__undo > span { flex: 1 1 12rem; min-inline-size: 0; overflow-wrap: anywhere; }
.hours-day__error { margin: 0; color: var(--color-danger, var(--color-fg)); font-weight: 600; }
.hours-day__total { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0; }
.hours-day__total strong { font-variant-numeric: tabular-nums; }
.hours-day__spacer { flex: 1 1 auto; }
.hours-day__tag { display: inline-flex; align-items: center; gap: 4px; font-size: 0.75rem; }
.hours-day__btn { min-block-size: 36px; }
.hours-day__rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.hours-day__row { display: flex; flex-direction: column; gap: 2px; padding: 4px 0; border-block-end: 1px solid var(--color-border); }
.hours-day__line {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto auto auto;
  align-items: center;
  gap: 4px;
  min-block-size: 44px;
}
.hours-day__row--rejected .hours-day__what,
.hours-day__row--rejected .hours-day__min { text-decoration: line-through; opacity: 0.7; }
.hours-day__what { display: flex; flex-direction: column; min-inline-size: 0; }
.hours-day__link,
.hours-day__name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hours-day__blocks,
.hours-day__rownote { overflow-wrap: anywhere; }
.hours-day__min { font-variant-numeric: tabular-nums; font-weight: 600; }
.hours-day__minbtn,
.hours-day__icon {
  min-inline-size: 44px;
  min-block-size: 44px;
  padding: 0 6px;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: inherit;
  font: inherit;
  cursor: pointer;
}
.hours-day__minbtn { border-color: var(--color-border); font-weight: 600; font-variant-numeric: tabular-nums; }
.hours-day__icon { display: inline-flex; align-items: center; justify-content: center; font-size: 0.8125rem; }
.hours-day__minbtn:hover,
.hours-day__icon:hover:not(:disabled) { background: var(--color-selected); }
.hours-day__icon:disabled { opacity: 0.4; cursor: default; }
.hours-day__state { font-size: 0.75rem; }
.hours-day__acts { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
.hours-day__act { min-block-size: 32px; padding: 0 8px; font-size: 0.8125rem; }
.hours-day__actlink { border: 0; background: transparent; color: var(--color-accent); font: inherit; font-size: 0.8125rem; cursor: pointer; }
.hours-day__why { padding: 6px 10px; border-radius: var(--radius-sm); background: var(--color-selected); font-size: 0.8125rem; }
.hours-day__why p { margin: 0; }
.hours-day__whylist { margin: 4px 0 0; padding-inline-start: 18px; font-variant-numeric: tabular-nums; }
.hours-day__stepper { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
.hours-day__input {
  inline-size: 5.5rem;
  min-block-size: 44px;
  box-sizing: border-box;
  padding: 0 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
  font-variant-numeric: tabular-nums;
  text-align: center;
}
.hours-day__noteedit { display: flex; flex-direction: column; gap: 4px; }
.hours-day__notelabel { display: flex; flex-direction: column; gap: 4px; font-size: 0.8125rem; }
.hours-day__notelabel textarea {
  inline-size: 100%;
  box-sizing: border-box;
  padding: 6px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
  resize: vertical;
}
.hours-day__noteacts { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
.hours-day__add { display: flex; flex-direction: column; gap: 6px; }
.hours-day__addbox { display: flex; flex-direction: column; gap: 6px; max-block-size: 60vh; min-block-size: 0; overflow: auto; }
.hours-day__addto { display: flex; align-items: center; gap: 8px; margin: 0; font-weight: 600; overflow-wrap: anywhere; }
.hours-day__week {
  position: sticky;
  inset-block-end: 0;
  padding-block: 8px;
  background: var(--color-surface);
}
.hours-day__weekbtn { inline-size: 100%; min-block-size: 44px; }
.hours-day__btn:disabled,
.hours-day__weekbtn:disabled { opacity: 0.5; cursor: default; }
@media (max-width: 820px) {
  .hours-day__btn,
  .hours-day__act { min-block-size: 44px; }
}
</style>
