<!-- Spec 107 Q7 = B (T019): the header's start/stop timer for time worked
     outside the app. A lazy chunk: TopBar draws a plain button and mounts
     this on the first click, or at once when this device holds a running
     timer (utils/hours-timer.mjs says where and why it is kept there).
     Idle: the button opens the target picker; a pick starts the timer.
     Running: the button shows the time; it opens Stop / Discard. Stop sends
     the interval once (POST /v1/me/hours/timer); a refusal is said in words
     and keeps the interval for Retry or Discard. Its strings are in the
     second catalogue (i18n-first-screen.mjs ON_DEMAND_COMPONENTS). -->
<template>
  <span class="hours-timer" data-test="hours-timer" :data-state="state">
    <button
      type="button"
      class="hours-timer__btn icon-btn"
      :class="{ 'hours-timer__btn--running': !!row, 'hours-timer__btn--refused': !!row?.stopped }"
      data-test="hours-timer-button"
      :aria-label="buttonLabel"
      :title="buttonLabel"
      @click="dialogOpen = true"
    >
      <UiIcon name="history" :size="18" />
      <span v-if="row" class="hours-timer__clock" data-test="hours-timer-clock">{{ clock }}</span>
    </button>
    <UiDialog :open="dialogOpen" :title="ready ? t('hours_timer.title') : ''" size="md" @update:open="onDialog">
      <div v-if="ready" class="hours-timer__body" data-test="hours-timer-dialog">
        <p v-if="done" class="hours-timer__done" role="status" data-test="hours-timer-done">
          {{ t('hours_timer.done', { time: done.time, target: done.label }) }}
        </p>
        <template v-if="row">
          <p class="hours-timer__now">
            <span class="hours-timer__target" data-test="hours-timer-target">{{ row.label }}</span>
            <span class="hours-timer__big" data-test="hours-timer-elapsed">{{ clock }}</span>
          </p>
          <p v-if="refusal" class="hours-timer__err" role="alert" data-test="hours-timer-error">{{ refusal }}</p>
          <div class="hours-timer__actions">
            <button type="button" class="btn primary" data-test="hours-timer-stop" :disabled="busy" @click="stop">
              {{ row.stopped ? t('hours_timer.retry') : t('hours_timer.stop') }}
            </button>
            <button type="button" class="btn ghost" data-test="hours-timer-discard" :disabled="busy" @click="discard">
              {{ t('hours_timer.discard') }}
            </button>
          </div>
        </template>
        <template v-else>
          <p class="muted hours-timer__hint">{{ t('hours_timer.hint') }}</p>
          <HoursTargetPicker @pick="start" />
        </template>
      </div>
    </UiDialog>
  </span>
</template>

<script setup lang="ts">
import HoursTargetPicker from '~/components/HoursTargetPicker.vue'
import UiDialog from '~/components/UiDialog.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import {
  hoursTimerClock, hoursTimerMinutes, hoursTimerOwner, hoursTimerRead, hoursTimerRefusalKey, hoursTimerWrite, postHoursTimer,
  type HoursTimerRow,
} from '~/utils/hours-timer.mjs'

const props = withDefaults(defineProps<{ ask?: boolean }>(), { ask: false })
const { t, te } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

/* the second catalogue holds these strings; the dialog waits for it */
const ready = computed(() => te('hours_timer.title'))
const owner = computed(() => hoursTimerOwner(String(session.claims?.t || api.tenant || ''), String(session.claims?.hum || '')))
const row = ref<HoursTimerRow | null>(null)
const now = ref(Date.now())
const dialogOpen = ref(props.ask)
const busy = ref(false)
const refusal = ref('')
const done = ref<{ time: string, label: string } | null>(null)
let tick: ReturnType<typeof setInterval> | null = null

const state = computed(() => (!row.value ? 'idle' : row.value.stopped ? 'refused' : 'running'))
const clock = computed(() => {
  const r = row.value
  if (!r) return ''
  const end = r.stopped ? Date.parse(r.stopped) : now.value
  return hoursTimerClock(end - Date.parse(r.start))
})
const buttonLabel = computed(() => {
  if (!ready.value) return ''
  return row.value ? t('hours_timer.running', { target: row.value.label, time: clock.value }) : t('hours_timer.start')
})

function storage(): Storage | null {
  try { return window.localStorage } catch { return null }
}
function save(next: HoursTimerRow | null) {
  row.value = next
  const s = storage()
  if (s) hoursTimerWrite(s, owner.value, next)
  syncTick()
}
function syncTick() {
  const want = !!row.value && !row.value.stopped
  if (want && !tick) tick = setInterval(() => { now.value = Date.now() }, 1000)
  if (!want && tick) { clearInterval(tick); tick = null }
  now.value = Date.now()
}
function load() {
  const s = storage()
  row.value = s ? hoursTimerRead(s, owner.value) : null
  syncTick()
}

function start(pick: { target: string, label: string }) {
  done.value = null
  refusal.value = ''
  save({ target: pick.target, label: pick.label, start: new Date().toISOString(), stopped: '' })
  dialogOpen.value = false
}

async function stop() {
  const r = row.value
  if (!r || busy.value) return
  /* the stop time is kept: a Retry after a refusal sends the same interval */
  const stopped = r.stopped || new Date().toISOString()
  if (!r.stopped) save({ ...r, stopped })
  busy.value = true
  refusal.value = ''
  try {
    const out = await postHoursTimer(api, { target: r.target, start: r.start, end: stopped })
    const minutes = (out.written || []).reduce((n, p) => n + (Number(p.minutes) || 0), 0)
    done.value = { time: hoursTimerMinutes(minutes), label: r.label }
    save(null)
  } catch (err) {
    const detail = err && typeof err === 'object' ? String((err as { detail?: string }).detail || '') : ''
    refusal.value = t(hoursTimerRefusalKey(err), { detail })
  } finally {
    busy.value = false
  }
}

function discard() {
  refusal.value = ''
  save(null)
  dialogOpen.value = false
}

function onDialog(open: boolean) {
  dialogOpen.value = open
  if (!open) done.value = null
}

/* another tab of this browser started or stopped it */
function onStorage(ev: StorageEvent) {
  if (ev.key === null || ev.key === 'spool.hours-timer') load()
}
watch(owner, load)
onMounted(() => {
  load()
  window.addEventListener('storage', onStorage)
})
onUnmounted(() => {
  if (tick) clearInterval(tick)
  window.removeEventListener('storage', onStorage)
})
</script>

<style scoped>
.hours-timer { display: inline-flex; align-items: center; min-width: 0; }
.hours-timer__btn { display: inline-flex; align-items: center; gap: 4px; min-width: 0; }
.hours-timer__btn--running { color: var(--color-accent); }
.hours-timer__btn--refused { color: var(--color-danger, var(--color-accent)); }
.hours-timer__clock { font-variant-numeric: tabular-nums; font-size: 0.8125rem; white-space: nowrap; }
.hours-timer__body { display: flex; flex-direction: column; gap: 0.75rem; padding: 0.5rem 1rem 1rem; min-width: 0; }
.hours-timer__now { display: flex; flex-direction: column; gap: 0.25rem; margin: 0; min-width: 0; }
.hours-timer__target { overflow-wrap: anywhere; font-weight: 600; }
.hours-timer__big { font-size: 1.75rem; font-variant-numeric: tabular-nums; }
.hours-timer__hint, .hours-timer__done, .hours-timer__err { margin: 0; }
.hours-timer__err { color: var(--color-danger, inherit); }
.hours-timer__actions { display: flex; flex-wrap: wrap; gap: 0.5rem; }
.hours-timer__actions .btn { min-height: 44px; }
</style>
