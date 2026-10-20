<!-- An issue's description (SPL-975): rendered markdown until a click, Enter
     or the page's `e` shortcut (edit()) opens the editor with the raw text.
     A click elsewhere (blur) saves it and shows the rendered view again; a
     save that fails keeps the editor and the text, and says so. Rendering is
     MessageBody's, forced to markdown, so a description renders like a
     message: the same lazy markdown chunk and the same allow-list.
     `keepOpen` (a new issue) keeps the editor after a blur. The view comes
     back only once the pointer is up: the editor is taller, so closing it on
     the mousedown that blurred it would move the control under the pointer
     and the click would land elsewhere.
     HUM-10 (t1 43ebdf0b): a file pasted into the editor, or picked with its
     attach button, is stored (`attach`, the page's) and named in the text as
     a markdown link; the view shows each named file as a card that opens. -->
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
        @paste="attach && onPaste($event)"
        @blur="mp.close(); onBlur()"
      />
      <MentionList :picker="mp" />
      <div v-if="attach" class="issue-desc__tools">
        <!-- the composer's Attach: a pointer target only, the box keeps the focus -->
        <button
          type="button"
          tabindex="-1"
          class="icon-btn"
          data-test="issues-desc-attach"
          :disabled="uploading"
          :aria-label="t('composer.attach')"
          :title="t('composer.attach')"
          @mousedown.prevent
          @click="openFiles"
        ><UiIcon name="paperclip" :size="16" /></button>
        <input
          ref="fileEl"
          type="file"
          multiple
          hidden
          tabindex="-1"
          data-test="issues-desc-attach-input"
          @change="onFiles"
          @cancel="onPickCancel"
        >
      </div>
      <p v-if="pickLost" class="issue-desc__note" role="status" data-testid="attach-nothing">{{ t('composer.attach_nothing') }}</p>
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
      <!-- a file card's own clicks (open, Download) never open the editor -->
      <div v-if="files.length" class="issue-desc__files" @click.stop>
        <div v-for="f in files" :key="f.file_id" data-test="issues-desc-file">
          <FileAttachment :file="f" :remove="attach ? () => removeFile(f.file_id) : undefined" />
        </div>
      </div>
    </div>
    <p v-if="error" class="issue-desc__error" role="alert" data-test="issues-description-error">{{ t('issues.save_failed') }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useFileAttach } from '~/composables/useFileAttach'
import { descFileRefs } from '~/utils/issue-files'
import { useMessageEdit } from '~/composables/useMessageEdit'
const props = defineProps<{
  text: string
  /* resolves true when the text is stored; false keeps the editor open */
  save: (value: string) => Promise<boolean>
  keepOpen?: boolean
  /* stores the files and resolves the markdown that names each; absent (a new
     issue, which has no discussion to carry them yet) = no attach, a plain paste */
  attach?: (files: File[]) => Promise<string[]>
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
const fileEl = ref<HTMLInputElement | null>(null)
const { picked, pickLost, openFiles, onPickCancel, onFiles, onPaste, picking } = useFileAttach(fileEl)
const uploading = ref(false)
/* the stored files the saved text names, shown as cards under it */
const files = computed(() => descFileRefs(props.text))

/* SPL-1560: the X on a description's file. The file rides on a note in the
   issue's discussion, so the hub takes it off that note (and drops the blob);
   then the link leaves the text. A refusal leaves both as they were; a file
   no note carries any more (not_found) still loses its link. Shown where the
   description takes files (an existing issue: `attach`). */
const { removeAttachment } = useMessageEdit()
async function removeFile(fileId: string) {
  try {
    await removeAttachment(fileId)
  } catch (e) {
    if ((e as { token?: string })?.token !== 'not_found') throw e
  }
  const link = new RegExp(`\\[[^\\]\\n]*\\]\\([^()\\s]*/v1/files/${fileId}(?:#bytes=\\d+)?\\)\\n?`, 'g')
  if (!(await props.save(props.text.replace(link, '').trimEnd()))) throw new Error('description not saved')
}

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

/* the file dialog's focus loss, or an upload under way, is not the reader
   leaving the editor: keep it open, the link lands in it */
function onBlur() {
  if (picking() || uploading.value) return
  void commit()
}

/* the markdown lands at the caret, on a line of its own */
function insertAtCaret(md: string) {
  const el = area.value
  const v = draft.value
  const start = el ? el.selectionStart : v.length
  const end = el ? el.selectionEnd : v.length
  const before = v.slice(0, start)
  const after = v.slice(end)
  const lead = before && !before.endsWith('\n') ? '\n' : ''
  const tail = after && !after.startsWith('\n') ? '\n' : ''
  draft.value = before + lead + md + tail + after
  emit('draft', mp.encode(draft.value))
}

watch(picked, async (list) => {
  if (!list.length || !props.attach) return
  picked.value = []
  uploading.value = true
  error.value = false
  try {
    insertAtCaret((await props.attach(list)).join('\n'))
  } catch {
    error.value = true
  } finally {
    uploading.value = false
  }
  await nextTick()
  area.value?.focus()
})

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
.issue-desc__tools { display: flex; justify-content: flex-end; }
.issue-desc__files { display: flex; flex-direction: column; gap: 6px; margin-top: 8px; cursor: default; }
.issue-desc__note {
  margin: 0;
  font-size: 0.8125rem;
  color: var(--color-muted);
}
.issue-desc__error {
  margin: 0;
  font-size: 0.8125rem;
  color: var(--color-danger);
}
</style>
