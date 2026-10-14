<!-- SPL-1593 (rdb 0194): the discussions an issue links to, at least one.
     Owner HUM-10 (t1 fcf09921, msg 9a8e4764): "We must create a special part
     of the UI somewhere in the bottom panel where one could click on that one
     or more discussions." It sits in the issue's bottom panel, above the
     comment box, on a phone and on a desktop. Each one opens its topic; an
     archived one still opens (msg 28b479fd); a deleted one opens the "no
     longer exists" note in place (no route of its own: a route record ships
     in the initial JS, ci_initial_gzip_kb). Live mode (issueKey) reads and changes the hub's
     links; draft mode (v-model, a new issue) only collects them. -->
<template>
  <section class="issue-discussions" data-test="issue-discussions" :aria-label="t('issue_discussions.title')">
    <h3 class="issue-discussions__h">{{ t('issue_discussions.title') }}</h3>
    <p v-if="draft && !items.length" class="muted issue-discussions__hint" data-test="issue-discussions-hint">{{ t('issue_discussions.hint_draft') }}</p>
    <ul v-if="items.length" class="issue-discussions__list">
      <li
        v-for="d in items"
        :key="d.task_id"
        class="issue-discussions__row"
        data-test="issue-discussion"
        :data-task="d.task_id"
        :data-state="d.state"
      >
        <UiIcon name="messages" :size="14" class="issue-discussions__icon" />
        <button
          v-if="!draft && d.state === 'gone'"
          type="button"
          class="issue-discussions__link issue-discussions__gone-btn"
          data-test="issue-discussion-link"
          :aria-expanded="gone === d.task_id"
          @click="gone = gone === d.task_id ? '' : d.task_id"
        >{{ labelOf(d) }}</button>
        <NuxtLink
          v-else-if="!draft"
          class="issue-discussions__link"
          data-test="issue-discussion-link"
          :to="localePath(discussionPath(d))"
        >{{ labelOf(d) }}</NuxtLink>
        <span v-else class="issue-discussions__link" data-test="issue-discussion-draft">{{ labelOf(d) }}</span>
        <span v-if="d.state === 'archived'" class="issue-discussions__badge" data-test="issue-discussion-archived">{{ t('issue_discussions.archived') }}</span>
        <span v-else-if="d.state === 'gone'" class="issue-discussions__badge" data-test="issue-discussion-gone">{{ t('issue_discussions.gone') }}</span>
        <button
          v-if="draft || items.length > 1"
          type="button"
          class="icon-btn issue-discussions__x"
          data-test="issue-discussion-remove"
          :disabled="busy"
          :aria-label="t('issue_discussions.remove', { name: labelOf(d) })"
          :title="t('issue_discussions.remove', { name: labelOf(d) })"
          @click="remove(d.task_id)"
        ><UiIcon name="x" :size="14" /></button>
      </li>
    </ul>
    <div v-if="gone" class="issue-discussions__gone" role="status" data-test="discussion-gone">
      <strong>{{ t('discussion_gone.title') }}</strong>
      <p>{{ t('discussion_gone.body') }}</p>
      <p class="muted" data-test="discussion-gone-topic">{{ t('discussion_gone.topic', { id: gone }) }}</p>
      <button type="button" class="btn" data-test="discussion-gone-close" @click="gone = ''">{{ t('common.close') }}</button>
    </div>
    <form class="issue-discussions__add" data-test="issue-discussion-add" @submit.prevent="add">
      <input
        v-model="text"
        class="issue-discussions__input"
        data-test="issue-discussion-input"
        :placeholder="t('issue_discussions.add_placeholder')"
        :aria-label="t('issue_discussions.add_placeholder')"
        :disabled="busy"
        @keydown.stop
      >
      <button type="submit" class="btn" data-test="issue-discussion-add-btn" :disabled="busy || !text.trim()">{{ t('issue_discussions.add') }}</button>
    </form>
    <p v-if="error" class="issues-error" role="alert" data-test="issue-discussion-error">{{ t(error) }}</p>
  </section>
</template>

<script setup lang="ts">
import type { IssueDiscussion } from '~/utils/issue-discussions.mjs'
import { discussionErrorKey, discussionPath, discussionRef, normalizeDiscussions, shortTopic } from '~/utils/issue-discussions.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

const props = defineProps<{
  /** live mode: the issue's key, SPL-12 */
  issueKey?: string
  /** live mode: changes when the issue did, and the links are read again */
  stamp?: string
  /** draft mode: the refs a new issue will link (topic ids, short ids) */
  modelValue?: string[]
  /** draft mode: the workspace's default discussion, named as such */
  defaultDiscussion?: string
}>()
const emit = defineEmits<{
  'update:modelValue': [value: string[]]
  /** live mode: the issue as the hub answered a link or an unlink */
  changed: [issue: unknown]
}>()

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const api = useSpoolApi()
const draft = computed(() => !props.issueKey)
const linked = ref<IssueDiscussion[]>([])
const text = ref('')
const busy = ref(false)
const error = ref('')
/** the deleted discussion whose "no longer exists" note is open */
const gone = ref('')

const items = computed<IssueDiscussion[]>(() => draft.value
  ? (props.modelValue || []).map((id) => ({ task_id: id, state: 'live', title: '', channel: '', linked_by: '', linked_at: '' }))
  : linked.value)

function labelOf(d: IssueDiscussion): string {
  if (draft.value && d.task_id === props.defaultDiscussion) return t('issue_discussions.default')
  return d.title || t('issue_discussions.untitled', { id: shortTopic(d.task_id) })
}

let seq = 0
async function load() {
  const key = props.issueKey
  if (!key) return
  const mine = ++seq
  try {
    const data = await withSessionRetry(api, () => api.getIssue(key))
    if (mine === seq) linked.value = normalizeDiscussions(data?.issue?.discussions)
  } catch {
    if (mine === seq) error.value = 'issue_discussions.error_failed'
  }
}
watch(() => [props.issueKey, props.stamp], load, { immediate: true })

async function add() {
  error.value = ''
  const ref = discussionRef(text.value)
  if (!ref) {
    error.value = 'issue_discussions.error_bad'
    return
  }
  if (draft.value) {
    const now = props.modelValue || []
    if (!now.includes(ref)) emit('update:modelValue', [...now, ref])
    text.value = ''
    return
  }
  await change(() => api.linkIssueDiscussion(String(props.issueKey), ref))
}

async function remove(taskId: string) {
  error.value = ''
  if (draft.value) {
    emit('update:modelValue', (props.modelValue || []).filter((id) => id !== taskId))
    return
  }
  await change(() => api.unlinkIssueDiscussion(String(props.issueKey), taskId))
}

async function change(call: () => Promise<{ issue: unknown }>) {
  if (busy.value) return
  busy.value = true
  try {
    const data = await withSessionRetry(api, call)
    linked.value = normalizeDiscussions((data?.issue as { discussions?: unknown })?.discussions)
    text.value = ''
    emit('changed', data?.issue)
  } catch (e) {
    error.value = discussionErrorKey(e as { status?: number, token?: string })
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.issue-discussions {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin: 8px 0;
  padding: 8px 0;
  border-top: 1px solid var(--color-border);
}
.issue-discussions__h {
  margin: 0;
  font-size: 0.8rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  color: var(--color-muted);
}
.issue-discussions__hint {
  margin: 0;
  font-size: 0.85rem;
}
.issue-discussions__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.issue-discussions__row {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}
.issue-discussions__icon {
  flex: none;
  color: var(--color-muted);
}
.issue-discussions__link {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.issue-discussions__row[data-state="gone"] .issue-discussions__link {
  text-decoration: line-through;
  color: var(--color-muted);
}
.issue-discussions__gone-btn {
  padding: 0;
  border: 0;
  background: none;
  font: inherit;
  text-align: left;
  cursor: pointer;
}
.issue-discussions__gone {
  padding: 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
}
.issue-discussions__gone p {
  margin: 4px 0;
}
.issue-discussions__badge {
  flex: none;
  font-size: 0.75rem;
  padding: 0 6px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--color-border);
  color: var(--color-muted);
}
.issue-discussions__x {
  flex: none;
  margin-left: auto;
}
.issue-discussions__add {
  display: flex;
  gap: 6px;
}
.issue-discussions__input {
  flex: 1;
  min-width: 0;
}
</style>
