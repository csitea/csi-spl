<!-- rdb 0181 (owner HUM-10, t1 62e48cef: "we need jira like history tab for
     each issue to see when it was created, when somebody commneted etc."):
     the issue's History tab, oldest first. One row per event: who, what,
     old -> new where it applies, when (relative; exact on hover). The hub
     answers GET /v1/view/issues/{ref}/history; `stamp` changes when the issue
     or its discussion did, and the list is read again. -->
<template>
  <div class="issue-history" data-test="issues-history">
    <p v-if="state === 'loading' && !events.length" class="muted" data-test="issues-history-loading">{{ t('issue_history.loading') }}</p>
    <p v-else-if="state === 'failed'" class="issues-error" role="alert" data-test="issues-history-failed">{{ t('issue_history.failed') }}</p>
    <p v-else-if="!events.length" class="muted" data-test="issues-history-empty">{{ t('issue_history.empty') }}</p>
    <ol v-else class="issue-history__list">
      <li
        v-for="(e, i) in events"
        :key="i"
        class="issue-history__row"
        data-test="issues-history-row"
        :data-event="e.event"
        :data-field="e.field || ''"
      >
        <span class="issue-history__who" data-test="issues-history-actor">{{ name(e.actor) || e.actor }}</span>
        <span class="issue-history__what">{{ whatOf(e) }}</span>
        <span v-if="e.event === 'changed' && e.field !== 'description'" class="issue-history__vals" data-test="issues-history-values">
          <span class="issue-history__old">{{ valueOf(e.field, e.old) }}</span>
          <span aria-hidden="true">&nbsp;→&nbsp;</span>
          <span class="issue-history__new">{{ valueOf(e.field, e.new) }}</span>
        </span>
        <span v-else-if="e.event === 'commented' && e.new" class="issue-history__excerpt">{{ e.new }}</span>
        <time class="issue-history__at" data-test="issues-history-at" :datetime="e.at" :title="exact(e.at)">{{ ago(e.at) }}</time>
      </li>
    </ol>
  </div>
</template>

<script setup lang="ts">
import type { IssueEvent } from '~/utils/issues.mjs'
import { statusLabel } from '~/utils/issues-view.mjs'
import { ageParts } from '~/composables/errorJournal.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

const props = defineProps<{
  /** the issue's key, SPL-12 */
  issueKey: string
  /** changes when the issue or its discussion did: the history is read again */
  stamp?: string
  /** an actor id (HUM-3, CLE-07) as the page shows people */
  name: (id: string) => string
  /** a label id as its name */
  label: (id: string) => string
}>()

const { t, locale } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const events = ref<IssueEvent[]>([])
const state = ref<'loading' | 'ok' | 'failed'>('loading')
const now = ref(Date.now())

/* the issue's own field names (issues.*), so the tab adds no copy of them */
const FIELD_KEY: Record<string, string> = {
  title: 'issue_history.title', description: 'issues.field_description', status: 'issues.field_status',
  priority: 'issues.field_priority', level: 'issues.field_level', assignee: 'issues.field_assignee',
  kind: 'issues.field_kind', parent: 'issues.parent_issue', deadline: 'issues.field_deadline', labels: 'issues.field_labels',
}

let seq = 0
async function load() {
  const key = props.issueKey
  if (!key) return
  const mine = ++seq
  state.value = 'loading'
  try {
    const data = await api.getIssueHistory(key)
    if (mine !== seq) return
    events.value = Array.isArray(data?.events) ? data.events : []
    state.value = 'ok'
    now.value = Date.now()
  } catch {
    if (mine === seq) state.value = 'failed'
  }
}
watch(() => [props.issueKey, props.stamp], load, { immediate: true })

function whatOf(e: IssueEvent): string {
  if (e.event === 'changed') return t('issue_history.changed', { field: t(FIELD_KEY[e.field || ''] || 'issue_history.title') })
  return t(`issue_history.${e.event}`)
}

function valueOf(field: string | undefined, v: string | null): string {
  if (v === null || v === '') return t('issue_history.none')
  switch (field) {
    case 'status': return statusLabel(v)
    case 'assignee': return props.name(v) || v
    case 'labels': return v.split(',').map((l) => props.label(l)).join(', ')
    case 'deadline': return exact(v)
    default: return v
  }
}

/* every absolute date is YYYY-MM-DD HH:MM (date-iso.mjs), in every locale */
function exact(at: string): string {
  return isoDateTime(at) || at
}

function ago(at: string): string {
  const p = ageParts(at, now.value) as { value: number, unit: string } | null
  if (!p) return ''
  try {
    return new Intl.RelativeTimeFormat(String(locale.value || 'en'), { numeric: 'auto' })
      .format(p.value, p.unit as Intl.RelativeTimeFormatUnit)
  } catch {
    return exact(at)
  }
}
</script>

<style scoped>
.issue-history__list {
  list-style: none;
  margin: 0;
  padding: 0;
}
.issue-history__row {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.25rem 0.5rem;
  padding: 0.4rem 0;
  border-bottom: 1px solid var(--border, rgba(127, 127, 127, 0.2));
}
.issue-history__who {
  font-weight: 600;
}
.issue-history__vals {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 0.25rem;
}
.issue-history__old {
  text-decoration: line-through;
  opacity: 0.7;
}
.issue-history__excerpt {
  flex-basis: 100%;
  opacity: 0.8;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.issue-history__at {
  margin-inline-start: auto;
  opacity: 0.7;
  font-size: 0.875rem;
}
</style>
