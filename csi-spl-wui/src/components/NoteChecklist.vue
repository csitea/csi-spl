<!-- Spec 155 2.6 (B6, SPL-4186): the open note's checklist (D6: a list inside
     the note, not a note type). Tick, add, edit, remove and reorder a line:
     Alt+Up / Alt+Down in a line, or drag its handle. It holds no hub call:
     every change emits the whole new list (`change`), and NoteDetail saves it
     (PUT items, 800 ms after the last key, at once for a tick). -->
<template>
  <section class="note-cl" data-test="note-checklist" :aria-label="t('notes.checklist')">
    <h3 class="note-cl__head">{{ t('notes.checklist') }}</h3>
    <ul v-if="items.length" class="note-cl__list">
      <li
        v-for="(it, i) in items"
        :key="it.id"
        class="note-cl__line"
        :class="{ 'note-cl__line--over': overIndex === i }"
        data-test="note-item"
        :data-done="it.done ? 'true' : 'false'"
        @dragover.prevent="overIndex = i"
        @dragleave="overIndex = -1"
        @drop.prevent="onDrop(i)"
      >
        <span
          class="note-cl__grip"
          draggable="true"
          aria-hidden="true"
          @dragstart="onDragStart(i, $event)"
          @dragend="dragIndex = -1; overIndex = -1"
        ><UiIcon name="grip" :size="16" /></span>
        <input
          type="checkbox"
          class="note-cl__tick"
          data-test="note-item-tick"
          :checked="it.done"
          :aria-label="it.text || t('notes.checklist')"
          @change="tick(i, ($event.target as HTMLInputElement).checked)"
        >
        <input
          :value="it.text"
          type="text"
          class="note-cl__text"
          data-test="note-item-text"
          maxlength="500"
          :aria-label="t('notes.checklist')"
          @input="edit(i, ($event.target as HTMLInputElement).value)"
          @keydown.alt.up.prevent="move(i, -1)"
          @keydown.alt.down.prevent="move(i, 1)"
        >
        <button type="button" class="icon-btn note-cl__remove" data-test="note-item-remove" :aria-label="t('notes.checklist_remove')" :title="t('notes.checklist_remove')" @click="remove(i)">
          <UiIcon name="x" :size="16" />
        </button>
      </li>
    </ul>
    <form class="note-cl__add" @submit.prevent="add">
      <input
        v-model="draft"
        type="text"
        class="note-cl__text"
        data-test="note-item-new"
        maxlength="500"
        :placeholder="t('notes.checklist_add')"
        :aria-label="t('notes.checklist_add')"
      >
      <button type="submit" class="btn ghost" data-test="note-item-add" :disabled="!draft.trim() || items.length >= MAX_ITEMS">{{ t('notes.checklist_add') }}</button>
    </form>
  </section>
</template>

<script setup lang="ts">
import type { NoteItem } from '~/stores/notes'
import { moveChecklistLine } from '~/utils/note-order.mjs'

/* spec 155 2.4: at most 200 lines of at most 500 characters */
const MAX_ITEMS = 200

const props = defineProps<{ items: NoteItem[] }>()
/* `now`: a tick or a remove saves at once, a typed key waits for the pause */
const emit = defineEmits<{ change: [items: NoteItem[], now: boolean] }>()
const { t } = useI18n({ useScope: 'global' })
const draft = ref('')
const dragIndex = ref(-1)
const overIndex = ref(-1)
let newSeq = 0

function put(items: NoteItem[], now: boolean) {
  emit('change', items, now)
}
function tick(i: number, done: boolean) {
  put(props.items.map((it, k) => (k === i ? { ...it, done } : it)), true)
}
function edit(i: number, text: string) {
  put(props.items.map((it, k) => (k === i ? { ...it, text } : it)), false)
}
function remove(i: number) {
  put(props.items.filter((_, k) => k !== i), true)
}
function add() {
  const text = draft.value.trim()
  if (!text || props.items.length >= MAX_ITEMS) return
  put([...props.items, { id: `new-${Date.now()}-${++newSeq}`, text, done: false }], true)
  draft.value = ''
}
function move(i: number, dir: number) {
  const next = moveChecklistLine(props.items, i, dir) as NoteItem[] | null
  if (!next) return
  put(next, true)
  /* the moved line keeps the keyboard focus */
  void nextTick(() => document.querySelectorAll<HTMLInputElement>('[data-test=note-item-text]')[i + dir]?.focus())
}
function onDragStart(i: number, e: DragEvent) {
  dragIndex.value = i
  e.dataTransfer?.setData('text/plain', String(i))
}
function onDrop(i: number) {
  const from = dragIndex.value
  dragIndex.value = -1
  overIndex.value = -1
  if (from < 0 || from === i) return
  const out = [...props.items]
  const [it] = out.splice(from, 1)
  out.splice(i, 0, it!)
  put(out, true)
}
</script>

<style scoped>
.note-cl__head { margin: 0 0 0.5rem; font-size: 0.8125rem; font-weight: 600; text-transform: uppercase; color: var(--color-muted); }
.note-cl__list { list-style: none; margin: 0 0 0.5rem; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.note-cl__line { display: flex; align-items: center; gap: 6px; min-width: 0; border-top: 2px solid transparent; }
.note-cl__line--over { border-top-color: var(--color-accent); }
.note-cl__line[data-done="true"] .note-cl__text { text-decoration: line-through; color: var(--color-muted); }
.note-cl__grip { cursor: grab; color: var(--color-muted); display: inline-grid; place-items: center; }
.note-cl__tick { width: 18px; height: 18px; flex: none; }
.note-cl__text {
  flex: 1 1 auto;
  min-width: 0;
  min-height: 32px;
  padding: 4px 8px;
  border: 1px solid transparent;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
}
.note-cl__text:hover, .note-cl__text:focus { border-color: var(--color-border); }
.note-cl__add { display: flex; gap: 6px; align-items: center; }
.note-cl__add .note-cl__text { border-color: var(--color-border); }
@media (max-width: 820px) {
  .note-cl__grip { display: none; }
  .note-cl__text, .note-cl__add .btn, .note-cl__remove { min-height: var(--tap, 44px); }
  .note-cl__remove { min-width: var(--tap, 44px); }
  .note-cl__tick { width: 22px; height: 22px; }
}
</style>
