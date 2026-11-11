<!-- Spec 155 2.6 (B6, SPL-4186): the open note. Above 820 px a modal like an
     open issue (IssueDetailFrame: focus trap, Esc / X / backdrop close); on a
     phone the level-3 full screen with the Back chevron (MobileBack). Owner
     HUM-10 (t1 cb9d7bdc, msg cc1a052f): "I cannot edit notes on mobile."
     Inside: title, the priority (NotePriorityChooser, saved at once), the text
     (NoteBodyEditor, SPL-4893: wiki toolbar, View / Wiki code, 6 rows), the
     checklist, the links (B7, NoteLinks: each link added or removed is its own
     POST / DELETE), and Pin, Archive, Move up / down,
     Delete. Each field saves 800 ms after the last key and on close; a failed
     save keeps the text and shows "Not saved, retry". Delete is the page's
     (D2: the note goes at once, the DELETE waits for the 10 s Undo).
     Spec 155 2.10 (SPL-5255): the note's menu (NoteMenu: Archive, Turn into
     a discussion, Delete) opens from the More button or a right-click on the
     note outside its text boxes and links; Archive, Delete and the
     discussion are the page's (composables/useNoteActions.ts).
     Loaded lazily from pages/notes.vue, so none of it is first-load JS. -->
<template>
  <IssueDetailFrame :modal="!phone" :open="true" :title="headTitle" class="note-detail" :aria-label="t('notes.title')" @close="close">
    <template v-if="!phone && note" #tools>
      <span class="note-in__acts">
        <button
          v-for="a in actions"
          :key="a.id"
          type="button"
          class="btn ghost note-in__act"
          :data-test="'note-' + a.id"
          :disabled="a.disabled"
          :aria-label="t(a.label)"
          :title="t(a.label)"
          @click="act(a.id, $event)"
        ><UiIcon :name="a.icon" :size="16" /></button>
      </span>
    </template>
    <div class="note-in" data-test="note-detail" :data-note-id="id" :data-state="state" :data-modal="phone ? 'false' : 'true'" @contextmenu="onContext">
      <header v-if="phone" class="note-in__h">
        <MobileBack class="note-in__back" data-test="note-back" />
        <span class="note-in__gap" />
        <template v-if="note">
          <button
            v-for="a in actions"
            :key="a.id"
            type="button"
            class="icon-btn note-in__act"
            :data-test="'note-' + a.id"
            :disabled="a.disabled"
            :aria-label="t(a.label)"
            :title="t(a.label)"
            @click="act(a.id, $event)"
          ><UiIcon :name="a.icon" :size="20" /></button>
        </template>
      </header>
      <p v-if="state === 'loading'" class="muted" data-test="note-loading">{{ t('notes.loading') }}</p>
      <p v-else-if="state === 'missing'" class="muted" data-test="note-not-found">{{ t('notes.not_found') }}</p>
      <p v-else-if="state === 'failed'" class="note-in__error" role="alert" data-test="note-load-failed">
        {{ t('notes.load_failed') }}
        <button type="button" class="btn ghost" data-test="note-reload" @click="load()">{{ t('notes.retry') }}</button>
      </p>
      <template v-else-if="note">
        <!-- owner t1 ba784026 (msg 037cedef): the priority sits right of the
             title; a title too long to share the row pushes it to the next row,
             still on the right (the input sizes to its text, the row wraps) -->
        <div class="note-in__head" data-test="note-head">
          <input
            v-model="title"
            type="text"
            class="note-in__title"
            data-test="note-title"
            maxlength="200"
            :placeholder="t('notes.untitled')"
            :aria-label="t('notes.title_label')"
            @input="schedule('fields')"
          >
          <NotePriorityChooser class="note-in__prio" :note-id="note.id" :priority="note.priority" @saved="note = $event" />
        </div>
        <NoteBodyEditor v-model="body" @update:model-value="schedule('fields')" />
        <NoteChecklist :items="items" @change="onItems" />
        <NoteLinks :note-id="note.id" :links="note.links" @change="onLinks" />
        <p class="note-in__status" role="status" aria-live="polite">
          <span v-if="saveFailed" class="note-in__error" data-test="note-not-saved">
            <button type="button" class="btn ghost" data-test="note-save-retry" @click="flush()">{{ t(failKey) }}</button>
          </span>
          <span v-else-if="saving" class="muted" data-test="note-saving">{{ t('notes.saving') }}</span>
        </p>
      </template>
    </div>
    <NoteMenu
      :open="Boolean(menuAt)"
      :x="menuAt?.x ?? 0"
      :y="menuAt?.y ?? 0"
      :note="note"
      :over-modal="!phone"
      @choose="onChoose"
      @close="menuAt = null"
    />
  </IssueDetailFrame>
</template>

<script setup lang="ts">
import { useNotesStore, type Note, type NoteItem, type NoteLink, type NotePatch } from '~/stores/notes'
import type { UiIconName } from '~/utils/uiIcons'
import { NOTE_MENU_ARCHIVE, NOTE_MENU_DELETE, NOTE_MENU_DISCUSS, NOTE_MENU_UNARCHIVE } from '~/utils/note-menu.mjs'

/* spec 155 2.6: a field saves this long after the last key */
const SAVE_PAUSE_MS = 800

const props = defineProps<{ id: string, phone: boolean, canUp: boolean, canDown: boolean }>()
const emit = defineEmits<{ close: [], delete: [id: string], archive: [id: string], discuss: [id: string], move: [id: string, dir: number] }>()
const { t } = useI18n({ useScope: 'global' })
const store = useNotesStore()

const state = ref<'loading' | 'ready' | 'missing' | 'failed'>('loading')
const note = ref<Note | null>(null)
const title = ref('')
const body = ref('')
const items = ref<NoteItem[]>([])
const saving = ref(false)
const saveFailed = ref(false)
const failKey = ref('notes.not_saved')
/* what is typed and not yet sent */
const dirty = { fields: false, items: false }
let timer: ReturnType<typeof setTimeout> | null = null
let loadSeq = 0

const headTitle = computed(() => title.value || t('notes.untitled'))
const actions = computed<Array<{ id: string, icon: UiIconName, label: string, disabled?: boolean }>>(() => [
  { id: 'pin', icon: 'pin', label: note.value?.pinned ? 'notes.unpin' : 'notes.pin' },
  { id: 'archive', icon: note.value?.archived ? 'unarchive' : 'archive', label: note.value?.archived ? 'notes.unarchive' : 'notes.archive' },
  { id: 'up', icon: 'chevron-up', label: 'notes.move_up', disabled: !props.canUp },
  { id: 'down', icon: 'chevron-down', label: 'notes.move_down', disabled: !props.canDown },
  { id: 'delete', icon: 'trash', label: 'notes.delete' },
  { id: 'menu', icon: 'more', label: 'notes.menu.label' },
])

async function load() {
  const mine = ++loadSeq
  state.value = 'loading'
  const got = await store.get(props.id)
  if (mine !== loadSeq) return
  if ('note' in got) {
    show(got.note)
    state.value = 'ready'
  } else state.value = 'missing' in got ? 'missing' : 'failed'
}

function show(n: Note) {
  note.value = n
  title.value = n.title
  body.value = n.body
  items.value = n.items.map((i) => ({ ...i }))
}

function schedule(what: 'fields' | 'items', now = false) {
  dirty[what] = true
  if (timer) clearTimeout(timer)
  timer = setTimeout(() => { void flush() }, now ? 0 : SAVE_PAUSE_MS)
}

function onItems(next: NoteItem[], now: boolean) {
  items.value = next
  schedule('items', now)
}

/** Send what is typed; a refusal keeps it and offers the retry. */
async function flush() {
  if (timer) clearTimeout(timer)
  timer = null
  if (!note.value || (!dirty.fields && !dirty.items)) return
  const id = note.value.id
  const send = { fields: dirty.fields, items: dirty.items }
  dirty.fields = dirty.items = false
  saving.value = true
  saveFailed.value = false
  try {
    if (send.fields) note.value = await store.patch(id, { title: title.value, body: body.value })
    if (send.items) adoptItems(await store.putItems(id, items.value))
  } catch (e) {
    dirty.fields ||= send.fields
    dirty.items ||= send.items
    failKey.value = (e as { token?: string }).token === 'bad_note' ? 'notes.too_long' : 'notes.not_saved'
    saveFailed.value = true
  } finally {
    saving.value = false
  }
}

/* the hub mints ids for new lines; the text typed meanwhile is kept */
function adoptItems(n: Note) {
  note.value = n
  if (dirty.items || n.items.length !== items.value.length) return
  items.value = n.items.map((it, k) => ({ ...it, text: items.value[k]?.text ?? it.text }))
}

/* B7: a link write is saved by NoteLinks itself; the open note follows */
function onLinks(links: NoteLink[]) {
  if (note.value) note.value = { ...note.value, links }
}

async function patch(fields: NotePatch) {
  if (!note.value) return false
  try {
    note.value = await store.patch(note.value.id, fields)
    return true
  } catch {
    failKey.value = 'notes.not_saved'
    saveFailed.value = true
    return false
  }
}

async function act(id: string, ev?: MouseEvent) {
  if (!note.value) return
  if (id === 'pin') await patch({ pinned: !note.value.pinned })
  else if (id === 'archive') {
    /* 2.10: archiving is the page's (it closes the note, then the Undo snackbar) */
    if (note.value.archived) await patch({ archived: false })
    else {
      await flush()
      emit('archive', note.value.id)
    }
  } else if (id === 'up' || id === 'down') emit('move', note.value.id, id === 'up' ? -1 : 1)
  else if (id === 'delete') {
    if (timer) clearTimeout(timer)
    dirty.fields = dirty.items = false
    emit('delete', note.value.id)
  } else if (id === 'menu' && ev) {
    const r = (ev.currentTarget as HTMLElement).getBoundingClientRect()
    menuAt.value = { x: r.left, y: r.bottom }
  }
}

/* 2.10: the note's menu; a right-click in a text box or on a link keeps the browser's own menu */
const menuAt = ref<{ x: number, y: number } | null>(null)
function onContext(ev: MouseEvent) {
  const el = ev.target as HTMLElement | null
  if (!note.value || el?.closest('input, textarea, a, [contenteditable="true"]')) return
  ev.preventDefault()
  menuAt.value = { x: ev.clientX, y: ev.clientY }
}
async function onChoose(action: string) {
  if (action === NOTE_MENU_UNARCHIVE) await act('archive')
  else if (action === NOTE_MENU_ARCHIVE) await act('archive')
  else if (action === NOTE_MENU_DELETE) await act('delete')
  else if (action === NOTE_MENU_DISCUSS && note.value) {
    /* what is typed goes first, so the discussion posts the text on screen */
    await flush()
    emit('discuss', note.value.id)
  }
}

function close() {
  void flush()
  emit('close')
}

watch(() => props.id, () => {
  void flush()
  void load()
})
/* D8: a Move onto another priority changes it from the page; the chooser follows the row */
watch(() => store.notes.find((n) => n.id === props.id)?.priority, (p) => {
  if (note.value && p && p !== note.value.priority) note.value = { ...note.value, priority: p }
})
onMounted(() => { void load() })
/* the page closed it (Back, another note): what is typed still goes */
onBeforeUnmount(() => { void flush() })
</script>

<style scoped>
.note-detail { min-width: 0; min-height: 0; overflow: auto; background: var(--color-bg); }
.note-in { display: flex; flex-direction: column; gap: 12px; min-width: 0; padding: 12px; box-sizing: border-box; }
.note-in[data-modal="true"] { padding: 16px 20px 20px; max-width: 760px; margin-inline: auto; width: 100%; }
.note-in__h { display: flex; align-items: center; gap: 4px; min-width: 0; }
.note-in__gap { flex: 1 1 auto; }
.note-in__acts { display: inline-flex; gap: 4px; }
.note-in__act { display: inline-flex; align-items: center; justify-content: center; }
.note-in__head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; min-width: 0; }
.note-in__prio { margin-inline-start: auto; }
.note-in__title {
  flex: 0 1 auto;
  min-width: 6ch;
  max-width: 100%;
  field-sizing: content;
  padding: 6px 8px;
  border: 1px solid transparent;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 1.25rem;
  font-weight: 600;
}
.note-in__title:hover, .note-in__title:focus { border-color: var(--color-border); }
.note-in__status { margin: 0; min-height: 1.5rem; }
.note-in__error { color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  /* level 3: the note, full screen under the top bar, above the composer dock (as pages/issues.vue) */
  .note-detail {
    position: fixed;
    inset-inline: 0;
    top: var(--top-bar-h, 0px);
    bottom: calc(var(--composer-dock-h, 0px) + var(--kb-inset, 0px));
    width: 100%;
    max-width: 100%;
    z-index: 20;
    padding-bottom: calc(12px + env(safe-area-inset-bottom, 0px));
  }
  .spool-shell[data-mobile-section="1"] .note-detail { position: absolute; top: 0; }
  .note-in__back, .note-in__act { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
  .note-in__title { min-height: var(--tap, 44px); }
}
</style>
