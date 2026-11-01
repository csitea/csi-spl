<!-- Spec 155 2.3 (B8, SPL-4578), default D3: "Add to note" opens this
     picker of the person's notes, latest changed first, a filter box, and
     New note on top; it never adds silently to a fixed note. One click adds
     the link and the toast says "Added to <title>" with Open. New note makes
     a note titled by the object's label, holding that one link.
     Mounted once by composables/useAddToNote.ts (its own chunk, fetched on
     the first open). UiDialog owns focus, Escape, the phone full screen and
     the Back overlay, as for the move picker. -->
<template>
  <UiDialog :open="open" :title="t('notes.add_to_note')" size="md" @update:open="(v: boolean) => { if (!v) open = false }">
    <div class="note-picker" data-test="note-picker" :data-state="store.state" :data-kind="link?.kind">
      <button type="button" class="btn note-picker__new" data-test="note-picker-new" :disabled="busy || store.state === 'off'" @click="pickNew">
        <UiIcon name="plus" :size="16" />
        <span>{{ t('notes.new') }}</span>
      </button>
      <input
        v-model="query"
        class="note-picker__filter"
        type="search"
        data-autofocus
        data-test="note-picker-filter"
        autocomplete="off"
        :placeholder="t('notes.picker_filter')"
        :aria-label="t('notes.picker_filter')"
        @keydown.enter.prevent="pickFirst"
      >
      <p v-if="store.state === 'off'" class="muted note-picker__empty" data-test="note-picker-off">{{ t('notes.off') }}</p>
      <p v-else-if="store.state === 'failed'" class="muted note-picker__empty" data-test="note-picker-failed">
        {{ t('notes.load_failed') }}
        <button type="button" class="btn ghost" @click="store.load()">{{ t('notes.retry') }}</button>
      </p>
      <p v-else-if="store.state !== 'ready'" class="muted note-picker__empty">{{ t('notes.loading') }}</p>
      <p v-else-if="!rows.length" class="muted note-picker__empty" data-test="note-picker-empty">{{ query.trim() ? t('notes.empty_filter') : t('notes.empty') }}</p>
      <ul v-else class="note-picker__list" :aria-label="t('notes.list_label')">
        <li v-for="n in rows" :key="n.id">
          <button type="button" class="note-picker__row" data-test="note-picker-row" :data-note-id="n.id" :disabled="busy" @click="pick(n.id, rowTitle(n))">
            <UiIcon name="notes" :size="16" />
            <span class="note-picker__label">{{ rowTitle(n) }}</span>
          </button>
        </li>
      </ul>
      <p v-if="error" class="note-picker__error" role="alert" data-test="note-picker-error">{{ t(error, { max: NOTES_MAX }) }}</p>
    </div>
  </UiDialog>
  <UndoSnackbar
    v-if="toast"
    :key="toast.seq"
    icon="notes"
    testid="note-added"
    :data-id="toast.id"
    :text="t('notes.added', { title: toast.title })"
    :undo-label="t('notes.open')"
    :close-label="t('common.close')"
    :duration="TOAST_MS"
    @undo="openNote"
    @dismiss="toast = null"
  />
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { useNotesStore, type NoteLinkIn, type NoteSummary } from '~/stores/notes'
import { noteNotesState } from '~/composables/useAddToNote'
import { pickerNotes } from '~/utils/add-to-note.mjs'

/* spec 155 2.4: 2 000 notes a person (notes_full) */
const NOTES_MAX = 2000
const TOAST_MS = 6000

const { t } = useI18n({ useScope: 'global' })
const store = useNotesStore()
const router = useRouter()
const localePath = useLocalePath()

const open = ref(false)
const link = ref<NoteLinkIn | null>(null)
const query = ref('')
const busy = ref(false)
const error = ref('')
const toast = ref<{ id: string, title: string, seq: number } | null>(null)
let seq = 0

const rows = computed(() => pickerNotes(store.notes, query.value))
watch(() => store.state, (s) => noteNotesState(s), { immediate: true })

function rowTitle(n: NoteSummary): string {
  return n.title || String(n.snippet || '').split('\n').find((l) => l.trim())?.trim() || t('notes.untitled')
}

/** Open the picker for one link; the list is read again, as the Notes page does on focus. */
function show(next: NoteLinkIn) {
  link.value = next
  query.value = ''
  error.value = ''
  busy.value = false
  open.value = true
  void store.load()
}
defineExpose({ show })

function refusal(e: unknown): string {
  const token = (e as { token?: string }).token
  return token === 'notes_full' ? 'notes.full' : token === 'bad_note' ? 'notes.too_long' : 'notes.not_saved'
}

async function pick(id: string, title: string) {
  if (!link.value || busy.value) return
  busy.value = true
  error.value = ''
  try {
    await store.addLink(id, link.value)
    done(id, title)
  } catch (e) {
    error.value = refusal(e)
  } finally {
    busy.value = false
  }
}

/* twin of C27: a new note, titled by the object's label, holding that one link */
async function pickNew() {
  if (!link.value || busy.value) return
  busy.value = true
  error.value = ''
  try {
    const id = await store.create()
    if (!id) {
      error.value = 'notes.create_failed'
      return
    }
    await store.addLink(id, link.value)
    const title = link.value.label || ''
    if (title) await store.patch(id, { title }).catch(() => { /* the link is in; the title stays empty */ })
    done(id, title || t('notes.untitled'))
  } catch (e) {
    error.value = refusal(e)
  } finally {
    busy.value = false
  }
}

function pickFirst() {
  const first = rows.value[0]
  if (first) void pick(first.id, rowTitle(first))
}

function done(id: string, title: string) {
  open.value = false
  toast.value = { id, title, seq: ++seq }
}

function openNote() {
  const id = toast.value?.id
  toast.value = null
  if (id) void router.push({ path: localePath('/notes'), query: { note: id } })
}
</script>

<style scoped>
.note-picker { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.5rem 1rem 1rem; min-height: 0; }
.note-picker__new { display: inline-flex; align-items: center; gap: 0.5rem; align-self: flex-start; min-height: var(--tap, 44px); }
.note-picker__filter {
  width: 100%;
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
}
.note-picker__empty { margin: 0.5rem 0; }
.note-picker__list { list-style: none; margin: 0; padding: 0; overflow-y: auto; max-height: min(60vh, 28rem); }
.note-picker__row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  min-height: 2.75rem;
  padding: 0.5rem 0.75rem;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.note-picker__row:hover,
.note-picker__row:focus-visible { background: var(--color-surface-hover); outline: none; }
.note-picker__label { min-width: 0; flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.note-picker__error { margin: 0; color: var(--color-danger); }
</style>
