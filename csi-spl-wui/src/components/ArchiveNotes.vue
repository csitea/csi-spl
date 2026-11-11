<!-- Spec 155 2.6 (SPL-4897, owner t1 2f4311d9 msg c6bf6b39: "Remove tje
     archive buton, the archive section should be used for that"): the
     person's archived notes, the Notes part of the Archive page. The Notes
     bar has no Archived switch any more; this is where an archived note is
     seen. A row is the title, its priority (above 600 px, as the Notes list
     shows it beside the title) and when it last changed; a click opens the
     note in place (NoteDetail, lazy, as on /notes), a modified click follows
     /notes?note=<id>. Unarchive PATCHes archived=false and the note is back in
     Notes. Loaded lazily from pages/archive.vue, so the notes store is no
     first-load JS. A switched-off Notes section (notes_off) shows nothing.
     Spec 155 2.10 (SPL-5255): a row's right-click and its menu button open
     the note's menu (Unarchive, Turn into a discussion, Delete), as on
     /notes; the actions and the Undo snackbar are useNoteActions'. -->
<template>
  <section v-if="store.state !== 'off'" class="archive-notes" data-test="archive-notes">
    <h3 class="archive-part__head">{{ t('sidebar.notes') }}</h3>
    <p v-if="store.state === 'failed'" class="archive-error" role="alert" data-test="archive-notes-error">
      {{ t('notes.load_failed') }}
      <button type="button" class="btn ghost" data-test="archive-notes-retry" @click="store.load()">{{ t('notes.retry') }}</button>
    </p>
    <p v-else-if="store.state === 'loading' || store.state === 'idle'" class="muted" data-test="archive-notes-loading">{{ t('notes.loading') }}</p>
    <p v-else-if="!rows.length" class="muted" data-test="archive-notes-empty">{{ t('notes.empty_archived') }}</p>
    <ul v-else class="archive-list" data-test="archive-notes-list">
      <li v-for="n in rows" :key="n.id" class="archive-row" data-test="archive-note-row" :data-note-id="n.id" @contextmenu.prevent="menu = { id: n.id, x: $event.clientX, y: $event.clientY }">
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
          <button
            type="button"
            class="icon-btn archive-row__menu"
            data-test="archive-note-menu"
            :aria-label="t('notes.menu.label')"
            :title="t('notes.menu.label')"
            aria-haspopup="menu"
            @click="openMenuAt(n.id, $event)"
          ><UiIcon name="more" :size="18" /></button>
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
      @archive="onArchive"
      @discuss="acts.discuss"
    />
    <NoteMenu
      :open="Boolean(menu)"
      :x="menu?.x ?? 0"
      :y="menu?.y ?? 0"
      :note="menuNote"
      @choose="onChoose"
      @close="menu = null"
    />
    <UndoSnackbar
      v-if="acts.toast.value"
      :key="acts.toast.value.seq"
      flip
      :icon="toastView.icon"
      :testid="toastView.testid"
      :data-id="acts.toast.value.id"
      :text="t(toastView.text)"
      :show-undo="Boolean(toastView.button)"
      :undo-label="toastView.button ? t(toastView.button) : ''"
      :close-label="t('common.close')"
      :duration="NOTE_UNDO_MS"
      @undo="acts.act()"
      @dismiss="acts.settle()"
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
import { NOTE_UNDO_MS, noteToastView, useNoteActions } from '~/composables/useNoteActions'
import { NOTE_MENU_ARCHIVE, NOTE_MENU_DELETE, NOTE_MENU_DISCUSS, NOTE_MENU_UNARCHIVE } from '~/utils/note-menu.mjs'

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

/* 2.10 (SPL-5255), as on /notes: Delete and Archive act at once, then the Undo snackbar */
const acts = useNoteActions({ onOpenTopic: (taskId) => { void router.push(localePath('/t/' + taskId)) } })
const toastView = computed(() => (acts.toast.value ? noteToastView(acts.toast.value) : noteToastView({ kind: 'failed', id: '', seq: 0 })))
function onDelete(id: string) {
  if (openId.value === id) close()
  acts.remove(id)
}
function onArchive(id: string) {
  if (openId.value === id) close()
  void acts.archive(id)
}
const menu = ref<{ id: string, x: number, y: number } | null>(null)
const menuNote = computed(() => (menu.value ? store.notes.find((n) => n.id === menu.value?.id) ?? null : null))
function openMenuAt(id: string, e: MouseEvent) {
  const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
  menu.value = { id, x: r.left, y: r.bottom }
}
function onChoose(action: string) {
  const id = menu.value?.id
  if (!id) return
  if (action === NOTE_MENU_UNARCHIVE) void unarchive(id)
  else if (action === NOTE_MENU_ARCHIVE) onArchive(id)
  else if (action === NOTE_MENU_DISCUSS) void acts.discuss(id)
  else if (action === NOTE_MENU_DELETE) onDelete(id)
}

onMounted(() => {
  void store.load()
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
.archive-row__menu { display: inline-flex; align-items: center; justify-content: center; }
@media (max-width: 820px) {
  .archive-row__btn { min-height: var(--tap, 44px); }
  .archive-row__menu { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
@media (max-width: 600px) {
  .archive-note__prio { display: none; }
  .archive-row__open { flex-basis: 100%; }
  .archive-row__actions { flex-basis: 100%; }
  .archive-row__btn { flex: 1 1 0; justify-content: center; }
}
</style>
