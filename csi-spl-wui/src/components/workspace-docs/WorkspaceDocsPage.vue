<!-- Spec 113 T006: the body of /workspace/docs (pages/workspace/docs.vue
     loads it on demand): workspace documents, an outline and a grid over one
     tree (?doc=<id>&view=doc|grid). The DB is the source of truth
     (spec 0); every edit is one of the hub's ops (T004, /v1/workspace/doctree)
     with the doc rev this page read, so neither view can break the tree. A
     412 (someone else changed the document) shows the reload prompt. -->
<template>
  <div class="feed-col wsdocs-page" data-test="ws-docs-page">
    <header class="feed-header wsdocs-head">
      <MobileBack />
      <h2>{{ t('ws_doctree.title') }}</h2>
      <!-- owner t1 889e15d9: a new document is made through the + and its
           modal, the issues page's pattern (SPL-978 round +; SPL-992 on a
           phone it floats bottom right) -->
      <button v-if="state === 'ready' || state === 'loading'" type="button" class="wsdocs-fab" data-test="ws-docs-new" aria-haspopup="dialog" :aria-label="t('ws_doctree.new_doc')" :title="t('ws_doctree.new_doc')" @click="newOpen = true">
        <UiIcon name="plus" :size="22" :stroke-width="2.5" />
      </button>
      <label v-if="docs.length" class="wsdocs-pick">
        <span class="sr-only">{{ t('ws_doctree.doc_label') }}</span>
        <select :value="docId" data-test="ws-docs-select" :aria-label="t('ws_doctree.doc_label')" @change="pick(($event.target as HTMLSelectElement).value)">
          <option v-for="d in docs" :key="d.id" :value="d.id">{{ d.title }}</option>
        </select>
      </label>
      <div v-if="docId" class="wsdocs-views" role="radiogroup" :aria-label="t('ws_doctree.view_label')">
        <button
          v-for="v in VIEWS"
          :key="v"
          type="button"
          role="radio"
          class="wsdocs-views__opt"
          :data-test="'ws-docs-view-' + v"
          :aria-checked="view === v ? 'true' : 'false'"
          @click="setView(v)"
        >
          <UiIcon :name="v === 'doc' ? 'list' : 'file-spreadsheet'" :size="16" />
          <span>{{ t('ws_doctree.view_' + v) }}</span>
        </button>
      </div>
    </header>
    <div class="feed-body wsdocs-body">
      <p v-if="state === 'loading'" class="muted wsdocs-note">{{ t('ws_doctree.loading') }}</p>
      <p v-else-if="state === 'off'" class="muted wsdocs-note" data-test="ws-docs-off">{{ t('ws_doctree.off') }}</p>
      <div v-else-if="state === 'failed'" class="wsdocs-note" role="alert">
        <p>{{ t('ws_doctree.load_failed') }}</p>
        <button type="button" class="btn ghost" @click="loadDocs">{{ t('ws_doctree.retry') }}</button>
      </div>
      <p v-else-if="!docs.length" class="muted wsdocs-note" data-test="ws-docs-none">{{ t('ws_doctree.empty_docs') }}</p>

      <div v-if="session?.stale.value" class="wsdocs-stale" role="alert" data-test="ws-docs-stale">
        <UiIcon name="alert-triangle" :size="18" />
        <span>{{ t('ws_doctree.stale') }}</span>
        <button type="button" class="btn" data-test="ws-docs-reload" @click="reopen">{{ t('ws_doctree.reload') }}</button>
      </div>
      <p v-else-if="session?.error.value" class="wsdocs-error" role="alert" data-test="ws-docs-error">{{ t(session.error.value) }}</p>

      <template v-if="session && root">
        <WorkspaceDocView v-if="view === 'doc'" :key="'doc' + mount" :session="session" :root="root" :title="docTitle" :docs="docs" @print="printBranch" @list="openList" @open="openAt" @renamed="renamed" />
        <WorkspaceGridView v-else :key="'grid' + mount" :session="session" :filter="String(route.query.q || '')" @print="printBranch" />
      </template>
    </div>
    <WorkspaceDocPrint :title="docTitle" :items="printItems" :doc="session?.doc ?? ''" :srcs="printSrcs" />
    <WorkspaceDocNewDialog v-model:open="newOpen" :create="createDoc" />
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, shallowRef } from 'vue'
import WorkspaceDocView from './WorkspaceDocView.vue'
import WorkspaceGridView from './WorkspaceGridView.vue'
import WorkspaceDocPrint from './WorkspaceDocPrint.vue'
import WorkspaceDocNewDialog from './WorkspaceDocNewDialog.vue'
import { createDocSession, DocTreeError, seedStarterDoc, useDocTree, type DocHead, type DocItem, type DocSession } from './-doctree-api'
import { picPaths } from './-doc-pics'
import { useSpoolApi } from '~/composables/useSpoolApi'

const VIEWS = ['doc', 'grid'] as const
type View = typeof VIEWS[number]

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const client = useDocTree()

const docs = ref<DocHead[]>([])
const state = ref<'loading' | 'ready' | 'off' | 'failed'>('loading')
const session = shallowRef<DocSession | null>(null)
const root = ref('')
const mount = ref(0)
const newOpen = ref(false)
const printItems = ref<DocItem[]>([])
/* the printed images' sources, resolved before the browser prints */
const printSrcs = ref<Record<string, string>>({})

const docId = computed(() => String(route.query.doc || '') || docs.value[0]?.id || '')
const view = computed<View>(() => (route.query.view === 'grid' ? 'grid' : 'doc'))
const docTitle = computed(() => docs.value.find((d) => d.id === docId.value)?.title || '')

async function setQuery(q: Record<string, string>) {
  const next: Record<string, unknown> = { ...route.query, ...q }
  for (const k of Object.keys(next)) if (next[k] === '') delete next[k] /* an empty value leaves the URL */
  await router.replace({ query: next as Record<string, string> })
}
function setView(v: View) {
  void setQuery({ view: v, q: '' })
}

/** Qto's "open as list": the grid, filtered to one branch's number */
function openList(outline: string) {
  void setQuery({ view: 'grid', q: outline })
}

/** a search hit in another document: open it, then its heading */
async function openAt(doc: string, item: string) {
  const { q: _q, ...rest } = route.query
  await router.replace({ query: { ...rest, doc, view: 'doc' }, hash: '#ws-doc-' + item })
  await open()
}

/** open (or reopen) the current document: its head, a fresh session, the view remounted */
async function open() {
  const id = docId.value
  session.value = null
  root.value = ''
  if (!id) return
  const s = createDocSession(client, id)
  const h = await s.run(() => client.head(id))
  if (!h || id !== docId.value) return
  s.rev.value = h.rev
  root.value = h.root
  session.value = s
  mount.value++
}

/* the route is the doc id's one source: open only once the navigation has landed */
async function pick(id: string) {
  await setQuery({ doc: id })
  await open()
}

/** the doc view renamed the open document: the picker shows the new title, the view stays mounted */
function renamed(title: string) {
  docs.value = docs.value.map((d) => (d.id === docId.value ? { ...d, title } : d))
}

function reopen() {
  void open()
}

async function loadDocs() {
  state.value = 'loading'
  try {
    docs.value = await client.list()
    state.value = 'ready'
    await open()
  } catch (e) {
    const status = e instanceof DocTreeError ? e.status : 0
    state.value = status === 401 || status === 403 || status === 404 ? 'off' : 'failed'
  }
}

/** the modal's create: the typed title (required there) and meta description; the new document starts with the starter outline and opens */
async function createDoc(title: string, description: string) {
  const r = await client.create(title, description)
  await seedStarterDoc(client, r.id, r.rev)
  docs.value = await client.list()
  state.value = 'ready'
  await pick(r.id)
}

function afterPrint() {
  document.documentElement.classList.remove('ws-doc-printing')
  printItems.value = []
  printSrcs.value = {}
}

/** print (D-Q2): one subtree read (no item = the whole document), the browser's print */
async function printBranch(item: DocItem | null) {
  const s = session.value
  if (!s) return
  const r = await s.run(() => client.subtree(s.doc, item?.id))
  if (!r) return
  const paths = [...new Set(r.items.flatMap((it) => [
    typeof it.attrs?.img_http_path === 'string' ? it.attrs.img_http_path : '', ...picPaths(it.body, s.doc)]).filter(Boolean))]
  printSrcs.value = Object.fromEntries(await Promise.all(paths.map(async (p) => [p, await client.imageSrc(p)])))
  printItems.value = r.items
  await nextTick()
  document.documentElement.classList.add('ws-doc-printing')
  window.addEventListener('afterprint', afterPrint, { once: true })
  window.print()
}

onMounted(() => {
  /* test hook (mock tenant only): another writer moves the doc rev on */
  if (useSpoolApi().mock) {
    const w = window as unknown as Record<string, unknown>
    w.__wsDocTreeBump = () => client.bumpForTest(docId.value)
    w.__wsDocTreeCall = (method: string, path: string, body?: Record<string, unknown>) => client.callForTest(method, path, body)
  }
  void loadDocs()
})
onBeforeUnmount(() => {
  window.removeEventListener('afterprint', afterPrint)
  document.documentElement.classList.remove('ws-doc-printing')
})

/* the Qto file tree (WorkspaceDocsLayout, t1 efde25bb) reads the list and drives the page */
defineExpose({ docs, docId, session, pick, openAt })
</script>

<style scoped>
.wsdocs-head { gap: 12px; flex-wrap: wrap; }
.wsdocs-pick select {
  font: inherit;
  padding: 4px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  max-width: 18rem;
}
.wsdocs-views { display: inline-flex; gap: 4px; }
.wsdocs-views__opt {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 4px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  background: none;
  color: var(--color-fg);
  font: inherit;
  cursor: pointer;
}
.wsdocs-views__opt[aria-checked='true'] { background: var(--color-selected); border-color: var(--color-accent); }
.wsdocs-body { display: grid; align-content: start; gap: 8px; }
/* the issues page's + (issues.vue .issues-fab, SPL-978 / SPL-992), same size and look */
.wsdocs-fab {
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
.wsdocs-fab:hover {
  background: var(--color-accent-pressed);
  box-shadow: 0 3px 6px rgba(0, 0, 0, 0.3), 0 2px 4px rgba(0, 0, 0, 0.22);
}
.wsdocs-fab:active { transform: scale(0.96); }
@media (prefers-reduced-motion: reduce) {
  .wsdocs-fab { transition: none; }
  .wsdocs-fab:active { transform: none; }
}
@media (max-width: 820px) {
  .wsdocs-fab {
    position: fixed;
    inset-inline-end: 16px;
    bottom: calc(16px + max(var(--composer-dock-h, 0px), env(safe-area-inset-bottom, 0px)));
    z-index: 15;
    width: 56px;
    height: 56px;
    box-shadow: 0 3px 5px rgba(0, 0, 0, 0.2), 0 6px 10px rgba(0, 0, 0, 0.14), 0 1px 18px rgba(0, 0, 0, 0.12);
  }
}
.wsdocs-note { padding: 12px 16px; }
.wsdocs-stale {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0 12px;
  padding: 8px 12px;
  border: 1px solid var(--color-danger);
  border-radius: var(--radius-sm);
  flex-wrap: wrap;
}
.wsdocs-error { margin: 0 12px; color: var(--color-danger); }
</style>
