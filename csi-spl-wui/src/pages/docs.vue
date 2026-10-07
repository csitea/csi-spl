<!-- /docs and /docs/<repo path> (owner, prd t1 9f0d751c): every .md of the
     repo, published to this env's docs bucket at each WUI deploy
     (do_publish_docs) and read through the hub (GET /v1/docs/...), never
     from GitHub and never baked into the bundle. Left: an explorer tree of
     the repo's folders (tree.json); right: the doc, rendered by MarkdownBlock
     in the current theme. /docs/<repo path> is the doc's stable address;
     a relative .md link opens the target doc here. /docs shows README.md.
     Signed-in members only (signed-out-redirect + the hub's door).
     At <= 820 px the tree folds above the doc behind its Folders button.
     t1 c13e8023 (owner): on a desktop the explorer is the left pane and
     the document is the second, each scrolling on its own. The sidebar
     keeps its icon rail (ChannelSidebar docsRailOnly) and a topic panel
     open beside the channel the reader came from closes.
     spec 075 repo-edit T11: a doc tree.json flags editable shows Edit to a
     member with docs.write; the editor (RepoDocEditor) is a lazy chunk.
     T12: its status chip (RepoDocStatus) on the doc header, "My edits"
     (?edits=mine, RepoDocMyEdits) and the conflict view (?conflict=<edit>,
     RepoDocConflict), each a lazy chunk too. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 id="docs-h">{{ t('docs.title') }}</h2>
      <SectionClose side="end" />
    </header>
    <div class="feed-body docs-page" data-test="docs" :data-state="state">
      <div class="docs-layout" :class="{ 'docs-layout--tree-open': treeOpen }">
        <button
          type="button"
          class="docs-tree-toggle"
          data-test="docs-tree-toggle"
          :aria-expanded="treeOpen ? 'true' : 'false'"
          aria-controls="docs-tree"
          @click="treeOpen = !treeOpen"
        >
          <UiIcon name="folder" :size="18" />
          <span>{{ t('docs.folders') }}</span>
        </button>
        <nav id="docs-tree" class="docs-tree" :aria-label="t('docs.tree_label')" data-test="docs-tree">
          <!-- t1 199cafc7 (owner could not find Edit / New doc): the workspace
               docs, the editable ones, come first; the repo tree is long -->
          <DocsWorkspaceTree :active="wsPath" />
          <p v-if="treeState === 'loading'" class="muted">{{ t('common.loading') }}</p>
          <p v-else-if="treeState === 'off'" class="muted" role="status">{{ t('docs.off') }}</p>
          <p v-else-if="treeState === 'failed'" class="muted" role="alert">{{ t('docs.load_failed') }}</p>
          <ul v-else role="tree" class="docs-tree__list">
            <li
              v-for="row in rows"
              :key="row.kind + ':' + row.path"
              role="treeitem"
              :aria-level="row.depth + 1"
              :aria-expanded="row.kind === 'dir' ? (row.open ? 'true' : 'false') : undefined"
              :aria-selected="row.kind === 'file' ? (row.path === docPath ? 'true' : 'false') : undefined"
              class="docs-tree__row"
              :style="{ '--depth': row.depth }"
            >
              <button
                v-if="row.kind === 'dir'"
                type="button"
                class="docs-tree__item docs-tree__dir"
                data-test="docs-dir"
                :data-path="row.path"
                @click="toggle(row.path)"
              >
                <UiIcon :name="row.open ? 'chevron-down' : 'chevron-right'" :size="14" class="docs-tree__chev" />
                <UiIcon name="folder" :size="16" />
                <span class="docs-tree__name">{{ row.name }}</span>
              </button>
              <NuxtLink
                v-else
                :to="route(row.path)"
                class="docs-tree__item docs-tree__file"
                :class="{ 'docs-tree__file--active': row.path === docPath }"
                :aria-current="row.path === docPath ? 'page' : undefined"
                :title="row.title"
                data-test="docs-file"
                :data-path="row.path"
              >
                <UiIcon name="file-text" :size="16" />
                <span class="docs-tree__name">{{ row.name }}</span>
              </NuxtLink>
            </li>
          </ul>
        </nav>
        <article class="docs-content" aria-labelledby="docs-h" data-test="docs-content" :data-page="docPath">
          <DocsWorkspaceDoc v-if="wsPath" :path="wsPath" />
          <RepoDocMyEdits v-else-if="showMine" :path="docPath" />
          <template v-else>
          <div class="docs-content__bar">
            <p class="docs-content__path muted" data-test="docs-path">{{ docPath }}</p>
            <span class="docs-content__tools">
              <RepoDocStatus v-if="showChip" :path="docPath" :me="access.me?.humanId || ''" @resolve="openConflict" />
              <NuxtLink v-if="editOn && !editing" :to="{ path: route(docPath), query: { edits: 'mine' } }" class="btn ghost" data-test="repo-edits-open">{{ t('docs.repoEdit.mine.title') }}</NuxtLink>
              <button v-if="canEdit && !editing && !conflictId" type="button" class="btn ghost docs-content__edit" data-test="repo-edit-open" @click="editing = true">
                <UiIcon name="pencil" :size="16" />
                <span>{{ t('docs.ws.edit') }}</span>
              </button>
            </span>
          </div>
          <p v-if="savedNote && !editing" class="muted" role="status" data-test="repo-edit-saved">{{ t('docs.repoEdit.saved') }}</p>
          <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
          <p v-else-if="state === 'off'" class="muted" role="status">{{ t('docs.off') }}</p>
          <p v-else-if="state === 'missing'" class="muted" role="alert" data-test="docs-missing">{{ t('docs.not_found') }}</p>
          <!-- SPL-1291: a doc link from a message lands here; a doc the store
               has not published still opens, on the repository (no dead link) -->
          <p v-if="(state === 'missing' || state === 'off') && repoUrl" class="docs-content__repo" data-test="docs-repo">
            {{ t('docs.not_published') }}
            <a :href="repoUrl" target="_blank" rel="noopener noreferrer nofollow" data-test="docs-repo-link">{{ t('docs.open_in_repo') }}</a>
          </p>
          <p v-else-if="state === 'failed'" class="muted" role="alert">{{ t('docs.load_failed') }}</p>
          <RepoDocConflict v-else-if="conflictId" :id="conflictId" @saved="onResolved" @cancel="closeConflict" />
          <RepoDocEditor v-else-if="editing" :path="docPath" :text="raw" :base="base || editFiles.get(docPath)?.blob || ''" @saved="onSaved" @cancel="editing = false" />
          <MarkdownBlock v-else :text="text" bare />
          </template>
        </article>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
/* the catch-all route, set here rather than by a [...path].vue file name:
   that name makes a "_...path_" chunk, and a static server that refuses
   ".." in a request path (the e2e gate's serve-generated.mjs) then fails
   the chunk and Nuxt reloads the page in a loop */
definePageMeta({ path: '/docs/:path(.*)*' })
import MarkdownBlock from '~/components/MarkdownBlock.vue'
import DocsWorkspaceDoc from '~/components/DocsWorkspaceDoc.vue'
import DocsWorkspaceTree from '~/components/DocsWorkspaceTree.vue'
import { wsPathOf } from '~/utils/ws-docs.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { DOCS_HOME, buildDocsTree, docsAncestors, docsRepoUrl, rewriteDocsLinks, validDocsPath, visibleDocsRows, type DocsDir } from '~/utils/docs.mjs'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { repoEditFiles, type RepoEditFile } from '~/utils/repo-edit.mjs'
import { canWriteDocs } from '~/utils/ws-docs.mjs'
import { useAccessStore } from '~/stores/access'

/* spec 075 repo-edit T11: the editor and its store load on Edit only */
const RepoDocEditor = defineAsyncComponent(() => import('~/components/RepoDocEditor.vue'))
/* T12: the status chip, My edits and the conflict view, lazy as well */
const RepoDocStatus = defineAsyncComponent(() => import('~/components/RepoDocStatus.vue'))
const RepoDocMyEdits = defineAsyncComponent(() => import('~/components/RepoDocMyEdits.vue'))
const RepoDocConflict = defineAsyncComponent(() => import('~/components/RepoDocConflict.vue'))

type TreeFile = { path: string, title: string }

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const current = useRoute()
const router = useRouter()
const api = useSpoolApi()
const docPath = computed(() => {
  const p = current.params.path
  const s = Array.isArray(p) ? p.join('/') : typeof p === 'string' ? p : ''
  return s || DOCS_HOME
})
const route = (p: string) => localePath('/docs/' + p)
const pub = useRuntimeConfig().public
/* the doc on the repository (cnf repo_web_url + repo_help_path's branch) */
const repoUrl = computed(() => docsRepoUrl(docPath.value, pub.repoWebUrl, pub.repoHelpPath))
/* spec 075 T010: /docs/ws/<path> is a workspace doc (DocsWorkspaceDoc) */
const wsPath = computed(() => wsPathOf(docPath.value))
const tree = ref<DocsDir>(buildDocsTree([]))
const open = ref<Set<string>>(new Set(['csi-spl-doc']))
const rows = computed(() => visibleDocsRows(tree.value, open.value))
const treeState = ref<'loading' | 'ready' | 'off' | 'failed'>('loading')
const text = ref('')
/* the doc as the hub served it, and the blob it is based on (If-Match) */
const raw = ref('')
const base = ref('')
const editFiles = ref<Map<string, RepoEditFile>>(new Map())
const editing = ref(false)
const savedNote = ref(false)
const access = useAccessStore()
const canEdit = computed(() => state.value === 'ready' && editFiles.value.get(docPath.value)?.editable === true && canWriteDocs(access.me))
/* T12: editing is on (some doc is editable) and the member may save */
const editOn = computed(() => canWriteDocs(access.me) && [...editFiles.value.values()].some((f) => f.editable))
const showChip = computed(() => state.value === 'ready' && editFiles.value.get(docPath.value)?.editable === true && !editing.value && !conflictId.value)
const showMine = computed(() => current.query.edits === 'mine')
const conflictId = computed(() => (typeof current.query.conflict === 'string' ? current.query.conflict : ''))
const state = ref<'loading' | 'ready' | 'missing' | 'off' | 'failed'>('loading')
/* the phone folds the tree; /docs with no doc opens it */
const treeOpen = ref(!(Array.isArray(current.params.path) ? current.params.path.length : current.params.path))

function toggle(path: string) {
  const s = new Set(open.value)
  if (s.has(path)) s.delete(path)
  else s.add(path)
  open.value = s
}

/* GET /v1/docs/<path> through the hub: the body, null for a 404, 'off'
   when the hub has no docs bucket. The mock tenant answers from docs-mock.
   Throws for any other non-2xx, a network failure or a timeout ('failed'). */
async function hubDoc(path: string, meta?: { base: string }): Promise<string | null | 'off'> {
  if (api.mock) {
    const { mockDocs, mockDocBase } = await import('~/utils/docs-mock.mjs')
    if (meta) meta.base = mockDocBase(path)
    return mockDocs(path)
  }
  const headers: Record<string, string> = {}
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const r = await fetch(`${api.base}/v1/docs/${path}`, { credentials: api.credentials, headers, cache: 'no-cache', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
  if (r.status === 404) {
    const body = await r.json().catch(() => null) as { error?: string } | null
    return body?.error === 'docs_off' ? 'off' : null
  }
  if (!r.ok) throw new Error('docs ' + r.status)
  if (meta) meta.base = r.headers.get('X-Spool-Doc-Base') ?? ''
  return r.text()
}

let seq = 0
async function load() {
  const mine = ++seq
  const p = docPath.value
  if (wsPath.value) return
  state.value = 'loading'
  editing.value = false
  savedNote.value = false
  if (!validDocsPath(p)) { state.value = 'missing'; return }
  for (const a of docsAncestors(p)) if (!open.value.has(a)) toggle(a)
  try {
    const meta = { base: '' }
    const md = await hubDoc(p, meta)
    if (mine !== seq) return
    if (md === 'off') { state.value = 'off'; return }
    if (md === null) { state.value = 'missing'; return }
    raw.value = md
    base.value = meta.base
    text.value = rewriteDocsLinks(md, p, route)
    state.value = 'ready'
  } catch {
    if (mine === seq) state.value = 'failed'
  }
}

async function loadTree() {
  try {
    const raw = await hubDoc('tree.json')
    if (raw === 'off') { treeState.value = 'off'; return }
    const body = raw ? JSON.parse(raw) as { files?: TreeFile[] } : null
    tree.value = buildDocsTree(body?.files)
    editFiles.value = repoEditFiles(body?.files)
    treeState.value = 'ready'
  } catch {
    treeState.value = 'failed'
  }
}

/* saved: the page shows the new text (the hub serves the overlay from now) */
function onSaved(md: string) {
  raw.value = md
  text.value = rewriteDocsLinks(md, docPath.value, route)
  editing.value = false
  savedNote.value = true
}

/* T12: the conflict view of an edit of this doc, and back */
function openConflict(id: string) {
  editing.value = false
  void router.push({ path: route(docPath.value), query: { conflict: id } })
}
function closeConflict() {
  void router.replace({ path: route(docPath.value) })
}
/* resolved: the page shows the saved text, and the chip the new edit */
function onResolved(md: string) {
  closeConflict()
  onSaved(md)
}

watch(docPath, () => { if (import.meta.client) void load() })
onMounted(() => { void loadTree(); void load() })
/* t1 c13e8023 (owner): a topic panel open beside the channel the reader
   came from closes when Docs opens. No third pane, whichever store holds it. */
const topic = useTopicStore()
const livePane = useLiveFeed('pane')
function closeTopicPanel() {
  if (livePane.taskId) livePane.close()
  if (topic.open) topic.close()
}
watch(() => [livePane.taskId, topic.open], closeTopicPanel)
onMounted(closeTopicPanel)
useHead(() => ({ title: t('docs.title') }))
</script>

<style scoped>
.docs-layout {
  display: grid;
  grid-template-columns: minmax(200px, 300px) minmax(0, 1fr);
  gap: 24px;
  align-items: start;
  min-width: 0;
}
.docs-tree-toggle { display: none; }
.docs-tree {
  position: sticky;
  top: 0;
  max-height: calc(100dvh - 140px);
  overflow: auto;
  min-width: 0;
  border-inline-end: 1px solid var(--color-border);
  padding-inline-end: 8px;
}
.docs-tree__list { list-style: none; margin: 0; padding: 0; text-align: start; }
.docs-tree__item {
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 6px;
  width: 100%;
  min-height: 30px;
  padding: 3px 8px;
  padding-inline-start: calc(8px + var(--depth, 0) * 16px);
  border: 0;
  border-radius: var(--radius-sm, 8px);
  background: none;
  color: var(--color-text);
  font: inherit;
  text-align: start;
  text-decoration: none;
  cursor: pointer;
}
.docs-tree__item:hover { background: var(--color-bg-2); }
.docs-tree__dir { font-weight: 600; }
.docs-tree__file { padding-inline-start: calc(28px + var(--depth, 0) * 16px); }
.docs-tree__file--active { background: var(--color-selected); font-weight: 600; }
.docs-tree__name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.docs-tree__chev { flex: none; }
:global([dir="rtl"]) .docs-tree__chev[data-icon="chevron-right"] { transform: scaleX(-1); }
.docs-content { min-width: 0; max-width: 900px; display: flex; flex-direction: column; gap: 8px; }
.docs-content__bar { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.docs-content__tools { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; }
.docs-content__edit { display: inline-flex; align-items: center; gap: 6px; }
.docs-content__path { margin: 0; font-size: 0.8125rem; overflow-wrap: anywhere; }
.docs-content__repo { margin: 0; overflow-wrap: anywhere; }
.docs-content__repo a { color: var(--color-accent); text-decoration: underline; }
.docs-content :deep(h1) { font-size: 1.5rem; margin: 0 0 0.5em; }
.docs-content :deep(h2) { font-size: 1.2rem; margin: 1.2em 0 0.4em; }
.docs-content :deep(h3) { font-size: 1.05rem; margin: 1em 0 0.3em; }
.docs-content :deep(hr) { border: 0; border-top: 1px solid var(--color-border); margin: 1.2em 0; }
@media (max-width: 820px) {
  .docs-layout { grid-template-columns: minmax(0, 1fr); gap: 12px; }
  .docs-tree-toggle {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    justify-self: start;
    min-height: 44px;
    padding: 6px 12px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm, 8px);
    background: var(--color-bg-2);
    color: var(--color-text);
    font: inherit;
  }
  .docs-tree { display: none; position: static; max-height: none; border-inline-end: 0; padding: 0; }
  .docs-layout--tree-open .docs-tree { display: block; }
  .docs-tree__item { min-height: 44px; }
}
/* Desktop: the page body does not scroll. The explorer and the document
   each scroll on their own, and the document fills the second pane. */
@media (min-width: 821px) {
  .docs-page {
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .docs-layout {
    flex: 1 1 auto;
    min-height: 0;
    align-items: stretch;
    grid-template-rows: minmax(0, 1fr);
  }
  .docs-tree {
    position: static;
    top: auto;
    max-height: none;
    min-height: 0;
    overflow-x: clip;
    overflow-y: auto;
    overscroll-behavior: contain;
  }
  .docs-content {
    max-width: none;
    min-height: 0;
    overflow-x: clip;
    overflow-y: auto;
    overscroll-behavior: contain;
  }
}
</style>
