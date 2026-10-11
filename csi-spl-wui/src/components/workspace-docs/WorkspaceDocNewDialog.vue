<!-- A new Qto document (owner, t1 889e15d9 msg 0a7a9702): the page's + opens
     this modal, as the issues page's + does. Title is required; the meta
     description is a short plain-text summary stored with the document (rdb
     0164) for the omnibox search later. UiDialog owns the modal behaviour
     (focus trap, Escape, backdrop click, restored focus); this owns the form.
     Every opening starts clean: a dialog closed half-typed is a cancel.
     With `folder` it is the explorer's + New folder (owner t1 3b8891e0):
     one name field, no description; a sibling of the same name (the hub's
     409 name_taken) says so. -->
<template>
  <UiDialog :open="open" :title="t(folder ? 'ws_doctree.new_folder' : 'ws_doctree.new_doc')" size="md" @update:open="emit('update:open', $event)">
    <form class="wsdoc-new-dlg" :data-test="folder ? 'qto-new-folder-form' : 'ws-docs-new-form'" @submit.prevent="submit">
      <label class="wsdoc-new-dlg__field">
        <span>{{ t(folder ? 'ws_doctree.folder_name' : 'ws_doctree.col_title') }}</span>
        <input
          v-model="title"
          type="text"
          :maxlength="folder ? 255 : 500"
          required
          data-autofocus
          :data-test="folder ? 'qto-new-folder-name' : 'ws-docs-new-title'"
          :placeholder="t(folder ? 'ws_doctree.new_folder_placeholder' : 'ws_doctree.new_doc_placeholder')"
          :disabled="busy"
        >
      </label>
      <label v-if="!folder" class="wsdoc-new-dlg__field">
        <span>{{ t('ws_doctree.meta_description') }}</span>
        <textarea
          v-model="description"
          rows="3"
          maxlength="1000"
          data-test="ws-docs-new-desc"
          :placeholder="t('ws_doctree.meta_description_placeholder')"
          :disabled="busy"
          @keydown.enter.exact.prevent="submit"
        />
      </label>
      <p v-if="error" class="wsdoc-new-dlg__error" role="alert" data-test="ws-docs-new-error">{{ t(error) }}</p>
      <div class="wsdoc-new-dlg__actions">
        <button type="button" class="btn ghost" :disabled="busy" data-test="ws-docs-new-cancel" @click="emit('update:open', false)">{{ t('common.cancel') }}</button>
        <button type="submit" class="btn" :data-test="folder ? 'qto-new-folder-create' : 'ws-docs-create'" :disabled="busy || !title.trim()">{{ t('ws_doctree.create') }}</button>
      </div>
    </form>
  </UiDialog>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue'
import UiDialog from '~/components/UiDialog.vue'

const props = defineProps<{
  open: boolean
  /** the explorer's + New folder: a name only */
  folder?: boolean
  /** makes the document; a throw shows the error and keeps the dialog open */
  create: (title: string, description: string) => Promise<void>
}>()
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t } = useI18n({ useScope: 'global' })

const title = ref('')
const description = ref('')
const busy = ref(false)
const error = ref('')

watch(() => props.open, (v) => {
  if (!v) return
  title.value = ''
  description.value = ''
  error.value = ''
})

async function submit() {
  const name = title.value.trim()
  if (!name || busy.value) return
  busy.value = true
  error.value = ''
  try {
    await props.create(name, description.value.trim())
    emit('update:open', false)
  } catch (e) {
    error.value = (e as { status?: number })?.status === 409 ? 'ws_doctree.err_name_taken' : 'ws_doctree.err_failed'
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.wsdoc-new-dlg { display: grid; gap: 10px; padding: 14px; min-width: 0; }
.wsdoc-new-dlg__field { display: flex; flex-direction: column; gap: 4px; min-width: 0; margin: 0; font-size: 0.8125rem; }
.wsdoc-new-dlg__field input,
.wsdoc-new-dlg__field textarea { min-width: 0; width: 100%; font: inherit; resize: vertical; }
.wsdoc-new-dlg__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.wsdoc-new-dlg__actions { display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
</style>
