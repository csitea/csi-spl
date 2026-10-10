<!-- Spec 113 T006: the grid view, spreadsheet-like rows over the same items
     as the doc view (number, level, title, text, meta). The hub filters and sorts the
     whole document (its grid read, 413 above 20,000 items); a cell is edited
     in place as one text edit under the item's rev; the row menu runs the
     same structural ops as the doc view. A 412 sets the session stale.
     Level is the item's depth ("1.1" = 2, the hub's depth sort) and meta its
     own attrs as key: value lines, both read-only (t1 504fe47d); on a phone
     the meta column is hidden, level stays narrow. -->
<template>
  <div class="wsgrid" data-test="ws-grid-view">
    <div class="wsgrid__tools">
      <label class="wsgrid__filter">
        <span class="sr-only">{{ t('ws_doctree.filter') }}</span>
        <UiIcon name="search" :size="16" />
        <input
          v-model="filter"
          type="search"
          data-test="ws-grid-filter"
          :placeholder="t('ws_doctree.filter_placeholder')"
          :aria-label="t('ws_doctree.filter')"
        >
      </label>
      <span class="muted" data-test="ws-grid-total">{{ t('ws_doctree.grid_total', { n: rows.length }) }}</span>
    </div>
    <p v-if="state === 'loading'" class="wsgrid__note muted">{{ t('ws_doctree.loading') }}</p>
    <p v-else-if="state === 'failed'" class="wsgrid__note" role="alert">{{ t('ws_doctree.load_failed') }}</p>
    <div v-else class="wsgrid__scroll">
      <table class="wsgrid__table">
        <thead>
          <tr>
            <th v-for="c in COLS" :key="c" scope="col" :aria-sort="sort === c ? (desc ? 'descending' : 'ascending') : 'none'">
              <button type="button" class="wsgrid__sort" :data-test="'ws-grid-sort-' + c" :aria-label="t('ws_doctree.sort_by', { col: t('ws_doctree.col_' + c) })" @click="sortBy(c)">
                <span>{{ t('ws_doctree.col_' + c) }}</span>
                <UiIcon v-if="sort === c" :name="desc ? 'chevron-down' : 'chevron-up'" :size="14" />
              </button>
            </th>
            <th scope="col" class="wsgrid__metacol" data-test="ws-grid-col-meta"><span class="wsgrid__head">{{ t('ws_doctree.col_meta') }}</span></th>
            <th scope="col"><span class="sr-only">{{ t('ws_doctree.actions') }}</span></th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="it in rows"
            :key="it.id"
            data-test="ws-grid-row"
            :data-id="it.id"
            :data-outline="it.outline"
            @contextmenu.prevent="openMenu(it, $event.clientX, $event.clientY)"
          >
            <td class="wsgrid__num" data-test="ws-grid-num">{{ it.outline }}</td>
            <td class="wsgrid__num" data-test="ws-grid-level">{{ it.depth }}</td>
            <td v-for="f in FIELDS" :key="f" class="wsgrid__cell" :class="'wsgrid__cell--' + f">
              <textarea
                v-if="cell && cell.id === it.id && cell.field === f"
                ref="cellInput"
                v-model="draft"
                class="wsgrid__input"
                :rows="f === 'body' ? 3 : 1"
                :data-test="'ws-grid-input-' + f"
                :aria-label="t('ws_doctree.col_' + f)"
                @keydown.enter.exact.prevent="commit(it)"
                @keydown.esc.prevent="cell = null"
                @blur="commit(it)"
              />
              <button
                v-else
                type="button"
                class="wsgrid__text"
                :data-test="'ws-grid-' + f"
                :title="t('ws_doctree.edit_cell')"
                @click="startEdit(it, f)"
              >{{ it[f] || (f === 'title' ? t('ws_doctree.untitled') : '') }}</button>
            </td>
            <td class="wsgrid__metacol">
              <div class="wsgrid__meta" data-test="ws-grid-meta" :title="metaOf(it)">{{ metaOf(it) }}</div>
            </td>
            <td class="wsgrid__act">
              <button
                type="button"
                class="icon-btn"
                data-test="ws-grid-menu-btn"
                :aria-label="t('ws_doctree.actions')"
                aria-haspopup="menu"
                @click="openMenuAt(it, $event)"
              >
                <UiIcon name="more" :size="16" />
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-if="!rows.length && filter.trim()" class="wsgrid__note muted" data-test="ws-grid-none">{{ t('ws_doctree.grid_none') }}</p>
      <div v-else-if="!rows.length" class="wsgrid__note">
        <button type="button" class="btn" data-test="ws-grid-add-first" :disabled="busy" @click="addFirst">
          <UiIcon name="plus" :size="16" /><span>{{ t('ws_doctree.add_first') }}</span>
        </button>
      </div>
    </div>
    <UiPointMenu
      :open="Boolean(menu)"
      :x="menu?.x ?? 0"
      :y="menu?.y ?? 0"
      :items="menuItems"
      :label="t('ws_doctree.actions')"
      block="wsgrid-menu"
      testid="ws-grid-menu"
      data-test="ws-grid-menu"
      wide
      @close="menu = null"
      @escape="menu = null"
      @choose="choose"
    />
    <UiConfirm
      :open="Boolean(doomed)"
      :title="t('ws_doctree.delete_title')"
      testid="ws-grid-delete"
      :confirm-label="t('ws_doctree.delete_confirm')"
      :busy-label="t('ws_doctree.deleting')"
      :busy="busy"
      @update:open="(v: boolean) => { if (!v) doomed = null }"
      @confirm="confirmDelete"
    >
      <p>{{ t('ws_doctree.delete_body', { title: doomed?.title || t('ws_doctree.untitled') }) }}</p>
    </UiConfirm>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import UiPointMenu from '~/components/UiPointMenu.vue'
import UiConfirm from '~/components/UiConfirm.vue'
import {
  docMenuItems, editDocItem, removeDocItem, runDocOp, moveTarget,
  type DocItem, type DocMenuId, type DocSession, type DocShape,
} from './-doctree-api'

const COLS = ['outline', 'level', 'title', 'body'] as const
const FIELDS = ['title', 'body'] as const
type Col = typeof COLS[number]
type Field = typeof FIELDS[number]

const props = defineProps<{ session: DocSession, filter?: string }>()
const emit = defineEmits<{ print: [item: DocItem] }>()
const { t } = useI18n({ useScope: 'global' })

const rows = ref<DocItem[]>([])
/* the whole document in outline order: what a structural op is planned on
   (a filtered or sorted grid does not show every sibling) */
const whole = ref<DocItem[]>([])
const state = ref<'loading' | 'ready' | 'failed'>('loading')
/* Qto's "open as list": the doc view opens the grid on one branch's number */
const filter = ref(props.filter ?? '')
const sort = ref<Col>('outline')
const desc = ref(false)
const busy = ref(false)
const cell = ref<{ id: string, field: Field } | null>(null)
const draft = ref('')
const cellInput = ref<HTMLTextAreaElement[] | HTMLTextAreaElement | null>(null)
const menu = ref<{ x: number, y: number, item: DocItem, shape: DocShape } | null>(null)
const doomed = ref<DocItem | null>(null)
let seq = 0
let filterTimer: ReturnType<typeof setTimeout> | undefined

const plain = () => !filter.value.trim() && sort.value === 'outline' && !desc.value

async function load(): Promise<boolean> {
  const s = props.session
  const mine = ++seq
  const r = await s.run(() => s.client.grid(s.doc, filter.value, sort.value === 'level' ? 'depth' : sort.value, desc.value))
  if (mine !== seq) return true
  if (!r) return false
  rows.value = r.items
  if (plain()) whole.value = r.items
  s.rev.value = r.rev
  return true
}

/** the item's own attrs, one "key: value" line each; an empty value is left out */
function metaOf(it: DocItem): string {
  return Object.entries(it.attrs ?? {})
    .filter(([, v]) => v !== null && v !== undefined && v !== '')
    .map(([k, v]) => `${k}: ${(typeof v === 'string' ? v : JSON.stringify(v)).replace(/\s+/g, ' ').trim()}`)
    .join('\n')
}

async function shapeOf(it: DocItem): Promise<DocShape | null> {
  if (!plain()) {
    const s = props.session
    const r = await s.run(() => s.client.grid(s.doc, '', 'outline', false))
    if (!r) return null
    whole.value = r.items
    s.rev.value = r.rev
  }
  const sib = whole.value.filter((x) => x.parent === it.parent)
  const i = sib.findIndex((x) => x.id === it.id)
  return { prev: i > 0 ? sib[i - 1] : undefined, parent: whole.value.find((x) => x.id === it.parent), count: sib.length }
}

function sortBy(c: Col) {
  if (sort.value === c) desc.value = !desc.value
  else {
    sort.value = c
    desc.value = false
  }
  void load()
}

watch(filter, () => {
  clearTimeout(filterTimer)
  filterTimer = setTimeout(() => void load(), 250)
})

const menuItems = computed(() => {
  const m = menu.value
  if (!m) return []
  const can = (k: 'indent' | 'outdent' | 'up' | 'down') => Boolean(moveTarget(k, m.item, m.shape.prev, m.shape.parent, m.shape.count))
  return docMenuItems({ indent: can('indent'), outdent: can('outdent'), up: can('up'), down: can('down') })
})

async function openMenu(item: DocItem, x: number, y: number) {
  const shape = await shapeOf(item)
  if (shape) menu.value = { x, y, item, shape }
}
function openMenuAt(item: DocItem, e: MouseEvent) {
  const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
  void openMenu(item, r.left, r.bottom)
}

async function choose(id: string) {
  const m = menu.value
  menu.value = null
  if (!m) return
  const op = id as DocMenuId
  if (op === 'print') return emit('print', m.item)
  if (op === 'delete') {
    doomed.value = m.item
    return
  }
  busy.value = true
  try {
    const r = await runDocOp(props.session, op, m.item, m.shape, t('ws_doctree.untitled'))
    if (!r) return
    await load()
    const made = r.item ? rows.value.find((x) => x.id === r.item) : undefined
    if (made) startEdit(made, 'title')
  } finally {
    busy.value = false
  }
}

async function addFirst() {
  const s = props.session
  busy.value = true
  try {
    const r = await s.run(() => s.client.add(s.doc, s.rev.value, '', 'child', t('ws_doctree.untitled')))
    if (!r) return
    s.rev.value = r.rev
    await load()
    const made = rows.value.find((x) => x.id === r.item)
    if (made) startEdit(made, 'title')
  } finally {
    busy.value = false
  }
}

async function confirmDelete() {
  const it = doomed.value
  if (!it) return
  busy.value = true
  try {
    if (await removeDocItem(props.session, it)) await load()
  } finally {
    busy.value = false
    doomed.value = null
  }
}

function startEdit(it: DocItem, field: Field) {
  cell.value = { id: it.id, field }
  draft.value = it[field]
  void nextTick(() => {
    const el = Array.isArray(cellInput.value) ? cellInput.value[0] : cellInput.value
    el?.focus()
    el?.select()
  })
}

async function commit(it: DocItem) {
  const c = cell.value
  if (!c || c.id !== it.id) return
  cell.value = null
  await editDocItem(props.session, it, c.field, c.field === 'title' ? draft.value.trim() : draft.value)
}

onMounted(async () => {
  state.value = (await load()) ? 'ready' : 'failed'
})
onBeforeUnmount(() => clearTimeout(filterTimer))
</script>

<style scoped>
.wsgrid { display: grid; gap: 8px; padding: 8px 0; min-width: 0; }
.wsgrid__tools { display: flex; align-items: center; gap: 12px; padding: 0 12px; flex-wrap: wrap; }
.wsgrid__filter {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  flex: 1 1 14rem;
  max-width: 24rem;
}
.wsgrid__filter input { flex: 1; min-width: 0; border: 0; background: none; color: var(--color-fg); font: inherit; outline: none; }
.wsgrid__note { padding: 12px 16px; }
.wsgrid__scroll { overflow-x: auto; }
.wsgrid__table { width: 100%; border-collapse: collapse; table-layout: fixed; }
.wsgrid__table th, .wsgrid__table td { border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; padding: 2px 4px; }
.wsgrid__table th:nth-child(1) { width: 5.5rem; }
.wsgrid__table th:nth-child(2) { width: 4.5rem; }
.wsgrid__table th:nth-child(3) { width: 26%; }
.wsgrid__table th:nth-child(5) { width: 18%; }
.wsgrid__table th:nth-child(6) { width: 2.75rem; }
@media (max-width: 640px) {
  .wsgrid__metacol { display: none; }
  .wsgrid__table th:nth-child(1) { width: 4rem; }
  .wsgrid__table th:nth-child(2) { width: 3.25rem; }
}
.wsgrid__head { display: inline-block; padding: 6px 4px; font-weight: 600; }
.wsgrid__meta {
  padding: 6px 4px;
  color: var(--color-muted);
  font-size: 0.875rem;
  white-space: pre-line;
  overflow-wrap: anywhere;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 4;
  line-clamp: 4;
  overflow: hidden;
}
.wsgrid__sort { display: inline-flex; align-items: center; gap: 4px; background: none; border: 0; padding: 6px 4px; font: inherit; font-weight: 600; color: var(--color-fg); cursor: pointer; }
.wsgrid__num { color: var(--color-muted); font-variant-numeric: tabular-nums; padding-top: 8px !important; }
.wsgrid__text {
  display: block;
  width: 100%;
  min-height: 32px;
  text-align: start;
  background: none;
  border: 0;
  padding: 6px 4px;
  font: inherit;
  color: var(--color-fg);
  cursor: text;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  border-radius: var(--radius-sm);
}
.wsgrid__text:hover { background: var(--color-selected); }
.wsgrid__input {
  width: 100%;
  box-sizing: border-box;
  font: inherit;
  padding: 5px 3px;
  border: 1px solid var(--color-accent);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  resize: vertical;
}
.wsgrid__act { text-align: end; }
</style>
