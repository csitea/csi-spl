<!-- A VS Code-like file tree (owner HUM-10, t1 efde25bb: "qto files file
     system visual studio code like"). Presentational only: the caller owns
     the data and passes the visible rows in order; this draws them, keeps a
     roving focus and answers the keys a tree has (WAI-ARIA tree pattern):
     Up / Down move, Right opens a closed node or steps into it, Left closes
     an open node or steps to its parent, Home / End jump, Enter and Space
     select. A click on the chevron toggles, a click on the row selects.
     A row with `menu` set asks for its menu (`menu` event, at a point):
     right-click, a touch long press, or Shift+F10 / the context-menu key
     on the focused row; the caller draws the menu. Other rows keep the
     browser's own.
     A row with `drag` set re-orders (SPL-1873, owner t1 1a9a14b6 msg
     32d5ea87: "drag and drop aka re-order of files within folders"): a mouse
     drags it, a finger long-presses (the menu opens) and then drags it. A
     line marks the gap it lands in; over a row with `into` set, its middle
     marks the row itself (a folder: in it). The caller's `canDrop` says
     which places it takes; the drop emits `move` (row, target row, before /
     after / into). Escape cancels. Alt+Up / Alt+Down move the focused row
     before its previous or after its next sibling.
     Built so the Docs explorer (DocsWorkspaceTree) can share it when the
     two doc sources merge (owner: "later on"). -->
<template>
  <ul role="tree" class="ftree" :class="{ 'ftree--dragging': Boolean(dragKey) }" :aria-label="label" data-test="file-tree" @keydown="onKey">
    <li
      v-for="(row, i) in rows"
      :key="row.key"
      :ref="(el) => setEl(row.key, el)"
      role="treeitem"
      class="ftree__row"
      :class="{ 'ftree__row--active': row.active, 'ftree__row--drag': row.key === dragKey, [`ftree__row--drop-${dropAt?.where}`]: dropAt?.key === row.key }"
      :style="{ '--depth': row.depth }"
      :aria-level="row.depth + 1"
      :aria-expanded="row.expandable ? (row.open ? 'true' : 'false') : undefined"
      :aria-selected="row.active ? 'true' : 'false'"
      :tabindex="row.key === focusKey ? 0 : -1"
      :title="row.title || row.name"
      data-test="file-tree-row"
      :data-key="row.key"
      :data-kind="row.kind"
      :data-drop="dropAt?.key === row.key ? dropAt.where : undefined"
      @focus="focusKey = row.key"
      @click="onRowClick(i)"
      @contextmenu="onContext(i, $event)"
      @pointerdown="(row.menu || row.drag) && press(i, $event)"
      @pointermove="gesture.move($event)"
      @pointerup="gesture.up($event)"
      @pointercancel="gesture.cancel()"
      @touchmove="onTouchMove"
    >
      <span
        class="ftree__chev"
        :data-test="row.expandable ? 'file-tree-toggle' : undefined"
        aria-hidden="true"
        @click.stop="row.expandable ? toggleAt(i) : select(i)"
      >
        <UiIcon v-if="row.expandable" :name="row.open ? 'chevron-down' : 'chevron-right'" :size="14" />
      </span>
      <UiIcon :name="row.icon" :size="16" class="ftree__icon" />
      <span class="ftree__name">{{ row.name }}</span>
    </li>
  </ul>
</template>

<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, watch, type ComponentPublicInstance } from 'vue'
import type { UiIconName } from '~/utils/uiIcons'
import { createTreeDrag, dropWhere, siblingAt } from '~/utils/tree-drag'

export type FileTreeRow = {
  key: string
  depth: number
  name: string
  icon: UiIconName
  kind: string
  expandable: boolean
  open?: boolean
  active?: boolean
  title?: string
  /** the row has a menu: right-click, long press and Shift+F10 emit `menu` */
  menu?: boolean
  /** the row re-orders: drag, or Alt+Up / Alt+Down */
  drag?: boolean
  /** a dragged row may drop into this one (a folder) */
  into?: boolean
}

export type FileTreeDrop = 'before' | 'after' | 'into'

const props = defineProps<{ rows: FileTreeRow[], label: string, canDrop?: (key: string, target: string, where: FileTreeDrop) => boolean }>()
const emit = defineEmits<{ toggle: [key: string], select: [key: string], menu: [key: string, x: number, y: number], move: [key: string, target: string, where: FileTreeDrop], lift: [key: string] }>()

/* the one row in the tab order: the active row, else the first */
const focusKey = ref('')
/* a row moved by the keys: re-ordering the list moves its element, which
   drops the focus, so it is focused again while the new order lands */
let refocus = ''
let refocusTimer: ReturnType<typeof setTimeout> | undefined
watch(() => props.rows, (rows) => {
  const j = refocus ? rows.findIndex((r) => r.key === refocus) : -1
  if (j >= 0) focusAt(j)
  if (rows.some((r) => r.key === focusKey.value)) return
  focusKey.value = (rows.find((r) => r.active) || rows[0])?.key || ''
}, { immediate: true })

const els = new Map<string, HTMLElement>()
function setEl(key: string, el: Element | ComponentPublicInstance | null) {
  if (el instanceof HTMLElement) els.set(key, el)
  else els.delete(key)
}

function focusAt(i: number) {
  const row = props.rows[Math.max(0, Math.min(i, props.rows.length - 1))]
  if (!row) return
  focusKey.value = row.key
  void nextTick(() => els.get(row.key)?.focus())
}

function select(i: number) {
  const row = props.rows[i]
  if (!row) return
  focusKey.value = row.key
  emit('select', row.key)
}

function openMenu(i: number, x: number, y: number) {
  const row = props.rows[i]
  if (!row?.menu) return
  focusKey.value = row.key
  els.get(row.key)?.focus({ preventScroll: true })
  emit('menu', row.key, x, y)
}

function onContext(i: number, e: MouseEvent) {
  if (!props.rows[i]?.menu) return
  e.preventDefault()
  openMenu(i, e.clientX, e.clientY)
}

/* a phone has no right-click: a held touch opens the row's menu (touch-ui's
   timing); a drag row then lifts when the finger moves (tree-drag.ts) */
let pressAt = -1
let pressPointer = -1
const dragKey = ref('')
const dropAt = ref<{ key: string, where: FileTreeDrop } | null>(null)

function canDrop(target: string, where: FileTreeDrop): boolean {
  const t = props.rows.find((r) => r.key === target)
  if (!t || target === dragKey.value || (where === 'into' && !t.into)) return false
  return props.canDrop ? props.canDrop(dragKey.value, target, where) : where !== 'into'
}

/** the row under the pointer and the place on it */
function track(x: number, y: number) {
  const el = document.elementFromPoint(x, y)?.closest('[data-test=file-tree-row]')
  const key = el instanceof HTMLElement ? el.dataset.key || '' : ''
  if (!key || !el || els.get(key) !== el) {
    dropAt.value = null
    return
  }
  const where = dropWhere(y, el.getBoundingClientRect(), { before: canDrop(key, 'before'), after: canDrop(key, 'after'), into: canDrop(key, 'into') })
  dropAt.value = where ? { key, where } : null
}

function endDrag() {
  dragKey.value = ''
  dropAt.value = null
  window.removeEventListener('keydown', onEscape, true)
}

function onEscape(e: KeyboardEvent) {
  if (e.key !== 'Escape') return
  e.preventDefault()
  e.stopPropagation()
  gesture.cancel()
}

const gesture = createTreeDrag({
  onHold: (x, y) => openMenu(pressAt, x, y),
  onStart: () => {
    const row = props.rows[pressAt]
    if (!row) return
    dragKey.value = row.key
    focusKey.value = row.key
    try { els.get(row.key)?.setPointerCapture(pressPointer) } catch { /* the pointer is gone */ }
    window.addEventListener('keydown', onEscape, true)
    emit('lift', row.key)
  },
  onMove: track,
  onDrop: (x, y) => {
    track(x, y)
    const key = dragKey.value
    const at = dropAt.value
    endDrag()
    if (key && at) emit('move', key, at.key, at.where)
  },
  onCancel: endDrag,
})
function press(i: number, e: PointerEvent) {
  pressAt = i
  pressPointer = e.pointerId
  gesture.down(e, Boolean(props.rows[i]?.drag))
}
/* a held finger drags: the list under it does not scroll */
function onTouchMove(e: TouchEvent) {
  if (gesture.holding && e.cancelable) e.preventDefault()
}
onBeforeUnmount(() => {
  gesture.cancel()
  endDrag()
  clearTimeout(refocusTimer)
})

/* the click a finger sends as it lifts from a long press, or a drag's release, does not also select */
function onRowClick(i: number) {
  if (gesture.takeClick()) return
  select(i)
}

/** Alt+Up / Alt+Down: before the previous sibling, after the next one */
function nudge(i: number, dir: -1 | 1) {
  const row = props.rows[i]
  const j = siblingAt(props.rows, i, dir)
  if (!row?.drag || j < 0) return
  const where = dir < 0 ? 'before' : 'after'
  if (props.canDrop && !props.canDrop(row.key, props.rows[j].key, where)) return
  refocus = row.key
  clearTimeout(refocusTimer)
  refocusTimer = setTimeout(() => { refocus = '' }, 2000)
  emit('move', row.key, props.rows[j].key, where)
}

/** the keyboard's menu: just under the focused row */
function menuFromKey(i: number) {
  const r = els.get(props.rows[i]?.key ?? '')?.getBoundingClientRect()
  if (r) openMenu(i, r.left + 16, r.bottom)
}

function toggleAt(i: number) {
  const row = props.rows[i]
  if (!row) return
  focusKey.value = row.key
  emit('toggle', row.key)
}

/** the row's parent: the nearest row above it one level up */
function parentOf(i: number): number {
  const d = props.rows[i]?.depth ?? 0
  for (let j = i - 1; j >= 0; j--) if (props.rows[j].depth < d) return j
  return -1
}

function onKey(e: KeyboardEvent) {
  const i = props.rows.findIndex((r) => r.key === focusKey.value)
  if (i < 0) return
  const row = props.rows[i]
  let done = true
  if (e.altKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
    e.preventDefault()
    return nudge(i, e.key === 'ArrowUp' ? -1 : 1)
  }
  switch (e.key) {
    case 'ArrowDown': focusAt(i + 1); break
    case 'ArrowUp': focusAt(i - 1); break
    case 'Home': focusAt(0); break
    case 'End': focusAt(props.rows.length - 1); break
    case 'ArrowRight':
      if (row.expandable && !row.open) toggleAt(i)
      else if (row.expandable && (props.rows[i + 1]?.depth ?? -1) > row.depth) focusAt(i + 1)
      break
    case 'ArrowLeft':
      if (row.expandable && row.open) toggleAt(i)
      else if (parentOf(i) >= 0) focusAt(parentOf(i))
      break
    case 'Enter':
    case ' ':
      select(i)
      break
    case 'ContextMenu':
      done = Boolean(row.menu)
      menuFromKey(i)
      break
    case 'F10':
      done = e.shiftKey && Boolean(row.menu)
      if (done) menuFromKey(i)
      break
    default: done = false
  }
  if (done) e.preventDefault()
}
</script>

<style scoped>
.ftree { list-style: none; margin: 0; padding: 0; text-align: start; }
.ftree__row {
  display: flex;
  align-items: center;
  gap: 4px;
  min-height: 28px;
  padding: 2px 8px;
  padding-inline-start: calc(4px + var(--depth, 0) * 14px);
  border-radius: var(--radius-sm, 8px);
  color: var(--color-fg);
  cursor: pointer;
  user-select: none;
}
.ftree__row:hover { background: var(--color-bg-2); }
.ftree__row--active { background: var(--color-selected); font-weight: 600; }
.ftree--dragging, .ftree--dragging .ftree__row { cursor: grabbing; }
.ftree__row--drag { opacity: 0.45; }
.ftree__row--drop-before { box-shadow: inset 0 2px 0 var(--color-accent); }
.ftree__row--drop-after { box-shadow: inset 0 -2px 0 var(--color-accent); }
.ftree__row--drop-into { background: var(--color-selected); box-shadow: inset 0 0 0 1px var(--color-accent); }
.ftree__chev { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; }
.ftree__icon { flex: none; color: var(--color-muted); }
.ftree__name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
:global([dir="rtl"]) .ftree__chev [data-icon="chevron-right"] { transform: scaleX(-1); }
@media (max-width: 820px) {
  .ftree__row { min-height: 44px; }
  .ftree__chev { width: 32px; height: 44px; }
}
</style>
