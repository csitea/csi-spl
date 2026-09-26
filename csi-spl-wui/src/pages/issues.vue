<!-- Issues (GRK-3519, topic 9c19bfe9). Three panes stay: the rail, this list,
     and the detail on the right. The description is only in the detail.
     Deadline is a calendar with a time, stored UTC. The hub contract is
     issues-v1 (CLE-34993): GET /v1/view/issues, POST /v1/issues, PATCH. -->
<template>
  <div class="issues-page" data-test="issues-page">
    <div class="issues-list" data-test="issues-list">
      <header class="feed-header issues-head">
        <h2>{{ t('issues.title') }}</h2>
        <button type="button" class="btn" data-test="issues-new" @click="startCreate">{{ t('issues.new') }}</button>
      </header>
      <p class="issues-shortcuts muted" data-test="issues-shortcuts">{{ t('issues.shortcuts') }}</p>
      <div class="issues-filters" data-test="issues-filters">
        <input v-model="textF" class="issues-search" type="search" data-test="issues-search" :placeholder="t('issues.search')" :aria-label="t('issues.search')">
        <select v-model="sortF" data-test="issues-sort" :aria-label="t('issues.sort')">
          <option value="priority">{{ t('issues.sort_priority') }}</option>
          <option value="level">{{ t('issues.sort_level') }}</option>
          <option value="deadline">{{ t('issues.sort_deadline') }}</option>
          <option value="updated">{{ t('issues.sort_updated') }}</option>
          <option value="created">{{ t('issues.sort_created') }}</option>
        </select>
        <select v-model="statusF" data-test="issues-filter-status" :aria-label="t('issues.filter_status')">
          <option value="">{{ t('issues.filter_status') }}: {{ t('issues.filter_all') }}</option>
          <option v-for="s in ISSUE_STATUSES" :key="s" :value="s">{{ t(statusKey(s)) }}</option>
        </select>
        <select v-model="priorityF" data-test="issues-filter-priority" :aria-label="t('issues.filter_priority')">
          <option value="">{{ t('issues.filter_priority') }}: {{ t('issues.filter_all') }}</option>
          <option v-for="n in ISSUE_PRIORITIES" :key="n" :value="String(n)">{{ t(priorityKey(n)) }}</option>
        </select>
        <select v-model="levelF" data-test="issues-filter-level" :aria-label="t('issues.filter_level')">
          <option value="">{{ t('issues.filter_level') }}: {{ t('issues.filter_all') }}</option>
          <option v-for="n in ISSUE_LEVELS" :key="'lv' + n" :value="String(n)">{{ LEVEL_SHORT[n] || t(levelKey(n)) }}</option>
        </select>
        <select v-model="assigneeF" data-test="issues-filter-assignee" :aria-label="t('issues.filter_assignee')">
          <option value="">{{ t('issues.filter_assignee') }}: {{ t('issues.filter_all') }}</option>
          <option value="me">{{ t('issues.filter_me') }}</option>
          <option value="none">{{ t('issues.filter_unassigned') }}</option>
          <option v-for="p in assigneeOptions" :key="p.id" :value="p.id">{{ p.label }}</option>
        </select>
        <select v-model="labelF" data-test="issues-filter-label" :aria-label="t('issues.filter_label')">
          <option value="">{{ t('issues.filter_label') }}: {{ t('issues.filter_all') }}</option>
          <option v-for="l in labels" :key="l.id" :value="l.id">{{ l.name }}</option>
        </select>
        <input v-model="fromF" type="datetime-local" data-test="issues-filter-from" :aria-label="t('issues.filter_from')">
        <input v-model="untilF" type="datetime-local" data-test="issues-filter-until" :aria-label="t('issues.filter_until')">
        <button type="button" class="btn ghost" data-test="issues-filter-clear" @click="clearFilters">{{ t('issues.filter_clear') }}</button>
      </div>
      <div ref="scrollerEl" class="issues-scroll">
        <p v-if="loading && !issues.length" class="muted" data-test="issues-loading">{{ t('issues.loading') }}</p>
        <p v-else-if="loadError" class="issues-error" role="alert" data-test="issues-error">{{ t(loadError) }}</p>
        <p v-else-if="!groups.length" class="muted" data-test="issues-empty">{{ t('issues.empty') }}</p>
        <section v-for="g in groups" :key="g.status" class="issues-group" :data-status="g.status">
          <button
            type="button"
            class="issues-group__h"
            :aria-expanded="isCollapsed(g.status) ? 'false' : 'true'"
            @click="toggleGroup(g.status)"
          >
            <IssueGlyph :name="statusIcon(g.status)" :size="16" :class="'issues-st issues-st--' + g.status" />
            <span>{{ t(statusKey(g.status)) }}</span>
            <span class="issues-count" data-test="issues-group-count">{{ g.count }}</span>
          </button>
          <div v-show="!isCollapsed(g.status)">
            <div
              v-for="issue in g.issues"
              :key="issue.key"
              class="issues-row"
              role="button"
              tabindex="0"
              data-test="issues-row"
              :data-key="issue.key"
              :data-priority="issue.priority"
              :data-level="issue.level"
              :data-selected="cursorKey === issue.key ? 'true' : 'false'"
              @click="choose(issue)"
              @keydown.enter.prevent="choose(issue)"
            >
              <button type="button" class="issues-iconbtn" data-test="issues-row-priority" :aria-label="t('issues.field_priority')" @click.stop="openMenu('priority', issue, $event)">
                <IssueGlyph :name="priorityIcon(issue.priority)" :size="16" :class="'issues-pri issues-pri--' + issue.priority" />
              </button>
              <span class="issues-key">{{ issue.key }}</span>
              <span class="issues-title">{{ issue.title }}</span>
              <button v-if="levelShort(issue.level)" type="button" class="issues-level" data-test="issues-row-level" @click.stop="openMenu('level', issue, $event)">{{ levelShort(issue.level) }}</button>
              <span v-if="issue.labels.length" class="issues-pills">
                <button v-for="id in issue.labels" :key="id" type="button" class="issues-pill" data-test="issues-row-label" @click.stop="openMenu('label', issue, $event)">
                  <i class="issues-dot" :style="dotStyle(id)" />{{ labelText(id) }}
                </button>
              </span>
              <time v-if="issue.deadline" class="issues-when" :datetime="issue.deadline">{{ when(issue.deadline) }}</time>
              <button type="button" class="issues-person" data-test="issues-row-assignee" :data-assignee="issue.assignee" :aria-label="t('issues.field_assignee')" @click.stop="openMenu('assign', issue, $event)">
                <SpoolAvatar v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" :size="20" />
                <HumanName v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" />
                <span v-else class="muted">{{ t('issues.no_assignee') }}</span>
              </button>
            </div>
          </div>
        </section>
      </div>
    </div>
    <aside v-if="form" class="issues-detail" data-test="issues-detail" :aria-label="t('issues.title')">
      <header class="issues-detail__h">
        <span class="issues-key" data-test="issues-detail-key">{{ creating ? t('issues.new') : form.key }}</span>
        <button type="button" class="icon-btn" data-test="issues-detail-close" :aria-label="t('common.close')" @click="closeDetail">
          <UiIcon name="x" :size="18" />
        </button>
      </header>
      <input
        ref="titleEl"
        class="issues-detail__title"
        data-test="issues-detail-title"
        :value="form.title"
        :placeholder="t('issues.title_placeholder')"
        :aria-label="t('issues.title_placeholder')"
        @input="onDraftInput($event, 'title')"
        @change="onTitle"
      >
      <label class="issues-field">
        <span>{{ t('issues.field_description') }}</span>
        <textarea
          data-test="issues-detail-body"
          rows="5"
          :value="form.description"
          :placeholder="t('issues.description_empty')"
          @input="onDraftInput($event, 'description')"
          @change="onBody"
        />
      </label>
      <div class="issues-props">
        <button type="button" class="issues-prop" data-test="issues-status" @click="openMenu('status', detailOrDraft(), $event)">
          <IssueGlyph :name="statusIcon(form.status)" :size="16" />
          <span>{{ t(statusKey(form.status)) }}</span>
        </button>
        <button type="button" class="issues-prop" data-test="issues-priority" @click="openMenu('priority', detailOrDraft(), $event)">
          <IssueGlyph :name="priorityIcon(form.priority)" :size="16" />
          <span>{{ t(priorityKey(form.priority)) }}</span>
        </button>
        <button type="button" class="issues-prop" data-test="issues-level" @click="openMenu('level', detailOrDraft(), $event)">
          <span class="issues-level">{{ levelShort(form.level) || t('issues.level_none') }}</span>
        </button>
        <button type="button" class="issues-prop" data-test="issues-assignee" @click="openMenu('assign', detailOrDraft(), $event)">
          <SpoolAvatar v-if="activeAssignee" :id="activeAssignee" :box="boxOf(activeAssignee)" :size="20" />
          <HumanName v-if="activeAssignee" :id="activeAssignee" :box="boxOf(activeAssignee)" />
          <span v-else>{{ t('issues.no_assignee') }}</span>
        </button>
        <button type="button" class="issues-prop" data-test="issues-labels" @click="openMenu('label', detailOrDraft(), $event)">
          <span>{{ activeLabels.length ? activeLabels.map(labelText).join(', ') : t('issues.field_labels') }}</span>
        </button>
        <label class="issues-field">
          <span>{{ t('issues.field_deadline') }}</span>
          <input
            type="datetime-local"
            data-test="issues-deadline"
            :value="form.deadline"
            @change="onDeadline"
          >
        </label>
      </div>
      <p v-if="!creating && form.created_by" class="muted issues-meta">{{ t('issues.created_by', { name: person(form.created_by) }) }}</p>
      <p v-if="!creating && form.updated_by" class="muted issues-meta">{{ t('issues.updated_by', { name: person(form.updated_by) }) }}</p>
      <p v-if="saveError" class="issues-error" role="alert" data-test="issues-save-error">{{ t(saveError) }}</p>
      <button v-if="creating" type="button" class="btn" data-test="issues-create" :disabled="busy || !draft.title.trim()" @click="createIssue">{{ busy ? t('issues.creating') : t('issues.create') }}</button>
      <section v-if="!creating && form.task_id" class="issues-talk" data-test="issues-talk">
        <h3>{{ t('issues.discussion') }}</h3>
        <p v-if="!comments.length" class="muted" data-test="issues-comment-empty">{{ t('issues.comment_empty') }}</p>
        <article v-for="c in comments" :key="c.msg_id" class="issues-comment" data-test="issues-comment">
          <HumanName :id="c.from" :box="c.from_box" />
          <time v-if="c.ts" class="muted" :datetime="c.ts">{{ when(c.ts) }}</time>
          <p>{{ c.body }}</p>
        </article>
        <label class="issues-field">
          <span class="sr-only">{{ t('issues.comment_placeholder') }}</span>
          <textarea v-model="commentText" data-test="issues-comment-input" rows="2" :placeholder="t('issues.comment_placeholder')" />
        </label>
        <button type="button" class="btn" data-test="issues-comment-send" :disabled="busy || !commentText.trim()" @click="sendComment">{{ t('issues.comment_send') }}</button>
      </section>
    </aside>
    <div v-if="menu" class="issues-menu" role="listbox" data-test="issues-menu" :style="menuStyle" @click.stop>
      <button
        v-for="(opt, i) in menuOptions"
        :key="opt.value"
        type="button"
        role="option"
        class="issues-menu__opt"
        data-test="issues-menu-option"
        :data-value="opt.value"
        :aria-selected="i === menuIndex ? 'true' : 'false'"
        @click="applyMenu(opt.value)"
      >{{ opt.label }}</button>
      <form v-if="menu.kind === 'label'" class="issues-menu__add" @submit.prevent="addLabel">
        <input v-model="labelName" data-test="issues-label-name" :placeholder="t('issues.label_name')" :aria-label="t('issues.label_name')">
        <button type="submit" class="btn" data-test="issues-label-add">{{ t('issues.add_label') }}</button>
      </form>
    </div>
  </div>
</template>

<script setup lang="ts">
import type { Issue, IssueFilter, IssueLabel } from '~/utils/issues.mjs'
import { useSessionStore } from '~/stores/session'
import { useRosterStore } from '~/stores/roster'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useHumanNames } from '~/composables/useHumanNames'
import { useLive } from '~/composables/useLive'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { tabForPath } from '~/utils/sidebar-tabs.mjs'
import { shownPerson } from '~/utils/channel-feed.mjs'
import { ISSUE_STATUSES, createMockIssues, normalizeIssue, normalizeLabel } from '~/utils/issues.mjs'
import {
  ISSUE_LEVELS,
  ISSUE_PRIORITIES,
  LEVEL_SHORT,
  applyIssueFrame,
  applyLabelFrame,
  deadlineToLocalInput,
  groupIssues,
  levelKey,
  localInputToDeadline,
  priorityKey,
  statusKey,
  stepKey,
  visibleOrder,
} from '~/utils/issues-view.mjs'

type Note = { msg_id: string, from: string, from_box: string, body: string, ts: string }

const STATUS_ICON: Record<string, string> = {
  backlog: 'status-backlog',
  todo: 'status-todo',
  in_progress: 'status-progress',
  in_review: 'status-review',
  done: 'status-done',
  canceled: 'status-canceled',
}
const PRIORITY_ICON: Record<number, string> = {
  0: 'priority-none',
  1: 'priority-urgent',
  2: 'priority-high',
  3: 'priority-medium',
  4: 'priority-low',
}

function statusIcon(status: string): string {
  return STATUS_ICON[status] || 'status-backlog'
}
function priorityIcon(priority: number): string {
  return PRIORITY_ICON[priority] || 'priority-none'
}

const { t, locale } = useI18n({ useScope: 'global' })
const route = useRoute()
const session = useSessionStore()
const roster = useRosterStore()
const people = useHumanNames()
const api = useSpoolApi()
if (api.mock) api.bindIssuesMock((me: string) => createMockIssues({ me }))
const live = useLive()

const issues = ref<Issue[]>([])
const labels = ref<IssueLabel[]>([])
const loading = ref(false)
const busy = ref(false)
const loadError = ref('')
const saveError = ref('')
const textF = ref('')
const sortF = ref('priority')
const statusF = ref('')
const priorityF = ref('')
const levelF = ref('')
const assigneeF = ref('')
const labelF = ref('')
const fromF = ref('')
const untilF = ref('')
const collapsed = ref<Record<string, boolean>>({ done: true, canceled: true })
const cursorKey = ref('')
const openKey = ref('')
const creating = ref(false)
const detail = ref<Issue | null>(null)
const comments = ref<Note[]>([])
const commentText = ref('')
const menu = ref<{ kind: string, key: string } | null>(null)
const menuIndex = ref(0)
const menuPos = ref({ top: 80, left: 80 })
const labelName = ref('')
const titleEl = ref<HTMLInputElement | null>(null)
const scrollerEl = ref<HTMLElement | null>(null)
const draft = reactive({
  title: '', description: '', status: 'todo', priority: 0, level: 0,
  assignee: '', labels: [] as string[], deadlineLocal: '',
})

function boxOf(id: string) {
  return roster.people.find((p) => p.id === id)?.box || ''
}
function person(id: string) {
  return id ? shownPerson(id, boxOf(id), people.names.value) : ''
}
function labelText(id: string) {
  return labels.value.find((l) => l.id === id)?.name || id
}
function dotStyle(id: string) {
  const color = labels.value.find((l) => l.id === id)?.color || ''
  return /^#[0-9a-f]{6}$/i.test(color) ? { background: color } : {}
}
function when(rfc: string) {
  if (!rfc) return ''
  const d = new Date(rfc)
  if (Number.isNaN(d.getTime())) return ''
  try {
    return new Intl.DateTimeFormat(String(locale.value || ''), {
      month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
    }).format(d)
  } catch {
    return deadlineToLocalInput(rfc).replace('T', ' ')
  }
}
function levelShort(n: number) {
  return LEVEL_SHORT[n] || ''
}
function meId() {
  return roster.self?.id || live.identity.value || ''
}
function isCollapsed(status: string) {
  if (statusF.value === status) return false
  return Boolean(collapsed.value[status])
}
function serverFilter(): IssueFilter {
  const f: IssueFilter = {}
  if (statusF.value) f.status = [statusF.value]
  if (priorityF.value !== '') f.priority = [Number(priorityF.value)]
  if (levelF.value !== '') f.level = [Number(levelF.value)]
  if (assigneeF.value) f.assignee = [assigneeF.value]
  if (labelF.value) f.label = [labelF.value]
  const after = localInputToDeadline(fromF.value)
  const before = localInputToDeadline(untilF.value)
  if (after) f.deadlineAfter = after
  if (before) f.deadlineBefore = before
  return f
}
function errorKey(err: { status?: number, token?: string }, which: 'list' | 'one') {
  const status = Number(err && err.status) || 0
  const token = String((err && err.token) || '')
  if (status === 401 || token === 'view_door' || token === 'unauthenticated') return 'issues.signed_out'
  if (status === 403) return 'issues.forbidden'
  if (status === 404) return which === 'list' ? 'issues.unavailable' : 'issues.not_found'
  if (status === 503 || token === 'unavailable') return 'issues.unavailable'
  return which === 'list' ? 'issues.load_failed' : 'issues.save_failed'
}

const assigneeOptions = computed(() => {
  const seen = new Set<string>()
  const out: { id: string, label: string }[] = []
  for (const p of roster.people) {
    if (!p.id || seen.has(p.id)) continue
    seen.add(p.id)
    out.push({ id: p.id, label: person(p.id) })
  }
  return out
})
const groups = computed(() => {
  const q = textF.value.trim().toLowerCase()
  const rows = q
    ? issues.value.filter((i) => `${i.key} ${i.title}`.toLowerCase().includes(q))
    : issues.value
  return groupIssues(rows, { sort: sortF.value, filter: serverFilter(), me: meId(), hideEmpty: false })
})
const flat = computed(() => visibleOrder(groups.value, Object.fromEntries(
  ISSUE_STATUSES.map((s) => [s, isCollapsed(s)]),
)))
const activeAssignee = computed(() => creating.value ? draft.assignee : (detail.value?.assignee || ''))
const activeLabels = computed(() => creating.value ? draft.labels : (detail.value?.labels || []))
const form = computed(() => {
  if (creating.value) {
    return {
      key: '', title: draft.title, description: draft.description, status: draft.status,
      priority: draft.priority, level: draft.level, deadline: draft.deadlineLocal,
      created_by: '', updated_by: '', task_id: '',
    }
  }
  const d = detail.value
  if (!d) return null
  return {
    key: d.key, title: d.title, description: d.description, status: d.status,
    priority: d.priority, level: d.level, deadline: deadlineToLocalInput(d.deadline),
    created_by: d.created_by, updated_by: d.updated_by, task_id: d.task_id,
  }
})

async function load() {
  if (!api.mock && session.state !== 'in') {
    issues.value = []
    loadError.value = session.state === 'out' ? 'issues.signed_out' : ''
    loading.value = session.state === 'loading'
    return
  }
  loading.value = true
  loadError.value = ''
  try {
    const data = await withSessionRetry(api, () => api.listIssues({ filter: serverFilter(), sort: sortF.value }))
    issues.value = (data.issues || []).map((row) => normalizeIssue(row))
    labels.value = (data.labels || []).map((row) => normalizeLabel(row))
    if (cursorKey.value && !flat.value.some((i) => i.key === cursorKey.value)) cursorKey.value = flat.value[0]?.key || ''
  } catch (e) {
    loadError.value = errorKey(e as { status?: number, token?: string }, 'list')
  } finally {
    loading.value = false
  }
}

function clearFilters() {
  textF.value = ''
  sortF.value = 'priority'
  statusF.value = ''
  priorityF.value = ''
  levelF.value = ''
  assigneeF.value = ''
  labelF.value = ''
  fromF.value = ''
  untilF.value = ''
}
function toggleGroup(status: string) {
  collapsed.value = { ...collapsed.value, [status]: !collapsed.value[status] }
}
function choose(issue: Issue) {
  cursorKey.value = issue.key
  creating.value = false
  openKey.value = issue.key
  detail.value = issue
  menu.value = null
}
function closeDetail() {
  creating.value = false
  openKey.value = ''
  detail.value = null
  menu.value = null
}
function startCreate() {
  creating.value = true
  openKey.value = ''
  detail.value = null
  draft.title = ''
  draft.description = ''
  draft.status = 'todo'
  draft.priority = 0
  draft.level = 0
  draft.assignee = ''
  draft.labels = []
  draft.deadlineLocal = ''
  menu.value = null
  saveError.value = ''
  void nextTick(() => titleEl.value?.focus())
}
function detailOrDraft(): Issue {
  if (detail.value && !creating.value) return detail.value
  return normalizeIssue({
    key: draft.title ? 'draft' : '',
    title: draft.title,
    description: draft.description,
    status: draft.status,
    priority: draft.priority,
    level: draft.level,
    assignee: draft.assignee,
    labels: draft.labels,
  })
}

const menuOptions = computed(() => {
  const kind = menu.value?.kind || ''
  if (kind === 'status') return ISSUE_STATUSES.map((s) => ({ value: s, label: t(statusKey(s)) }))
  if (kind === 'priority') return ISSUE_PRIORITIES.map((n) => ({ value: String(n), label: t(priorityKey(n)) }))
  if (kind === 'level') return ISSUE_LEVELS.map((n) => ({ value: String(n), label: LEVEL_SHORT[n] || t(levelKey(n)) }))
  if (kind === 'assign') return [{ value: '', label: t('issues.no_assignee') }, ...assigneeOptions.value.map((p) => ({ value: p.id, label: p.label }))]
  if (kind === 'label') return labels.value.map((l) => ({ value: l.id, label: l.name }))
  return []
})
const menuStyle = computed(() => ({ top: `${menuPos.value.top}px`, left: `${menuPos.value.left}px` }))

function openMenu(kind: string, issue: Issue, ev?: Event) {
  if (issue?.key && issue.key !== 'draft') cursorKey.value = issue.key
  const el = ev && (ev.currentTarget as HTMLElement)
  const r = el && el.getBoundingClientRect ? el.getBoundingClientRect() : null
  menuPos.value = {
    top: r ? r.bottom + 4 : 120,
    left: Math.max(8, r ? Math.min(r.left, window.innerWidth - 240) : 80),
  }
  menu.value = { kind, key: issue?.key || '' }
  menuIndex.value = 0
  labelName.value = ''
}
function scrollSelected() {
  const scroller = scrollerEl.value
  const key = cursorKey.value
  if (!scroller || !key) return
  const row = scroller.querySelector(`[data-test=issues-row][data-key="${CSS.escape(key)}"]`)
  if (row) scrollRowToTop(scroller, row)
}
function move(delta: number) {
  const next = stepKey(flat.value, cursorKey.value, delta)
  if (!next) return
  cursorKey.value = next
  const issue = flat.value.find((i) => i.key === next)
  if (issue && openKey.value && !creating.value) {
    openKey.value = issue.key
    detail.value = issue
  }
  void nextTick(scrollSelected)
}
function hold(issue: Issue) {
  issues.value = applyIssueFrame(issues.value, { type: 'issue', issue })
  if (detail.value && detail.value.key === issue.key) detail.value = issue
}

async function save(key: string, body: Record<string, unknown>) {
  busy.value = true
  saveError.value = ''
  try {
    const data = await withSessionRetry(api, () => api.updateIssue(key, body))
    hold(normalizeIssue(data.issue))
  } catch (e) {
    saveError.value = errorKey(e as { status?: number, token?: string }, 'one')
  } finally {
    busy.value = false
  }
}
function onDraftInput(ev: Event, field: 'title' | 'description') {
  if (!creating.value) return
  draft[field] = (ev.target as HTMLInputElement).value
}
function onTitle(ev: Event) {
  const value = (ev.target as HTMLInputElement).value
  if (creating.value) { draft.title = value; return }
  if (!detail.value || value === detail.value.title) return
  void save(detail.value.key, { title: value })
}
function onBody(ev: Event) {
  const value = (ev.target as HTMLTextAreaElement).value
  if (creating.value) { draft.description = value; return }
  if (!detail.value || value === detail.value.description) return
  void save(detail.value.key, { description: value })
}
function onDeadline(ev: Event) {
  const value = (ev.target as HTMLInputElement).value
  if (creating.value) { draft.deadlineLocal = value; return }
  if (!detail.value) return
  const deadline = localInputToDeadline(value)
  if (deadline === null) return
  void save(detail.value.key, { deadline })
}
async function applyMenu(value: string) {
  const kind = menu.value?.kind || ''
  if (!kind) return
  if (creating.value) {
    if (kind === 'status') draft.status = value
    else if (kind === 'priority') draft.priority = Number(value)
    else if (kind === 'level') draft.level = Number(value)
    else if (kind === 'assign') draft.assignee = value
    else if (kind === 'label') {
      draft.labels = draft.labels.includes(value) ? draft.labels.filter((x) => x !== value) : [...draft.labels, value]
    }
    if (kind !== 'label') menu.value = null
    return
  }
  const issue = detail.value || issues.value.find((i) => i.key === menu.value?.key)
  if (!issue || !issue.key) return
  const body: Record<string, unknown> = {}
  if (kind === 'status') body.status = value
  else if (kind === 'priority') body.priority = Number(value)
  else if (kind === 'level') body.level = Number(value)
  else if (kind === 'assign') body.assignee = value
  else if (kind === 'label') {
    body.labels = issue.labels.includes(value) ? issue.labels.filter((x) => x !== value) : [...issue.labels, value]
  }
  await save(issue.key, body)
  if (kind !== 'label') menu.value = null
}
async function addLabel() {
  const name = labelName.value.trim()
  if (!name) return
  busy.value = true
  saveError.value = ''
  try {
    const data = await withSessionRetry(api, () => api.createIssueLabel({ name }))
    labels.value = applyLabelFrame(labels.value, { type: 'issue_label', label: data.label })
    labelName.value = ''
    await applyMenu(data.label.id)
  } catch (e) {
    saveError.value = errorKey(e as { status?: number, token?: string }, 'one')
  } finally {
    busy.value = false
  }
}
async function createIssue() {
  const title = draft.title.trim()
  if (!title) return
  busy.value = true
  saveError.value = ''
  const body: Record<string, unknown> = {
    title,
    description: draft.description,
    status: draft.status,
    priority: draft.priority,
    level: draft.level,
  }
  if (draft.assignee) body.assignee = draft.assignee
  if (draft.labels.length) body.labels = draft.labels.slice()
  const deadline = localInputToDeadline(draft.deadlineLocal)
  if (deadline) body.deadline = deadline
  try {
    const data = await withSessionRetry(api, () => api.createIssue(body))
    const created = normalizeIssue(data.issue)
    hold(created)
    creating.value = false
    openKey.value = created.key
    detail.value = created
    cursorKey.value = created.key
  } catch (e) {
    saveError.value = errorKey(e as { status?: number, token?: string }, 'one')
  } finally {
    busy.value = false
  }
}

function asNotes(rows: unknown): Note[] {
  if (!Array.isArray(rows)) return []
  const out: Note[] = []
  for (const raw of rows) {
    if (!raw || typeof raw !== 'object') continue
    const m = raw as Record<string, unknown>
    const id = String(m.msg_id || '')
    if (!id) continue
    out.push({
      msg_id: id,
      from: String(m.from || ''),
      from_box: String(m.from_box || ''),
      body: String(m.body || ''),
      ts: String(m.ts || m.received_at || ''),
    })
  }
  return out
}
let followed = ''
async function loadComments(issue: Issue | null) {
  comments.value = []
  const sock = live.ensure()
  if (followed && sock) sock.unsubscribe(followed)
  followed = ''
  if (!issue || !issue.task_id) return
  followed = issue.task_id
  if (sock) sock.subscribe(issue.task_id)
  try {
    const data = await withSessionRetry(api, () => api.getTopic(issue.task_id, { limit: 50 }))
    comments.value = asNotes(data && data.messages)
  } catch {
    comments.value = []
  }
}
async function sendComment() {
  const issue = detail.value
  const text = commentText.value.trim()
  if (!issue || !issue.task_id || !text) return
  busy.value = true
  saveError.value = ''
  try {
    const sock = live.ensure()
    if (sock) {
      await sock.send({ task_id: issue.task_id, kind: 'note', body: text, files: [], channel: issue.channel || 'tasks', is_parent: 0 })
    } else {
      await api.sendMessage({ text, task_id: issue.task_id, channel: issue.channel || 'tasks', is_parent: 0 })
    }
    commentText.value = ''
    await loadComments(issue)
  } catch {
    saveError.value = 'issues.save_failed'
  } finally {
    busy.value = false
  }
}

function typingTarget(el: EventTarget | null) {
  if (!(el instanceof HTMLElement)) return false
  const tag = el.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable
}
function onDocKey(ev: KeyboardEvent) {
  if (tabForPath(route.path) !== 'issues') return
  if (document.querySelector('[aria-modal="true"]')) return
  const key = ev.key
  const typing = typingTarget(ev.target)
  const menuOpen = Boolean(menu.value)
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return
  if (key === 'Escape' && typing) { (ev.target as HTMLElement).blur(); ev.preventDefault(); return }
  if (key === 'Escape') {
    ev.preventDefault()
    if (menuOpen) menu.value = null
    else closeDetail()
    return
  }
  if (typing) return
  if (menuOpen) {
    if (key === 'ArrowDown' || key === 'j' || key === 'J') { menuIndex.value = Math.min(menuOptions.value.length - 1, menuIndex.value + 1); ev.preventDefault(); return }
    if (key === 'ArrowUp' || key === 'k' || key === 'K') { menuIndex.value = Math.max(0, menuIndex.value - 1); ev.preventDefault(); return }
    if (key === 'Enter') {
      const opt = menuOptions.value[menuIndex.value]
      if (opt) void applyMenu(opt.value)
      ev.preventDefault()
    }
    return
  }
  const k = key.toLowerCase()
  if (k === 'j' || key === 'ArrowDown') { move(1); ev.preventDefault(); return }
  if (k === 'k' || key === 'ArrowUp') { move(-1); ev.preventDefault(); return }
  if (key === 'Enter') { const issue = flat.value.find((i) => i.key === cursorKey.value) || flat.value[0]; if (issue) choose(issue); ev.preventDefault(); return }
  if (k === 'c') { startCreate(); ev.preventDefault(); return }
  const kind = { s: 'status', p: 'priority', e: 'level', a: 'assign', l: 'label' }[k]
  const issue = creating.value ? detailOrDraft() : (detail.value || flat.value.find((i) => i.key === cursorKey.value) || flat.value[0])
  if (kind && issue) { openMenu(kind, issue); ev.preventDefault() }
}

watch([statusF, priorityF, levelF, assigneeF, labelF, fromF, untilF, sortF], () => { void load() })
watch(() => session.state, () => { void load() }, { immediate: true })
watch(detail, (issue) => { if (!creating.value) void loadComments(issue) })
watch(creating, (on) => { if (on) comments.value = [] })

let offIssue = () => {}
let offLabel = () => {}
let offMsg = () => {}
let offBack = () => {}
onMounted(() => {
  useTopicStore().close()
  useLiveFeed('pane').close()
  document.addEventListener('keydown', onDocKey)
  offIssue = live.onIssue((f) => { issues.value = applyIssueFrame(issues.value, f) })
  offLabel = live.onIssueLabel((f) => { labels.value = applyLabelFrame(labels.value, f) })
  offMsg = live.onMessage((m) => {
    const issue = detail.value
    if (!issue || String(m.task_id || '') !== issue.task_id) return
    const note = asNotes([m])[0]
    if (note && !comments.value.some((c) => c.msg_id === note.msg_id)) comments.value = [...comments.value, note]
  })
  offBack = live.onReconnected(() => { void load() })
})
onUnmounted(() => {
  document.removeEventListener('keydown', onDocKey)
  offIssue()
  offLabel()
  offMsg()
  offBack()
  const sock = live.ensure()
  if (followed && sock) sock.unsubscribe(followed)
})
</script>

<style scoped>
.issues-page {
  display: flex;
  flex: 1 1 auto;
  min-width: 0;
  min-height: 0;
  height: 100%;
  max-width: 100%;
  overflow: clip;
}
.issues-list {
  flex: 1 1 auto;
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: clip;
}
.issues-head { gap: 8px; }
.issues-shortcuts {
  margin: 0;
  padding: 0 12px 6px;
  font-size: 0.75rem;
  min-width: 0;
}
.issues-filters {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  padding: 0 12px 8px;
  min-width: 0;
}
.issues-filters select,
.issues-filters input,
.issues-search {
  max-width: 100%;
  min-width: 0;
  background: var(--color-bg-2);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 4px 8px;
  font: inherit;
}
.issues-scroll {
  flex: 1 1 auto;
  min-height: 0;
  min-width: 0;
  overflow: auto;
}
.issues-group__h {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  min-width: 0;
  padding: 8px 12px 4px;
  background: transparent;
  border: 0;
  color: var(--color-muted);
  font: inherit;
  font-size: 0.8125rem;
  font-weight: 600;
  text-align: start;
  cursor: pointer;
}
.issues-count { margin-inline-start: auto; }
.issues-row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  max-width: 100%;
  padding: 6px 12px;
  cursor: pointer;
}
.issues-row[data-selected="true"] {
  background: var(--color-selected);
  border-inline-start: var(--select-bar-w) solid var(--focus-ring);
}
.issues-key { flex: 0 0 auto; color: var(--color-muted); font-variant-numeric: tabular-nums; }
.issues-title {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.issues-iconbtn, .issues-level, .issues-pill, .issues-person, .issues-prop {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
  background: transparent;
  border: 0;
  color: inherit;
  font: inherit;
  cursor: pointer;
  padding: 2px;
}
.issues-person { flex: 0 1 9rem; overflow: hidden; }
.issues-person :deep(.human-name__text) {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.issues-pills { display: flex; gap: 4px; min-width: 0; flex: 0 1 auto; overflow: hidden; }
.issues-pill {
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  padding: 0 6px;
  max-width: 8rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.issues-dot {
  width: 8px;
  height: 8px;
  border-radius: var(--radius-pill);
  background: var(--color-muted);
  display: inline-block;
}
.issues-when { flex: 0 0 auto; color: var(--color-muted); font-size: 0.75rem; }
.issues-level {
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 0 4px;
  font-size: 0.75rem;
}
.issues-pri--1 { color: var(--color-danger); }
.issues-pri--2 { color: var(--color-warn); }
.issues-pri--3 { color: var(--color-accent); }
.issues-pri--4, .issues-pri--0 { color: var(--color-muted); }
.issues-st--in_progress { color: var(--color-warn); }
.issues-st--in_review { color: var(--color-accent-2); }
.issues-st--done { color: var(--color-ok); }
.issues-st--canceled, .issues-st--backlog { color: var(--color-muted); }
.issues-detail {
  flex: 0 0 380px;
  width: min(380px, 100%);
  max-width: 100%;
  min-width: 0;
  min-height: 0;
  overflow: auto;
  border-inline-start: 1px solid var(--color-border);
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  background: var(--color-bg);
}
.issues-detail__h { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-width: 0; }
.issues-detail__title, .issues-field textarea, .issues-field input, .issues-menu__add input {
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  background: var(--color-bg-2);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 6px 8px;
  font: inherit;
}
.issues-detail__title { font-size: 1.125rem; font-weight: 600; }
.issues-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; font-size: 0.8125rem; color: var(--color-muted); }
.issues-props { display: flex; flex-wrap: wrap; gap: 6px; min-width: 0; }
.issues-prop { border: 1px solid var(--color-border); border-radius: var(--radius-sm); padding: 4px 8px; }
.issues-meta { margin: 0; font-size: 0.75rem; }
.issues-talk { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.issues-talk h3 { margin: 8px 0 0; font-size: 0.875rem; }
.issues-comment { min-width: 0; }
.issues-comment p { margin: 2px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.issues-error { color: var(--color-danger); margin: 0; }
.issues-menu {
  position: fixed;
  z-index: 30;
  min-width: 10rem;
  max-width: min(16rem, calc(100% - 16px));
  max-height: 16rem;
  overflow: auto;
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  padding: 4px;
  box-shadow: var(--focus-3d);
}
.issues-menu__opt {
  display: block;
  width: 100%;
  text-align: start;
  background: transparent;
  border: 0;
  color: inherit;
  font: inherit;
  padding: 6px 8px;
  cursor: pointer;
}
.issues-menu__opt[aria-selected="true"] { background: var(--color-selected); }
.issues-menu__add { display: flex; gap: 4px; padding: 4px; min-width: 0; }
.sr-only {
  position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0;
}
@media (max-width: 1100px) {
  .issues-detail {
    position: fixed;
    inset-inline-end: 0;
    top: var(--top-bar-h);
    bottom: 0;
    width: min(380px, 100%);
    z-index: 20;
    box-shadow: -8px 0 24px rgb(0 0 0 / .35);
  }
}
</style>
