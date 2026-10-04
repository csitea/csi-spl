<!-- spec 075 T010 (owner, prd t1 9f0d751c: "simple editing functionality"
     first, a WYSIWYG later): one workspace doc at /docs/ws/<path>, rendered by
     MarkdownBlock as the repo docs are. Edit swaps in a plain markdown
     textarea with a live preview beside it (stacked on a phone); Save PUTs
     the text, Cancel drops it. Last write wins: the hub keeps each overwritten
     version in .history/, so there is no lock and no conflict dialog.
     ?edit=1 opens the editor, on a new doc too (New doc in the tree): a doc
     that does not exist yet is created by its first Save. Delete asks first.
     Edit and Delete show only to a reader who can write (canWriteDocs); the
     hub's docs.write check is the control. -->
<template>
  <div class="ws-doc" data-test="ws-doc" :data-state="state" :data-mode="mode">
    <div class="ws-doc__bar">
      <p class="docs-content__path muted" data-test="docs-path">
        <span class="ws-doc__badge">{{ t('docs.ws.badge') }}</span>
        <span>{{ path }}</span>
      </p>
      <div v-if="canWrite && mode === 'view' && state === 'ready'" class="ws-doc__tools">
        <button type="button" class="btn ghost" data-test="ws-doc-edit" @click="startEdit">
          <UiIcon name="pencil" :size="16" />
          <span>{{ t('docs.ws.edit') }}</span>
        </button>
        <button type="button" class="btn ghost danger" data-test="ws-doc-delete" @click="confirmOpen = true">
          <UiIcon name="trash" :size="16" />
          <span>{{ t('docs.ws.delete') }}</span>
        </button>
      </div>
    </div>
    <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'missing' && mode === 'view'" class="muted" role="alert" data-test="docs-missing">{{ t('docs.not_found') }}</p>
    <p v-else-if="state === 'failed'" class="muted" role="alert">{{ t('docs.load_failed') }}</p>
    <form v-else-if="mode === 'edit'" class="ws-doc__editor" data-test="ws-doc-editor" @submit.prevent="save">
      <div class="ws-doc__panes">
        <div class="ws-doc__pane">
          <label class="ws-doc__label" for="ws-doc-src">{{ t('docs.ws.source') }}</label>
          <textarea
            id="ws-doc-src"
            v-model="draft"
            class="ws-doc__src"
            data-test="ws-doc-source"
            dir="auto"
            spellcheck="true"
            @keydown.ctrl.enter.prevent="save"
            @keydown.meta.enter.prevent="save"
            @keydown.esc.prevent="cancel"
          />
        </div>
        <div class="ws-doc__pane">
          <p class="ws-doc__label" id="ws-doc-preview-h">{{ t('docs.ws.preview') }}</p>
          <div class="ws-doc__preview" data-test="ws-doc-preview" aria-labelledby="ws-doc-preview-h" aria-live="polite">
            <MarkdownBlock :text="preview" bare />
          </div>
        </div>
      </div>
      <p v-if="error" class="ws-doc__error" role="alert" data-test="ws-doc-error">{{ error }}</p>
      <div class="ws-doc__actions">
        <button type="button" class="btn ghost" data-test="ws-doc-cancel" :disabled="busy" @click="cancel">{{ t('common.cancel') }}</button>
        <button type="submit" class="btn" data-test="ws-doc-save" :disabled="busy">{{ busy ? t('docs.ws.saving') : t('docs.ws.save') }}</button>
      </div>
    </form>
    <MarkdownBlock v-else :text="rendered" bare />
    <UiConfirm
      v-model:open="confirmOpen"
      :title="t('docs.ws.delete_title')"
      testid="ws-doc-delete-confirm"
      :confirm-label="t('docs.ws.delete')"
      :busy-label="t('docs.ws.deleting')"
      :busy="busy"
      :error="error"
      @confirm="del"
    >
      <p>{{ t('docs.ws.delete_body', { path }) }}</p>
    </UiConfirm>
  </div>
</template>

<script setup lang="ts">
import MarkdownBlock from '~/components/MarkdownBlock.vue'
import { rewriteDocsLinks } from '~/utils/docs.mjs'
import { canWriteDocs, newDocBody, wsDocsRoute } from '~/utils/ws-docs.mjs'
import { useWorkspaceDocs } from '~/composables/useWorkspaceDocs'
import { useAccessStore } from '~/stores/access'

const props = defineProps<{ path: string }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const current = useRoute()
const access = useAccessStore()
const docs = useWorkspaceDocs()
const canWrite = computed(() => canWriteDocs(access.me))

const text = ref('')
const draft = ref('')
const state = ref<'loading' | 'ready' | 'missing' | 'failed'>('loading')
const mode = ref<'view' | 'edit'>('view')
const busy = ref(false)
const error = ref('')
const confirmOpen = ref(false)

const route = (p: string) => localePath(wsDocsRoute(p))
const rendered = computed(() => rewriteDocsLinks(text.value, props.path, route))
/* the preview follows the typing, a beat behind so a long doc does not
   re-render on every key */
const preview = ref('')
let previewTimer: ReturnType<typeof setTimeout> | undefined
watch(draft, (v) => {
  clearTimeout(previewTimer)
  previewTimer = setTimeout(() => { preview.value = rewriteDocsLinks(v, props.path, route) }, 150)
})
onBeforeUnmount(() => clearTimeout(previewTimer))

const wantsEdit = () => current.query.edit === '1'

function startEdit() {
  draft.value = state.value === 'ready' ? text.value : newDocBody(props.path)
  preview.value = rewriteDocsLinks(draft.value, props.path, route)
  error.value = ''
  mode.value = 'edit'
}

function dropEditQuery() {
  if (!wantsEdit()) return
  const q = { ...current.query }
  delete q.edit
  void router.replace({ query: q })
}

async function save() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await docs.write(props.path, draft.value)
    text.value = draft.value
    state.value = 'ready'
    mode.value = 'view'
    dropEditQuery()
    void docs.loadTree()
  } catch (e) {
    error.value = (e as { status?: number }).status === 403 ? t('docs.ws.forbidden') : t('docs.ws.save_failed')
  } finally {
    busy.value = false
  }
}

function cancel() {
  error.value = ''
  mode.value = 'view'
  dropEditQuery()
  /* a new doc that was never saved: nothing to show, back to Docs */
  if (state.value === 'missing') void router.push(localePath('/docs'))
}

async function del() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await docs.remove(props.path)
    confirmOpen.value = false
    void docs.loadTree()
    await router.push(localePath('/docs'))
  } catch (e) {
    error.value = (e as { status?: number }).status === 403 ? t('docs.ws.forbidden') : t('docs.ws.delete_failed')
  } finally {
    busy.value = false
  }
}

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  mode.value = 'view'
  error.value = ''
  try {
    const md = await docs.read(props.path)
    if (mine !== seq) return
    if (md === null) state.value = 'missing'
    else { text.value = md; state.value = 'ready' }
    if (wantsEdit() && canWrite.value) startEdit()
  } catch {
    if (mine === seq) state.value = 'failed'
  }
}

/* /v1/view/me can answer after the doc: a reader it shows cannot write
   leaves the editor */
watch(canWrite, (on) => { if (!on && mode.value === 'edit') { mode.value = 'view'; confirmOpen.value = false } })
watch(() => props.path, () => { if (import.meta.client) void load() })
onMounted(() => { void load() })
</script>

<style scoped>
.ws-doc { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.ws-doc__bar { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.ws-doc__bar .docs-content__path { margin: 0; font-size: 0.8125rem; overflow-wrap: anywhere; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.ws-doc__badge {
  padding: 1px 6px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  font-size: 0.75rem;
  color: var(--color-fg);
  background: var(--color-bg-2);
}
.ws-doc__tools, .ws-doc__actions { display: flex; gap: 8px; flex-wrap: wrap; }
.ws-doc__tools .btn { display: inline-flex; align-items: center; gap: 6px; }
.ws-doc__actions { justify-content: flex-end; }
.ws-doc__editor { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.ws-doc__panes { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 12px; min-width: 0; }
.ws-doc__pane { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.ws-doc__label { margin: 0; font-size: 0.8125rem; color: var(--color-muted); }
.ws-doc__src {
  min-height: 420px;
  width: 100%;
  box-sizing: border-box;
  padding: 10px;
  border: 1px solid var(--color-border);
  background: var(--color-bg);
  color: var(--color-fg);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.875rem;
  line-height: 1.5;
  resize: vertical;
}
.ws-doc__preview {
  min-height: 420px;
  padding: 10px;
  border: 1px dashed var(--color-border);
  border-radius: var(--radius-sm, 8px);
  overflow: auto;
  min-width: 0;
}
.ws-doc__error { margin: 0; color: var(--color-danger); }
@media (max-width: 820px) {
  .ws-doc__panes { grid-template-columns: minmax(0, 1fr); }
  .ws-doc__src { min-height: 240px; }
  .ws-doc__preview { min-height: 120px; }
  .ws-doc .btn { min-height: 44px; }
  /* the composer dock covers the bottom of a phone: Save and Cancel lead */
  .ws-doc__actions { order: -1; }
}
</style>
