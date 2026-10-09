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
      <form v-if="state !== 'off'" class="wsdocs-new" data-test="ws-docs-new" @submit.prevent="createDoc">
        <input
          v-model="newTitle"
          type="text"
          maxlength="500"
          data-test="ws-docs-new-title"
          :placeholder="t('ws_doctree.new_doc_placeholder')"
          :aria-label="t('ws_doctree.new_doc')"
        >
        <button type="submit" class="btn" data-test="ws-docs-create" :disabled="!newTitle.trim() || creating">
          <UiIcon name="plus" :size="16" /><span>{{ t('ws_doctree.create') }}</span>
        </button>
      </form>

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
        <WorkspaceDocView v-if="view === 'doc'" :key="'doc' + mount" :session="session" :root="root" @print="printBranch" />
        <WorkspaceGridView v-else :key="'grid' + mount" :session="session" @print="printBranch" />
      </template>
    </div>
    <WorkspaceDocPrint :title="docTitle" :items="printItems" />
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, shallowRef } from 'vue'
import WorkspaceDocView from './WorkspaceDocView.vue'
import WorkspaceGridView from './WorkspaceGridView.vue'
import WorkspaceDocPrint from './WorkspaceDocPrint.vue'
import { createDocSession, DocTreeError, useDocTree, type DocHead, type DocItem, type DocSession } from './-doctree-api'
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
const newTitle = ref('')
const creating = ref(false)
const printItems = ref<DocItem[]>([])

const docId = computed(() => String(route.query.doc || '') || docs.value[0]?.id || '')
const view = computed<View>(() => (route.query.view === 'grid' ? 'grid' : 'doc'))
const docTitle = computed(() => docs.value.find((d) => d.id === docId.value)?.title || '')

async function setQuery(q: Record<string, string>) {
  await router.replace({ query: { ...route.query, ...q } })
}
function setView(v: View) {
  void setQuery({ view: v })
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

async function createDoc() {
  const title = newTitle.value.trim()
  if (!title) return
  creating.value = true
  try {
    const r = await client.create(title)
    newTitle.value = ''
    docs.value = await client.list()
    await pick(r.id)
  } catch {
    state.value = 'failed'
  } finally {
    creating.value = false
  }
}

function afterPrint() {
  document.documentElement.classList.remove('ws-doc-printing')
  printItems.value = []
}

/** print (D-Q2): one subtree read (no item = the whole document), the browser's print */
async function printBranch(item: DocItem | null) {
  const s = session.value
  if (!s) return
  const r = await s.run(() => client.subtree(s.doc, item?.id))
  if (!r) return
  printItems.value = r.items
  await nextTick()
  document.documentElement.classList.add('ws-doc-printing')
  window.addEventListener('afterprint', afterPrint, { once: true })
  window.print()
}

onMounted(() => {
  /* test hook (mock tenant only): another writer moves the doc rev on */
  if (useSpoolApi().mock) {
    (window as unknown as Record<string, unknown>).__wsDocTreeBump = () => client.bumpForTest(docId.value)
  }
  void loadDocs()
})
onBeforeUnmount(() => {
  window.removeEventListener('afterprint', afterPrint)
  document.documentElement.classList.remove('ws-doc-printing')
})
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
.wsdocs-new { display: flex; gap: 8px; padding: 8px 12px 0; flex-wrap: wrap; }
.wsdocs-new input {
  flex: 1 1 14rem;
  max-width: 24rem;
  font: inherit;
  padding: 4px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
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
