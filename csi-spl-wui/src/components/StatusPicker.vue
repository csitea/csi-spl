<!-- Spec 096 §7.5: "Set a status". Opened from the reader's own row at the
     top of the DM list and from the avatar menu; mounted lazily by the
     default layout while open. A centred card on a desktop, a bottom sheet
     on a phone (<= 820 px), the same fields in both: Available / Busy /
     Unavailable, a note with its 80-character counter, the "until" choices
     of spec §3, Set in all my workspaces (Q2), Pause my notifications while
     unavailable (Q1, off), Save, Clear status. Available is no row: Save on
     Available clears. -->
<template>
  <Teleport v-if="i18nReady" to="body">
    <div class="status-picker-backdrop" data-testid="status-picker-backdrop" @mousedown.self="close" />
    <div
      ref="panelEl"
      class="status-picker"
      role="dialog"
      aria-modal="true"
      :aria-labelledby="titleId"
      data-testid="status-picker"
      tabindex="-1"
      @keydown="onKeydown"
    >
      <span class="status-picker__grip" aria-hidden="true" />
      <header class="status-picker__head">
        <h2 :id="titleId" class="status-picker__title">{{ t('status_edit.title') }}</h2>
        <UiCloseButton side="end" :label="t('common.close')" data-testid="status-close" @click="close" />
      </header>
      <form class="status-picker__body" @submit.prevent="save">
        <fieldset class="status-picker__states">
          <legend class="sr-only">{{ t('status_edit.title') }}</legend>
          <label v-for="s in STATUS_STATES" :key="s" class="status-picker__state" :data-state="s">
            <input
              type="radio"
              name="spool-status-state"
              :value="s"
              :checked="state === s"
              @change="state = s"
              :data-testid="'status-state-' + s"
            >
            <span class="dot" :class="s === 'available' ? 'on' : 'on dot--' + s" aria-hidden="true" />
            <span>{{ t('status_edit.state_' + s) }}</span>
          </label>
        </fieldset>
        <template v-if="state !== 'available'">
          <label class="status-picker__field">
            <span class="status-picker__label">{{ t('status_edit.note_label') }}</span>
            <input
              v-model="note"
              type="text"
              :maxlength="STATUS_NOTE_MAX"
              autocomplete="off"
              data-testid="status-note"
              :placeholder="t('status_edit.note_placeholder')"
              :aria-describedby="counterId"
            >
            <span :id="counterId" class="status-picker__counter muted" data-testid="status-note-count">{{ t('status_edit.note_count', { n: noteLength, max: STATUS_NOTE_MAX }) }}</span>
          </label>
          <label class="status-picker__field">
            <span class="status-picker__label">{{ t('status_edit.until_label') }}</span>
            <select v-model="untilChoice" data-testid="status-until" @change="untilTouched = true">
              <option v-for="c in STATUS_UNTIL_CHOICES" :key="c" :value="c">{{ t('status_edit.until_' + c) }}</option>
            </select>
          </label>
          <label v-if="untilChoice === 'custom'" class="status-picker__field">
            <span class="status-picker__label">{{ t('status_edit.until_custom_label') }}</span>
            <input v-model="customUntil" type="datetime-local" data-testid="status-until-custom">
          </label>
          <label v-if="state === 'unavailable'" class="status-picker__check">
            <input v-model="pauseNotify" type="checkbox" data-testid="status-pause-notify">
            <span>{{ t('status_edit.pause_notify') }}</span>
          </label>
        </template>
        <label class="status-picker__check">
          <input v-model="allWorkspaces" type="checkbox" data-testid="status-all-workspaces">
          <span>{{ t('status_edit.all_workspaces') }}</span>
        </label>
        <p class="status-picker__privacy muted">{{ t('status_edit.privacy') }}</p>
        <p v-if="error" class="status-picker__error" role="alert" data-testid="status-error">{{ t(error) }}</p>
        <div class="status-picker__actions">
          <button
            v-if="current"
            type="button"
            class="btn ghost"
            data-testid="status-clear"
            :disabled="busy"
            @click="clear"
          >{{ t('status_edit.clear') }}</button>
          <button type="submit" class="btn" data-testid="status-save" :disabled="busy">{{ t('status_edit.save') }}</button>
        </div>
      </form>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import UiCloseButton from '~/components/UiCloseButton.vue'
import { useRosterStore } from '~/stores/roster'
import { useHumanStatusStore } from '~/stores/human-status'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useStatusPicker } from '~/composables/useStatusPicker'
import { useMobileStack } from '~/composables/useMobileStack'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { STATUS_NOTE_MAX, STATUS_STATES, STATUS_UNTIL_CHOICES, cleanStatusNote, defaultUntilChoice, liveStatus, putMyStatus, statusBody, untilFromChoice, untilProblem } from '~/utils/human-status.mjs'

const { t, te } = useI18n({ useScope: 'global' })
/* its words are in the second catalogue (i18n-first-screen ON_DEMAND_COMPONENTS),
   merged when the browser is first idle (plugins/i18n-more.client.ts): shown once there */
const i18nReady = computed(() => te('status_edit.title'))
const roster = useRosterStore()
const status = useHumanStatusStore()
const api = useSpoolApi()
const picker = useStatusPicker()
const titleId = useId()
const counterId = useId()
const panelEl = ref<HTMLElement | null>(null)

const current = computed(() => liveStatus(status.statusByPeer[roster.self?.id || ''] || null))
const start = current.value
const state = ref<string>(start ? start.state : 'available')
const note = ref(start ? start.note : '')
/* a status that has an end opens on that end, as a custom time */
const untilChoice = ref(start ? (start.until ? 'custom' : 'none') : defaultUntilChoice('available'))
const customUntil = ref(start && start.until ? isoDateTime(start.until).replace(' ', 'T') : '')
const untilTouched = ref(Boolean(start))
const allWorkspaces = ref(false)
const pauseNotify = ref(false)
const busy = ref(false)
const error = ref('')

const noteLength = computed(() => Array.from(note.value).length)

/* spec §9: a new state brings its default end (Busy: no end, Unavailable:
   1 hour) until the member picks one themselves */
watch(state, (s) => {
  error.value = ''
  if (!untilTouched.value) untilChoice.value = defaultUntilChoice(s)
  if (s !== 'unavailable') pauseNotify.value = false
})

function close() {
  picker.hide()
}

async function run(body: Record<string, unknown> | null) {
  /* "Set in all my workspaces" clears in all of them too (DELETE ?all_workspaces=true) */
  const allWs = allWorkspaces.value
  busy.value = true
  error.value = ''
  try {
    const peer = roster.self?.id || ''
    await putMyStatus(api, peer, body, { allWorkspaces: allWs })
    /* the hub's frame follows; the reader's own row shows at once */
    if (peer) await status.applyStatus(body ? { type: 'status', peer, ...body } : { type: 'status', peer, state: 'available' })
    close()
  } catch (e) {
    const status = (e as { status?: number })?.status
    error.value = status === 400 ? 'status_edit.err_refused' : 'status_edit.err_save'
  } finally {
    busy.value = false
  }
}

function save() {
  if (state.value === 'available') return void run(null)
  const until = untilFromChoice(untilChoice.value, Date.now(), customUntil.value)
  const problem = untilProblem(until)
  if (problem) {
    error.value = problem
    return
  }
  void run(statusBody({
    state: state.value,
    note: cleanStatusNote(note.value),
    until: until || '',
    allWorkspaces: allWorkspaces.value,
    pauseNotify: pauseNotify.value,
  }))
}

function clear() {
  void run(null)
}

/* a dialog keeps the focus inside: Tab wraps, Escape closes */
function onKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') {
    e.preventDefault()
    close()
    return
  }
  if (e.key !== 'Tab' || !panelEl.value) return
  const items = [...panelEl.value.querySelectorAll<HTMLElement>('button, input, select, [tabindex="0"]')]
    .filter((el) => !el.hasAttribute('disabled') && el.offsetParent !== null)
  if (!items.length) return
  const first = items[0]!
  const last = items[items.length - 1]!
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault()
    last.focus()
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault()
    first.focus()
  }
}

/* phone: Back closes the sheet first (SPL-994) */
useMobileStack().overlay(() => picker.open.value, close)

let returnFocusTo: HTMLElement | null = null
onMounted(() => {
  returnFocusTo = document.activeElement instanceof HTMLElement ? document.activeElement : null
})
/* the panel exists once its words are merged: focus the chosen state then */
watch(i18nReady, (ok) => {
  if (!ok) return
  void nextTick(() => {
    const checked = panelEl.value?.querySelector<HTMLInputElement>('input[type=radio]:checked')
    ;(checked || panelEl.value)?.focus()
  })
}, { immediate: true })
onBeforeUnmount(() => {
  if (returnFocusTo && document.contains(returnFocusTo)) returnFocusTo.focus()
})
</script>

<style scoped>
.status-picker-backdrop {
  position: fixed;
  inset: 0;
  z-index: var(--z-modal);
  background: rgb(0 0 0 / .45);
}
.status-picker {
  position: fixed;
  z-index: var(--z-modal);
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: min(26rem, calc(100vw - 32px));
  max-height: calc(100dvh - 32px);
  overflow-y: auto;
  background: var(--color-bg);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  box-shadow: 0 12px 40px rgb(0 0 0 / .35);
  padding: 12px 16px 16px;
}
.status-picker__grip { display: none; }
.status-picker__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 8px;
}
.status-picker__title { margin: 0; font-size: 1.0625rem; }
.status-picker__body { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.status-picker__states {
  display: flex;
  flex-direction: column;
  gap: 2px;
  margin: 0;
  padding: 0;
  border: 0;
}
.status-picker__state {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: var(--tap);
  padding: 4px 8px;
  border-radius: var(--radius-sm);
  cursor: pointer;
}
.status-picker__state:hover { background: var(--color-surface); }
.status-picker__field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.status-picker__label { font-size: 0.8125rem; color: var(--color-muted); }
.status-picker__field input,
.status-picker__field select {
  min-height: var(--tap);
  min-width: 0;
  max-width: 100%;
  padding: 6px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
}
.status-picker__counter { align-self: flex-end; font-size: 0.75rem; }
.status-picker__check {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  font-size: 0.875rem;
  cursor: pointer;
}
.status-picker__check input { margin-top: 3px; }
.status-picker__privacy { margin: 0; font-size: 0.8125rem; }
.status-picker__error { margin: 0; color: var(--color-danger); font-size: 0.875rem; }
.status-picker__actions { display: flex; justify-content: flex-end; flex-wrap: wrap; gap: 8px; }

/* phone: the same fields in a bottom sheet over a scrim */
@media (max-width: 820px) {
  .status-picker {
    top: auto;
    left: 0;
    right: 0;
    bottom: 0;
    transform: none;
    width: 100%;
    max-height: 85dvh;
    border-radius: var(--radius-lg) var(--radius-lg) 0 0;
    border-bottom: 0;
    padding-bottom: calc(16px + env(safe-area-inset-bottom, 0px));
  }
  .status-picker__grip {
    display: block;
    width: 40px;
    height: 4px;
    margin: 0 auto 8px;
    border-radius: var(--radius-pill);
    background: var(--color-border);
  }
  .status-picker__actions .btn { flex: 1 1 0; min-height: var(--tap); }
}
</style>
