<!-- SPL-974: the subtask UI of an issue, behind the plus+hierarchy icon in
     the issue pane. UiDialog owns the modal behaviour (focus trap, Escape,
     backdrop click, restored focus); this owns the form. The title field has
     data-autofocus, so the first keystroke lands there, and Enter in any field
     submits. Level is the tree's (a subtask is level 3): shown, never picked. -->
<template>
  <UiDialog :open="open" :title="t('issues.subtask_dialog_title', { key: parentKey })" size="md" @update:open="emit('update:open', $event)">
    <form class="subtask-dlg" data-test="issues-subtask-form" @submit.prevent="submit">
      <label class="subtask-dlg__field subtask-dlg__field--wide">
        <span>{{ t('issues.subtask_title') }}</span>
        <!-- SPL-985: @ opens the shared picker; Enter / Tab pick while it is open -->
        <span class="mention-anchor">
          <input
            ref="titleEl"
            v-model="title"
            data-autofocus
            data-test="issues-subtask-input"
            :placeholder="t('issues.subtask_placeholder')"
            :disabled="busy"
            @input="mp.sync"
            @click="mp.sync"
            @keyup="mp.sync"
            @blur="mp.close"
            @keydown="mp.onKeydown($event)"
          >
          <MentionList :picker="mp" />
        </span>
      </label>
      <label class="subtask-dlg__field">
        <span>{{ t('issues.field_status') }}</span>
        <select v-model="status" data-test="issues-subtask-status" :disabled="busy">
          <option v-for="s in ISSUE_STATUSES" :key="s" :value="s" :title="t(statusHintKey(s))">{{ statusLabel(s) }}</option>
        </select>
      </label>
      <label class="subtask-dlg__field">
        <span>{{ t('issues.field_priority') }}</span>
        <select v-model.number="priority" data-test="issues-subtask-priority" :disabled="busy">
          <option v-for="p in ISSUE_PRIORITIES" :key="p" :value="p">{{ p }}</option>
        </select>
      </label>
      <label class="subtask-dlg__field">
        <span>{{ t('issues.field_assignee') }}</span>
        <select v-model="assignee" data-test="issues-subtask-assignee" :disabled="busy">
          <option value="">{{ t('issues.no_assignee') }}</option>
          <option v-for="p in assignees" :key="p.id" :value="p.id">{{ p.label }}</option>
        </select>
      </label>
      <p class="subtask-dlg__field muted" data-test="issues-subtask-level">
        <span>{{ t('issues.field_level') }}</span>
        <span>3 · {{ t('issues.level.3') }}</span>
      </p>
      <p v-if="error" class="subtask-dlg__error subtask-dlg__field--wide" role="alert" data-test="issues-subtask-error">{{ t(error) }}</p>
      <!-- a real submit inside the form: Enter in any field creates -->
      <div class="subtask-dlg__actions subtask-dlg__field--wide">
        <button type="button" class="btn ghost" :disabled="busy" data-test="issues-subtask-cancel" @click="emit('update:open', false)">{{ t('common.cancel') }}</button>
        <button type="submit" class="btn" data-test="issues-subtask-add" :disabled="busy || !title.trim()">{{ busy ? t('issues.creating') : t('issues.add_subtask') }}</button>
      </div>
    </form>
  </UiDialog>
</template>

<script setup lang="ts">
import type { Issue } from '~/utils/issues.mjs'
import { ISSUE_STATUSES, PRIO_DEFAULT, normalizeIssue } from '~/utils/issues.mjs'
import { ISSUE_PRIORITIES, statusHintKey, statusLabel } from '~/utils/issues-view.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { useMentionPicker } from '~/composables/useMentionPicker'

const props = defineProps<{
  open: boolean
  parentKey: string
  assignees: { id: string, label: string }[]
}>()
const emit = defineEmits<{ 'update:open': [boolean], created: [Issue] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const title = ref('')
const titleEl = ref<HTMLInputElement | null>(null)
const mp = useMentionPicker({ text: title, el: titleEl })
const status = ref('todo')
const priority = ref<number>(PRIO_DEFAULT)
const assignee = ref('')
const busy = ref(false)
const error = ref('')

/* every opening starts clean: a dialog closed half-typed is a cancel */
watch(() => props.open, (v) => {
  if (!v) return
  title.value = ''
  status.value = 'todo'
  priority.value = PRIO_DEFAULT
  assignee.value = ''
  error.value = ''
})

function errorKey(e: { status?: number, token?: string }) {
  const code = Number(e && e.status) || 0
  const token = String((e && e.token) || '')
  if (code === 401 || token === 'view_door' || token === 'unauthenticated') return 'issues.signed_out'
  if (code === 403) return 'issues.forbidden'
  if (code === 404 || token === 'unknown_parent') return 'issues.not_found'
  return 'issues.save_failed'
}

async function submit() {
  const text = title.value.trim()
  if (!text || !props.parentKey || busy.value) return
  busy.value = true
  error.value = ''
  const body: Record<string, unknown> = { title: text, parent: props.parentKey, status: status.value, priority: priority.value }
  if (assignee.value) body.assignee = assignee.value
  try {
    const data = await withSessionRetry(api, () => api.createIssue(body))
    emit('created', normalizeIssue(data.issue))
    emit('update:open', false)
  } catch (e) {
    error.value = errorKey(e as { status?: number, token?: string })
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.mention-anchor { position: relative; display: flex; flex-direction: column; min-width: 0; }
.subtask-dlg {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
  gap: 10px 12px;
  padding: 14px;
  min-width: 0;
}
.subtask-dlg__field { display: flex; flex-direction: column; gap: 4px; min-width: 0; margin: 0; font-size: 0.8125rem; }
.subtask-dlg__field--wide { grid-column: 1 / -1; }
.subtask-dlg__field input,
.subtask-dlg__field select { min-width: 0; width: 100%; }
.subtask-dlg__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.subtask-dlg__actions { display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
</style>
