/*
 * The Qto file tree's Repository branch (QtoFileTree, split out in r17-01).
 * Spec 137 T023: the repository's docs beside the workspace's own, under
 * one `r:` row; tree.json is read once, the first time the branch opens.
 * Row keys: r: the branch itself, rd:<path> a repo folder, rf:<path> a repo
 * doc. A tree mounted without `repo` (undefined) has no branch: `repoDocs`
 * stays null and the caller adds no rows.
 */
import { ref, watch, type Ref } from 'vue'
import type { FileTreeRow } from '~/components/UiFileTree.vue'
import { useRepoDocs } from '~/components/workspace-docs/-repo-docs'
import { buildDocsTree, docsAncestors, visibleDocsRows, type DocsDir } from '~/utils/docs.mjs'

export interface QtoTreeRepoOpts {
  /** the open repo doc's path ('' none); undefined = no Repository branch */
  repo: () => string | undefined
  /* the tree's expanded rows (useQtoTreeFolders) */
  opened: Ref<Set<string>>
  setOpen: (key: string, on: boolean) => void
  /** the short line under the tree: a failed read says so there */
  status: Ref<string>
  t: (key: string) => string
}

export function useQtoTreeRepo(opts: QtoTreeRepoOpts) {
  const { opened, setOpen, status, t } = opts
  const REPO = 'r:'
  const repoDocs = typeof opts.repo() === 'string' ? useRepoDocs() : null
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
  watch(opts.repo, (path) => {
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
        : { key: 'rf:' + r.path, depth: r.depth + 1, name: r.name, title: r.title, icon: 'file-text', kind: 'repo-doc', expandable: false, active: r.path === opts.repo() })
    }
    return out
  }

  return { REPO, repoDocs, toggleRepo, repoRows }
}
