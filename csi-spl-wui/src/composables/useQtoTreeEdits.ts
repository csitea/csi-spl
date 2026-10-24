/*
 * The Qto file tree's row edit dialogs (QtoFileTree, split out in r19-02):
 * folder delete, document delete and rename. Each is "guard, `busy`, the
 * hub's call, report the change, error text"; `busy` is one ref shared by the
 * three. The tree's menus open the dialogs by writing the returned refs.
 */
import { computed, ref, type Ref } from 'vue'
import { DocTreeError, type DocHead, type DocTreeClient } from '~/components/workspace-docs/-doctree-api'
import type { QtoTreeFolders } from '~/composables/useQtoTreeFolders'

export interface QtoTreeEditsOpts {
  client: () => DocTreeClient
  docs: () => DocHead[]
  folders: QtoTreeFolders
  t: (key: string) => string
  /** a folder was deleted: the list reads the documents again */
  refresh: () => void
  deleted: (doc: string) => void
  renamed: (doc: string, title: string, rev: number) => void
}

interface EditState {
  busy: Ref<boolean>
  deleteError: Ref<string>
  dropping: Ref<{ node: string, name: string, held?: { folders: number, documents: number } } | null>
  deleting: Ref<string | null>
  renaming: Ref<string | null>
  renameTo: Ref<string>
  renameError: Ref<string>
}

/* Delete a folder: confirmed, then the hub's DELETE; a folder that holds
   anything answers 409 folder_not_empty with its counts, shown in the same
   confirm, and a second confirm deletes it with them (recursive) */
async function removeFolder(o: QtoTreeEditsOpts, s: EditState) {
  const d = s.dropping.value
  if (!d || s.busy.value) return
  s.busy.value = true
  s.deleteError.value = ''
  try {
    await o.client().removeFolder(d.node, Boolean(d.held))
    s.dropping.value = null
    await o.folders.folderGone(d.node)
    o.refresh()
  } catch (e) {
    const held = e instanceof DocTreeError && e.code === 'folder_not_empty' && !d.held ? e.body : null
    if (held) s.dropping.value = { ...d, held: { folders: Number(held.folders) || 0, documents: Number(held.documents) || 0 } }
    else s.deleteError.value = 'ws_doctree.err_failed'
  } finally {
    s.busy.value = false
  }
}

/* Delete: confirmed, then the hub's DELETE under the doc rev read just now */
async function removeDoc(o: QtoTreeEditsOpts, s: EditState) {
  const doc = s.deleting.value
  if (!doc || s.busy.value) return
  s.busy.value = true
  s.deleteError.value = ''
  try {
    const h = await o.client().head(doc)
    await o.client().removeDoc(doc, h.rev)
    s.deleting.value = null
    o.deleted(doc)
  } catch {
    s.deleteError.value = 'ws_doctree.err_failed'
  } finally {
    s.busy.value = false
  }
}

/* Rename (renaming = the row's key): a document is the hub's PATCH under the
   doc rev read just now (cleared, the hub gives the default title); a folder
   is PATCH /folders/{folder}, 409 when a sibling folder has the name */
async function rename(o: QtoTreeEditsOpts, s: EditState) {
  const key = s.renaming.value
  if (!key || s.busy.value) return
  s.busy.value = true
  s.renameError.value = ''
  const name = s.renameTo.value.replace(/\s+/g, ' ').trim()
  try {
    if (key.startsWith('f:')) {
      await o.client().renameFolder(key.slice(2), name)
      await o.folders.loadNodes(o.folders.folderOf.value[key.slice(2)]?.parent ?? '')
    } else {
      const doc = key.slice(2)
      const h = await o.client().head(doc)
      const r = await o.client().rename(doc, h.rev, name)
      o.renamed(doc, r.title, r.rev)
    }
    s.renaming.value = null
  } catch (e) {
    s.renameError.value = e instanceof DocTreeError && e.code === 'name_taken' ? 'ws_doctree.folder_menu.name_taken' : 'ws_doctree.err_failed'
  } finally {
    s.busy.value = false
  }
}

export function useQtoTreeEdits(o: QtoTreeEditsOpts) {
  const s: EditState = {
    busy: ref(false),
    deleteError: ref(''),
    dropping: ref(null),
    deleting: ref(null),
    renaming: ref(null),
    renameTo: ref(''),
    renameError: ref(''),
  }
  const deletingTitle = computed(() => o.docs().find((d) => d.id === s.deleting.value)?.title || o.t('ws_doctree.default_doc_title'))
  return {
    ...s,
    deletingTitle,
    removeFolder: () => removeFolder(o, s),
    removeDoc: () => removeDoc(o, s),
    rename: () => rename(o, s),
  }
}
