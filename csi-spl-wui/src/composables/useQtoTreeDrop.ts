/*
 * The Qto file tree's re-order (QtoFileTree, split out in r14-03). The row
 * gesture and the drop place (before / after / into) are tree-drag.mjs's,
 * driven by UiFileTree; this decides whether a place takes the row
 * (`canDrop`) and makes the hub's move there (`moveRow`).
 *
 * SPL-1873 (owner t1 1a9a14b6 msg 32d5ea87): a document or folder row drops
 * by a row of its kind (folders stay first) or into a folder or `/`: the
 * hub's nodes/{node}/move with before / after. SPL-1892 (owner t1 089630f7
 * msg fcf24997): a section row drops within its own document only: the
 * hub's items/{item}/move {rev, parent, ord} under the rev the tree read; a
 * stale rev (412) reads the document again and says so, it never overwrites.
 */
import type { Ref } from 'vue'
import type { FileTreeDrop } from '~/components/UiFileTree.vue'
import { DocTreeError, type DocItem, type DocTreeClient } from '~/components/workspace-docs/-doctree-api'
import { QTO_ROOT, docKey, folderKey, itemKey, type QtoTreeFolders } from '~/composables/useQtoTreeFolders'

export interface QtoTreeDropOpts {
  client: () => DocTreeClient
  active: () => string
  folders: QtoTreeFolders
  /* each loaded document's items grouped by parent, its rev and root item, and the read of them */
  kids: Ref<Record<string, Map<string, DocItem[]>>>
  revOf: Record<string, number>
  rootOf: Record<string, string>
  load: (doc: string) => Promise<void>
  /** a short line under the tree, by i18n key */
  say: (key: string) => void
  /** a section move landed (or a stale one was read again): the document's new rev */
  moved: (doc: string, rev: number) => void
}

/** a section's drop (SPL-1892): within its own document only */
function sectionDrop(opts: QtoTreeDropOpts) {
  const { setOpen } = opts.folders
  /* its document's items by id, from the loaded subtree */
  function itemsOf(doc: string): Map<string, DocItem> {
    const byId = new Map<string, DocItem>()
    for (const list of opts.kids.value[doc]?.values() || []) for (const it of list) byId.set(it.id, it)
    return byId
  }

  /** a section of the same document: by or onto a section, or onto its document's row; never into its own subtree */
  function canDropSection(key: string, target: string, where: FileTreeDrop): boolean {
    const [, doc, item] = key.split(':')
    if (target === docKey(doc)) return where === 'into' && Boolean(opts.rootOf[doc])
    const [kind, tdoc, titem] = target.split(':')
    if (kind !== 'i' || tdoc !== doc) return false
    const byId = itemsOf(doc)
    for (let it = byId.get(titem); it; it = byId.get(it.parent)) if (it.id === item) return false
    return true
  }

  /** the hub's items/{item}/move: the parent and the final place under it (0 = last); a stale rev reads the document again */
  async function moveSection(key: string, target: string, where: FileTreeDrop) {
    const [, doc, item] = key.split(':')
    const titem = target.split(':')[2] || ''
    const parent = where === 'into' ? titem || opts.rootOf[doc] : itemsOf(doc).get(titem)?.parent
    const sibs = (parent && opts.kids.value[doc]?.get(parent) || []).filter((it) => it.id !== item)
    const ord = where === 'into' ? 0 : sibs.findIndex((it) => it.id === titem) + (where === 'after' ? 2 : 1)
    if (!parent || ord < 0) return
    try {
      const r = await opts.client().move(doc, opts.revOf[doc] ?? 0, item, parent, ord)
      await opts.load(doc)
      if (where === 'into') setOpen(titem ? itemKey(doc, titem) : docKey(doc), true)
      opts.moved(doc, r.rev)
    } catch (e) {
      const stale = e instanceof DocTreeError && e.status === 412
      if (stale) {
        await opts.load(doc)
        opts.moved(doc, opts.revOf[doc] ?? 0)
      }
      opts.say(stale ? 'ws_doctree.stale' : 'ws_doctree.err_failed')
    }
  }

  return { canDropSection, moveSection }
}

export function useQtoTreeDrop(opts: QtoTreeDropOpts) {
  const { folderOf, nodesOff, folderOfDoc, nodeOfDoc, loadNodes, setOpen, reveal } = opts.folders
  const { canDropSection, moveSection } = sectionDrop(opts)

  /* a row's node and its folder ('' = the top) */
  const nodeOfKey = (key: string) => (key.startsWith('f:') ? key.slice(2) : key.startsWith('d:') ? nodeOfDoc(key.slice(2)) : '')
  const parentOfKey = (key: string) => (key.startsWith('f:') ? folderOf.value[key.slice(2)]?.parent ?? '' : folderOfDoc(key.slice(2)))
  /** folder f is node or under it: a folder never goes into its own subtree */
  function within(f: string, node: string): boolean {
    for (let p = f; p; p = folderOf.value[p]?.parent || '') if (p === node) return true
    return false
  }

  /** where a dragged row may land: into a folder or `/`, or next to a row of its own kind (folders stay first) */
  function canDrop(key: string, target: string, where: FileTreeDrop): boolean {
    if (key.startsWith('i:')) return canDropSection(key, target, where)
    const node = nodeOfKey(key)
    if (!node || nodesOff.value) return false
    const folderMove = key.startsWith('f:')
    if (where === 'into') {
      if (target !== QTO_ROOT && !target.startsWith('f:')) return false
      return !folderMove || !within(target === QTO_ROOT ? '' : target.slice(2), node)
    }
    if (key.slice(0, 2) !== target.slice(0, 2) || !nodeOfKey(target)) return false
    return !folderMove || !within(parentOfKey(target), node)
  }

  /** a drop or Alt+Up / Alt+Down: the hub's move at that place, then both folders' listings read again */
  async function moveRow(key: string, target: string, where: FileTreeDrop) {
    if (key.startsWith('i:')) return moveSection(key, target, where)
    const node = nodeOfKey(key)
    const from = parentOfKey(key)
    const into = where === 'into'
    const parent = into ? (target === QTO_ROOT ? '' : target.slice(2)) : parentOfKey(target)
    try {
      await opts.client().moveNode(node, parent, into ? {} : { [where]: nodeOfKey(target) })
    } catch (e) {
      opts.say(e instanceof DocTreeError && e.code === 'name_taken' ? 'ws_doctree.folder_menu.name_taken' : 'ws_doctree.err_failed')
      return
    }
    const read = new Set([from, parent])
    for (const f of [from, parent]) if (f) read.add(folderOf.value[f]?.parent ?? '')
    await Promise.all([...read].map(loadNodes))
    if (into) setOpen(parent ? folderKey(parent) : QTO_ROOT, true)
    if (opts.active()) reveal(opts.active())
  }

  return { canDrop, moveRow }
}
