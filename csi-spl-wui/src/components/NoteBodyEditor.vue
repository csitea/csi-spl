<!-- SPL-4893 (owner HUM-10, t1 ba784026): the open note's text. msg de86531f:
     "the simplest possible WYSIWYG editor - bolding, underlining, numbering,
     bullets ... to be wiki based, not html based"; msg e6a8148b: "a direct wiki
     code option to view"; msg a9f94922: links turn into links "the same way it
     happens in our discussions". The body stays plain text (no storage
     change): the toolbar writes wiki marks into it (utils/note-wiki.mjs:
     **bold**, ++underline++, "1. ", "- "). View draws it with the discussions'
     own renderer (MessageBody, markdown mode: lists, marks and every URL a
     link); Source is the raw text, edited directly. A note with text opens in
     View, an empty one in Source; a click on the text (not on a link) or any
     toolbar button goes to Source. The box is 6 rows (poll 2fefe460 UP).
     Loaded with NoteDetail, so none of it is first-load JS. -->
<template>
  <div class="note-ed" data-test="note-editor" :data-mode="mode">
    <div class="note-ed__bar" role="toolbar" :aria-label="t('notes.editor.toolbar')">
      <button
        v-for="b in TOOLS"
        :key="b.id"
        type="button"
        class="icon-btn note-ed__tool"
        :data-test="'note-ed-' + b.id"
        :aria-label="t(b.label)"
        :title="t(b.label)"
        @mousedown.prevent
        @click="apply(b.id)"
      ><span class="note-ed__glyph" :class="'note-ed__glyph--' + b.id" aria-hidden="true">{{ b.glyph }}</span></button>
      <span class="note-ed__gap" />
      <button
        type="button"
        class="btn ghost note-ed__mode"
        data-test="note-ed-mode"
        :aria-pressed="mode === 'source' ? 'true' : 'false'"
        @click="mode === 'view' ? toSource() : (mode = 'view')"
      >{{ t(mode === 'view' ? 'notes.editor.source' : 'notes.editor.view') }}</button>
    </div>
    <textarea
      v-if="mode === 'source'"
      ref="box"
      :value="modelValue"
      class="note-ed__box"
      data-test="note-body"
      maxlength="20000"
      rows="6"
      :placeholder="t('notes.body_placeholder')"
      :aria-label="t('notes.body_label')"
      @input="put(($event.target as HTMLTextAreaElement).value)"
    />
    <div
      v-else
      class="note-ed__view"
      data-test="note-body-view"
      :aria-label="t('notes.body_label')"
      @click="onViewClick"
    >
      <MessageBody :body="modelValue" markdown no-previews no-poll />
    </div>
  </div>
</template>

<script setup lang="ts">
import { toggleList, toggleMark } from '~/utils/note-wiki.mjs'

type Tool = 'bold' | 'underline' | 'number' | 'bullet'
/* glyphs, not words: the same in every language */
const TOOLS: Array<{ id: Tool, glyph: string, label: string }> = [
  { id: 'bold', glyph: 'B', label: 'notes.editor.bold' },
  { id: 'underline', glyph: 'U', label: 'notes.editor.underline' },
  { id: 'number', glyph: '1.', label: 'notes.editor.numbered' },
  { id: 'bullet', glyph: '•', label: 'notes.editor.bullets' },
]

const props = defineProps<{ modelValue: string }>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()
const { t } = useI18n({ useScope: 'global' })
const mode = ref<'view' | 'source'>(props.modelValue.trim() ? 'view' : 'source')
const box = ref<HTMLTextAreaElement | null>(null)

function put(v: string) {
  emit('update:modelValue', v)
}

async function toSource() {
  mode.value = 'source'
  await nextTick()
  box.value?.focus()
}

/* a click on a link opens it; anywhere else on the text edits it */
function onViewClick(e: MouseEvent) {
  if ((e.target as HTMLElement).closest('a')) return
  void toSource()
}

async function apply(id: Tool) {
  if (mode.value !== 'source') await toSource()
  const el = box.value
  if (!el) return
  const s = el.selectionStart ?? el.value.length
  const e = el.selectionEnd ?? s
  const out = id === 'bold' || id === 'underline'
    ? toggleMark(el.value, s, e, id === 'bold' ? '**' : '++')
    : toggleList(el.value, s, e, id)
  put(out.text)
  await nextTick()
  el.focus()
  el.setSelectionRange(out.start, out.end)
}
</script>

<style scoped>
.note-ed { display: flex; flex-direction: column; min-width: 0; border: 1px solid var(--color-border); border-radius: var(--radius-md); background: var(--color-surface); }
.note-ed:focus-within { border-color: var(--color-accent); }
.note-ed__bar { display: flex; align-items: center; gap: 2px; padding: 2px 4px; border-bottom: 1px solid var(--color-border); min-width: 0; }
.note-ed__gap { flex: 1 1 auto; }
.note-ed__tool { min-width: 32px; min-height: 32px; display: inline-flex; align-items: center; justify-content: center; }
.note-ed__glyph { font-size: 0.9375rem; line-height: 1; }
.note-ed__glyph--bold { font-weight: 700; }
.note-ed__glyph--underline { text-decoration: underline; }
.note-ed__mode { font-size: 0.8125rem; }
.note-ed__box {
  min-width: 0;
  padding: 8px;
  border: 0;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  resize: vertical;
}
.note-ed__box:focus { outline: none; }
.note-ed__view { min-height: 6lh; padding: 8px; cursor: text; overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .note-ed__tool, .note-ed__mode { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
</style>
