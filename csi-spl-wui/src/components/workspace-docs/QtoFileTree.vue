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
     Folders (spec 120, owner t1 3b8891e0): the tree's top level is the
     hub's /nodes, folders first; a folder row expands (desktop) or drills
     (phone, `f:<node>`) into its own /nodes. The page's + New document lands
     in the current folder (useQtoFolder): the last folder picked on the
     desktop, the level shown on a phone. A hub without /nodes keeps the
     flat list.
     The root (owner t1 f6bec016, msg 9663760c: "remove the + button on the
     file explorer on the left side of the qto view, also add the root dir -
     which / , the creation of the files and dirs should happen only via the
     right click"; msg b06f13ad: "but keep the + button of the creae new
     document"): no + at the top of the tree; one `/` row at depth 0 holds
     the top level, open by default, expanding and collapsing like a folder,
     and on a phone it tops the first drill level the same way. Its menu
     has New document and New folder, landing at the top level (no Rename,
     no Delete), so every creation in the explorer goes through a row's
     menu, and an empty workspace still makes its first one from `/`. The
     page's + New document stays.
     A folder row and a section row have a menu too (owner t1 ed2e3583, msg
     407fc16f: a right-click in the Qto file system opens a matching menu
     for the directories as well), the same
     UiPointMenu, keys and long press. A folder's: New document and New
     folder in it, Rename (PATCH /folders/{folder}), Copy path, Delete
     (confirmed; a folder that holds anything shows its counts and goes
     with them, DELETE /folders/{folder}?recursive=1). A section's: Open,
     Copy link, Open in a new tab.
     Spec 137 T023 (§4.1, owner t1 bed3ed0a msg 0e9d17b5: "one spool-hub
     file system"): on the desktop, under the workspace's documents, one
     Repository row holds the repository's docs (the /docs tree.json) as
     folders and files in the same tree, the same keys; a file opens in the
     explorer's right pane (`repo`, WorkspaceRepoDoc), a workspace row opens
     the Qto document again. The layout passes `repo` (the open repo doc's
     path, '' = none); without it (the phone's drill list) there is no such
     row. -->
<template>
  <nav class="qto-tree" data-test="qto-file-tree" :aria-label="t('ws_doctree.title')">
    <WorkspaceDocNewDialog v-model:open="folderOpen" folder :create="makeFolder" />
    <UiFileTree :rows="rows" :label="t('ws_doctree.title')" @toggle="toggle" @select="select" @menu="openMenu" />
    <UiPointMenu
      :open="Boolean(menu)"
      :x="menu?.x ?? 0"
      :y="menu?.y ?? 0"
      :items="menuItems"
      :label="t(`ws_doctree.${menu?.kind === 'root' ? 'folder' : menu?.kind ?? 'doc'}_menu.label`)"
      :block="`qto-${menu?.kind ?? 'doc'}-menu`"
      :testid="`qto-${menu?.kind ?? 'doc'}-menu`"
      @choose="choose"
      @close="menu = null"
    />
    <UiDialog :open="Boolean(renaming)" :title="t(renaming?.startsWith('f:') ? 'ws_doctree.folder_menu.rename_title' : 'ws_doctree.edit_doc_title')" size="sm" @update:open="(v) => { if (!v) renaming = null }">
      <form class="qto-rename" data-test="qto-rename-form" @submit.prevent="rename">
        <input
          v-model="renameTo"
          type="text"
          maxlength="500"
          data-autofocus
          data-test="qto-rename-title"
          :aria-label="t(renaming?.startsWith('f:') ? 'ws_doctree.folder_name' : 'ws_doctree.col_title')"
          :placeholder="renaming?.startsWith('f:') ? '' : t('ws_doctree.default_doc_title')"
          :disabled="busy"
        >
        <p v-if="renameError" class="qto-rename__error" role="alert" data-test="qto-rename-error">{{ t(renameError) }}</p>
        <div class="qto-rename__actions">
          <button type="button" class="btn ghost" :disabled="busy" @click="renaming = null">{{ t('common.cancel') }}</button>
          <button type="submit" class="btn" data-test="qto-rename-save" :disabled="busy || (renaming?.startsWith('f:') && !renameTo.trim())">{{ t('ws_doctree.doc_menu.rename') }}</button>
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
    <UiConfirm
      :open="Boolean(dropping)"
      :title="t('ws_doctree.folder_menu.delete_title')"
      testid="qto-folder-delete"
      :confirm-label="t('ws_doctree.delete_confirm')"
      :busy-label="t('ws_doctree.deleting')"
      :busy="busy"
      :error="deleteError ? t(deleteError) : ''"
      @update:open="(v) => { if (!v) dropping = null }"
      @confirm="removeFolder"
    >
      <p>{{ t('ws_doctree.folder_menu.delete_body', { name: dropping?.name ?? '' }) }}</p>
      <p v-if="dropping?.held" data-test="qto-folder-delete-held">{{ t('ws_doctree.folder_menu.delete_held', { folders: dropping.held.folders, documents: dropping.held.documents }) }}</p>
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
import { DocTreeError, useQtoFolder, type DocHead, type DocItem, type DocNode, type DocTreeClient } from './-doctree-api'
import { useRepoDocs } from './-repo-docs'
import { buildDocsTree, docsAncestors, visibleDocsRows, type DocsDir } from '~/utils/docs.mjs'

const props = defineProps<{ docs: DocHead[], active: string, rev: number, client: DocTreeClient, drill?: string | null, repo?: string }>()
const emit = defineEmits<{ open: [doc: string, item: string], renamed: [doc: string, title: string, rev: number], deleted: [doc: string], drill: [key: string], title: [path: string], newDoc: [], refresh: [], repo: [path: string] }>()
const { t } = useI18n({ useScope: 'global' })

/* row keys: / the root, f:<node> for a folder, d:<doc> for a document, i:<doc>:<item> for a section;
   the Repository branch (T023): r: itself, rd:<path> a repo folder, rf:<path> a repo doc */
const ROOT = '/'
const folderKey = (id: string) => 'f:' + id
const docKey = (doc: string) => 'd:' + doc
const itemKey = (doc: string, item: string) => `i:${doc}:${item}`

/* the root starts open */
const opened = ref<Set<string>>(new Set([ROOT]))
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
  return { key, depth, name, title: it.title.trim() ? `${it.outline} ${name}` : name, icon: sub ? 'plus' : 'list', kind: 'section', menu: true, expandable: sub, open: sub && opened.value.has(key), active: doc === props.active && it.id === activeItem.value }
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
  return { key, depth, name: n.name, icon: 'folder', kind: 'folder', menu: true, expandable: n.child_count > 0, open: n.child_count > 0 && opened.value.has(key), active: folderPicked.value && folder.value === n.id }
}

/** the `/` row: the top level's folder, open unless closed */
function rootRow(): FileTreeRow {
  return { key: ROOT, depth: 0, name: '/', icon: 'folder', kind: 'root', menu: true, expandable: true, open: opened.value.has(ROOT), active: folderPicked.value && !folder.value }
}

/** the folder's path from the top: Plans / 2026 */
function folderPath(id: string): string {
  const names: string[] = []
  for (let f = folderOf.value[id]; f; f = folderOf.value[f.parent]) names.unshift(f.name)
  return names.join(' / ')
}

/** every folder up from a document's open, so it shows where it landed */
function reveal(doc: string) {
  const s = new Set(opened.value).add(ROOT)
  for (let p = folderOfDoc(doc); p; p = folderOf.value[p]?.parent || '') s.add(folderKey(p))
  opened.value = s
}

/** New folder (a folder's or the root's menu): a folder in the current one, then its listing read again */
async function makeFolder(name: string) {
  const parent = folder.value
  await props.client.createFolder(parent, name)
  await loadNodes(parent)
  const up = folderOf.value[parent]
  if (up) await loadNodes(up.parent)
  setOpen(parent ? folderKey(parent) : ROOT, true)
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
function levelRows(parent: string, depth = 0): FileTreeRow[] {
  return (nodesAt.value[parent] || []).map((n) => ({ ...(n.kind === 'folder' ? folderRow(n, depth) : docRow(headOf(n), depth)), expandable: n.kind === 'folder' || docRow(headOf(n)).expandable, open: false, active: false }))
}

/** the phone's first level: the `/` row, the top level under it while it is open */
function topRows(): FileTreeRow[] {
  const root = { ...rootRow(), active: false }
  if (!root.open) return [root]
  if (nodesOff.value) return [root, ...props.docs.map((d) => ({ ...docRow(d, 1), open: false, active: false }))]
  return [root, ...levelRows('', 1)]
}

/** the phone's drill-down: the rows of one node, one level */
const drillRows = computed<FileTreeRow[]>(() => {
  if (!props.drill) return topRows()
  if (props.drill.startsWith('f:')) return levelRows(props.drill.slice(2))
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

/* the Repository branch (T023): tree.json read once, the first time it opens */
const REPO = 'r:'
const repoDocs = typeof props.repo === 'string' ? useRepoDocs() : null
const repoTree = ref<DocsDir | null>(null)
const repoOpen = ref<Set<string>>(new Set())
let repoLoad: Promise<void> | null = null

function loadRepo() {
  if (!repoDocs || repoLoad) return repoLoad
  repoLoad = (async () => {
    try {
      const files = await repoDocs.files()
      if (files === 'off') throw new Error('docs off')
      repoTree.value = buildDocsTree(files)
    } catch {
      repoLoad = null
      status.value = t('ws_doctree.repo_failed')
    }
  })()
  return repoLoad
}

function toggleRepo(key: string) {
  if (key === REPO) {
    const on = !opened.value.has(REPO)
    setOpen(REPO, on)
    if (on) void loadRepo()
    return
  }
  const s = new Set(repoOpen.value)
  const path = key.slice(3)
  if (s.has(path)) s.delete(path)
  else s.add(path)
  repoOpen.value = s
}

/* the open repo doc (a fresh load of ?repo= too): its branch opens down to it */
watch(() => props.repo, (path) => {
  if (!path) return
  setOpen(REPO, true)
  repoOpen.value = new Set([...repoOpen.value, ...docsAncestors(path)])
  void loadRepo()
}, { immediate: true })

function repoRows(): FileTreeRow[] {
  const open = opened.value.has(REPO)
  const out: FileTreeRow[] = [{ key: REPO, depth: 0, name: t('ws_doctree.repo_root'), icon: 'book-open', kind: 'repo', expandable: true, open }]
  if (!open || !repoTree.value) return out
  for (const r of visibleDocsRows(repoTree.value, repoOpen.value)) {
    out.push(r.kind === 'dir'
      ? { key: 'rd:' + r.path, depth: r.depth + 1, name: r.name, icon: 'folder', kind: 'repo-dir', expandable: true, open: r.open }
      : { key: 'rf:' + r.path, depth: r.depth + 1, name: r.name, title: r.title, icon: 'file-text', kind: 'repo-doc', expandable: false, active: r.path === props.repo })
  }
  return out
}

const rows = computed<FileTreeRow[]>(() => {
  if (drilling.value) return drillRows.value
  const tail = repoDocs ? repoRows() : []
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
  out.push(rootRow())
  if (!out[0].open) return [...out, ...tail]
  if (nodesOff.value || !nodesAt.value['']) for (const d of props.docs) pushDoc(d, 1)
  else level('', 1)
  return [...out, ...tail]
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
  if (key === ROOT) return setOpen(ROOT, !opened.value.has(ROOT))
  if (drilling.value) return void drillSelect(key)
  if (key === REPO || key.startsWith('rd:')) return toggleRepo(key)
  const on = !opened.value.has(key)
  setOpen(key, on)
  if (on && key.startsWith('d:') && !kids.value[key.slice(2)]) void load(key.slice(2))
  if (on && key.startsWith('f:') && !nodesAt.value[key.slice(2)]) void loadNodes(key.slice(2))
}

/** a folder row: it becomes the current folder (+ New document creates in it) and opens */
function pickFolder(key: string) {
  folder.value = key.slice(2)
  folderPicked.value = true
  if (!opened.value.has(key)) toggle(key)
  else if (!nodesAt.value[folder.value]) void loadNodes(folder.value)
}

/** the `/` row: the top level becomes the current folder, and it opens */
function pickRoot() {
  folder.value = ''
  folderPicked.value = true
  setOpen(ROOT, true)
}

function select(key: string) {
  if (key === ROOT) return drilling.value ? toggle(ROOT) : pickRoot()
  if (drilling.value) return void drillSelect(key)
  if (key === REPO || key.startsWith('rd:')) return toggleRepo(key)
  if (key.startsWith('rf:')) {
    folderPicked.value = false
    activeItem.value = ''
    return void emit('repo', key.slice(3))
  }
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

/* each row kind's menu (UiPointMenu, the WUI's one menu at a point) */
type MenuKind = 'doc' | 'folder' | 'section' | 'root'
const NEW_DOC: PointMenuItem = { id: 'new_doc', icon: 'plus', labelKey: 'ws_doctree.folder_menu.new_doc' }
const NEW_FOLDER: PointMenuItem = { id: 'new_folder', icon: 'folder', labelKey: 'ws_doctree.folder_menu.new_folder' }
const MENUS: Record<MenuKind, PointMenuItem[]> = {
  doc: [
    { id: 'edit', icon: 'edit', labelKey: 'ws_doctree.doc_menu.edit' },
    { id: 'rename', icon: 'pencil', labelKey: 'ws_doctree.doc_menu.rename' },
    { id: 'copy_link', icon: 'copy', labelKey: 'ws_doctree.doc_menu.copy_link' },
    { id: 'new_tab', icon: 'open', labelKey: 'ws_doctree.doc_menu.new_tab' },
    { id: 'delete', icon: 'delete', labelKey: 'ws_doctree.doc_menu.delete', danger: true },
  ],
  folder: [
    NEW_DOC,
    NEW_FOLDER,
    { id: 'rename', icon: 'pencil', labelKey: 'ws_doctree.doc_menu.rename' },
    { id: 'copy_path', icon: 'copy', labelKey: 'ws_doctree.folder_menu.copy_path' },
    { id: 'delete', icon: 'delete', labelKey: 'ws_doctree.folder_menu.delete', danger: true },
  ],
  section: [
    { id: 'open', icon: 'go', labelKey: 'ws_doctree.section_menu.open' },
    { id: 'copy_link', icon: 'copy', labelKey: 'ws_doctree.doc_menu.copy_link' },
    { id: 'new_tab', icon: 'open', labelKey: 'ws_doctree.doc_menu.new_tab' },
  ],
  /* the root: create only; a hub without folders has no New folder */
  root: [NEW_DOC, NEW_FOLDER],
}
const KINDS: Record<string, MenuKind> = { d: 'doc', f: 'folder', i: 'section', [ROOT]: 'root' }
const menu = ref<{ kind: MenuKind, key: string, x: number, y: number } | null>(null)
const menuItems = computed(() => menu.value?.kind === 'root' && nodesOff.value ? [NEW_DOC] : MENUS[menu.value?.kind ?? 'doc'])
const status = ref('')
let statusTimer: ReturnType<typeof setTimeout> | undefined
const router = useRouter()

function openMenu(key: string, x: number, y: number) {
  const kind = KINDS[key.split(':')[0]]
  if (kind) menu.value = { kind, key, x, y }
}

/** a document's own address, at a section when item is set: the page that opens it */
function docHref(doc: string, item = ''): string {
  return new URL(router.resolve({ path: '/workspace/docs', query: { doc, view: 'doc' }, hash: item ? '#ws-doc-' + item : '' }).href, location.origin).href
}

/** a short line under the tree (the copy's answer), gone after 3 s */
async function copied(text: string, okKey: string) {
  status.value = ''
  status.value = t(await writeClipboard(text) ? okKey : 'common.copy_failed')
  clearTimeout(statusTimer)
  statusTimer = setTimeout(() => { status.value = '' }, 3000)
}

async function choose(id: string) {
  const m = menu.value
  if (!m) return
  if (m.kind === 'folder') return chooseFolder(id, m.key.slice(2))
  if (m.kind === 'root') return chooseFolder(id, '')
  const [, doc, item = ''] = m.key.split(':')
  if (id === 'open' && drilling.value) emit('open', doc, item)
  else if (id === 'open') select(m.key)
  else if (id === 'edit' && drilling.value) emit('open', doc, '')
  else if (id === 'edit') select(docKey(doc))
  else if (id === 'rename') {
    renameTo.value = props.docs.find((d) => d.id === doc)?.title || ''
    renameError.value = ''
    renaming.value = m.key
  } else if (id === 'copy_link') await copied(docHref(doc, item), 'ws_doctree.doc_menu.link_copied')
  else if (id === 'new_tab') window.open(docHref(doc, item), '_blank', 'noopener')
  else if (id === 'delete') {
    deleteError.value = ''
    deleting.value = doc
  }
}

/** a folder's menu (node '' = the root's): New document / New folder land in it (the current folder) */
async function chooseFolder(id: string, node: string) {
  if (id === 'new_doc' || id === 'new_folder') {
    folder.value = node
    if (id === 'new_doc') emit('newDoc')
    else folderOpen.value = true
  } else if (id === 'rename') {
    renameTo.value = folderOf.value[node]?.name || ''
    renameError.value = ''
    renaming.value = folderKey(node)
  } else if (id === 'copy_path') await copied(folderPath(node), 'ws_doctree.folder_menu.path_copied')
  else if (id === 'delete') {
    deleteError.value = ''
    dropping.value = { node, name: folderOf.value[node]?.name || '' }
  }
}

/* Delete a folder: confirmed, then the hub's DELETE; a folder that holds
   anything answers 409 folder_not_empty with its counts, shown in the same
   confirm, and a second confirm deletes it with them (recursive) */
const dropping = ref<{ node: string, name: string, held?: { folders: number, documents: number } } | null>(null)

async function removeFolder() {
  const d = dropping.value
  if (!d || busy.value) return
  busy.value = true
  deleteError.value = ''
  try {
    await props.client.removeFolder(d.node, Boolean(d.held))
    dropping.value = null
    await folderGone(d.node)
  } catch (e) {
    const held = e instanceof DocTreeError && e.code === 'folder_not_empty' && !d.held ? e.body : null
    if (held) dropping.value = { ...d, held: { folders: Number(held.folders) || 0, documents: Number(held.documents) || 0 } }
    else deleteError.value = 'ws_doctree.err_failed'
  } finally {
    busy.value = false
  }
}

/** a folder went: its listing read again, the current folder moved up out of it, the page's list too */
async function folderGone(node: string) {
  const parent = folderOf.value[node]?.parent ?? ''
  for (let f: string = folder.value; f; f = folderOf.value[f]?.parent || '') {
    if (f === node) {
      folder.value = parent
      folderPicked.value = false
      break
    }
  }
  setOpen(folderKey(node), false)
  await loadNodes(parent)
  emit('refresh')
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

/* Rename (renaming = the row's key): a document is the hub's PATCH under the
   doc rev read just now (cleared, the hub gives the default title); a folder
   is PATCH /folders/{folder}, 409 when a sibling folder has the name */
const renaming = ref<string | null>(null)
const renameTo = ref('')
const renameError = ref('')
const busy = ref(false)
async function rename() {
  const key = renaming.value
  if (!key || busy.value) return
  busy.value = true
  renameError.value = ''
  const name = renameTo.value.replace(/\s+/g, ' ').trim()
  try {
    if (key.startsWith('f:')) {
      await props.client.renameFolder(key.slice(2), name)
      await loadNodes(folderOf.value[key.slice(2)]?.parent ?? '')
    } else {
      const doc = key.slice(2)
      const h = await props.client.head(doc)
      const r = await props.client.rename(doc, h.rev, name)
      emit('renamed', doc, r.title, r.rev)
    }
    renaming.value = null
  } catch (e) {
    renameError.value = e instanceof DocTreeError && e.code === 'name_taken' ? 'ws_doctree.folder_menu.name_taken' : 'ws_doctree.err_failed'
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
