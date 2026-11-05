<!-- Spec 155 2.6 (SPL-4897, owner t1 2f4311d9 msg c6bf6b39: "Remove tje
     archive buton, the archive section should be used for that"): the
     person's archived notes, the Notes part of the Archive page. The Notes
     bar has no Archived switch any more; this is where an archived note is
     seen. A row is the title, its priority (above 600 px, as the Notes list
     shows it beside the title) and when it last changed; a click opens the
     note in place (NoteDetail, lazy, as on /notes), a modified click follows
     /notes?note=<id>. Unarchive PATCHes archived=false and the note is back in
     Notes. Loaded lazily from pages/archive.vue, so the notes store is no
     first-load JS. A switched-off Notes section (notes_off) shows nothing. -->
<template>
  <section v-if="store.state !== 'off'" class="archive-notes" data-test="archive-notes">
    <h3 class="archive-part__head">{{ t('archive.notes') }}</h3>
    <p v-if="store.state === 'failed'" class="archive-error" role="alert" data-test="archive-notes-error">
      {{ t('notes.load_failed') }}
      <button type="button" class="btn ghost" data-test="archive-notes-retry" @click="store.load()">{{ t('notes.retry') }}</button>
    </p>
    <p v-else-if="store.state === 'loading' || store.state === 'idle'" class="muted" data-test="archive-notes-loading">{{ t('notes.loading') }}</p>
    <p v-else-if="!rows.length" class="muted" data-test="archive-notes-empty">{{ t('notes.empty_archived') }}</p>
    <ul v-else class="archive-list" data-test="archive-notes-list">
      <li v-for="n in rows" :key="n.id" class="archive-row" data-test="archive-note-row" :data-note-id="n.id">
        <a class="archive-row__open" :href="noteHref(n.id)" data-test="archive-note-open" @click.exact.prevent="open(n.id)">
          <span class="archive-note__head">
            <span class="archive-note__title">{{ rowTitle(n) }}</span>
            <span class="archive-note__prio" data-test="archive-note-priority">{{ t('topic.priority.badge', { n: notePriority(n) }) }}</span>
          </span>
          <span class="archive-row__meta muted">
            <span dir="ltr">{{ t('notes.changed', { when: isoDateTime(n.updated_at) }) }}</span>
          </span>
        </a>
        <div class="archive-row__actions">
          <button
            type="button"
            class="btn ghost archive-row__btn"
            data-test="archive-note-unarchive"
            :disabled="busy === n.id"
            @click="unarchive(n.id)"
          >
            <UiIcon name="unarchive" :size="16" />
            <span>{{ t('notes.unarchive') }}</span>
          </button>
        </div>
        <p v-if="rowError[n.id]" class="archive-error" role="alert">{{ t('archive.note_error') }}</p>
      </li>
    </ul>
    <LazyNoteDetail
      v-if="openId"
      :id="openId"
      :phone="phone"
      :can-up="false"
      :can-down="false"
      @close="close"
      @delete="onDelete"
    />
    <UndoSnackbar
      v-if="deleted"
      :key="deleted.id"
      icon="trash"
      testid="notes-delete-toast"
      :text="t('notes.deleted')"
      :undo-label="t('notes.undo')"
      :close-label="t('common.close')"
      :duration="DELETE_UNDO_MS"
      @undo="undoDelete"
      @dismiss="sendDelete()"
    />
  </section>
</template>

<script setup lang="ts">
import { useNotesStore } from '~/stores/notes'
import type { NoteSummary } from '~/stores/notes'
import { notePriority } from '~/utils/note-order.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { useMobileStack } from '~/composables/useMobileStack'
import { useNoteOpen } from '~/composables/useNoteOpen'

/* D2 (spec 155 section 3): the same 10 s Undo as on /notes */
const DELETE_UNDO_MS = 10_000

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const stack = useMobileStack()
const phone = computed(() => stack.isMobile.value)
const { openId, open, close } = useNoteOpen({ route, router, phone })
const localePath = useLocalePath()
const store = useNotesStore()
const busy = ref('')
const rowError = ref<Record<string, boolean>>({})

/* newest archived first, as the topics part above */
const archivedAt = (n: NoteSummary) => n.archived_at || n.updated_at || ''
const rows = computed(() => store.notes.filter((n) => n.archived).sort((a, b) => archivedAt(b).localeCompare(archivedAt(a))))

function noteHref(id: string) {
  return router.resolve({ path: localePath('/notes'), query: { note: id } }).href
}

/** the title, else the first line of the text, else "Untitled note" (as on /notes) */
function rowTitle(n: NoteSummary) {
  return n.title || n.snippet.split('\n')[0] || t('notes.untitled')
}

/* the store keeps the row with the hub's answer: archived=false takes it off here and puts it back in Notes */
async function unarchive(id: string) {
  busy.value = id
  rowError.value = { ...rowError.value, [id]: false }
  try {
    await store.patch(id, { archived: false })
  } catch {
    rowError.value = { ...rowError.value, [id]: true }
  } finally {
    busy.value = ''
  }
}

/* D2, as on /notes: the note leaves the list at once; Undo puts it back, nothing sent */
const deleted = ref<NoteSummary | null>(null)
function onDelete(id: string) {
  sendDelete()
  close()
  const row = store.hide(id)
  if (row) deleted.value = row
  else void store.remove(id)
}
function undoDelete() {
  if (deleted.value) store.unhide(deleted.value)
  deleted.value = null
}
function sendDelete(keepalive = false) {
  const row = deleted.value
  deleted.value = null
  if (row && store.hidden.includes(row.id)) void store.remove(row.id, keepalive)
}
const onPageHide = () => sendDelete(true)

onMounted(() => {
  void store.load()
  window.addEventListener('pagehide', onPageHide)
})
onUnmounted(() => {
  window.removeEventListener('pagehide', onPageHide)
  sendDelete()
})
</script>

<style scoped>
.archive-notes { margin-top: 1.25rem; }
.archive-part__head { margin: 0 0 0.5rem; font-size: 0.8125rem; font-weight: 600; text-transform: uppercase; color: var(--color-muted); }
.archive-error { margin: 0.25rem 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
.archive-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.archive-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  min-width: 0;
}
.archive-row__open {
  flex: 1 1 16rem;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  color: var(--color-fg);
  text-decoration: none;
}
.archive-note__head { display: flex; align-items: center; min-width: 0; }
.archive-note__title { flex: 1 1 auto; min-width: 0; font-weight: 600; overflow-wrap: anywhere; }
/* the Notes list's priority tag (pages/notes.vue .notes-row__prio) */
.archive-note__prio {
  flex: 0 0 auto;
  margin-inline-start: 8px;
  color: var(--color-muted);
  font-size: 0.75rem;
  white-space: nowrap;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 0 4px;
}
.archive-row__meta { display: flex; flex-wrap: wrap; gap: 4px 10px; font-size: 0.8125rem; min-width: 0; }
.archive-row__actions { display: flex; gap: 6px; flex-wrap: wrap; }
.archive-row__btn { display: inline-flex; align-items: center; gap: 6px; }
@media (max-width: 820px) {
  .archive-row__btn { min-height: var(--tap, 44px); }
}
@media (max-width: 600px) {
  .archive-note__prio { display: none; }
  .archive-row__open { flex-basis: 100%; }
  .archive-row__actions { flex-basis: 100%; }
  .archive-row__btn { flex: 1 1 0; justify-content: center; }
}
</style>
