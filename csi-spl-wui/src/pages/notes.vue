<!-- Spec 155 2.6 (SPL-2403, B5 SPL-4123): the Notes section, the person's
     own list (the realm, 2.2: the same list in every workspace). The sidebar
     keeps the icon rail only (ChannelSidebar notesRailOnly); this page is the
     list: New note, the filter box, the Archived switch, the Pinned group,
     then the rest. A row is /notes?note=<id>; B6 (SPL-4186) opens it:
     components/NoteDetail.vue, lazy, a modal above 820 px and the level-3
     full screen on a phone. The order is the person's own: drag a row, or
     Alt+Up / Alt+Down on it (utils/note-order.mjs). Delete (D2) takes the note
     off at once and shows a 10 s Undo; the DELETE goes when it ends. -->
<template>
  <div class="feed-col notes-page" data-test="notes-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 class="notes-title" data-test="notes-heading">
        <UiIcon name="notes" :size="18" />
        <span>{{ t('notes.title') }}</span>
      </h2>
      <SectionClose side="end" />
    </header>
    <div class="feed-body notes-body">
      <p v-if="store.state === 'off'" class="muted" data-test="notes-off">{{ t('notes.off') }}</p>
      <template v-else>
        <div class="notes-bar">
          <button type="button" class="btn notes-bar__new" data-test="notes-new" :disabled="creating" @click="newNote">
            <UiIcon name="plus" :size="16" />
            <span>{{ t('notes.new') }}</span>
          </button>
          <input
            v-model="query"
            type="search"
            class="notes-bar__filter"
            data-test="notes-filter"
            :placeholder="t('notes.filter')"
            :aria-label="t('notes.filter')"
          >
          <button
            type="button"
            class="btn ghost notes-bar__archived"
            data-test="notes-archived"
            :aria-pressed="archived ? 'true' : 'false'"
            @click="archived = !archived"
          >{{ t('notes.archived') }}</button>
        </div>
        <p v-if="createFailed" class="notes-error" role="alert" data-test="notes-create-failed">{{ t('notes.create_failed') }}</p>
        <p v-if="store.state === 'failed'" class="notes-error" role="alert" data-test="notes-error">
          {{ t('notes.load_failed') }}
          <button type="button" class="btn ghost" data-test="notes-retry" @click="store.load()">{{ t('notes.retry') }}</button>
        </p>
        <p v-else-if="store.state === 'loading' || store.state === 'idle'" class="muted" data-test="notes-loading">{{ t('notes.loading') }}</p>
        <p v-else-if="!rows.length" class="muted" data-test="notes-empty">{{ t(emptyKey) }}</p>
        <template v-else>
          <section v-for="g in groups" :key="g.id" class="notes-group" :data-test="'notes-group-' + g.id">
            <h3 v-if="g.label" class="notes-group__head">{{ t(g.label) }}</h3>
            <ul class="notes-list" :aria-label="t('notes.list_label')">
              <li
                v-for="n in g.rows"
                :key="n.id"
                class="notes-row"
                :class="{ 'notes-row--over': dragOver === n.id }"
                data-test="notes-row"
                :data-note-id="n.id"
                :draggable="phone ? undefined : 'true'"
                @dragstart="onDragStart(n.id, $event)"
                @dragover.prevent="dragOver = n.id"
                @dragleave="dragOver = ''"
                @drop.prevent="onDrop(n.id)"
                @dragend="dragId = ''; dragOver = ''"
              >
                <a
                  class="notes-row__open"
                  :class="{ 'notes-row__open--current': openId === n.id }"
                  :href="noteHref(n.id)"
                  :aria-current="openId === n.id ? 'true' : undefined"
                  data-test="notes-open"
                  @click.exact.prevent="open(n.id)"
                  @keydown.alt.up.prevent="move(n.id, -1)"
                  @keydown.alt.down.prevent="move(n.id, 1)"
                >
                  <span class="notes-row__title">{{ rowTitle(n) }}</span>
                  <span v-if="rowText(n)" class="notes-row__text muted" data-test="notes-row-text">{{ rowText(n) }}</span>
                  <span class="notes-row__meta muted">
                    <span v-if="n.items_total" :title="t('notes.items_hint', { done: n.items_done, total: n.items_total })" dir="ltr">{{ t('notes.items', { done: n.items_done, total: n.items_total }) }}</span>
                    <span v-if="n.link_count">{{ t('notes.links', { n: n.link_count }) }}</span>
                    <span dir="ltr">{{ t('notes.changed', { when: isoDateTime(n.updated_at) }) }}</span>
                  </span>
                </a>
              </li>
            </ul>
          </section>
        </template>
      </template>
    </div>
    <LazyNoteDetail
      v-if="openId"
      :id="openId"
      :phone="phone"
      :can-up="canMove(openId, -1)"
      :can-down="canMove(openId, 1)"
      @close="close"
      @delete="onDelete"
      @move="move"
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
  </div>
</template>

<script setup lang="ts">
import { filterNotes, useNotesStore } from '~/stores/notes'
import type { NoteSummary } from '~/stores/notes'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { movePosition, dropPosition } from '~/utils/note-order.mjs'
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { useMobileStack } from '~/composables/useMobileStack'
import { useNoteOpen } from '~/composables/useNoteOpen'

/* D2 (spec 155 section 3): Delete has a 10 s Undo, then the DELETE goes */
const DELETE_UNDO_MS = 10_000

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const stack = useMobileStack()
const phone = computed(() => stack.isMobile.value)
const { openId, open, close } = useNoteOpen({ route, router, phone })
const localePath = useLocalePath()
const store = useNotesStore()
const query = ref('')
const archived = ref(false)
const creating = ref(false)
const createFailed = ref(false)

useHead({ title: () => t('notes.title') })

const rows = computed(() => filterNotes(store.notes, query.value, archived.value))
/* 2.6: the Pinned group, then the rest; the Archived view is one list */
const groups = computed(() => {
  if (archived.value) return [{ id: 'archived', label: '', rows: rows.value }]
  const pinned = rows.value.filter((n) => n.pinned)
  const rest = rows.value.filter((n) => !n.pinned)
  if (!pinned.length) return [{ id: 'rest', label: '', rows: rest }]
  return [{ id: 'pinned', label: 'notes.pinned', rows: pinned }, ...(rest.length ? [{ id: 'rest', label: 'notes.others', rows: rest }] : [])]
})
const emptyKey = computed(() => (query.value.trim() ? 'notes.empty_filter' : archived.value ? 'notes.empty_archived' : 'notes.empty'))

/* the order (B6): one PATCH position; the row moves at once, a refusal reloads the list */
function move(id: string, dir: number) {
  place(id, movePosition(store.notes, id, dir))
}
function canMove(id: string, dir: number) {
  return movePosition(store.notes, id, dir) !== null
}
function place(id: string, position: number | null) {
  if (position === null) return
  store.notes = store.notes.map((n) => (n.id === id ? { ...n, position } : n))
  store.patch(id, { position }).catch(() => store.load())
}
const dragId = ref('')
const dragOver = ref('')
function onDragStart(id: string, e: DragEvent) {
  dragId.value = id
  e.dataTransfer?.setData('text/plain', id)
}
function onDrop(target: string) {
  const id = dragId.value
  dragId.value = dragOver.value = ''
  if (!id) return
  /* dragged down: it lands after the row it is dropped on; dragged up: before it */
  const pos = (x: string) => store.notes.find((n) => n.id === x)?.position ?? 0
  place(id, dropPosition(store.notes, id, target, pos(id) < pos(target)))
}

/* D2: the note leaves the list at once; Undo puts it back, nothing sent */
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
  if (row) void store.remove(row.id, keepalive)
}
/* the page goes (reload, tab closed): the DELETE still goes */
const onPageHide = () => sendDelete(true)

/* a plain link: a click opens the note in place (useNoteOpen), a
   Ctrl / middle click still opens its address in a new tab. A NuxtLink's own
   click pushed the route before the page could open it, so a phone got two
   history entries and Back did not close the note. */
function noteHref(id: string) {
  return router.resolve({ path: localePath('/notes'), query: { note: id } }).href
}

/** the title, else the first line of the text (2.6), else "Untitled note" */
function rowTitle(n: NoteSummary) {
  return n.title || n.snippet.split('\n')[0] || t('notes.untitled')
}

/** up to two lines of text; with no title the first line is the title (2.6), so the text starts at the second */
function rowText(n: NoteSummary) {
  return n.title ? n.snippet : n.snippet.split('\n').slice(1).join('\n')
}

async function newNote() {
  creating.value = true
  createFailed.value = false
  const id = await store.create()
  creating.value = false
  if (!id) {
    createFailed.value = true
    return
  }
  archived.value = false
  query.value = ''
  open(id)
}

/* 2.1: no live updates between tabs; the list is read again on focus */
function onFocus() {
  if (store.state === 'ready') void store.load()
}
onMounted(() => {
  void store.load()
  window.addEventListener('focus', onFocus)
  window.addEventListener('pagehide', onPageHide)
})
onUnmounted(() => {
  window.removeEventListener('focus', onFocus)
  window.removeEventListener('pagehide', onPageHide)
  sendDelete()
})
</script>

<style scoped>
.notes-title { display: inline-flex; align-items: center; gap: 8px; margin: 0; }
.notes-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0 0 0.75rem; }
.notes-bar__new { display: inline-flex; align-items: center; gap: 6px; }
.notes-bar__filter {
  flex: 1 1 12rem;
  min-width: 0;
  min-height: 36px;
  padding: 6px 10px;
  border: 1px solid var(--color-border);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
}
.notes-bar__archived[aria-pressed="true"] { background: var(--color-selected); border-color: var(--color-accent); }
.notes-error { margin: 0 0 0.75rem; color: var(--color-danger); overflow-wrap: anywhere; }
.notes-group + .notes-group { margin-top: 1rem; }
.notes-group__head { margin: 0 0 0.5rem; font-size: 0.8125rem; font-weight: 600; text-transform: uppercase; color: var(--color-muted); }
.notes-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.notes-row { min-width: 0; }
.notes-row__open {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  color: var(--color-fg);
  text-decoration: none;
  min-width: 0;
}
.notes-row__open--current { border-color: var(--color-accent); }
.notes-row--over .notes-row__open { border-top: 2px solid var(--color-accent); }
.notes-row__title { font-weight: 600; overflow-wrap: anywhere; }
.notes-row__text {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  white-space: pre-line;
  overflow-wrap: anywhere;
}
.notes-row__meta { display: flex; flex-wrap: wrap; gap: 4px 10px; font-size: 0.8125rem; min-width: 0; }
@media (max-width: 820px) {
  .notes-bar .btn, .notes-bar__filter { min-height: var(--tap, 44px); }
}
</style>
