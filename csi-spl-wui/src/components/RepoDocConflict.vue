<!-- spec 075 repo-edit §8 (T12): the conflict view. Master changed the same
     lines as the member's edit, so nothing was pushed; the overlay keeps
     their text. Side by side: theirs (master now, read only) and mine (the
     saved edit, editable, stacked on a phone). "Save again" saves the
     resolved text with base = master's head blob (GET .../conflict
     head_blob), which supersedes the conflict; the author notice and the
     save errors are the editor's (repoEdit store). A lazy chunk of the docs
     page (/docs/<path>?conflict=<edit id>). -->
<template>
  <form class="repo-conflict" data-test="repo-conflict" :data-edit="id" @submit.prevent="save">
    <p v-if="!store.conflict && !message" class="muted">{{ t('common.loading') }}</p>
    <template v-if="store.conflict">
      <p class="repo-conflict__lead" role="status">{{ t('docs.repoEdit.conflict.lead') }}</p>
      <p v-if="store.conflict.reason" class="muted repo-conflict__reason" data-test="repo-conflict-reason">{{ store.conflict.reason }}</p>
      <div class="repo-conflict__panes">
        <div class="repo-conflict__pane">
          <label class="repo-conflict__label" for="repo-conflict-theirs">{{ t('docs.repoEdit.conflict.theirs') }}</label>
          <textarea id="repo-conflict-theirs" class="repo-conflict__src" data-test="repo-conflict-theirs" :value="store.conflict.theirs" readonly dir="auto" />
        </div>
        <div class="repo-conflict__pane">
          <label class="repo-conflict__label" for="repo-conflict-mine">{{ t('docs.repoEdit.conflict.mine') }}</label>
          <textarea id="repo-conflict-mine" v-model="draft" class="repo-conflict__src" data-test="repo-conflict-mine" dir="auto" spellcheck="true" @keydown.ctrl.enter.prevent="save" @keydown.meta.enter.prevent="save" />
        </div>
      </div>
    </template>
    <p v-if="message && !store.notice" class="repo-conflict__error" role="alert" data-test="repo-conflict-error">{{ message }}</p>
    <div class="repo-conflict__actions">
      <button type="button" class="btn ghost" data-test="repo-conflict-cancel" :disabled="store.busy" @click="emit('cancel')">{{ t('common.cancel') }}</button>
      <button v-if="store.conflict" type="submit" class="btn" data-test="repo-conflict-save" :disabled="store.busy">{{ store.busy ? t('docs.ws.saving') : t('docs.repoEdit.conflict.save') }}</button>
    </div>
    <RepoDocAuthorNotice :identity="store.notice" :busy="store.busy" :error="message" @cancel="store.dismissNotice()" @confirm="consent" />
  </form>
</template>

<script setup lang="ts">
import RepoDocAuthorNotice from '~/components/RepoDocAuthorNotice.vue'
import { useRepoEditStore, type RepoEditSaved } from '~/stores/repoEdit'

const props = defineProps<{ id: string }>()
const emit = defineEmits<{ saved: [text: string, edit: RepoEditSaved], cancel: [] }>()
const { t } = useI18n({ useScope: 'global' })
const store = useRepoEditStore()

const draft = ref('')
const message = computed(() => (store.error ? t(store.error.key, store.error.params) : ''))

async function open() {
  draft.value = ''
  if (await store.openConflict(props.id)) draft.value = store.conflict?.mine ?? ''
}
function done(edit: RepoEditSaved | null) {
  if (!edit) return
  store.conflict = null
  emit('saved', draft.value, edit)
}
async function save() {
  done(await store.resolve(draft.value))
}
async function consent() {
  done(await store.consent())
}
watch(() => props.id, () => void open())
onMounted(() => void open())
onBeforeUnmount(() => {
  store.dismissNotice()
  store.conflict = null
  store.error = null
})
</script>

<style scoped>
.repo-conflict { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.repo-conflict__lead, .repo-conflict__reason { margin: 0; overflow-wrap: anywhere; }
.repo-conflict__panes { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 12px; min-width: 0; }
.repo-conflict__pane { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.repo-conflict__label { margin: 0; font-size: 0.8125rem; color: var(--color-muted); }
.repo-conflict__src {
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
.repo-conflict__src[readonly] { border-style: dashed; color: var(--color-muted); }
.repo-conflict__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.repo-conflict__actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
@media (max-width: 820px) {
  .repo-conflict__panes { grid-template-columns: minmax(0, 1fr); }
  .repo-conflict__src { min-height: 200px; }
  .repo-conflict .btn { min-height: 44px; }
}
</style>
