<!-- Owner HUM-10 (t1 efde25bb): the Docs (Qto) left panel is a VS Code-like
     file tree of the workspace documents, not the channel list. Each
     document is a top row; opened, it shows its sections (the spec 113
     nested-set tree, read with one subtree call per document) as nested
     rows, a section with sections under it expanding and collapsing. The
     open document is highlighted and opens expanded; a click (or Enter)
     on a document opens it, on a section opens its document at that
     section. The rows are drawn by the shared UiFileTree. No visible
     heading above the tree (msg 8471b818: "Remove the documents label,
     not needed."); its name stays on the aria-labels.
     Each document row has a menu (msgs 635c2125, 500ca8f5: "a right-click
     menu on each of the documents ... Delete, Edit, figure out something
     else"): right-click, a long press on a phone, or Shift+F10 / the
     context-menu key. Edit opens it; Rename is the hub's PATCH
     /v1/workspace/doctree/{doc}; Copy link and Open in a new tab use the
     page's own URL. Delete confirms first, then the hub's DELETE
     /v1/workspace/doctree/{doc} under a fresh head rev.
     On a phone (owner t1 8bf89f96, msgs dfe000c1, c09ae88e, d8a12bb3: "drill
     down" as from Channels to a channel to a topic) the page passes `drill`,
     the node on screen ('' = the top level): the rows are that node's
     children only. A row with rows under it drills one level deeper
     (`drill`), any other opens (`open`); `title` names the node's path. -->
<template>
  <nav class="qto-tree" data-test="qto-file-tree" :aria-label="t('ws_doctree.title')">
    <UiFileTree :rows="rows" :label="t('ws_doctree.title')" @toggle="toggle" @select="select" @menu="openMenu" />
    <UiPointMenu
      :open="Boolean(menu)"
      :x="menu?.x ?? 0"
      :y="menu?.y ?? 0"
      :items="MENU"
      :label="t('ws_doctree.doc_menu.label')"
      block="qto-doc-menu"
      testid="qto-doc-menu"
      @choose="choose"
      @close="menu = null"
    />
    <UiDialog :open="Boolean(renaming)" :title="t('ws_doctree.edit_doc_title')" size="sm" @update:open="(v) => { if (!v) renaming = null }">
      <form class="qto-rename" data-test="qto-rename-form" @submit.prevent="rename">
        <input
          v-model="renameTo"
          type="text"
          maxlength="500"
          data-autofocus
          data-test="qto-rename-title"
          :aria-label="t('ws_doctree.col_title')"
          :placeholder="t('ws_doctree.default_doc_title')"
          :disabled="busy"
        >
        <p v-if="renameError" class="qto-rename__error" role="alert" data-test="qto-rename-error">{{ t(renameError) }}</p>
        <div class="qto-rename__actions">
          <button type="button" class="btn ghost" :disabled="busy" @click="renaming = null">{{ t('common.cancel') }}</button>
          <button type="submit" class="btn" data-test="qto-rename-save" :disabled="busy">{{ t('ws_doctree.doc_menu.rename') }}</button>
        </div>
      </form>
    </UiDialog>
    <UiConfirm
      :open="Boolean(deleting)"
      :title="t('ws_doctree.doc_menu.delete_title')"
      testid="qto-delete"
      :confirm-label="t('ws_doctree.delete_confirm')"
      :busy-label="t('ws_doctree.deleting')"
      :busy="busy"
      :error="deleteError ? t(deleteError) : ''"
      @update:open="(v) => { if (!v) deleting = null }"
      @confirm="removeDoc"
    >
      <p>{{ t('ws_doctree.doc_menu.delete_body', { title: deletingTitle }) }}</p>
    </UiConfirm>
    <p class="qto-tree__status" role="status" data-test="qto-tree-status">{{ status }}</p>
  </nav>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import UiFileTree, { type FileTreeRow } from '~/components/UiFileTree.vue'
import UiPointMenu, { type PointMenuItem } from '~/components/UiPointMenu.vue'
import UiDialog from '~/components/UiDialog.vue'
import UiConfirm from '~/components/UiConfirm.vue'
import { writeClipboard } from '~/utils/clipboard.mjs'
import type { DocHead, DocItem, DocTreeClient } from './-doctree-api'

const props = defineProps<{ docs: DocHead[], active: string, rev: number, client: DocTreeClient, drill?: string | null }>()
const emit = defineEmits<{ open: [doc: string, item: string], renamed: [doc: string, title: string, rev: number], deleted: [doc: string], drill: [key: string], title: [path: string] }>()
const { t } = useI18n({ useScope: 'global' })

/* row keys: d:<doc> for a document, i:<doc>:<item> for a section */
const docKey = (doc: string) => 'd:' + doc
const itemKey = (doc: string, item: string) => `i:${doc}:${item}`

const opened = ref<Set<string>>(new Set())
/* each loaded document's items grouped by parent, in outline order */
const kids = ref<Record<string, Map<string, DocItem[]>>>({})
const activeItem = ref('')

async function load(doc: string) {
  try {
    const r = await props.client.subtree(doc)
    const m = new Map<string, DocItem[]>()
    for (const it of r.items) {
      if (!it.parent) continue
      const list = m.get(it.parent) || []
      list.push(it)
      m.set(it.parent, list)
    }
    for (const list of m.values()) list.sort((a, b) => a.ord - b.ord)
    kids.value = { ...kids.value, [doc]: m }
  } catch { /* the document row stays, without sections */ }
}

function setOpen(key: string, on: boolean) {
  const s = new Set(opened.value)
  if (on) s.add(key)
  else s.delete(key)
  opened.value = s
}

/* an empty title reads as the document view's placeholder (Heading 1.1) */
const itemName = (it: DocItem) => it.title.trim() || t('ws_doctree.heading_placeholder', { n: it.outline })
const docName = (d: DocHead) => d.title || t('ws_doctree.default_doc_title')

function sectionRow(doc: string, it: DocItem, m: Map<string, DocItem[]>, depth: number): FileTreeRow {
  const key = itemKey(doc, it.id)
  const sub = (m.get(it.id) || []).length > 0
  const name = itemName(it)
  return { key, depth, name, title: it.title.trim() ? `${it.outline} ${name}` : name, icon: sub ? 'folder' : 'list', kind: 'section', expandable: sub, open: sub && opened.value.has(key), active: doc === props.active && it.id === activeItem.value }
}

function docRow(d: DocHead): FileTreeRow {
  const m = kids.value[d.id]
  return { key: docKey(d.id), depth: 0, name: docName(d), icon: 'file-text', kind: 'doc', menu: true, expandable: !m || (m.get(d.root) || []).length > 0, open: opened.value.has(docKey(d.id)), active: d.id === props.active && !activeItem.value }
}

const drilling = computed(() => typeof props.drill === 'string')

/** the phone's node on screen: its document and the parent its rows hang from */
const drillNode = computed(() => {
  const [kind, doc, item] = (props.drill || '').split(':')
  const d = props.docs.find((x) => x.id === doc)
  if (!d) return null
  return { doc: d, parent: kind === 'i' ? item : d.root }
})

/** the phone's drill-down: the rows of one node, one level */
const drillRows = computed<FileTreeRow[]>(() => {
  if (!props.drill) return props.docs.map((d) => ({ ...docRow(d), open: false, active: false }))
  const n = drillNode.value
  const m = n && kids.value[n.doc.id]
  if (!n || !m) return []
  return (m.get(n.parent) || []).map((it) => ({ ...sectionRow(n.doc.id, it, m, 0), open: false, active: false }))
})

/** the node's path, document first: Handbook / Introduction / Scope */
const drillTitle = computed(() => {
  const n = drillNode.value
  if (!n) return ''
  const names: string[] = []
  const byId = new Map<string, DocItem>()
  for (const list of kids.value[n.doc.id]?.values() || []) for (const it of list) byId.set(it.id, it)
  for (let it = byId.get(n.parent); it; it = byId.get(it.parent)) names.unshift(itemName(it))
  return [docName(n.doc), ...names].join(' / ')
})
watch(drillTitle, (v) => emit('title', v), { immediate: true })
watch(() => props.drill, (key) => {
  const doc = (key || '').split(':')[1]
  if (doc && !kids.value[doc]) void load(doc)
}, { immediate: true })

const rows = computed<FileTreeRow[]>(() => {
  if (drilling.value) return drillRows.value
  const out: FileTreeRow[] = []
  const walk = (doc: string, m: Map<string, DocItem[]>, parent: string, depth: number) => {
    for (const it of m.get(parent) || []) {
      const row = sectionRow(doc, it, m, depth)
      out.push(row)
      if (row.open) walk(doc, m, it.id, depth + 1)
    }
  }
  for (const d of props.docs) {
    const row = docRow(d)
    out.push(row)
    const m = kids.value[d.id]
    if (row.open && m) walk(d.id, m, d.root, 1)
  }
  return out
})

/** a phone row: one with rows under it drills, any other opens */
async function drillSelect(key: string) {
  const [kind, doc, item] = key.split(':')
  if (!kids.value[doc]) await load(doc)
  const m = kids.value[doc]
  const parent = kind === 'i' ? item : props.docs.find((d) => d.id === doc)?.root
  if (m && parent && (m.get(parent) || []).length) emit('drill', key)
  else emit('open', doc, kind === 'i' ? item : '')
}

function toggle(key: string) {
  if (drilling.value) return void drillSelect(key)
  const on = !opened.value.has(key)
  setOpen(key, on)
  if (on && key.startsWith('d:') && !kids.value[key.slice(2)]) void load(key.slice(2))
}

function select(key: string) {
  if (drilling.value) return void drillSelect(key)
  if (key.startsWith('d:')) {
    const doc = key.slice(2)
    activeItem.value = ''
    if (!opened.value.has(key)) toggle(key)
    emit('open', doc, '')
    return
  }
  const [, doc, item] = key.split(':')
  activeItem.value = item
  if (opened.value.has(key) === false && rows.value.find((r) => r.key === key)?.expandable) setOpen(key, true)
  emit('open', doc, item)
}

/* a document row's menu (UiPointMenu, the WUI's one menu at a point) */
const MENU: PointMenuItem[] = [
  { id: 'edit', icon: 'edit', labelKey: 'ws_doctree.doc_menu.edit' },
  { id: 'rename', icon: 'pencil', labelKey: 'ws_doctree.doc_menu.rename' },
  { id: 'copy_link', icon: 'copy', labelKey: 'ws_doctree.doc_menu.copy_link' },
  { id: 'new_tab', icon: 'open', labelKey: 'ws_doctree.doc_menu.new_tab' },
  { id: 'delete', icon: 'delete', labelKey: 'ws_doctree.doc_menu.delete', danger: true },
]
const menu = ref<{ doc: string, x: number, y: number } | null>(null)
const status = ref('')
let statusTimer: ReturnType<typeof setTimeout> | undefined
const router = useRouter()

function openMenu(key: string, x: number, y: number) {
  if (key.startsWith('d:')) menu.value = { doc: key.slice(2), x, y }
}

/** the document's own address: the page that opens it */
function docHref(doc: string): string {
  return new URL(router.resolve({ path: '/workspace/docs', query: { doc, view: 'doc' } }).href, location.origin).href
}

async function choose(id: string) {
  const doc = menu.value?.doc
  if (!doc) return
  if (id === 'edit' && drilling.value) emit('open', doc, '')
  else if (id === 'edit') select(docKey(doc))
  else if (id === 'rename') {
    renameTo.value = props.docs.find((d) => d.id === doc)?.title || ''
    renameError.value = ''
    renaming.value = doc
  } else if (id === 'copy_link') {
    status.value = ''
    status.value = t(await writeClipboard(docHref(doc)) ? 'ws_doctree.doc_menu.link_copied' : 'common.copy_failed')
    clearTimeout(statusTimer)
    statusTimer = setTimeout(() => { status.value = '' }, 3000)
  } else if (id === 'new_tab') window.open(docHref(doc), '_blank', 'noopener')
  else if (id === 'delete') {
    deleteError.value = ''
    deleting.value = doc
  }
}

/* Delete: confirmed, then the hub's DELETE under the doc rev read just now */
const deleting = ref<string | null>(null)
const deleteError = ref('')
const deletingTitle = computed(() => props.docs.find((d) => d.id === deleting.value)?.title || t('ws_doctree.default_doc_title'))
async function removeDoc() {
  const doc = deleting.value
  if (!doc || busy.value) return
  busy.value = true
  deleteError.value = ''
  try {
    const h = await props.client.head(doc)
    await props.client.removeDoc(doc, h.rev)
    deleting.value = null
    emit('deleted', doc)
  } catch {
    deleteError.value = 'ws_doctree.err_failed'
  } finally {
    busy.value = false
  }
}

/* Rename: the hub's PATCH under the doc rev read just now; cleared, the hub gives the default title */
const renaming = ref<string | null>(null)
const renameTo = ref('')
const renameError = ref('')
const busy = ref(false)
async function rename() {
  const doc = renaming.value
  if (!doc || busy.value) return
  busy.value = true
  renameError.value = ''
  try {
    const h = await props.client.head(doc)
    const r = await props.client.rename(doc, h.rev, renameTo.value.replace(/\s+/g, ' ').trim())
    emit('renamed', doc, r.title, r.rev)
    renaming.value = null
  } catch {
    renameError.value = 'ws_doctree.err_failed'
  } finally {
    busy.value = false
  }
}

/* the open document opens expanded; another document clears the section mark */
watch(() => props.active, (doc, was) => {
  if (doc !== was && was) activeItem.value = ''
  if (!doc) return
  if (!opened.value.has(docKey(doc))) setOpen(docKey(doc), true)
  if (!kids.value[doc]) void load(doc)
}, { immediate: true })

/* an edit in the open document (its rev moved on): read its sections again, once the edits settle */
let timer: ReturnType<typeof setTimeout> | undefined
watch(() => props.rev, () => {
  clearTimeout(timer)
  if (props.active) timer = setTimeout(() => { void load(props.active) }, 400)
})
onBeforeUnmount(() => {
  clearTimeout(timer)
  clearTimeout(statusTimer)
})
</script>

<style scoped>
.qto-tree { padding: 8px 4px; text-align: start; }
.qto-tree__status { margin: 4px 8px 0; font-size: 0.75rem; color: var(--color-muted); }
.qto-tree__status:empty { display: none; }
.qto-rename { display: grid; gap: 12px; }
.qto-rename input {
  font: inherit;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
}
.qto-rename__error { margin: 0; color: var(--color-danger); }
.qto-rename__actions { display: flex; justify-content: flex-end; gap: 8px; }
</style>
