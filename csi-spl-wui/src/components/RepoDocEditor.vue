<!-- spec 075 repo-edit T11: the editor of an editable repo doc, a lazy
     chunk the docs page mounts on Edit. A plain markdown textarea with a
     live preview beside it (stacked on a phone), as the workspace docs
     editor. Save PUTs the text with If-Match = the blob the doc was opened
     at (the repoEdit store); the first save under an identity shows the
     author notice (RepoDocAuthorNotice) and saves once the member consents.
     A refused save (409/413/422/429/403) says why and keeps the draft. -->
<template>
  <form class="repo-edit" data-test="repo-edit" :data-path="path" @submit.prevent="save">
    <div class="repo-edit__panes">
      <div class="repo-edit__pane">
        <label class="repo-edit__label" for="repo-edit-src">{{ t('docs.ws.source') }}</label>
        <textarea
          id="repo-edit-src"
          v-model="draft"
          class="repo-edit__src"
          data-test="repo-edit-source"
          dir="auto"
          spellcheck="true"
          @keydown.ctrl.enter.prevent="save"
          @keydown.meta.enter.prevent="save"
          @keydown.esc.prevent="cancel"
        />
      </div>
      <div class="repo-edit__pane">
        <p id="repo-edit-preview-h" class="repo-edit__label">{{ t('docs.ws.preview') }}</p>
        <div class="repo-edit__preview" data-test="repo-edit-preview" aria-labelledby="repo-edit-preview-h" aria-live="polite">
          <MarkdownBlock :text="preview" bare />
        </div>
      </div>
    </div>
    <p v-if="message && !store.notice" class="repo-edit__error" role="alert" data-test="repo-edit-error">{{ message }}</p>
    <div class="repo-edit__actions">
      <button type="button" class="btn ghost" data-test="repo-edit-cancel" :disabled="store.busy" @click="cancel">{{ t('common.cancel') }}</button>
      <button type="submit" class="btn" data-test="repo-edit-save" :disabled="store.busy">{{ store.busy ? t('docs.ws.saving') : t('docs.ws.save') }}</button>
    </div>
    <RepoDocAuthorNotice :identity="store.notice" :busy="store.busy" :error="message" @cancel="store.dismissNotice()" @confirm="consent" />
  </form>
</template>

<script setup lang="ts">
import MarkdownBlock from '~/components/MarkdownBlock.vue'
import RepoDocAuthorNotice from '~/components/RepoDocAuthorNotice.vue'
import { rewriteDocsLinks } from '~/utils/docs.mjs'
import { useRepoEditStore, type RepoEditSaved } from '~/stores/repoEdit'

const props = defineProps<{ path: string, text: string, base: string }>()
const emit = defineEmits<{ saved: [text: string, edit: RepoEditSaved], cancel: [] }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const store = useRepoEditStore()

const draft = ref(props.text)
const route = (p: string) => localePath('/docs/' + p)
const message = computed(() => store.error ? t(store.error.key, store.error.params) : '')
/* the preview follows the typing, a beat behind */
const preview = ref(rewriteDocsLinks(props.text, props.path, route))
let timer: ReturnType<typeof setTimeout> | undefined
watch(draft, (v) => {
  clearTimeout(timer)
  timer = setTimeout(() => { preview.value = rewriteDocsLinks(v, props.path, route) }, 150)
})
onBeforeUnmount(() => {
  clearTimeout(timer)
  store.dismissNotice()
  store.error = null
})

function done(edit: RepoEditSaved | null) {
  if (edit) emit('saved', draft.value, edit)
}
async function save() {
  done(await store.save(props.path, draft.value, props.base))
}
async function consent() {
  done(await store.consent())
}
function cancel() {
  if (store.busy) return
  emit('cancel')
}
</script>

<style scoped>
.repo-edit { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.repo-edit__panes { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 12px; min-width: 0; }
.repo-edit__pane { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.repo-edit__label { margin: 0; font-size: 0.8125rem; color: var(--color-muted); }
.repo-edit__src {
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
.repo-edit__preview {
  min-height: 420px;
  padding: 10px;
  border: 1px dashed var(--color-border);
  border-radius: var(--radius-sm, 8px);
  overflow: auto;
  min-width: 0;
}
.repo-edit__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.repo-edit__actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
@media (max-width: 820px) {
  .repo-edit__panes { grid-template-columns: minmax(0, 1fr); }
  .repo-edit__src { min-height: 240px; }
  .repo-edit__preview { min-height: 120px; }
  .repo-edit .btn { min-height: 44px; }
  .repo-edit__actions { order: -1; }
}
</style>
