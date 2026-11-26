<!-- Spec 155 2.6 (SPL-2403, B5 SPL-4123): the Notes section, the person's
     own list (the realm, 2.2: the same list in every workspace). The sidebar
     keeps the icon rail only (ChannelSidebar notesRailOnly); this page is the
     list: the + (New note), the filter box, the Pinned group, then the rest. An
     archived note is seen in the Archive section (components/ArchiveNotes.vue;
     owner t1 2f4311d9, SPL-4897), so the bar has no Archived switch. A row is
     one line, the title alone (owner, t1 2a0b4d9e, SPL-4651) with its priority
     beside it (spec 155 2.9, SPL-4652; hidden on a phone, SPL-4893), and is
     /notes?note=<id>; B6 (SPL-4186) opens it, and closing it puts the focus
     on its row, a spec 103 vim item (j / k, arrows; SPL-6063):
     components/NoteDetail.vue, lazy, a modal above 820 px and the level-3
     full screen on a phone. The order is the person's own: drag a row, or
     Alt+Up / Alt+Down on it (utils/note-order.mjs); on a phone a press held on
     a row lifts it and the finger drags it (SPL-6175, useDragReorder). Every
     row has a menu (spec 155 2.10, SPL-5255): a right-click, or its menu
     button (a phone has no right-click), with Archive, Turn into a discussion
     and Delete (components/NoteMenu.vue, composables/useNoteActions.ts). Archive and
     Delete (D2) act at once, no confirm, and show a 10 s Undo snackbar, at the
     bottom on a phone and at the top on a desktop; the DELETE goes when it ends.
     On a desktop the Delete key (or Backspace) deletes the focused row, or
     every checked row, through that same Delete with one Undo (SPL-6542,
     owner t1 7a01494a): Ctrl / Cmd + click checks a row, Shift + click the
     run to it, Shift + J / K (or the arrows) the next row; Esc clears. The
     check is the issues list's (utils/issues-bulk.ts), marked with the
     selected fill and bar. -->
<template>
  <div class="feed-col notes-page" data-test="notes-page">
    <header class="feed-header">
      <MobileBack />
      <h2 class="notes-title" data-test="notes-heading">
        <UiIcon name="notes" :size="18" />
        <span>{{ t('notes.title') }}</span>
      </h2>
      <!-- owner t1 2f4311d9 (msg b182efa5): "Use the standard plus button" - the
           round + of Issues (issues-fab), Docs and Calendar; there is no shared
           component, each page draws it. On a phone it floats 16 px over the dock
           (--composer-dock-h, 0 on Notes: SPL-4901 hides the dock there, so no
           go button for msg 7c54e6f7's 5 mm), and hides under an open note -->
      <button
        v-if="store.state !== 'off'"
        v-show="!(phone && openId)"
        ref="newBtn"
        type="button"
        class="notes-fab"
        data-test="notes-new"
        :disabled="creating"
        :aria-label="t('notes.new')"
        :title="t('notes.new')"
        @click="newNote"
      >
        <UiIcon name="plus" :size="22" :stroke-width="2.5" />
      </button>
    </header>
    <div class="feed-body notes-body">
      <p v-if="store.state === 'off'" class="muted" data-test="notes-off">{{ t('notes.off') }}</p>
      <template v-else>
        <div class="notes-bar">
          <input
            v-model="query"
            type="search"
            class="notes-bar__filter"
            data-test="notes-filter"
            :placeholder="t('notes.filter')"
            :aria-label="t('notes.filter')"
          >
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
                :class="{ 'notes-row--over': dragOver === n.id, 'notes-row--lifted': lifted === n.id }"
                data-test="notes-row"
                :data-checked="selSet.has(n.id) ? 'true' : undefined"
                :data-note-id="n.id"
                :data-reorder-id="n.id"
                :draggable="phone ? undefined : 'true'"
                @dragstart="onDragStart(n.id, $event)"
                @dragover.prevent="dragOver = n.id"
                @dragleave="dragOver = ''"
                @drop.prevent="onDrop(n.id)"
                @dragend="dragId = ''; dragOver = ''"
                @contextmenu.prevent="onContextMenu(n.id, $event)"
                @click.capture="swallowHeldClick"
              >
                <a
                  class="notes-row__open"
                  :class="{ 'notes-row__open--current': openId === n.id }"
                  :href="noteHref(n.id)"
                  :aria-current="openId === n.id ? 'true' : undefined"
                  data-test="notes-open"
                  data-vim-item
                  :draggable="phone ? 'false' : undefined"
                  @pointerdown="phone && holdRow(g.id, n.id, $event)"
                  @click="onRowClick(n.id, $event)"
                  @keydown="onRowKey(n.id, $event)"
                  @keydown.alt.up.prevent="move(n.id, -1)"
                  @keydown.alt.down.prevent="move(n.id, 1)"
                >
                  <span class="notes-row__title">{{ rowTitle(n) }}</span>
                  <span class="notes-row__prio" data-test="notes-row-priority">{{ t('topic.priority.badge', { n: notePriority(n) }) }}</span>
                </a>
                <button
                  type="button"
                  class="icon-btn notes-row__menu"
                  data-test="notes-row-menu"
                  :aria-label="t('notes.menu.label')"
                  :title="t('notes.menu.label')"
                  aria-haspopup="menu"
                  :aria-expanded="menu?.id === n.id ? 'true' : 'false'"
                  @click="openMenuAt(n.id, $event)"
                ><UiIcon name="more" :size="18" /></button>
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
      @close="closeNote"
      @delete="onDelete"
      @archive="onArchive"
      @discuss="acts.discuss"
      @move="move"
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
      :text="t(toastView.text, { n: toastView.n })"
      :show-undo="Boolean(toastView.button)"
      :undo-label="toastView.button ? t(toastView.button) : ''"
      :close-label="t('common.close')"
      :duration="NOTE_UNDO_MS"
      @undo="acts.act()"
      @dismiss="acts.settle()"
    />
  </div>
</template>

<script setup lang="ts">
import { filterNotes, useNotesStore } from '~/stores/notes'
import type { NoteSummary } from '~/stores/notes'
import { movePlacement, dropPlacement, drawnAbove, notePriority } from '~/utils/note-order.mjs'
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { useMobileStack } from '~/composables/useMobileStack'
import { useDragReorder } from '~/composables/useDragReorder'
import { useNoteOpen } from '~/composables/useNoteOpen'
import { NOTE_UNDO_MS, noteToastView, useNoteActions } from '~/composables/useNoteActions'
import { NOTE_MENU_ARCHIVE, NOTE_MENU_DELETE, NOTE_MENU_DISCUSS, NOTE_MENU_UNARCHIVE } from '~/utils/note-menu.mjs'
import { DELETE_KEYS } from '~/utils/msg-edit.mjs'
import { rangeSelect, toggleKey } from '~/utils/issues-bulk'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const stack = useMobileStack()
const phone = computed(() => stack.isMobile.value)
const { openId, open, close } = useNoteOpen({ route, router, phone })
const localePath = useLocalePath()
const store = useNotesStore()
const query = ref('')
const creating = ref(false)
const createFailed = ref(false)
const newBtn = ref<HTMLButtonElement | null>(null)

useHead({ title: () => t('notes.title') })

const rows = computed(() => filterNotes(store.notes, query.value, false))
/* 2.6: the Pinned group, then the rest; archived notes are in the Archive section */
const groups = computed(() => {
  const pinned = dragged('pinned', rows.value.filter((n) => n.pinned))
  const rest = dragged('rest', rows.value.filter((n) => !n.pinned))
  if (!pinned.length) return [{ id: 'rest', label: '', rows: rest }]
  return [{ id: 'pinned', label: 'notes.pinned', rows: pinned }, ...(rest.length ? [{ id: 'rest', label: 'notes.others', rows: rest }] : [])]
})
const emptyKey = computed(() => (query.value.trim() ? 'notes.empty_filter' : 'notes.empty'))

/* the order (B6): one PATCH position, with the priority when D8 changes it;
   the row moves at once, a refusal reloads the list */
function move(id: string, dir: number) {
  place(id, movePlacement(store.notes, id, dir))
}
function canMove(id: string, dir: number) {
  return movePlacement(store.notes, id, dir) !== null
}
function place(id: string, to: { position: number, priority: number } | null) {
  const was = store.notes.find((n) => n.id === id)
  if (!to || !was) return
  const fields = notePriority(was) === to.priority ? { position: to.position } : to
  store.notes = store.notes.map((n) => (n.id === id ? { ...n, ...fields } : n))
  store.patch(id, fields).catch(() => store.load())
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
  place(id, dropPlacement(store.notes, id, target, drawnAbove(store.notes, id, target)))
}

/* SPL-6175 (owner HUM-10, t1 cc9d7c26, msg 82670a2e): "just keeping the thumb
   down would activate the dragging mode". On a phone a press held on a row
   (the rail's 450 ms, no move) lifts it, the finger drags it inside its group,
   and the release lands it as a desktop drop: on the row it took the place
   of, so D8 gives it that row's priority. A move before the hold scrolls. */
const dragGroup = ref('rest')
const groupRows = (g: string) => [...document.querySelectorAll<HTMLElement>(`[data-test=notes-group-${g}] [data-reorder-id]`)]
const rowDrag = useDragReorder<string>({
  order: () => groupRows(dragGroup.value).map((el) => el.dataset.reorderId || ''),
  items: () => groupRows(dragGroup.value),
  onDrop: (next) => onHoldDrop(next),
  touchHoldMs: 450,
})
const lifted = computed(() => rowDrag.draggingId.value || rowDrag.heldId.value)
/* the pressed row and its group's order when the press began */
let press = { id: '', order: [] as string[] }
function holdRow(group: string, id: string, ev: PointerEvent) {
  dragGroup.value = group
  press = { id, order: groupRows(group).map((el) => el.dataset.reorderId || '') }
  rowDrag.down(ev, id)
}
/* the group's rows in the order the finger shows while it drags */
function dragged(group: string, list: NoteSummary[]) {
  const order = rowDrag.preview.value
  if (!order || dragGroup.value !== group) return list
  const byId = new Map(list.map((n) => [n.id, n]))
  return order.map((id) => byId.get(id)).filter((n): n is NoteSummary => Boolean(n))
}
/* dragged down: it lands after the row now above it; dragged up: before the one below */
function onHoldDrop(next: string[]) {
  const { id, order } = press
  const k = next.indexOf(id)
  const down = k > order.indexOf(id)
  const target = next[down ? k - 1 : k + 1]
  if (target) place(id, dropPlacement(store.notes, id, target, down))
}
/* the lift buzzes where a phone can; a hold let go in place opens nothing */
let heldClickUntil = 0
watch(() => rowDrag.heldId.value, (now, was) => {
  if (now) navigator.vibrate?.(15)
  else if (was) heldClickUntil = Date.now() + 400
}, { flush: 'sync' })
function swallowHeldClick(e: MouseEvent) {
  if (Date.now() >= heldClickUntil) return
  heldClickUntil = 0
  e.preventDefault()
  e.stopPropagation()
}
/* a long press is the drag on a phone, never the row menu (it has its button);
   a wider touch screen keeps the long press menu */
function onContextMenu(id: string, e: MouseEvent) {
  if (phone.value && ((e as PointerEvent).pointerType === 'touch' || rowDrag.heldId.value)) return
  openMenu(id, e.clientX, e.clientY)
}

/* 2.10 (SPL-5255): Archive and Delete act at once, no confirm, then the Undo
   snackbar; D2: Undo of a Delete sends nothing, its DELETE goes when the
   snackbar ends. Turn into a discussion: its snackbar's Open goes to the topic. */
const acts = useNoteActions({ onOpenTopic: (taskId) => { void router.push(localePath('/t/' + taskId)) } })
const toastView = computed(() => (acts.toast.value ? noteToastView(acts.toast.value) : noteToastView({ kind: 'failed', id: '', seq: 0 })))
function onDelete(id: string | string[]) {
  const ids = typeof id === 'string' ? [id] : id
  if (ids.includes(openId.value)) close()
  acts.remove(ids)
}
function onArchive(id: string) {
  if (openId.value === id) close()
  void acts.archive(id)
}

/* SPL-6542 (owner HUM-10, t1 7a01494a, msg 3ece009b): "delete notes by
   having them selected and clicking the delete button the keyboard on the
   desktop wui". The checked rows, in the order they were checked; a row that
   leaves the list leaves them. Desktop only: a phone has no keyboard keys. */
const selected = ref<string[]>([])
const selSet = computed(() => new Set(selected.value))
const shownIds = computed(() => groups.value.flatMap((g) => g.rows.map((n) => n.id)))
let checkAnchor = ''
watch(shownIds, (ids) => {
  const keep = selected.value.filter((id) => ids.includes(id))
  if (keep.length !== selected.value.length) selected.value = keep
})
function clearChecked() {
  selected.value = []
  checkAnchor = ''
}
/* a plain click opens the note; Ctrl / Cmd checks the row, Shift the run to it */
function onRowClick(id: string, e: MouseEvent) {
  const mod = e.ctrlKey || e.metaKey || e.shiftKey || e.altKey
  if (!mod) {
    e.preventDefault()
    clearChecked()
    open(id)
    return
  }
  if (phone.value || e.altKey) return
  e.preventDefault()
  selected.value = e.shiftKey && checkAnchor
    ? rangeSelect(selected.value, shownIds.value, checkAnchor, id, true)
    : toggleKey(selected.value, id)
  checkAnchor = id
}
/* Shift + J / K (or the arrows): this row and the next one are checked, the focus moves on */
function checkStep(id: string, dir: number) {
  const next = shownIds.value[shownIds.value.indexOf(id) + dir]
  if (!next) return
  selected.value = toggleKey(toggleKey(selected.value, id, true), next, true)
  checkAnchor = next
  focusRow(next)
}
const STEP_KEYS: Record<string, number> = { J: 1, j: 1, ArrowDown: 1, K: -1, k: -1, ArrowUp: -1 }
function onRowKey(id: string, e: KeyboardEvent) {
  if (phone.value || e.isComposing || e.target !== e.currentTarget) return
  if (e.ctrlKey || e.metaKey || e.altKey) return
  const step = e.shiftKey ? STEP_KEYS[e.key] : undefined
  if (step) {
    e.preventDefault()
    checkStep(id, step)
  } else if (e.key === 'Escape' && selected.value.length) {
    e.preventDefault()
    e.stopPropagation()
    clearChecked()
  } else if (!e.shiftKey && DELETE_KEYS.includes(e.key)) {
    e.preventDefault()
    const ids = selected.value.length ? [...selected.value] : [id]
    clearChecked()
    onDelete(ids)
  }
}

/* SPL-6063 (owner HUM-10, t1 3858d264, msg 7bd1c224): Esc, the X or a click
   beside the note puts the focus on its row, also for a note made with the +
   (the dialog hands it back to the + first), so j / k and the arrows step the
   list at once (each row link is a spec 103 vim item, data-vim-item) */
function closeNote() {
  const id = openId.value
  close()
  if (id && !phone.value) void nextTick(() => focusRow(id))
}
function focusRow(id: string) {
  const row = [...document.querySelectorAll<HTMLElement>('[data-test=notes-row]')].find((el) => el.dataset.noteId === id)
  row?.querySelector<HTMLElement>('[data-test=notes-open]')?.focus()
}

/* the row's menu: at the pointer (right-click), or under its button */
const menu = ref<{ id: string, x: number, y: number } | null>(null)
const menuNote = computed(() => (menu.value ? store.notes.find((n) => n.id === menu.value?.id) ?? null : null))
function openMenu(id: string, x: number, y: number) {
  menu.value = { id, x, y }
}
function openMenuAt(id: string, e: MouseEvent) {
  const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
  openMenu(id, r.left, r.bottom)
}
function onChoose(action: string) {
  const id = menu.value?.id
  if (!id) return
  if (action === NOTE_MENU_ARCHIVE) onArchive(id)
  else if (action === NOTE_MENU_UNARCHIVE) void acts.unarchive(id)
  else if (action === NOTE_MENU_DISCUSS) void acts.discuss(id)
  else if (action === NOTE_MENU_DELETE) onDelete(id)
}

/* a plain link: a click opens the note in place (useNoteOpen), a middle
   click still opens its address in a new tab (Ctrl / Cmd + click checks the
   row, SPL-6542). A NuxtLink's own click pushed the route before the page
   could open it, so a phone got two history entries and Back did not close
   the note. */
function noteHref(id: string) {
  return router.resolve({ path: localePath('/notes'), query: { note: id } }).href
}

/** the title, else the first line of the text (2.6), else "Untitled note" */
function rowTitle(n: NoteSummary) {
  return n.title || n.snippet.split('\n')[0] || t('notes.untitled')
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
  query.value = ''
  open(id)
}

/* 2.1: no live updates between tabs; the list is read again on focus */
function onFocus() {
  if (store.state === 'ready') void store.load()
}
/* SPL-6153 (owner HUM-10, t1 1f25c14e, msg 17b9aebc): entering Notes puts the
   focus on the +, so Enter makes a note at once; inside the page, so the
   layout's route focus (useShellRouteFocus) leaves it there. Not over a note
   opened by its address: closing one focuses its row (SPL-6063). */
onMounted(() => {
  if (!openId.value) void nextTick(() => newBtn.value?.focus({ preventScroll: true }))
  void store.load()
  window.addEventListener('focus', onFocus)
})
onUnmounted(() => {
  window.removeEventListener('focus', onFocus)
})
</script>

<style scoped>
.notes-title { display: inline-flex; align-items: center; gap: 8px; margin: 0; }
.notes-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0 0 0.75rem; }
/* the issues page's + (issues.vue .issues-fab, SPL-978), same size and look */
.notes-fab {
  position: relative;
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 2.5rem;
  height: 2.5rem;
  padding: 0;
  border: 0;
  border-radius: 50%;
  overflow: hidden;
  background: var(--color-accent);
  color: var(--color-on-accent);
  cursor: pointer;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3), 0 1px 2px rgba(0, 0, 0, 0.2);
  transition: box-shadow 0.15s ease, background-color 0.15s ease, transform 0.1s ease;
}
.notes-fab:hover {
  background: var(--color-accent-pressed);
  box-shadow: 0 3px 6px rgba(0, 0, 0, 0.3), 0 2px 4px rgba(0, 0, 0, 0.22);
}
.notes-fab:active { transform: scale(0.96); }
.notes-fab:disabled { opacity: 0.6; cursor: default; }
@media (prefers-reduced-motion: reduce) {
  .notes-fab { transition: none; }
  .notes-fab:active { transform: none; }
}
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
.notes-error { margin: 0 0 0.75rem; color: var(--color-danger); overflow-wrap: anywhere; }
.notes-group + .notes-group { margin-top: 1rem; }
.notes-group__head { margin: 0 0 0.5rem; font-size: 0.8125rem; font-weight: 600; text-transform: uppercase; color: var(--color-muted); }
.notes-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.notes-row { display: flex; align-items: center; gap: 4px; min-width: 0; }
.notes-row__menu { flex: 0 0 auto; display: inline-flex; align-items: center; justify-content: center; }
.notes-row__open {
  flex: 1 1 auto;
  display: flex;
  align-items: center;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  color: var(--color-fg);
  text-decoration: none;
  min-width: 0;
}
.notes-row__open--current { border-color: var(--color-accent); }
/* SPL-6542: a checked row: the selected fill and marker bar (SideHitList .side-hit.active) */
.notes-row[data-checked='true'] .notes-row__open { background: var(--color-selected); box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring); }
.notes-row--over .notes-row__open { border-top: 2px solid var(--color-accent); }
/* SPL-6175: the row a held press lifted, while the finger drags it */
.notes-row--lifted .notes-row__open { border-color: var(--color-accent); background: var(--color-surface); box-shadow: 0 3px 8px rgba(0, 0, 0, 0.25); }
/* owner t1 ba784026 (msg 037cedef): the chip sits right of the title, not at
   the row's far edge, so the title takes only its own width */
.notes-row__title {
  flex: 0 1 auto;
  min-width: 0;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
/* the same small outlined tag as a message's priority badge (MessageCard .msg-prio) */
.notes-row__prio {
  flex: 0 0 auto;
  margin-inline-start: 8px;
  color: var(--color-muted);
  font-size: 0.75rem;
  white-space: nowrap;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 0 4px;
}
@media (max-width: 820px) {
  .notes-bar .btn, .notes-bar__filter, .notes-row__open { min-height: var(--tap, 44px); }
  .notes-row__menu { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
  /* a held press is the drag: no text selection, no link callout */
  .notes-row__open { user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
  /* the phone +: over the dock, if any, on the bottom right */
  .notes-fab {
    position: fixed;
    /* px, as issues-fab: the send button sits 16 px from the edge at every
       root font size, and --spacing-md is 1rem (18 px on a phone) */
    inset-inline-end: 16px;
    bottom: calc(16px + max(var(--composer-dock-h, 0px), env(safe-area-inset-bottom, 0px)));
    z-index: 15;
    width: 56px;
    height: 56px;
    box-shadow: 0 3px 5px rgba(0, 0, 0, 0.2), 0 6px 10px rgba(0, 0, 0, 0.14), 0 1px 18px rgba(0, 0, 0, 0.12);
  }
  /* the last row scrolls clear of the + */
  .notes-body { padding-bottom: calc(56px + 32px); }
  /* owner t1 2f4311d9 (msg 65341de0, poll 1de5c599 PH): no P1..P5 on a phone */
  .notes-row__prio { display: none; }
}
</style>
