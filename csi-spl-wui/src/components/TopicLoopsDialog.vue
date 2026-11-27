<!-- Spec 182 row L3 (SPL-6034; HUM-10, t1 f08c0c58 msg 19acb8f9): behind a
     topic card's Discussion loops… entry. It lists the topic's loops (first
     line of the prompt, the checked triggers, on / paused / held until hh:mm
     by the cap, the author) with Edit, Pause / Resume and Delete per row, and
     Add loop. Add and Edit share one form: the prompt and the twelve trigger
     radios of section 1.2 (v0.4 less Q11 C's "before each human reply"), with each box's own field next to it:
     n for "each n minutes" and "no reply for n minutes", the word or phrase
     for "a post that contains", a time and a zone (the browser's to start)
     for "every day at". At least one box must be checked, and a field is
     required exactly when its box is (utils/topic-loops.mjs loopFormError). The routes are those of
     section 7.1.2; the hub re-checks the archive policy on every write, and
     `may_edit` from the list read locks the buttons. A `topic_loops` frame
     (another tab or member) replaces the list. Loaded lazily
     (LazyTopicLoopsDialog): needed only after the entry is picked.
     Spec 182 v0.11 (HUM-10, t1 6e8c1cdb): one trigger per loop, a radio
     group (msg febf1db4, SPL-6582); the trigger with its parameter is the
     loop's title, set the moment a radio is picked and shown on the list row
     above the prompt's first line (msgs 543a5bde, 9e3161d9, a04bba37,
     SPL-6580 / SPL-6581). A loop stored with several triggers names them on
     its row; its form opens on the first and says a save keeps only one. -->
<template>
  <!-- v0.11 changes 4 and 5 (msgs e68509d5, ac0a7377): dragged by its header, 70% wide, 10% from the top -->
  <UiDialog :open="open" :title="t('feed.topic_loops.title')" size="wide" draggable @update:open="emit('update:open', $event)">
    <div class="topic-loops" data-testid="topic-loops">
      <p v-if="error" class="topic-loops__error" role="alert" data-testid="topic-loops-error">{{ t(error) }}</p>
      <form v-if="form" class="topic-loops__form" data-testid="topic-loops-form" @submit.prevent="save">
        <h3 v-if="formTitle" class="topic-loops__title" data-testid="topic-loops-form-title">{{ formTitle }}</h3>
        <!-- v0.11 change 11 (msgs 534340d9, ca849d36, SPL-6592): two columns on a desktop, the prompt left, Run it right -->
        <div class="topic-loops__cols" data-testid="topic-loops-cols">
        <label class="topic-loops__field">
          <span>{{ t('feed.topic_loops.prompt') }}</span>
          <textarea
            v-model="form.prompt"
            data-autofocus
            rows="5"
            :maxlength="LOOP_PROMPT_MAX"
            :placeholder="t('feed.topic_loops.prompt_placeholder')"
            :disabled="busy"
            data-testid="topic-loops-prompt"
          />
        </label>
        <fieldset class="topic-loops__triggers" :disabled="busy">
          <legend>{{ t('feed.topic_loops.triggers') }}</legend>
          <p v-if="form.others.length" class="topic-loops__note" data-testid="topic-loops-multi-note">{{ t('feed.topic_loops.multi_note', { triggers: othersText }) }}</p>
          <div v-for="k in LOOP_TRIGGERS" :key="k" class="topic-loops__trigger">
            <label>
              <input v-model="form.trigger" type="radio" name="topic-loops-trigger" :value="k" :data-testid="'topic-loops-trigger-' + k">
              <span>{{ t('feed.topic_loops.trigger.' + k) }}</span>
            </label>
            <input
              v-if="k === LOOP_EVERY_N || k === LOOP_IDLE"
              v-model.number="form[k === LOOP_IDLE ? 'idle' : 'interval']"
              class="topic-loops__interval"
              type="number"
              :min="LOOP_INTERVAL_MIN"
              :max="LOOP_INTERVAL_MAX"
              :aria-label="t('feed.topic_loops.interval', { min: LOOP_INTERVAL_MIN, max: LOOP_INTERVAL_MAX })"
              :data-testid="k === LOOP_IDLE ? 'topic-loops-idle' : 'topic-loops-interval'"
            >
            <input
              v-if="k === LOOP_KEYWORD"
              v-model="form.keyword"
              class="topic-loops__keyword"
              type="text"
              :maxlength="LOOP_KEYWORD_MAX"
              :aria-label="t('feed.topic_loops.keyword')"
              :placeholder="t('feed.topic_loops.keyword')"
              data-testid="topic-loops-keyword"
            >
            <template v-if="k === LOOP_DAILY">
              <!-- SPL-6589: a 24-hour HH:MM field, never the locale's AM/PM; loopFormError checks it -->
              <input
                v-model.trim="form.dailyAt"
                class="topic-loops__time"
                type="text"
                inputmode="numeric"
                maxlength="5"
                pattern="([01][0-9]|2[0-3]):[0-5][0-9]"
                placeholder="HH:MM"
                :aria-label="t('feed.topic_loops.daily_time')"
                data-testid="topic-loops-daily-at"
              >
              <input
                v-model="form.dailyTz"
                class="topic-loops__zone"
                type="text"
                list="topic-loops-zones"
                :aria-label="t('feed.topic_loops.daily_tz')"
                :title="t('feed.topic_loops.daily_tz')"
                data-testid="topic-loops-daily-tz"
              >
              <datalist id="topic-loops-zones">
                <option v-for="z in zones" :key="z" :value="z" />
              </datalist>
            </template>
            <small v-if="k === 'after_agent_reply'" class="topic-loops__note">{{ t('feed.topic_loops.self_fire_note') }}</small>
          </div>
        </fieldset>
        </div>
        <div class="topic-loops__actions">
          <button type="button" class="btn ghost" data-testid="topic-loops-cancel" :disabled="busy" @click="closeForm">{{ t('common.cancel') }}</button>
          <button type="submit" class="btn primary" data-testid="topic-loops-save" :disabled="busy">{{ t('feed.topic_loops.save') }}</button>
        </div>
      </form>
      <template v-else>
        <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
        <p v-else-if="!loops.length" class="muted" data-testid="topic-loops-empty">{{ t('feed.topic_loops.empty') }}</p>
        <ul v-else ref="listEl" class="topic-loops__list" data-testid="topic-loops-list">
          <li
            v-for="l in shown"
            :key="l.loop_id"
            class="topic-loops__row"
            :class="{ 'topic-loops__row--dragging': drag.draggingId.value === l.loop_id }"
            data-testid="topic-loops-row"
            :data-state="loopRowState(l).state"
            :data-reorder-id="l.loop_id"
          >
            <!-- v0.11 change 8 (SPL-6587): drag the grip (mouse, pen, touch),
                 or Arrow Up / Down on the focused grip -->
            <button
              type="button"
              class="topic-loops__grip"
              data-testid="topic-loops-grip"
              :disabled="!writable || loops.length < 2"
              :aria-label="t('settings.rail_order.drag')"
              :title="lockTitle || t('settings.rail_order.drag')"
              aria-keyshortcuts="ArrowUp ArrowDown"
              @pointerdown="drag.down($event, l.loop_id)"
              @keydown.up.prevent="step(l.loop_id, -1)"
              @keydown.down.prevent="step(l.loop_id, 1)"
            >
              <UiIcon name="grip" :size="18" />
            </button>
            <div class="topic-loops__body">
              <p class="topic-loops__first" data-testid="topic-loops-row-title">{{ loopTitle(l, t, locale) }}</p>
              <p class="topic-loops__prompt" data-testid="topic-loops-row-prompt">{{ loopFirstLine(l.prompt) }}</p>
              <p class="topic-loops__meta muted">
                <span data-testid="topic-loops-row-state">{{ stateText(l) }}</span>
                <span>{{ t('feed.topic_loops.by', { who: people.label(l.set_by) }) }}</span>
              </p>
              <div class="topic-loops__row-actions">
                <button type="button" class="icon-btn" data-testid="topic-loops-edit" :disabled="!writable" :aria-label="t('feed.topic_loops.edit')" :title="lockTitle || t('feed.topic_loops.edit')" @click="openForm(l)">
                  <UiIcon name="pencil" :size="16" />
                </button>
                <button type="button" class="icon-btn" data-testid="topic-loops-pause" :disabled="!writable" :aria-label="pauseLabel(l)" :title="lockTitle || pauseLabel(l)" @click="toggle(l)">
                  <UiIcon :name="l.state === 'paused' ? 'play' : 'pause'" :size="16" />
                </button>
                <button type="button" class="icon-btn" data-testid="topic-loops-delete" :disabled="!writable" :aria-label="t('feed.topic_loops.delete')" :title="lockTitle || t('feed.topic_loops.delete')" @click="remove(l)">
                  <UiIcon name="trash" :size="16" />
                </button>
              </div>
            </div>
          </li>
        </ul>
        <p class="sr-only" role="status" aria-live="polite">{{ announce }}</p>
        <p v-if="!loading && !mayEdit" class="muted" data-testid="topic-loops-locked">{{ t('feed.topic_loops.locked') }}</p>
        <div class="topic-loops__actions">
          <button type="button" class="btn primary" data-testid="topic-loops-add" :disabled="!writable" :title="lockTitle" @click="openForm(null)">{{ t('feed.topic_loops.add') }}</button>
        </div>
      </template>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useHumanNames } from '~/composables/useHumanNames'
import { useLive } from '~/composables/useLive'
import { useDragReorder } from '~/composables/useDragReorder'
import { moveBy } from '~/utils/rail-order'
import { createLatest } from '~/utils/latest-only.mjs'
import { browserTimeZone, isoClock, knownTimeZones } from '~/utils/date-iso.mjs'
import {
  LOOP_DAILY, LOOP_EVERY_N, LOOP_IDLE, LOOP_INTERVAL_MAX, LOOP_INTERVAL_MIN, LOOP_KEYWORD, LOOP_KEYWORD_MAX, LOOP_PROMPT_MAX, LOOP_TRIGGERS,
  emptyLoopForm, formLoop, formOthersLoop, loopBody, loopErrorKey, loopFirstLine, loopForm, loopFormError, loopRowState, loopsFromFrame, loopTitle,
} from '~/utils/topic-loops.mjs'
import type { TopicLoop, TopicLoopForm } from '~/utils/topic-loops'

const props = defineProps<{ open: boolean, taskId: string }>()
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t, locale } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const people = useHumanNames()

const loops = ref<TopicLoop[]>([])
const mayEdit = ref(false)
const loading = ref(true)
const busy = ref(false)
const error = ref('')
/* null: the list; else the form, with the loop it edits ('' = a new one) */
const form = ref<TopicLoopForm | null>(null)
const editing = ref('')

const writable = computed(() => mayEdit.value && !busy.value && !loading.value)
const lockTitle = computed(() => (mayEdit.value ? undefined : t('feed.topic_loops.locked')))
// Icon-only row buttons (SPL-6585): the label is the hover title and the aria-label.
const pauseLabel = (l: TopicLoop) => t(l.state === 'paused' ? 'feed.topic_loops.resume' : 'feed.topic_loops.pause')

/* a new loop's zone is the browser's (4.1 step 2); the list is read once, on the form */
const tz = browserTimeZone() || 'UTC'
const zones = computed(() => (form.value ? knownTimeZones() : []))

/* the title follows the picked radio and its field (v0.11, change 1) */
const formTitle = computed(() => (form.value ? loopTitle(formLoop(form.value), t, locale.value) : ''))
const othersText = computed(() => (form.value ? loopTitle(formOthersLoop(form.value), t, locale.value) : ''))

function stateText(l: TopicLoop): string {
  const s = loopRowState(l)
  if (s.state === 'held') return t('feed.topic_loops.state_held', { time: isoClock(s.until) })
  if (s.state === 'idle') return t(s.why)
  return t(s.state === 'paused' ? 'feed.topic_loops.state_paused' : 'feed.topic_loops.state_on')
}

/* the dialog can re-open for another topic while a read is in flight */
const latest = createLatest()
async function load() {
  const mine = latest.next()
  loading.value = true
  error.value = ''
  try {
    const out = await api.listTopicLoops(props.taskId)
    if (!latest.isLatest(mine)) return
    loops.value = Array.isArray(out?.loops) ? out.loops : []
    mayEdit.value = out?.may_edit === true
  } catch (e) {
    if (latest.isLatest(mine)) error.value = loopErrorKey(e)
  } finally {
    if (latest.isLatest(mine)) loading.value = false
  }
}

function openForm(l: TopicLoop | null) {
  error.value = ''
  editing.value = l ? l.loop_id : ''
  form.value = l ? loopForm(l, tz) : emptyLoopForm(tz)
}

function closeForm() {
  form.value = null
  editing.value = ''
  error.value = ''
}

/* every write answers the loop; the list is re-read so it matches the hub */
async function run(write: () => Promise<unknown>): Promise<boolean> {
  if (busy.value) return false
  busy.value = true
  error.value = ''
  try {
    await write()
    await load()
    return true
  } catch (e) {
    error.value = loopErrorKey(e)
    return false
  } finally {
    busy.value = false
  }
}

async function save() {
  if (!form.value) return
  const bad = loopFormError(form.value)
  if (bad) {
    error.value = bad
    return
  }
  const body = loopBody(form.value)
  const id = editing.value
  const ok = await run(() => (id ? api.editTopicLoop(props.taskId, id, body) : api.addTopicLoop(props.taskId, body)))
  if (ok) closeForm()
}

function toggle(l: TopicLoop) {
  void run(() => api.editTopicLoop(props.taskId, l.loop_id, { state: l.state === 'paused' ? 'on' : 'paused' }))
}

function remove(l: TopicLoop) {
  void run(() => api.deleteTopicLoop(props.taskId, l.loop_id))
}

/* v0.11 change 8 (SPL-6587): the order is the hub's (PUT .../loops/order).
   The list shows the new order at once; a refused write reads it back. */
const listEl = ref<HTMLElement | null>(null)
const announce = ref('')
const drag = useDragReorder<string>({
  order: () => loops.value.map((l) => l.loop_id),
  items: () => [...(listEl.value?.querySelectorAll<HTMLElement>('[data-reorder-id]') || [])],
  onDrop: (next) => { void reorder(next) },
})
const shown = computed(() => {
  const ids = drag.preview.value
  if (!ids) return loops.value
  const byId = new Map(loops.value.map((l) => [l.loop_id, l]))
  return ids.map((id) => byId.get(id)).filter((l): l is TopicLoop => Boolean(l))
})

async function reorder(ids: string[]): Promise<boolean> {
  const byId = new Map(loops.value.map((l) => [l.loop_id, l]))
  loops.value = ids.map((id) => byId.get(id)).filter((l): l is TopicLoop => Boolean(l))
  const ok = await run(() => api.orderTopicLoops(props.taskId, ids))
  if (!ok) void load()
  return ok
}

async function step(id: string, delta: number) {
  const order = loops.value.map((l) => l.loop_id)
  const next = moveBy(order, id, delta)
  if (next.every((x, i) => x === order[i]) || !(await reorder(next))) return
  const l = loops.value.find((x) => x.loop_id === id)
  announce.value = t('settings.rail_order.moved', { name: l ? loopTitle(l, t, locale.value) : id, n: loops.value.findIndex((x) => x.loop_id === id) + 1 })
  /* the grip was disabled while the write ran: give the keyboard it back */
  await nextTick()
  listEl.value?.querySelector<HTMLButtonElement>(`[data-reorder-id="${id}"] [data-testid=topic-loops-grip]`)?.focus()
}

function onFrame(f: unknown) {
  const next = loopsFromFrame(f, props.taskId)
  if (next && !busy.value) loops.value = next as TopicLoop[]
}

watch(() => [props.open, props.taskId], ([open]) => { if (open) void load() })
onMounted(() => { if (props.open) void load() })
let offFrame: () => void = () => {}
if (import.meta.client) {
  if (api.mock) void api.onMockTopicLoops(onFrame).then((off) => { offFrame = off })
  else offFrame = useLive().onTopic(onFrame)
}
onUnmounted(() => offFrame())
</script>

<style scoped>
.topic-loops { display: flex; flex-direction: column; gap: 12px; padding: 14px; min-width: 0; }
.topic-loops__error { color: var(--color-danger); margin: 0; }
/* SPL-6593: no text in the dialog under the omnibox's size; fields do not inherit font-size */
.topic-loops :is(textarea, input, select) { font-size: var(--omnibox-fs); }
.topic-loops__form { display: flex; flex-direction: column; gap: 12px; }
.topic-loops__field { display: flex; flex-direction: column; gap: 4px; }
/* v0.11 change 7 (msg ae3a2d5c, SPL-6586): still resizable; by default about
   17% of the screen's height (the owner's hand-sized box, ~11 lines) */
.topic-loops__field textarea { width: 100%; resize: vertical; height: 17vh; min-height: 6lh; }
.topic-loops__cols { display: grid; grid-template-columns: minmax(0, 1fr); gap: 12px; align-items: start; }
@media (min-width: 601px) {
  .topic-loops__cols { grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); }
}
.topic-loops__triggers { border: 1px solid var(--color-border); border-radius: var(--radius-sm); padding: 8px 12px; display: flex; flex-direction: column; gap: 6px; }
.topic-loops__trigger { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
.topic-loops__trigger label { display: inline-flex; align-items: center; gap: 6px; }
.topic-loops__interval { width: 6em; }
.topic-loops__keyword { flex: 1 1 10em; min-width: 0; }
.topic-loops__zone { flex: 1 1 12em; min-width: 0; }
.topic-loops__time { flex: 0 0 auto; width: 6ch; font-variant-numeric: tabular-nums; }
.topic-loops__note { flex-basis: 100%; padding-left: 24px; font-size: var(--omnibox-fs); color: var(--color-muted); }
.topic-loops__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.topic-loops__row { display: flex; gap: 8px; border: 1px solid var(--color-border); border-radius: var(--radius-sm); padding: 8px 12px 8px 4px; }
.topic-loops__row--dragging { background: var(--color-surface-hover); }
.topic-loops__body { flex: 1 1 auto; min-width: 0; }
/* the grip: pointer drag, and touch without the page panning under it */
.topic-loops__grip { flex: 0 0 auto; display: grid; place-items: center; min-width: 32px; padding: 0; border: 0; background: none; color: var(--color-muted); cursor: grab; touch-action: none; }
.topic-loops__grip:disabled { cursor: default; opacity: 0.4; }
.topic-loops__row--dragging .topic-loops__grip { cursor: grabbing; }
.topic-loops__title { margin: 0; font-size: 1rem; font-weight: 600; color: var(--color-heading); overflow-wrap: anywhere; }
.topic-loops__first { margin: 0; font-weight: 600; overflow-wrap: anywhere; }
.topic-loops__prompt { margin: 2px 0 0; overflow-wrap: anywhere; }
.topic-loops__meta { margin: 4px 0; font-size: var(--omnibox-fs); display: flex; flex-wrap: wrap; gap: 4px 12px; }
/* R7 a-099 N2: a locked or busy row's icon buttons look disabled */
.topic-loops__row-actions .icon-btn:disabled { opacity: 0.4; cursor: default; }
.topic-loops__row-actions, .topic-loops__actions { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 6px; }
</style>
