/*
 * The Qto file tree's folders and their expansion (QtoFileTree, split out in
 * r14-03). Spec 120 (owner t1 3b8891e0): the tree's top level is the hub's
 * /nodes, folders first; a folder row expands into its own /nodes. The `/`
 * row (owner t1 f6bec016) holds the top level and starts open. `opened`
 * holds every expanded row key of the tree, folders and documents alike.
 * A hub without /nodes (an older hub, a mock without folders) keeps the
 * flat list: `nodesOff`.
 */
import { ref, watch } from 'vue'
import type { FileTreeRow } from '~/components/UiFileTree.vue'
import { useQtoFolder, type DocHead, type DocNode, type DocTreeClient } from '~/components/workspace-docs/-doctree-api'

/* row keys: / the root, f:<node> for a folder, d:<doc> for a document, i:<doc>:<item> for a section */
export const QTO_ROOT = '/'
export const folderKey = (id: string) => 'f:' + id
export const docKey = (doc: string) => 'd:' + doc
export const itemKey = (doc: string, item: string) => `i:${doc}:${item}`

export interface QtoTreeFoldersOpts {
  client: () => DocTreeClient
  docs: () => DocHead[]
  active: () => string
}

/** the tree's folder state: the expanded rows, the loaded listings, the current folder */
function folderState() {
  return {
    /* the root starts open */
    opened: ref<Set<string>>(new Set([QTO_ROOT])),
    /* each loaded folder's children ('' = the top level), and each folder's
       name and parent (the phone's path, the reveal) */
    nodesAt: ref<Record<string, DocNode[]>>({}),
    folderOf: ref<Record<string, { name: string, parent: string }>>({}),
    nodesOff: ref(false),
    folder: useQtoFolder(),
    /* the last row picked on the desktop was a folder: it is the marked row */
    folderPicked: ref(false),
  }
}
type FolderState = ReturnType<typeof folderState>

/** reading the folders: the listings, where a document sits, the open rows */
function folderNav(st: FolderState, opts: QtoTreeFoldersOpts) {
  const { opened, nodesAt, folderOf, nodesOff } = st
  function setOpen(key: string, on: boolean) {
    const s = new Set(opened.value)
    if (on) s.add(key)
    else s.delete(key)
    opened.value = s
  }

  async function loadNodes(parent: string) {
    try {
      const r = await opts.client().nodes(parent)
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

  /** a document's node id, '' = none (an older hub's document, or not loaded) */
  function nodeOfDoc(doc: string): string {
    for (const list of Object.values(nodesAt.value)) for (const n of list) if (n.doc === doc && n.id) return n.id
    return ''
  }

  /** the folder's path from the top: Plans / 2026 */
  function folderPath(id: string): string {
    const names: string[] = []
    for (let f = folderOf.value[id]; f; f = folderOf.value[f.parent]) names.unshift(f.name)
    return names.join(' / ')
  }

  /** every folder up from a document's open, so it shows where it landed */
  function reveal(doc: string) {
    const s = new Set(opened.value).add(QTO_ROOT)
    for (let p = folderOfDoc(doc); p; p = folderOf.value[p]?.parent || '') s.add(folderKey(p))
    opened.value = s
  }

  return { setOpen, loadNodes, folderOfDoc, nodeOfDoc, folderPath, reveal }
}

/** a folder's row and the `/` row */
function folderRows({ opened, nodesOff, folder, folderPicked }: FolderState) {
  function folderRow(n: DocNode, depth: number): FileTreeRow {
    const key = folderKey(n.id)
    return { key, depth, name: n.name, icon: 'folder', kind: 'folder', menu: true, drag: true, into: true, expandable: n.child_count > 0, open: n.child_count > 0 && opened.value.has(key), active: folderPicked.value && folder.value === n.id }
  }

  /** the `/` row: the top level's folder, open unless closed */
  function rootRow(): FileTreeRow {
    return { key: QTO_ROOT, depth: 0, name: '/', icon: 'folder', kind: 'root', menu: true, into: !nodesOff.value, expandable: true, open: opened.value.has(QTO_ROOT), active: folderPicked.value && !folder.value }
  }

  return { folderRow, rootRow }
}

/** changing the folders: a new one, the root picked, one gone */
function folderEdits(st: FolderState, nav: ReturnType<typeof folderNav>, opts: QtoTreeFoldersOpts) {
  const { folderOf, folder, folderPicked } = st
  const { setOpen, loadNodes } = nav
  /** New folder (a folder's or the root's menu): a folder in the current one, then its listing read again */
  async function makeFolder(name: string) {
    const parent = folder.value
    await opts.client().createFolder(parent, name)
    await loadNodes(parent)
    const up = folderOf.value[parent]
    if (up) await loadNodes(up.parent)
    setOpen(parent ? folderKey(parent) : QTO_ROOT, true)
  }

  /** the `/` row: the top level becomes the current folder, and it opens */
  function pickRoot() {
    folder.value = ''
    folderPicked.value = true
    setOpen(QTO_ROOT, true)
  }

  /** a folder went: its listing read again, the current folder moved up out of it */
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
  }

  return { makeFolder, pickRoot, folderGone }
}

export function useQtoTreeFolders(opts: QtoTreeFoldersOpts) {
  const st = folderState()
  const nav = folderNav(st, opts)

  /* the list changed (a create, a rename, a delete): the loaded folders read again */
  watch(() => opts.docs().map((d) => d.id + d.title).join('|'), async () => {
    await Promise.all([...new Set(['', ...Object.keys(st.nodesAt.value)])].map(nav.loadNodes))
    if (opts.active()) nav.reveal(opts.active())
  }, { immediate: true })

  return { ...st, ...nav, ...folderRows(st), ...folderEdits(st, nav, opts) }
}

export type QtoTreeFolders = ReturnType<typeof useQtoTreeFolders>
