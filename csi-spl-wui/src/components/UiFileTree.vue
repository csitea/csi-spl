<!-- A VS Code-like file tree (owner HUM-10, t1 efde25bb: "qto files file
     system visual studio code like"). Presentational only: the caller owns
     the data and passes the visible rows in order; this draws them, keeps a
     roving focus and answers the keys a tree has (WAI-ARIA tree pattern):
     Up / Down move, Right opens a closed node or steps into it, Left closes
     an open node or steps to its parent, Home / End jump, Enter and Space
     select. A click on the chevron toggles, a click on the row selects.
     Built so the Docs explorer (DocsWorkspaceTree) can share it when the
     two doc sources merge (owner: "later on"). -->
<template>
  <ul role="tree" class="ftree" :aria-label="label" data-test="file-tree" @keydown="onKey">
    <li
      v-for="(row, i) in rows"
      :key="row.key"
      :ref="(el) => setEl(row.key, el)"
      role="treeitem"
      class="ftree__row"
      :class="{ 'ftree__row--active': row.active }"
      :style="{ '--depth': row.depth }"
      :aria-level="row.depth + 1"
      :aria-expanded="row.expandable ? (row.open ? 'true' : 'false') : undefined"
      :aria-selected="row.active ? 'true' : 'false'"
      :tabindex="row.key === focusKey ? 0 : -1"
      :title="row.title || row.name"
      data-test="file-tree-row"
      :data-key="row.key"
      :data-kind="row.kind"
      @focus="focusKey = row.key"
      @click="select(i)"
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
import { nextTick, ref, watch, type ComponentPublicInstance } from 'vue'
import type { UiIconName } from '~/utils/uiIcons'

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
}

const props = defineProps<{ rows: FileTreeRow[], label: string }>()
const emit = defineEmits<{ toggle: [key: string], select: [key: string] }>()

/* the one row in the tab order: the active row, else the first */
const focusKey = ref('')
watch(() => props.rows, (rows) => {
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
.ftree__chev { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; }
.ftree__icon { flex: none; color: var(--color-muted); }
.ftree__name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
:global([dir="rtl"]) .ftree__chev [data-icon="chevron-right"] { transform: scaleX(-1); }
@media (max-width: 820px) {
  .ftree__row { min-height: 44px; }
  .ftree__chev { width: 32px; height: 44px; }
}
</style>
