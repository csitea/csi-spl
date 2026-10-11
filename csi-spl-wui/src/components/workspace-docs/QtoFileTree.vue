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
     (`drill`), any other opens (`open`); `title` names the node's path.
     Folders (spec 120, owner t1 3b8891e0: "add the + button similarly to
     how docs are created for the creation of folders - but only on the
     explorer like pane", msg e3b5a06a: "use the same type and shape of the
     button and place it respectively on the top"): the tree's top level is
     the hub's /nodes, folders first; a folder row expands (desktop) or
     drills (phone, `f:<node>`) into its own /nodes. The + at the top makes
     a folder in the current folder: the last folder picked on the desktop,
     the level shown on a phone. The page's + New document lands in that
     same folder (useQtoFolder). A hub without /nodes keeps the flat list. -->
<template>
  <nav class="qto-tree" data-test="qto-file-tree" :aria-label="t('ws_doctree.title')">
    <div v-if="!nodesOff" class="qto-tree__top">
      <button type="button" class="qto-tree__new" data-test="qto-new-folder" aria-haspopup="dialog" :aria-label="t('ws_doctree.new_folder')" :title="t('ws_doctree.new_folder')" @click="folderOpen = true">
        <UiIcon name="plus" :size="22" :stroke-width="2.5" />
      </button>
    </div>
    <WorkspaceDocNewDialog v-model:open="folderOpen" folder :create="makeFolder" />
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
import WorkspaceDocNewDialog from './WorkspaceDocNewDialog.vue'
import { useQtoFolder, type DocHead, type DocItem, type DocNode, type DocTreeClient } from './-doctree-api'

const props = defineProps<{ docs: DocHead[], active: string, rev: number, client: DocTreeClient, drill?: string | null }>()
const emit = defineEmits<{ open: [doc: string, item: string], renamed: [doc: string, title: string, rev: number], deleted: [doc: string], drill: [key: string], title: [path: string] }>()
const { t } = useI18n({ useScope: 'global' })

/* row keys: f:<node> for a folder, d:<doc> for a document, i:<doc>:<item> for a section */
const folderKey = (id: string) => 'f:' + id
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

function docRow(d: DocHead, depth = 0): FileTreeRow {
  const m = kids.value[d.id]
  return { key: docKey(d.id), depth, name: docName(d), icon: 'file-text', kind: 'doc', menu: true, expandable: !m || (m.get(d.root) || []).length > 0, open: opened.value.has(docKey(d.id)), active: d.id === props.active && !activeItem.value && !folderPicked.value }
}

/* the folders: each loaded folder's children ('' = the top level), and each
   folder's name and parent (the phone's path, the reveal) */
const nodesAt = ref<Record<string, DocNode[]>>({})
const folderOf = ref<Record<string, { name: string, parent: string }>>({})
/* the hub has no /nodes (an older hub, a mock without folders): the flat list */
const nodesOff = ref(false)
const folder = useQtoFolder()
/* the last row picked on the desktop was a folder: it is the marked row */
const folderPicked = ref(false)
const folderOpen = ref(false)

async function loadNodes(parent: string) {
  try {
    const r = await props.client.nodes(parent)
    const info = { ...folderOf.value }
    for (const n of r.nodes) if (n.kind === 'folder') info[n.id] = { name: n.name, parent }
    folderOf.value = info
    nodesAt.value = { ...nodesAt.value, [parent]: r.nodes }
    nodesOff.value = false
  } catch {
    if (!parent) nodesOff.value = true
  }
}

/** the folder a document's node sits in, '' = the top (or not loaded) */
function folderOfDoc(doc: string): string {
  for (const [parent, list] of Object.entries(nodesAt.value)) if (list.some((n) => n.doc === doc)) return parent
  return ''
}

/** a document node as the list's head (the list carries the live title), else as the node says */
function headOf(n: DocNode): DocHead {
  return props.docs.find((d) => d.id === n.doc) || { id: n.doc, title: n.title, description: n.description, rev: 0, items: 0, root: '', topic_id: '', updated_at: '' }
}

function folderRow(n: DocNode, depth: number): FileTreeRow {
  const key = folderKey(n.id)
  return { key, depth, name: n.name, icon: 'folder', kind: 'folder', expandable: n.child_count > 0, open: n.child_count > 0 && opened.value.has(key), active: folderPicked.value && folder.value === n.id }
}

/** the folder's path from the top: Plans / 2026 */
function folderPath(id: string): string {
  const names: string[] = []
  for (let f = folderOf.value[id]; f; f = folderOf.value[f.parent]) names.unshift(f.name)
  return names.join(' / ')
}

/** every folder up from a document's open, so it shows where it landed */
function reveal(doc: string) {
  const s = new Set(opened.value)
  for (let p = folderOfDoc(doc); p; p = folderOf.value[p]?.parent || '') s.add(folderKey(p))
  opened.value = s
}

/** the + at the top: a folder in the current one, then its listing read again */
async function makeFolder(name: string) {
  const parent = folder.value
  await props.client.createFolder(parent, name)
  await loadNodes(parent)
  const up = folderOf.value[parent]
  if (up) await loadNodes(up.parent)
  if (parent) setOpen(folderKey(parent), true)
}

/* the list changed (a create, a rename, a delete): the loaded folders read again */
watch(() => props.docs.map((d) => d.id + d.title).join('|'), async () => {
  await Promise.all([...new Set(['', ...Object.keys(nodesAt.value)])].map(loadNodes))
  if (props.active) reveal(props.active)
}, { immediate: true })

const drilling = computed(() => typeof props.drill === 'string')

/** the phone's node on screen: its document and the parent its rows hang from */
const drillNode = computed(() => {
  const [kind, doc, item] = (props.drill || '').split(':')
  const d = props.docs.find((x) => x.id === doc)
  if (!d) return null
  return { doc: d, parent: kind === 'i' ? item : d.root }
})

/** one level of folders and documents, as phone rows */
function levelRows(parent: string): FileTreeRow[] {
  return (nodesAt.value[parent] || []).map((n) => ({ ...(n.kind === 'folder' ? folderRow(n, 0) : docRow(headOf(n))), expandable: n.kind === 'folder' || docRow(headOf(n)).expandable, open: false, active: false }))
}

/** the phone's drill-down: the rows of one node, one level */
const drillRows = computed<FileTreeRow[]>(() => {
  if (!props.drill && nodesOff.value) return props.docs.map((d) => ({ ...docRow(d), open: false, active: false }))
  if (!props.drill || props.drill.startsWith('f:')) return levelRows(props.drill ? props.drill.slice(2) : '')
  const n = drillNode.value
  const m = n && kids.value[n.doc.id]
  if (!n || !m) return []
  return (m.get(n.parent) || []).map((it) => ({ ...sectionRow(n.doc.id, it, m, 0), open: false, active: false }))
})

/** the node's path, document first: Handbook / Introduction / Scope */
const drillTitle = computed(() => {
  if (props.drill?.startsWith('f:')) return folderPath(props.drill.slice(2))
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
  if (typeof key !== 'string') return
  if (key.startsWith('f:')) {
    folder.value = key.slice(2)
    if (!nodesAt.value[folder.value]) void loadNodes(folder.value)
    return
  }
  const doc = key.split(':')[1]
  folder.value = doc ? folderOfDoc(doc) : ''
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
  const pushDoc = (d: DocHead, depth: number) => {
    const row = docRow(d, depth)
    out.push(row)
    const m = kids.value[d.id]
    if (row.open && m) walk(d.id, m, d.root, depth + 1)
  }
  const level = (parent: string, depth: number) => {
    for (const n of nodesAt.value[parent] || []) {
      if (n.kind === 'doc') {
        pushDoc(headOf(n), depth)
        continue
      }
      const row = folderRow(n, depth)
      out.push(row)
      if (row.open) level(n.id, depth + 1)
    }
  }
  if (nodesOff.value || !nodesAt.value['']) for (const d of props.docs) pushDoc(d, 0)
  else level('', 0)
  return out
})

/** a phone row: one with rows under it drills, any other opens */
async function drillSelect(key: string) {
  if (key.startsWith('f:')) return void emit('drill', key)
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
  if (on && key.startsWith('f:') && !nodesAt.value[key.slice(2)]) void loadNodes(key.slice(2))
}

/** a folder row: it becomes the current folder (the + buttons create in it) and opens */
function pickFolder(key: string) {
  folder.value = key.slice(2)
  folderPicked.value = true
  if (!opened.value.has(key)) toggle(key)
  else if (!nodesAt.value[folder.value]) void loadNodes(folder.value)
}

function select(key: string) {
  if (drilling.value) return void drillSelect(key)
  if (key.startsWith('f:')) return pickFolder(key)
  folderPicked.value = false
  if (key.startsWith('d:')) {
    const doc = key.slice(2)
    folder.value = folderOfDoc(doc)
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
  if (doc !== was) folderPicked.value = false
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
/* the + New folder: the page's + New document (WorkspaceDocsPage .wsdocs-fab,
   the issues page's +), same size and look, at the top of the explorer */
.qto-tree__top { display: flex; justify-content: flex-end; padding: 0 8px 6px; }
.qto-tree__new {
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
.qto-tree__new:hover {
  background: var(--color-accent-pressed);
  box-shadow: 0 3px 6px rgba(0, 0, 0, 0.3), 0 2px 4px rgba(0, 0, 0, 0.22);
}
.qto-tree__new:active { transform: scale(0.96); }
@media (prefers-reduced-motion: reduce) {
  .qto-tree__new { transition: none; }
  .qto-tree__new:active { transform: none; }
}
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
