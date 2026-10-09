<!-- Spec 113 T006: the doc view, an outline numbered 1 / 1.1 / 1.1.1 over
     one workspace document. Lazy: the top level loads first and each
     expand loads that one node's children (the hub's lazy unit, spec 6),
     never the whole document. Every edit is one of the hub's ops (spec 3.3)
     with the doc rev it read; a 412 sets the session stale and the page shows
     its reload prompt. The item menu (the ... button or a right-click) adds a
     sibling / parent / child, moves (indent, outdent, up, down), prints or
     deletes the branch. -->
<template>
  <div class="wsdoc" data-test="ws-doc-view">
    <p v-if="state === 'loading'" class="wsdoc__note muted">{{ t('ws_doctree.loading') }}</p>
    <p v-else-if="state === 'failed'" class="wsdoc__note" role="alert">{{ t('ws_doctree.load_failed') }}</p>
    <template v-else>
      <div v-if="!rows.length" class="wsdoc__empty" data-test="ws-doc-empty">
        <p class="muted">{{ t('ws_doctree.empty_doc') }}</p>
        <button type="button" class="btn" data-test="ws-doc-add-first" :disabled="busy" @click="addFirst">
          <UiIcon name="plus" :size="16" /><span>{{ t('ws_doctree.add_first') }}</span>
        </button>
      </div>
      <ul v-else class="wsdoc__list" role="tree" :aria-label="t('ws_doctree.view_doc')">
        <li
          v-for="row in rows"
          :key="row.item.id"
          class="wsdoc__row"
          role="treeitem"
          :aria-level="row.depth"
          :aria-expanded="isLeaf(row.item.id) ? undefined : expanded.has(row.item.id) ? 'true' : 'false'"
          :style="{ '--wsdoc-depth': row.depth - 1 }"
          data-test="ws-doc-row"
          :data-id="row.item.id"
          :data-outline="row.item.outline"
          @contextmenu.prevent="openMenu(row.item, $event.clientX, $event.clientY)"
        >
          <button
            type="button"
            class="icon-btn wsdoc__toggle"
            data-test="ws-doc-toggle"
            :disabled="isLeaf(row.item.id)"
            :aria-label="expanded.has(row.item.id) ? t('ws_doctree.collapse') : t('ws_doctree.expand')"
            @click="toggle(row.item.id)"
          >
            <UiIcon v-if="!isLeaf(row.item.id)" :name="expanded.has(row.item.id) ? 'chevron-down' : 'chevron-right'" :size="16" />
            <span v-else class="wsdoc__dot" aria-hidden="true" />
          </button>
          <span class="wsdoc__num" data-test="ws-doc-num">{{ row.item.outline }}</span>
          <input
            v-if="editing === row.item.id"
            ref="editInput"
            v-model="draft"
            class="wsdoc__input"
            data-test="ws-doc-title-input"
            :aria-label="t('ws_doctree.edit_title')"
            @keydown.enter.prevent="commitTitle(row.item)"
            @keydown.esc.prevent="editing = ''"
            @blur="commitTitle(row.item)"
          >
          <button
            v-else
            type="button"
            class="wsdoc__title"
            data-test="ws-doc-title"
            :title="t('ws_doctree.edit_title')"
            @click="startEdit(row.item)"
          >{{ row.item.title || t('ws_doctree.untitled') }}</button>
          <button
            type="button"
            class="icon-btn wsdoc__more"
            data-test="ws-doc-menu-btn"
            :aria-label="t('ws_doctree.actions')"
            aria-haspopup="menu"
            @click="openMenuAt(row.item, $event)"
          >
            <UiIcon name="more" :size="16" />
          </button>
        </li>
      </ul>
    </template>
    <UiPointMenu
      :open="Boolean(menu)"
      :x="menu?.x ?? 0"
      :y="menu?.y ?? 0"
      :items="menuItems"
      :label="t('ws_doctree.actions')"
      block="wsdoc-menu"
      testid="ws-doc-menu"
      data-test="ws-doc-menu"
      wide
      @close="menu = null"
      @escape="menu = null"
      @choose="choose"
    />
    <UiConfirm
      :open="Boolean(doomed)"
      :title="t('ws_doctree.delete_title')"
      testid="ws-doc-delete"
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
import { computed, nextTick, onMounted, reactive, ref } from 'vue'
import UiPointMenu from '~/components/UiPointMenu.vue'
import UiConfirm from '~/components/UiConfirm.vue'
import {
  docMenuItems, editDocItem, removeDocItem, runDocOp, moveTarget,
  type DocItem, type DocMenuId, type DocSession, type DocShape,
} from './-doctree-api'

const props = defineProps<{ session: DocSession, root: string }>()
const emit = defineEmits<{ print: [item: DocItem] }>()
const { t } = useI18n({ useScope: 'global' })

const nodes = reactive(new Map<string, DocItem>())
/* parent id -> its loaded children, in order; a parent not in here is not loaded */
const kids = reactive(new Map<string, string[]>())
const expanded = reactive(new Set<string>())
const state = ref<'loading' | 'ready' | 'failed'>('loading')
const busy = ref(false)
const editing = ref('')
const draft = ref('')
const editInput = ref<HTMLInputElement[] | HTMLInputElement | null>(null)
const menu = ref<{ x: number, y: number, item: DocItem } | null>(null)
const doomed = ref<DocItem | null>(null)

/** the visible rows: the top level, and under each expanded node its children */
const rows = computed(() => {
  const out: { item: DocItem, depth: number }[] = []
  const walk = (parent: string, depth: number) => {
    for (const id of kids.get(parent) ?? []) {
      const item = nodes.get(id)
      if (!item) continue
      out.push({ item, depth })
      if (expanded.has(id)) walk(id, depth + 1)
    }
  }
  walk(props.root, 1)
  return out
})

const isLeaf = (id: string) => kids.has(id) && (kids.get(id)?.length ?? 0) === 0

/** one lazy unit: parent's children (false = it did not load) */
async function load(parent: string): Promise<boolean> {
  const s = props.session
  const r = await s.run(() => s.client.children(s.doc, parent === props.root ? '' : parent))
  if (!r) return false
  for (const it of r.items) nodes.set(it.id, it)
  kids.set(r.parent, r.items.map((it) => it.id))
  s.rev.value = r.rev
  return true
}

/** after a structural op: the top level and every still-open node, again */
async function reload() {
  const open = [props.root, ...rows.value.filter((r) => expanded.has(r.item.id)).map((r) => r.item.id)]
  kids.clear()
  for (const id of open) {
    if (id !== props.root && !nodes.has(id)) continue
    if (!(await load(id))) expanded.delete(id)
  }
  for (const id of [...expanded]) if (!kids.has(id)) expanded.delete(id)
}

async function toggle(id: string) {
  if (expanded.has(id)) {
    expanded.delete(id)
    return
  }
  expanded.add(id)
  if (!kids.has(id) && !(await load(id))) expanded.delete(id)
}

function shapeOf(it: DocItem): DocShape {
  const sib = kids.get(it.parent) ?? []
  const i = sib.indexOf(it.id)
  return { prev: i > 0 ? nodes.get(sib[i - 1] ?? '') : undefined, parent: nodes.get(it.parent), count: sib.length }
}

const menuItems = computed(() => {
  const it = menu.value?.item
  if (!it) return []
  const sh = shapeOf(it)
  const can = (k: 'indent' | 'outdent' | 'up' | 'down') => Boolean(moveTarget(k, it, sh.prev, sh.parent, sh.count))
  return docMenuItems({ indent: can('indent'), outdent: can('outdent'), up: can('up'), down: can('down') })
})

function openMenu(item: DocItem, x: number, y: number) {
  menu.value = { x, y, item }
}
function openMenuAt(item: DocItem, e: MouseEvent) {
  const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
  openMenu(item, r.left, r.bottom)
}

async function choose(id: string) {
  const it = menu.value?.item
  menu.value = null
  if (!it) return
  const op = id as DocMenuId
  if (op === 'print') return emit('print', it)
  if (op === 'delete') {
    doomed.value = it
    return
  }
  busy.value = true
  try {
    const r = await runDocOp(props.session, op, it, shapeOf(it), t('ws_doctree.untitled'))
    if (!r) return
    if (r.expand) expanded.add(r.expand)
    await reload()
    if (r.item) {
      const made = nodes.get(r.item)
      if (made) startEdit(made)
    }
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
    await reload()
    const made = nodes.get(r.item)
    if (made) startEdit(made)
  } finally {
    busy.value = false
  }
}

async function confirmDelete() {
  const it = doomed.value
  if (!it) return
  busy.value = true
  try {
    if (await removeDocItem(props.session, it)) {
      expanded.delete(it.id)
      await reload()
    }
  } finally {
    busy.value = false
    doomed.value = null
  }
}

function startEdit(it: DocItem) {
  editing.value = it.id
  draft.value = it.title
  void nextTick(() => {
    const el = Array.isArray(editInput.value) ? editInput.value[0] : editInput.value
    el?.focus()
    el?.select()
  })
}

async function commitTitle(it: DocItem) {
  if (editing.value !== it.id) return
  editing.value = ''
  await editDocItem(props.session, it, 'title', draft.value.trim())
}

onMounted(async () => {
  state.value = (await load(props.root)) ? 'ready' : 'failed'
})
</script>

<style scoped>
.wsdoc { padding: 8px 0; }
.wsdoc__note { padding: 12px 16px; }
.wsdoc__empty { display: grid; gap: 12px; justify-items: start; padding: 16px; }
.wsdoc__list { list-style: none; margin: 0; padding: 0; }
.wsdoc__row {
  display: flex;
  align-items: center;
  gap: 6px;
  min-height: var(--tap, 36px);
  padding-inline-start: calc(8px + var(--wsdoc-depth, 0) * 24px);
  padding-inline-end: 8px;
  border-bottom: 1px solid var(--color-border);
}
.wsdoc__row:hover { background: var(--color-selected); }
.wsdoc__toggle { flex: none; }
.wsdoc__toggle:disabled { cursor: default; opacity: 1; }
.wsdoc__dot { display: inline-block; width: 5px; height: 5px; border-radius: 50%; background: var(--color-muted); }
.wsdoc__num { flex: none; min-width: 3.5em; color: var(--color-muted); font-variant-numeric: tabular-nums; }
.wsdoc__title {
  flex: 1;
  min-width: 0;
  text-align: start;
  background: none;
  border: 0;
  padding: 4px 6px;
  color: var(--color-fg);
  font: inherit;
  cursor: text;
  overflow-wrap: anywhere;
  border-radius: var(--radius-sm);
}
.wsdoc__input {
  flex: 1;
  min-width: 0;
  font: inherit;
  padding: 3px 5px;
  border: 1px solid var(--color-accent);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
}
.wsdoc__more { flex: none; opacity: 0.6; }
.wsdoc__row:hover .wsdoc__more, .wsdoc__more:focus-visible { opacity: 1; }
</style>
