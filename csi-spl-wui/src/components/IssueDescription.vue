<!-- An issue's description (SPL-975): rendered markdown until a click, Enter
     or the page's `e` shortcut (edit()) opens the editor with the raw text.
     A click elsewhere (blur) saves it and shows the rendered view again; a
     save that fails keeps the editor and the text, and says so. Rendering is
     MessageBody's, forced to markdown, so a description renders like a
     message: the same lazy markdown chunk and the same allow-list.
     `keepOpen` (a new issue) keeps the editor after a blur. The view comes
     back only once the pointer is up: the editor is taller, so closing it on
     the mousedown that blurred it would move the control under the pointer
     and the click would land elsewhere. -->
<template>
  <div class="issue-desc" data-test="issues-description" :data-state="editing ? 'edit' : 'view'">
    <span :id="labelId" class="issue-desc__label">{{ t('issues.field_description') }}</span>
    <!-- SPL-985: @ opens the shared picker; Enter / Tab pick while it is open -->
    <div v-if="editing" class="mention-anchor">
      <textarea
        ref="area"
        v-model="draft"
        data-test="issues-detail-body"
        rows="8"
        :aria-labelledby="labelId"
        :aria-invalid="error ? 'true' : undefined"
        :placeholder="t('issues.description_empty')"
        @input="emit('draft', mp.encode(draft)); mp.sync()"
        @click="mp.sync"
        @keyup="mp.sync"
        @keydown="mp.onKeydown($event) || onSubmitKey($event, submit)"
        @blur="mp.close(); commit()"
      />
      <MentionList :picker="mp" />
    </div>
    <div
      v-else
      class="issue-desc__view"
      data-test="issues-detail-rendered"
      role="button"
      tabindex="0"
      :aria-labelledby="labelId"
      :title="t('issues.description_edit_hint')"
      @click="onViewClick"
      @keydown.enter.self.prevent="edit"
    >
      <MessageBody v-if="text.trim()" :body="text" markdown />
      <span v-else class="muted">{{ t('issues.description_empty') }}</span>
    </div>
    <p v-if="error" class="issue-desc__error" role="alert" data-test="issues-description-error">{{ t('issues.save_failed') }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useMentionPicker } from '~/composables/useMentionPicker'
const props = defineProps<{
  text: string
  /* resolves true when the text is stored; false keeps the editor open */
  save: (value: string) => Promise<boolean>
  keepOpen?: boolean
}>()
const emit = defineEmits<{ draft: [value: string], submit: [] }>()
const { t } = useI18n({ useScope: 'global' })
/* SPL-976: the "Text fields" submit key saves (and, on a new issue, creates) */
const { onKeydown: onSubmitKey } = useSubmitKey()

const labelId = useId()
const editing = ref(props.keepOpen === true)
const draft = ref('')
const error = ref(false)
const area = ref<HTMLTextAreaElement | null>(null)
/* SPL-1009: the box shows mentioned people by name; what is saved and reported carries their tags */
const mp = useMentionPicker({ text: draft, el: area, onPick: (v) => emit('draft', mp.encode(v)) })
let saving = false
let pressed = false

/* document-level and capture: the editor's blur fires before the click that
 * caused it lands, so close() must already know a press is down anywhere on
 * the page (a press inside a child that stops propagation included) */
function onPress() { pressed = true }
function onRelease() { pressed = false }
/* one controller for the group: abort() removes all three, flags and all */
const listeners = new AbortController()
onMounted(() => {
  if (editing.value) draft.value = mp.decode(props.text)
  const opts = { capture: true, signal: listeners.signal }
  document.addEventListener('pointerdown', onPress, opts)
  document.addEventListener('pointerup', onRelease, opts)
  document.addEventListener('pointercancel', onRelease, opts)
})
onBeforeUnmount(() => listeners.abort())

/* back to the rendered view, after the click that blurred the editor */
function close() {
  if (props.keepOpen) return
  if (!pressed) { editing.value = false; return }
  document.addEventListener('pointerup', () => setTimeout(() => { editing.value = false }, 0), { once: true, capture: true })
}

async function edit() {
  if (editing.value) return
  draft.value = mp.decode(props.text)
  error.value = false
  editing.value = true
  await nextTick()
  area.value?.focus()
}

/* a link inside the rendered text opens; any other click edits */
function onViewClick(ev: MouseEvent) {
  const target = ev.target
  if (target instanceof Element && target.closest('a, button')) return
  const sel = typeof window !== 'undefined' ? window.getSelection() : null
  if (sel && sel.type === 'Range' && !sel.isCollapsed) return
  void edit()
}

async function commit() {
  if (!editing.value || saving) return
  const value = mp.encode(draft.value)
  if (value === props.text) { error.value = false; close(); return }
  saving = true
  let ok = false
  try {
    ok = await props.save(value)
  } catch {
    ok = false
  } finally {
    saving = false
  }
  error.value = !ok
  if (ok) close()
}

async function submit() {
  await commit()
  if (!error.value) emit('submit')
}

/* another issue in the pane: drop an unsaved edit of the one before */
watch(() => props.text, () => {
  if (!editing.value) error.value = false
})

defineExpose({ edit, commit, editing })
</script>

<style scoped>
.mention-anchor { position: relative; display: flex; flex-direction: column; min-width: 0; }
.issue-desc {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
}
.issue-desc__label {
  font-size: 0.8125rem;
  color: var(--color-muted);
}
.issue-desc textarea {
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  background: var(--color-bg-2);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 6px 8px;
  font: inherit;
  resize: vertical;
}
.issue-desc__view {
  min-height: 2.5em;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  cursor: text;
  min-width: 0;
  overflow-wrap: anywhere;
}
.issue-desc__view:hover {
  border-color: var(--color-border-strong);
}
.issue-desc__error {
  margin: 0;
  font-size: 0.8125rem;
  color: var(--color-danger);
}
</style>
