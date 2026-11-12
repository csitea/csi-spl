<!-- Spec 155 2.9 (SPL-4652, owner HUM-10, t1 2a0b4d9e msg a4c630a8): the open
     note's priority, the pattern of TopicPriorityChooser: one row of native
     radios in one named group (Tab lands on the group, the arrows move), the
     current value checked. A click saves at once; a failed save puts the old
     value back and says why. The list row follows through the store.
     SPL-5349: the topic chooser's size and its fading "✓ N" right of the
     bar; screen readers hear the whole sentence. -->
<template>
  <div class="note-prio" data-test="note-priority" :data-priority="value">
    <span :id="labelId" class="note-prio__label">{{ t('topic.priority.short') }}</span>
    <div class="note-prio__group" role="radiogroup" :aria-labelledby="labelId">
      <label
        v-for="n in LEVELS"
        :key="n"
        class="note-prio__opt"
        :class="{ 'note-prio__opt--on': value === n }"
      >
        <input
          type="radio"
          :name="name"
          :value="n"
          :checked="value === n"
          :disabled="saving"
          :data-test="`note-priority-${n}`"
          @change="choose(n)"
        >
        <span>{{ n }}</span>
      </label>
    </div>
    <span v-if="okShown" class="note-prio__ok" aria-hidden="true" data-test="note-priority-ok">{{ okValue }}</span>
    <span class="note-prio__note" :class="{ 'note-prio__note--err': failed, 'sr-only': !failed }" role="status" data-test="note-priority-note">{{ message }}</span>
  </div>
</template>

<script setup lang="ts">
import { useNotesStore, type Note } from '~/stores/notes'
import { notePriority } from '~/utils/note-order.mjs'

const LEVELS = [1, 2, 3, 4, 5]

const props = defineProps<{ noteId: string, priority?: number }>()
const emit = defineEmits<{ saved: [note: Note] }>()
const { t } = useI18n({ useScope: 'global' })
const store = useNotesStore()
/* one radio group per control on the page */
const name = `note-prio-${useId()}`
const labelId = `${name}-label`
const value = ref(notePriority({ priority: props.priority }))
const saving = ref(false)
const failed = ref(false)
const message = ref('')
/* the visible "✓ N": shown on a saved pick, gone under 1 s (CSS fades it) */
const OK_MS = 800
const okShown = ref(false)
const okValue = ref(0)
let okTimer: ReturnType<typeof setTimeout> | undefined
function flashOk(n: number) {
  clearTimeout(okTimer)
  okValue.value = n
  okShown.value = false
  nextTick(() => {
    okShown.value = true
    okTimer = setTimeout(() => { okShown.value = false }, OK_MS)
  })
}
onUnmounted(() => clearTimeout(okTimer))

watch(() => [props.noteId, props.priority] as const, ([, p], [id]) => {
  value.value = notePriority({ priority: p })
  if (id !== props.noteId) { message.value = ''; okShown.value = false }
})

async function choose(n: number) {
  const old = value.value
  if (n === old || saving.value) return
  value.value = n
  saving.value = true
  try {
    emit('saved', await store.patch(props.noteId, { priority: n }))
    failed.value = false
    message.value = t('topic.priority.saved', { n })
    flashOk(n)
  } catch (e) {
    value.value = old
    failed.value = true
    okShown.value = false
    message.value = t('topic.priority.failed', { token: String((e as { token?: string })?.token || (e as { status?: number })?.status || '') })
  } finally {
    saving.value = false
  }
}
</script>

<style scoped>
/* SPL-5349: the topic chooser's size, cells 26 x 16 px on the desktop and
   35 x 30 on a phone */
.note-prio {
  position: relative;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 6px;
  font-size: 0.75rem;
  /* the label no taller than the bar: the header row keeps its height
     when the lazy chooser mounts */
  line-height: 1;
  color: var(--color-muted);
}
.note-prio__group {
  display: inline-flex;
  font-size: 0.75rem;
  line-height: 1;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
}
.note-prio__opt {
  position: relative;
  box-sizing: border-box;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 16px;
  cursor: pointer;
}
.note-prio__opt:first-child { border-start-start-radius: var(--radius-pill); border-end-start-radius: var(--radius-pill); }
.note-prio__opt:last-child { border-start-end-radius: var(--radius-pill); border-end-end-radius: var(--radius-pill); }
.note-prio__opt + .note-prio__opt { border-inline-start: 1px solid var(--color-border); }
.note-prio__opt--on {
  background: var(--color-selected);
  color: var(--color-fg);
  font-weight: 600;
}
/* the radio stays in the tab order and the accessibility tree, drawn by its label */
.note-prio__opt input {
  position: absolute;
  inset: 0;
  margin: 0;
  opacity: 0;
  cursor: pointer;
}
.note-prio__opt:has(input:focus-visible) {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: calc(-1 * var(--focus-ring-w));
}
/* right of the bar, out of the flow: no row height, nothing jumps. The bar
   ends its row (NoteDetail), so the room for it is kept on the right. */
.note-prio { padding-inline-end: 2.5em; }
.note-prio__ok {
  position: absolute;
  inset-inline-end: 0;
  font-weight: 600;
  white-space: nowrap;
  color: var(--color-ok);
  animation: note-prio-ok 750ms ease-in forwards;
}
.note-prio__ok::before { content: '\2713\00a0'; }
@keyframes note-prio-ok {
  0%, 55% { opacity: 1; }
  100% { opacity: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .note-prio__ok { animation: none; }
}
.note-prio__note--err { flex-basis: 100%; color: var(--color-danger); }
/* on a phone each value keeps a 44 px tall target (its invisible radio); it
   stays right of the title (NoteDetail, owner t1 ba784026 msg 037cedef) */
@media (max-width: 820px) {
  /* an empty first item keeps the bar's line 44 px tall */
  .note-prio::before { content: ''; height: var(--tap); }
  .note-prio__group { font-size: 0.875rem; }
  .note-prio__opt { width: 35px; height: 30px; }
  /* near-square, as TopicPriorityChooser (R7 c-611, W1) */
  .note-prio__opt input {
    inset: 50% 0 auto;
    height: var(--tap);
    transform: translateY(-50%);
    appearance: none;
    border-radius: var(--radius-xs);
  }
  /* SPL-4893: the chooser shares the title's row (NoteDetail); the label
     stays for screen readers (the group's aria-labelledby), not drawn */
  .note-prio__label {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
}
</style>
