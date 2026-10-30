<!-- Spec 155 2.6 (B6, SPL-4186): the open note. Above 820 px a modal like an
     open issue (IssueDetailFrame: focus trap, Esc / X / backdrop close); on a
     phone the level-3 full screen with the Back chevron (MobileBack). Owner
     HUM-10 (t1 cb9d7bdc, msg cc1a052f): "I cannot edit notes on mobile."
     Inside: title, text, the checklist, the links (B7, NoteLinks: each link
     added or removed is its own POST / DELETE), and Pin, Archive, Move up / down,
     Delete. Each field saves 800 ms after the last key and on close; a failed
     save keeps the text and shows "Not saved, retry". Delete is the page's
     (D2: the note goes at once, the DELETE waits for the 10 s Undo).
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
          @click="act(a.id)"
        ><UiIcon :name="a.icon" :size="16" /></button>
      </span>
    </template>
    <div class="note-in" data-test="note-detail" :data-note-id="id" :data-state="state" :data-modal="phone ? 'false' : 'true'">
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
            @click="act(a.id)"
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
        <textarea
          v-model="body"
          class="note-in__body"
          data-test="note-body"
          maxlength="20000"
          rows="8"
          :placeholder="t('notes.body_placeholder')"
          :aria-label="t('notes.body_label')"
          @input="schedule('fields')"
        />
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
  </IssueDetailFrame>
</template>

<script setup lang="ts">
import { useNotesStore, type Note, type NoteItem, type NoteLink, type NotePatch } from '~/stores/notes'
import type { UiIconName } from '~/utils/uiIcons'

/* spec 155 2.6: a field saves this long after the last key */
const SAVE_PAUSE_MS = 800

const props = defineProps<{ id: string, phone: boolean, canUp: boolean, canDown: boolean }>()
const emit = defineEmits<{ close: [], delete: [id: string], move: [id: string, dir: number] }>()
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

async function act(id: string) {
  if (!note.value) return
  if (id === 'pin') await patch({ pinned: !note.value.pinned })
  else if (id === 'archive') {
    const archiving = !note.value.archived
    if ((await patch({ archived: archiving })) && archiving) close()
  } else if (id === 'up' || id === 'down') emit('move', note.value.id, id === 'up' ? -1 : 1)
  else if (id === 'delete') {
    if (timer) clearTimeout(timer)
    dirty.fields = dirty.items = false
    emit('delete', note.value.id)
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
.note-in__title {
  min-width: 0;
  padding: 6px 8px;
  border: 1px solid transparent;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 1.25rem;
  font-weight: 600;
}
.note-in__body {
  min-width: 0;
  min-height: 8rem;
  padding: 8px;
  border: 1px solid var(--color-border);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  resize: vertical;
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
