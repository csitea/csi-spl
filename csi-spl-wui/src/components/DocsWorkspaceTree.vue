<!-- spec 075 T010 (owner, prd t1 9f0d751c): the Workspace docs section of
     the Docs explorer, under the repo tree. The workspace's own docs
     (GET /v1/workspace/docs/tree.json), each opening at /docs/ws/<path>.
     New doc asks for a path and opens the editor on it; nothing is written
     until Save. Shows nothing while the hub has no workspace docs routes
     (404 / 403: off). A reader who cannot write sees no New doc. -->
<template>
  <section v-if="treeState !== 'off'" class="ws-tree" data-test="ws-docs" :data-state="treeState" aria-labelledby="ws-docs-h">
    <div class="ws-tree__head">
      <h3 id="ws-docs-h" class="ws-tree__title">{{ t('docs.ws.title') }}</h3>
      <button
        v-if="canWrite && treeState === 'ready'"
        type="button"
        class="ws-tree__new"
        data-test="ws-docs-new"
        :aria-expanded="adding ? 'true' : 'false'"
        :title="t('docs.ws.new')"
        :aria-label="t('docs.ws.new')"
        @click="adding = !adding"
      >
        <UiIcon name="plus" :size="16" />
      </button>
    </div>
    <form v-if="adding" class="ws-tree__form" data-test="ws-docs-new-form" @submit.prevent="create">
      <label class="ws-tree__label" for="ws-docs-new-path">{{ t('docs.ws.new_path') }}</label>
      <input
        id="ws-docs-new-path"
        ref="input"
        v-model="draft"
        class="ws-tree__input"
        data-test="ws-docs-new-path"
        :placeholder="t('docs.ws.new_placeholder')"
        autocomplete="off"
        spellcheck="false"
        @keydown.esc.prevent="adding = false"
      >
      <p v-if="bad" class="ws-tree__bad" role="alert" data-test="ws-docs-new-bad">{{ t('docs.ws.bad_path') }}</p>
      <div class="ws-tree__actions">
        <button type="button" class="btn ghost" data-test="ws-docs-new-cancel" @click="adding = false">{{ t('common.cancel') }}</button>
        <button type="submit" class="btn" data-test="ws-docs-new-create">{{ t('docs.ws.create') }}</button>
      </div>
    </form>
    <p v-if="treeState === 'loading'" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="treeState === 'failed'" class="muted" role="alert">{{ t('docs.load_failed') }}</p>
    <p v-else-if="!rows.length" class="muted" data-test="ws-docs-empty">{{ t('docs.ws.empty') }}</p>
    <ul v-else role="tree" class="docs-tree__list" :aria-labelledby="'ws-docs-h'">
      <li
        v-for="row in rows"
        :key="row.kind + ':' + row.path"
        role="treeitem"
        :aria-level="row.depth + 1"
        :aria-expanded="row.kind === 'dir' ? (row.open ? 'true' : 'false') : undefined"
        :aria-selected="row.kind === 'file' ? (row.path === active ? 'true' : 'false') : undefined"
        class="docs-tree__row"
        :style="{ '--depth': row.depth }"
      >
        <button
          v-if="row.kind === 'dir'"
          type="button"
          class="docs-tree__item docs-tree__dir"
          data-test="ws-docs-dir"
          :data-path="row.path"
          @click="toggle(row.path)"
        >
          <UiIcon :name="row.open ? 'chevron-down' : 'chevron-right'" :size="14" class="docs-tree__chev" />
          <UiIcon name="folder" :size="16" />
          <span class="docs-tree__name">{{ row.name }}</span>
        </button>
        <NuxtLink
          v-else
          :to="localePath(wsDocsRoute(row.path))"
          class="docs-tree__item docs-tree__file"
          :class="{ 'docs-tree__file--active': row.path === active }"
          :aria-current="row.path === active ? 'page' : undefined"
          :title="row.title"
          data-test="ws-docs-file"
          :data-path="row.path"
        >
          <UiIcon name="file-text" :size="16" />
          <span class="docs-tree__name">{{ row.name }}</span>
        </NuxtLink>
      </li>
    </ul>
  </section>
</template>

<script setup lang="ts">
import { buildDocsTree, docsAncestors, visibleDocsRows } from '~/utils/docs.mjs'
import { canWriteDocs, newDocPath, wsDocsRoute } from '~/utils/ws-docs.mjs'
import { useWorkspaceDocs } from '~/composables/useWorkspaceDocs'
import { useAccessStore } from '~/stores/access'

const props = defineProps<{ active: string }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const access = useAccessStore()
const { files, treeState, loadTree } = useWorkspaceDocs()
const canWrite = computed(() => canWriteDocs(access.me))

const open = ref<Set<string>>(new Set())
const tree = computed(() => buildDocsTree(files.value))
const rows = computed(() => visibleDocsRows(tree.value, open.value))
function toggle(path: string) {
  const s = new Set(open.value)
  if (s.has(path)) s.delete(path)
  else s.add(path)
  open.value = s
}
watch(() => props.active, (p) => {
  const missing = docsAncestors(p).filter((a) => !open.value.has(a))
  if (missing.length) open.value = new Set([...open.value, ...missing])
}, { immediate: true })

const adding = ref(false)
const draft = ref('')
const bad = ref(false)
const input = ref<HTMLInputElement | null>(null)
watch(adding, (on) => {
  draft.value = ''
  bad.value = false
  if (on) void nextTick(() => input.value?.focus())
})
async function create() {
  const path = newDocPath(draft.value)
  if (!path) { bad.value = true; return }
  adding.value = false
  await router.push({ path: localePath(wsDocsRoute(path)), query: { edit: '1' } })
}

onMounted(() => { void loadTree(); if (!access.me) void access.load() })
</script>

<style scoped>
.ws-tree { margin-top: 16px; padding-top: 12px; border-top: 1px solid var(--color-border); text-align: start; }
.ws-tree__head { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 4px; }
.ws-tree__title { margin: 0; padding-inline-start: 8px; font-size: 0.8125rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--color-muted); }
.ws-tree__new {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 32px;
  min-height: 32px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 8px);
  background: none;
  color: var(--color-fg);
  cursor: pointer;
}
.ws-tree__new:hover { background: var(--color-bg-2); }
.ws-tree__form { display: flex; flex-direction: column; gap: 6px; padding: 8px; margin-bottom: 6px; border: 1px solid var(--color-border); border-radius: var(--radius-sm, 8px); background: var(--color-bg-2); }
.ws-tree__label { font-size: 0.8125rem; }
.ws-tree__input { min-height: 36px; padding: 4px 8px; border: 1px solid var(--color-border); background: var(--color-bg); color: var(--color-fg); font: inherit; min-width: 0; }
.ws-tree__bad { margin: 0; color: var(--color-danger); font-size: 0.8125rem; }
.ws-tree__actions { display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.ws-tree .muted { padding-inline-start: 8px; }
/* the rows look like the repo tree's (docs.vue owns those rules, scoped) */
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
  color: var(--color-fg);
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
:global([dir="rtl"]) .ws-tree .docs-tree__chev[data-icon="chevron-right"] { transform: scaleX(-1); }
@media (max-width: 820px) {
  .docs-tree__item, .ws-tree__new, .ws-tree__input { min-height: 44px; }
  .ws-tree__new { min-width: 44px; }
}
</style>
