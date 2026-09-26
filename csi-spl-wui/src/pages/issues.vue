<!-- Issues (GRK-3519, topic 9c19bfe9). Three panes stay: the rail, this list,
     and the detail on the right. The description is only in the detail.
     Deadline is a calendar with a time, stored UTC. The hub contract is
     issues-v1 (CLE-34993): GET /v1/view/issues, POST /v1/issues, PATCH. -->
<template>
  <div ref="pageEl" class="issues-page" data-test="issues-page" :style="detailStyle">
    <div class="issues-list" data-test="issues-list">
      <header class="feed-header issues-head">
        <h2 data-test="issues-heading">{{ epicTitle || t('issues.title') }}</h2>
        <button type="button" class="btn" data-test="issues-new" @click="startCreate">{{ t('issues.new') }}</button>
      </header>
      <p class="issues-shortcuts muted" data-test="issues-shortcuts">{{ t('issues.shortcuts') }}</p>
      <div class="issues-filters" data-test="issues-filters">
        <select v-model="sortF" class="issues-sort" data-test="issues-sort" :aria-label="t('issues.sort')">
          <option value="priority">{{ controlLabel(t('issues.sort'), t('issues.sort_priority')) }}</option>
          <option value="level">{{ controlLabel(t('issues.sort'), t('issues.sort_level')) }}</option>
          <option value="deadline">{{ controlLabel(t('issues.sort'), t('issues.sort_deadline')) }}</option>
          <option value="updated">{{ controlLabel(t('issues.sort'), t('issues.sort_updated')) }}</option>
          <option value="created">{{ controlLabel(t('issues.sort'), t('issues.sort_created')) }}</option>
        </select>
        <div class="issues-status-dd" data-test="issues-filter-status">
          <button
            type="button"
            class="issues-status-dd__btn"
            data-test="issues-filter-status-btn"
            :aria-label="t('issues.filter_status')"
            :aria-expanded="statusOpen ? 'true' : 'false'"
            :title="statusF ? t(statusHintKey(statusF)) : undefined"
            @click="statusOpen = !statusOpen"
          >{{ controlLabel(t('issues.filter_status'), statusF ? statusLabel(statusF) : t('issues.filter_all')) }}</button>
          <div v-show="statusOpen" class="issues-status-dd__list" role="listbox">
            <button type="button" class="issues-status-dd__opt" data-test="issues-filter-status-all" @click="pickStatus('')">
              {{ t('issues.filter_status') }}: {{ t('issues.filter_all') }}
            </button>
            <button
              v-for="s in ISSUE_STATUSES"
              :key="s"
              type="button"
              class="issues-status-dd__opt"
              data-test="issues-filter-status-opt"
              :data-value="s"
              :aria-selected="statusF === s ? 'true' : 'false'"
              :title="t(statusHintKey(s))"
              @click="pickStatus(s)"
            >
              <span class="issues-status-code">{{ statusLabel(s) }}</span>
              <span class="issues-status-tip" role="tooltip">{{ t(statusHintKey(s)) }}</span>
            </button>
          </div>
        </div>
        <select v-model="priorityF" data-test="issues-filter-priority" :aria-label="t('issues.filter_priority')">
          <option value="">{{ t('issues.filter_priority') }}: {{ t('issues.filter_all') }}</option>
          <option v-for="n in ISSUE_PRIORITIES" :key="n" :value="String(n)">{{ controlLabel(t('issues.filter_priority'), String(n)) }}</option>
        </select>
        <select v-model="levelF" data-test="issues-filter-level" :aria-label="t('issues.filter_level')">
          <option value="">{{ t('issues.filter_level') }}: {{ t('issues.filter_all') }}</option>
          <option v-for="n in ISSUE_LEVELS" :key="'lv' + n" :value="String(n)" :title="t(levelKey(n))">{{ controlLabel(t('issues.filter_level'), String(n)) }}</option>
        </select>
        <!-- owner, topic e00da93b: "the assignee: string is obsolete" - the
             value alone behind a person icon; "Assignee" stays the name and hover -->
        <span class="issues-filter-who">
          <UiIcon name="user" :size="14" class="issues-filter-who__icon" />
          <select v-model="assigneeF" class="issues-filter-assignee" data-test="issues-filter-assignee" :aria-label="t('issues.filter_assignee')" :title="assigneeTitle">
            <option value="">{{ t('issues.filter_all') }}</option>
            <option value="me">{{ t('issues.filter_me') }}</option>
            <option value="none">{{ t('issues.filter_unassigned') }}</option>
            <option v-for="p in assigneeOptions" :key="p.id" :value="p.id">{{ p.label }}</option>
          </select>
        </span>
        <select v-model="labelF" data-test="issues-filter-label" :aria-label="t('issues.filter_label')">
          <option value="">{{ t('issues.filter_label') }}: {{ t('issues.filter_all') }}</option>
          <option v-for="l in labels" :key="l.id" :value="l.id">{{ controlLabel(t('issues.filter_label'), l.name) }}</option>
        </select>
        <!-- owner, topic 778ad161: the calendar control, YYYY-MM-DD HH:MM; due on or before that minute -->
        <div class="issues-filter-when" role="group" :aria-label="t('issues.field_deadline')" data-test="issues-filter-deadline">
          <span>{{ t('issues.field_deadline') }}:</span>
          <DeadlinePicker v-model="dueF" :label="t('issues.field_deadline')" test-id="issues-filter-deadline-date" time-test-id="issues-filter-deadline-time" default-time="23:59" />
        </div>
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
            <span class="issues-status-host" :title="t(statusHintKey(g.status))">
              <span class="issues-status-code">{{ statusLabel(g.status) }}</span>
              <span class="issues-status-tip" role="tooltip">{{ t(statusHintKey(g.status)) }}</span>
            </span>
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
                <span class="issues-prio" data-test="issues-row-prio" :class="'issues-prio--' + issue.priority">{{ issue.priority }}</span>
              </button>
              <span class="issues-key">{{ issue.key }}</span>
              <span class="issues-title">{{ issue.title }}</span>
              <button v-if="!epicF && issue.epic" type="button" class="issues-pill issues-epic-tag" data-test="issues-row-epic" @click.stop="openMenu('epic', issue, $event)">{{ epicTitleOf(issue.epic) }}</button>
              <span v-if="levelShort(issue.level)" class="issues-level" data-test="issues-row-level" :title="t(levelKey(issue.level))">{{ levelShort(issue.level) }}</span>
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
    <PaneDivider
      v-if="form"
      pane="issue"
      :value="detailShown"
      :min="ISSUE_PANE_MIN"
      :max="detailRoom"
      @input="setDetailW"
      @reset="resetDetailW"
    />
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
      <!-- the description's markdown blocks, rendered (SPL-73); the textarea stays the source -->
      <MessageBody
        v-if="hasMarkdownBlock(form.description)"
        class="issues-detail__rendered"
        data-test="issues-detail-rendered"
        :body="form.description"
      />
      <div class="issues-props">
        <button v-if="creating" type="button" class="issues-prop" data-test="issues-kind" :data-kind="draft.kind" @click="toggleKind">
          <span>{{ t('issues.kind_' + draft.kind) }}</span>
        </button>
        <button v-if="!isTopKind(form.kind) && form.kind !== 'subtask'" type="button" class="issues-prop" data-test="issues-epic" @click="openMenu('epic', detailOrDraft(), $event)">
          <span>{{ form.epic ? epicLabel(form.epic) : t('issues.no_epic') }}</span>
        </button>
        <button v-if="form.kind === 'subtask' && detail" type="button" class="issues-prop" data-test="issues-parent" @click="openParent">
          <span>{{ t('issues.parent_issue') }}: {{ detail.parent }}</span>
        </button>
        <button type="button" class="issues-prop" data-test="issues-status" @click="openMenu('status', detailOrDraft(), $event)">
          <IssueGlyph :name="statusIcon(form.status)" :size="16" />
          <span class="issues-status-host" :title="t(statusHintKey(form.status))">
            <span class="issues-status-code">{{ statusLabel(form.status) }}</span>
            <span class="issues-status-tip" role="tooltip">{{ t(statusHintKey(form.status)) }}</span>
          </span>
        </button>
        <button type="button" class="issues-prop" data-test="issues-priority" @click="openMenu('priority', detailOrDraft(), $event)">
          <span>{{ t('issues.field_priority') }} {{ form.priority }}</span>
        </button>
        <!-- SPL-949: level is the tree's (1 epic / feature, 2 issue, 3 subtask); the hub derives it, nobody picks it -->
        <span class="issues-prop issues-prop--fixed" data-test="issues-level" :data-level="form.level" :title="t(levelKey(form.level))">
          {{ t('issues.field_level') }} <span class="issues-level">{{ levelShort(form.level) }}</span>
        </span>
        <button type="button" class="issues-prop" data-test="issues-assignee" @click="openMenu('assign', detailOrDraft(), $event)">
          <SpoolAvatar v-if="activeAssignee" :id="activeAssignee" :box="boxOf(activeAssignee)" :size="20" />
          <HumanName v-if="activeAssignee" :id="activeAssignee" :box="boxOf(activeAssignee)" />
          <span v-else>{{ t('issues.no_assignee') }}</span>
        </button>
        <button type="button" class="issues-prop" data-test="issues-labels" @click="openMenu('label', detailOrDraft(), $event)">
          <span>{{ activeLabels.length ? activeLabels.map(labelText).join(', ') : t('issues.field_labels') }}</span>
        </button>
        <!-- owner, topic 778ad161: a calendar (month grid) plus a 24-hour time,
             shown and typed as YYYY-MM-DD HH:MM in every locale -->
        <div class="issues-field" role="group" :aria-label="t('issues.field_deadline')">
          <span>{{ t('issues.field_deadline') }}</span>
          <DeadlinePicker
            class="issues-deadline"
            :model-value="form.deadline"
            :label="t('issues.field_deadline')"
            test-id="issues-deadline"
            time-test-id="issues-deadline-time"
            @update:model-value="applyDeadline"
          />
        </div>
      </div>
      <p v-if="!creating && form.created_by" class="muted issues-meta">{{ t('issues.created_by', { name: person(form.created_by) }) }}</p>
      <p v-if="!creating && form.updated_by" class="muted issues-meta">{{ t('issues.updated_by', { name: person(form.updated_by) }) }}</p>
      <p v-if="saveError" class="issues-error" role="alert" data-test="issues-save-error">{{ t(saveError) }}</p>
      <button v-if="creating" type="button" class="btn" data-test="issues-create" :disabled="busy || !draft.title.trim() || (!isTopKind(draft.kind) && !draft.epic)" @click="createIssue">{{ busy ? t('issues.creating') : t('issues.create') }}</button>
      <!-- SPL-18 level 3: a level-2 issue's subtasks, in the right pane -->
      <section v-if="!creating && form.kind === 'issue'" class="issues-subs" data-test="issues-subtasks">
        <h3>{{ t('issues.subtasks') }}</h3>
        <button
          v-for="sub in subtasks"
          :key="sub.key"
          type="button"
          class="issues-sub"
          data-test="issues-subtask"
          :data-key="sub.key"
          :data-status="sub.status"
          @click="choose(sub)"
        >
          <IssueGlyph :name="statusIcon(sub.status)" :size="14" />
          <span class="issues-key">{{ sub.key }}</span>
          <span class="issues-title">{{ sub.title }}</span>
        </button>
        <form class="issues-sub-add" @submit.prevent="addSubtask">
          <input v-model="subtaskTitle" data-test="issues-subtask-input" :placeholder="t('issues.subtask_placeholder')" :aria-label="t('issues.add_subtask')">
          <button type="submit" class="btn ghost" data-test="issues-subtask-add" :disabled="busy || !subtaskTitle.trim()">{{ t('issues.add_subtask') }}</button>
        </form>
      </section>
      <section v-if="!creating && form.task_id" class="issues-talk" data-test="issues-talk">
        <!-- SPL-963: the discussion sits in the right pane and takes its titles / 5 rows / full -->
        <div class="issues-talk__h">
          <h3>{{ t('issues.discussion') }}</h3>
          <LazyCardClipControl pane="thread" />
        </div>
        <p v-if="!comments.length" class="muted" data-test="issues-comment-empty">{{ t('issues.comment_empty') }}</p>
        <article v-for="c in comments" :key="c.msg_id" class="issues-comment" :class="listClipClass(clipMode)" data-test="issues-comment" :data-clip-mode="clipMode">
          <HumanName :id="c.from" :box="c.from_box" />
          <time v-if="c.ts" class="muted" :datetime="c.ts">{{ when(c.ts) }}</time>
          <p v-if="clipMode === 'titles'" class="issues-comment__body issues-comment__title" data-test="issues-comment-title" :title="cardTitle(c.body)">{{ cardTitle(c.body) }}</p>
          <MessageBody v-else class="issues-comment__body" :body="c.body" />
        </article>
        <label class="issues-field">
          <span class="sr-only">{{ t('issues.comment_placeholder') }}</span>
          <textarea v-model="commentText" data-test="issues-comment-input" rows="2" :placeholder="t('issues.comment_placeholder')" />
        </label>
        <button type="button" class="btn" data-test="issues-comment-send" :disabled="busy || !commentText.trim()" @click="sendComment">{{ t('issues.comment_send') }}</button>
      </section>
    </aside>
    <div v-if="menu" class="issues-menu" :class="{ 'issues-menu--status': menu.kind === 'status' }" role="listbox" data-test="issues-menu" :style="menuStyle" @click.stop>
      <button
        v-for="(opt, i) in menuOptions"
        :key="opt.value"
        type="button"
        role="option"
        class="issues-menu__opt"
        data-test="issues-menu-option"
        :data-value="opt.value"
        :aria-selected="i === menuIndex ? 'true' : 'false'"
        :title="opt.hint || undefined"
        @click="applyMenu(opt.value)"
      >
        <span class="issues-status-code">{{ opt.label }}</span>
        <span v-if="opt.hint" class="issues-status-tip" role="tooltip">{{ opt.hint }}</span>
      </button>
      <form v-if="menu.kind === 'label'" class="issues-menu__add" @submit.prevent="addLabel">
        <input v-model="labelName" data-test="issues-label-name" :placeholder="t('issues.label_name')" :aria-label="t('issues.label_name')">
        <button type="submit" class="btn" data-test="issues-label-add">{{ t('issues.add_label') }}</button>
      </form>
    </div>
  </div>
</template>

<script setup lang="ts">
import type { EpicSummary, Issue, IssueFilter, IssueLabel } from '~/utils/issues.mjs'
import { hasMarkdownBlock } from '~/utils/code-blocks.mjs'
import { useSessionStore } from '~/stores/session'
import { useRosterStore } from '~/stores/roster'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useHumanNames } from '~/composables/useHumanNames'
import { useLive } from '~/composables/useLive'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { ISSUE_CHANNEL } from '~/utils/parent-section.mjs'
import { tabForPath } from '~/utils/sidebar-tabs.mjs'
import { shownPerson } from '~/utils/channel-feed.mjs'
import { useCardClip } from '~/composables/useCardClip'
import { cardTitle, listClipClass } from '~/utils/card-clip.mjs'
import { ISSUE_STATUSES, PRIO_DEFAULT, createMockIssues, isTopKind, normalizeIssue, normalizeLabel } from '~/utils/issues.mjs'
import {
  ISSUE_LEVELS,
  ISSUE_PANE_DEFAULT,
  ISSUE_PANE_MIN,
  ISSUE_PRIORITIES,
  LEVEL_SHORT,
  applyIssueFrame,
  applyLabelFrame,
  clampIssuePane,
  deadlineToLocalInput,
  groupIssues,
  levelKey,
  loadIssuePane,
  localInputToDeadline,
  saveIssuePane,
  controlLabel,
  statusHintKey,
  statusLabel,
  stepKey,
  visibleOrder,
} from '~/utils/issues-view.mjs'

type Note = { msg_id: string, from: string, from_box: string, body: string, ts: string }

const STATUS_ICON: Record<string, string> = {
  eval: 'status-backlog',
  todo: 'status-todo',
  wip: 'status-progress',
  diss: 'status-canceled',
  qas: 'status-review',
  done: 'status-done',
}
function statusIcon(status: string): string {
  return STATUS_ICON[status] || 'status-backlog'
}

const { t } = useI18n({ useScope: 'global' })
const { mode: clipMode } = useCardClip('thread')
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
const sortF = ref('priority')
const statusF = ref('')
const statusOpen = ref(false)
const priorityF = ref('')
const levelF = ref('')
const assigneeF = ref('')
const labelF = ref('')
const dueF = ref('')
const collapsed = ref<Record<string, boolean>>({ done: true, diss: true })
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
const pageEl = ref<HTMLElement | null>(null)
const detailW = ref(ISSUE_PANE_DEFAULT)
const detailRoom = ref(720)
const draft = reactive({
  title: '', description: '', status: 'todo', priority: PRIO_DEFAULT,
  assignee: '', labels: [] as string[], deadlineLocal: '',
  epic: '', kind: 'issue' as 'issue' | 'epic' | 'feature',
})
const subtasks = ref<Issue[]>([])
const subtaskTitle = ref('')
/* SPL-18: the epics of the tenant (the hub's summary), shared with the
   Issues tab's left-most panel (ChannelSidebar reads the same state). */
const epics = useState<EpicSummary[]>('issue-epics', () => [])
const epicF = computed(() => {
  const q = route.query.epic
  const raw = Array.isArray(q) ? q[0] : q
  return typeof raw === 'string' ? raw.trim().toUpperCase() : ''
})
const epicTitle = computed(() => epics.value.find((e) => e.key === epicF.value)?.title || '')
function epicLabel(key: string) {
  const e = epics.value.find((x) => x.key === key)
  return e ? `${e.key} ${e.title}` : key
}
function epicTitleOf(key: string) {
  return epics.value.find((x) => x.key === key)?.title || key
}
function toggleKind() {
  draft.kind = draft.kind === 'issue' ? 'epic' : draft.kind === 'epic' ? 'feature' : 'issue'
}
/* SPL-18 level 3: the open issue's subtasks (parent=), re-read after a
   frame that names it and after a subtask is added */
async function loadSubtasks(issue: Issue | null) {
  if (!issue || issue.kind !== 'issue') { subtasks.value = []; return }
  try {
    const data = await withSessionRetry(api, () => api.listIssues({ filter: { parent: [issue.key] }, sort: 'created' }))
    if (detail.value?.key === issue.key) subtasks.value = (data.issues || []).map((row) => normalizeIssue(row))
  } catch {
    subtasks.value = []
  }
}
async function addSubtask() {
  const parent = detail.value
  const title = subtaskTitle.value.trim()
  if (!parent || !title) return
  busy.value = true
  saveError.value = ''
  try {
    await withSessionRetry(api, () => api.createIssue({ title, parent: parent.key }))
    subtaskTitle.value = ''
    await loadSubtasks(parent)
  } catch (e) {
    saveError.value = errorKey(e as { status?: number, token?: string }, 'one')
  } finally {
    busy.value = false
  }
}
async function openParent() {
  const key = detail.value?.parent || ''
  if (!key) return
  const held = issues.value.find((i) => i.key === key)
  if (held) { choose(held); return }
  try {
    const data = await withSessionRetry(api, () => api.getIssue(key))
    choose(normalizeIssue(data.issue))
  } catch (e) {
    saveError.value = errorKey(e as { status?: number, token?: string }, 'one')
  }
}

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
  return isoDateTime(rfc)
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
  const f: IssueFilter = { kind: 'issue' }
  if (epicF.value) f.epic = [epicF.value]
  if (statusF.value) f.status = [statusF.value]
  if (priorityF.value !== '') f.priority = [Number(priorityF.value)]
  if (levelF.value !== '') f.level = [Number(levelF.value)]
  if (assigneeF.value) f.assignee = [assigneeF.value]
  if (labelF.value) f.label = [labelF.value]
  /* one day: issues due on or before its last minute */
  const before = dueF.value ? localInputToDeadline(`${dueF.value}:59`) : ''
  if (before) f.deadlineBefore = before
  return f
}
function errorKey(err: { status?: number, token?: string }, which: 'list' | 'one') {
  const status = Number(err && err.status) || 0
  const token = String((err && err.token) || '')
  if (status === 401 || token === 'view_door' || token === 'unauthenticated') return 'issues.signed_out'
  if (status === 403) return 'issues.forbidden'
  if (status === 404) return which === 'list' ? 'issues.unavailable' : 'issues.not_found'
  if (token === 'epic_required') return 'issues.err_epic_required'
  if (token === 'bad_epic') return 'issues.err_bad_epic'
  if (token === 'epic_has_issues') return 'issues.err_epic_has_issues'
  if (status === 503 || token === 'unavailable') return 'issues.unavailable'
  return which === 'list' ? 'issues.load_failed' : 'issues.save_failed'
}

/* the whole closed-control text, for the hover when it is ellipsized */
const assigneeTitle = computed(() => {
  const v = assigneeF.value
  const who = !v ? t('issues.filter_all') : v === 'me' ? t('issues.filter_me') : v === 'none' ? t('issues.filter_unassigned') : (assigneeOptions.value.find((p) => p.id === v)?.label || v)
  return controlLabel(t('issues.filter_assignee'), who)
})
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
const groups = computed(() => groupIssues(issues.value, { sort: sortF.value, filter: serverFilter(), me: meId(), hideEmpty: false }))
const flat = computed(() => visibleOrder(groups.value, Object.fromEntries(
  ISSUE_STATUSES.map((s) => [s, isCollapsed(s)]),
)))
const activeAssignee = computed(() => creating.value ? draft.assignee : (detail.value?.assignee || ''))
const activeLabels = computed(() => creating.value ? draft.labels : (detail.value?.labels || []))
const detailShown = computed(() => clampIssuePane(detailW.value, detailRoom.value))
const detailStyle = computed(() => ({ '--issues-detail-w': `${detailShown.value}px` }))
function measureDetailRoom() {
  const page = pageEl.value?.clientWidth || 0
  const room = (page > 0 ? page : 900) - 360 - 6
  detailRoom.value = Math.max(ISSUE_PANE_MIN, Math.min(720, Math.round(room)))
}
function setDetailW(n: number) {
  detailW.value = clampIssuePane(n, detailRoom.value)
  saveIssuePane(detailW.value)
}
function resetDetailW() {
  setDetailW(ISSUE_PANE_DEFAULT)
}
const form = computed(() => {
  if (creating.value) {
    return {
      key: '', title: draft.title, description: draft.description, status: draft.status,
      priority: draft.priority, level: isTopKind(draft.kind) ? 1 : 2, deadline: draft.deadlineLocal,
      created_by: '', updated_by: '', task_id: '', epic: isTopKind(draft.kind) ? '' : draft.epic, kind: draft.kind as string,
    }
  }
  const d = detail.value
  if (!d) return null
  return {
    key: d.key, title: d.title, description: d.description, status: d.status,
    priority: d.priority, level: d.level, deadline: deadlineToLocalInput(d.deadline),
    created_by: d.created_by, updated_by: d.updated_by, task_id: d.task_id, epic: d.epic, kind: d.kind as string,
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
    epics.value = data.epics || []
    if (cursorKey.value && !flat.value.some((i) => i.key === cursorKey.value)) cursorKey.value = flat.value[0]?.key || ''
    void openLinkedIssue()
  } catch (e) {
    loadError.value = errorKey(e as { status?: number, token?: string }, 'list')
  } finally {
    loading.value = false
  }
}

function pickStatus(s: string) {
  statusF.value = s
  statusOpen.value = false
}
function clearFilters() {
  sortF.value = 'priority'
  statusF.value = ''
  statusOpen.value = false
  priorityF.value = ''
  levelF.value = ''
  assigneeF.value = ''
  labelF.value = ''
  dueF.value = ''
}
function toggleGroup(status: string) {
  collapsed.value = { ...collapsed.value, [status]: !collapsed.value[status] }
}
function issueLinkKey(): string {
  if (import.meta.client) {
    try { return new URL(window.location.href).searchParams.get('issue')?.trim() || '' } catch { /* use the route */ }
  }
  const q = route.query.issue
  const raw = Array.isArray(q) ? q[0] : q
  return typeof raw === 'string' ? raw.trim() : ''
}
function writeIssueQuery(key: string) {
  if (!import.meta.client) return
  const url = new URL(window.location.href)
  if ((url.searchParams.get('issue') || '') === key) return
  if (key) url.searchParams.set('issue', key)
  else url.searchParams.delete('issue')
  window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash)
}
function choose(issue: Issue) {
  cursorKey.value = issue.key
  creating.value = false
  openKey.value = issue.key
  detail.value = issue
  menu.value = null
  if (collapsed.value[issue.status]) collapsed.value = { ...collapsed.value, [issue.status]: false }
  writeIssueQuery(issue.key)
}
function closeDetail() {
  creating.value = false
  openKey.value = ''
  detail.value = null
  menu.value = null
  writeIssueQuery('')
}
function startCreate() {
  creating.value = true
  openKey.value = ''
  detail.value = null
  writeIssueQuery('')
  draft.title = ''
  draft.description = ''
  draft.status = 'todo'
  draft.priority = PRIO_DEFAULT
  draft.assignee = ''
  draft.labels = []
  draft.deadlineLocal = ''
  draft.kind = 'issue'
  draft.epic = epicF.value || epics.value.find((e) => e.status !== 'done' && e.status !== 'diss')?.key || epics.value[0]?.key || ''
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
    level: isTopKind(draft.kind) ? 1 : 2,
    assignee: draft.assignee,
    labels: draft.labels,
    epic: draft.epic,
    kind: draft.kind,
  })
}

const menuOptions = computed(() => {
  const kind = menu.value?.kind || ''
  const hint = ''
  if (kind === 'status') return ISSUE_STATUSES.map((s) => ({ value: s, label: statusLabel(s), hint: t(statusHintKey(s)) }))
  if (kind === 'priority') return ISSUE_PRIORITIES.map((n) => ({ value: String(n), label: String(n), hint }))
  if (kind === 'assign') return [{ value: '', label: t('issues.no_assignee'), hint }, ...assigneeOptions.value.map((p) => ({ value: p.id, label: p.label, hint }))]
  if (kind === 'label') return labels.value.filter((l) => l.id !== 'epic').map((l) => ({ value: l.id, label: l.name, hint }))
  if (kind === 'epic') return epics.value.map((e) => ({ value: e.key, label: `${e.key} ${e.title}`, hint }))
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
    writeIssueQuery(issue.key)
  }
  void nextTick(scrollSelected)
}
function hold(issue: Issue) {
  issues.value = applyIssueFrame(issues.value, { type: 'issue', issue })
  refreshEpics()
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
function applyDeadline(local: string) {
  if (creating.value) { draft.deadlineLocal = local; return }
  if (!detail.value) return
  const deadline = localInputToDeadline(local)
  if (deadline === null) return
  void save(detail.value.key, { deadline })
}
async function applyMenu(value: string) {
  const kind = menu.value?.kind || ''
  if (!kind) return
  if (creating.value) {
    if (kind === 'status') draft.status = value
    else if (kind === 'priority') draft.priority = Number(value)
    else if (kind === 'assign') draft.assignee = value
    else if (kind === 'epic') draft.epic = value
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
  else if (kind === 'assign') body.assignee = value
  else if (kind === 'epic') body.parent = value /* issues-v1: parent is the epic; an older hub knows only parent */
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
  }
  if (draft.assignee) body.assignee = draft.assignee
  if (draft.labels.length) body.labels = draft.labels.slice()
  /* The label and parent forms work on every hub since 0.7.0 (issues-v1 §8:
     the epic label makes an epic, parent is the epic). */
  if (isTopKind(draft.kind)) body.kind = draft.kind
  else body.parent = draft.epic
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
    writeIssueQuery(created.key)
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
      await sock.send({ task_id: issue.task_id, kind: 'note', body: text, files: [], channel: issue.channel || ISSUE_CHANNEL, is_parent: 0 })
    } else {
      await api.sendMessage({ text, task_id: issue.task_id, channel: issue.channel || ISSUE_CHANNEL, is_parent: 0 })
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
    if (statusOpen.value) { statusOpen.value = false; return }
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
  const kind = { s: 'status', p: 'priority', a: 'assign', l: 'label' }[k]
  const issue = creating.value ? detailOrDraft() : (detail.value || flat.value.find((i) => i.key === cursorKey.value) || flat.value[0])
  if (kind && issue) { openMenu(kind, issue); ev.preventDefault() }
}

watch([statusF, priorityF, levelF, assigneeF, labelF, dueF, sortF, epicF], () => { void load() })
watch(() => session.state, () => { void load() }, { immediate: true })
async function openLinkedIssue() {
  const key = issueLinkKey()
  if (!key) return
  if (detail.value && detail.value.key.toLowerCase() === key.toLowerCase()) return
  let issue = issues.value.find((i) => i.key.toLowerCase() === key.toLowerCase())
  if (!issue) {
    try {
      const data = await withSessionRetry(api, () => api.getIssue(key))
      issue = normalizeIssue(data.issue)
      hold(issue)
    } catch {
      return
    }
  }
  choose(issue)
}
watch(detail, (issue) => {
  if (creating.value) return
  void loadComments(issue)
  void loadSubtasks(issue)
})
watch(() => {
  const q = route.query.issue
  const raw = Array.isArray(q) ? q[0] : q
  return typeof raw === 'string' ? raw.trim() : ''
}, () => { void openLinkedIssue() })
watch(creating, (on) => { if (on) comments.value = [] })

/* SPL-18: a frame can move an issue between epics or change its status, so
   the left-most panel's counts are re-read (one light read, debounced). */
let epicsTimer: ReturnType<typeof setTimeout> | null = null
function refreshEpics() {
  if (epicsTimer) clearTimeout(epicsTimer)
  epicsTimer = setTimeout(async () => {
    epicsTimer = null
    try {
      const data = await withSessionRetry(api, () => api.listIssues({ filter: { kind: 'epic' } }))
      epics.value = data.epics || []
    } catch { /* the next load re-reads it */ }
  }, 400)
}
let offIssue = () => {}
let offLabel = () => {}
let offMsg = () => {}
let offBack = () => {}
let detailObserver: ResizeObserver | null = null
function onDocPointer(ev: Event) {
  if (!statusOpen.value) return
  const root = pageEl.value?.querySelector('[data-test=issues-filter-status]')
  const t = ev.target
  if (root && t instanceof Node && root.contains(t)) return
  statusOpen.value = false
}
onMounted(() => {
  useTopicStore().close()
  useLiveFeed('pane').close()
  detailW.value = loadIssuePane()
  measureDetailRoom()
  document.addEventListener('keydown', onDocKey)
  document.addEventListener('pointerdown', onDocPointer)
  if (typeof ResizeObserver !== 'undefined' && pageEl.value) {
    detailObserver = new ResizeObserver(() => measureDetailRoom())
    detailObserver.observe(pageEl.value)
  }
  offIssue = live.onIssue((f) => {
    issues.value = applyIssueFrame(issues.value, f)
    refreshEpics()
    const fi = (f as { issue?: { parent?: string } }).issue
    if (detail.value && fi && fi.parent === detail.value.key) void loadSubtasks(detail.value)
  })
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
  document.removeEventListener('pointerdown', onDocPointer)
  detailObserver?.disconnect()
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
.issues-sort { margin-inline-end: 10px; }
.issues-filter-when {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
  max-width: 100%;
  font-size: 0.8125rem;
  color: var(--color-muted);
}
.issues-filter-when input { max-width: 11rem; }
.issues-filters select,
.issues-filters input,
.issues-status-dd__btn {
  max-width: 100%;
  min-width: 0;
  background: var(--color-bg-2);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 4px 8px;
  font: inherit;
}
/* owner, topic e00da93b: the closed Assignee control is as wide as its value,
   like prio / level, never wider than 13em; a long name ends in an ellipsis
   and reads in full on hover. The open list keeps its own width. Firefox has
   no field-sizing yet and just gets the cap. */
.issues-filter-who { position: relative; display: inline-flex; align-items: center; min-width: 0; }
.issues-filter-who__icon { position: absolute; inset-inline-start: 8px; pointer-events: none; color: var(--color-muted); }
.issues-filters .issues-filter-assignee {
  padding-inline-start: 26px;
  field-sizing: content;
  max-width: 13em;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.issues-status-dd { position: relative; }
.issues-status-dd__btn { cursor: pointer; text-align: start; }
.issues-status-dd__list {
  position: absolute;
  z-index: 25;
  top: calc(100% + 4px);
  left: 0;
  min-width: 8rem;
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  padding: 4px;
  box-shadow: var(--focus-3d);
}
.issues-status-dd__opt,
.issues-menu__opt,
.issues-status-host { position: relative; }
.issues-status-dd__opt {
  display: block;
  width: 100%;
  text-align: start;
  background: transparent;
  border: 0;
  color: inherit;
  font: inherit;
  padding: 4px 8px;
  cursor: pointer;
}
.issues-status-dd__opt[aria-selected="true"] { background: var(--color-selected); }
.issues-status-tip {
  display: none;
  position: absolute;
  left: calc(100% + 6px);
  top: 50%;
  transform: translateY(-50%);
  z-index: 40;
  white-space: nowrap;
  pointer-events: none;
  padding: 2px 6px;
  font-size: 0.75rem;
  line-height: 1.3;
  color: var(--color-fg);
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  box-shadow: var(--focus-3d);
}
.issues-status-dd__opt:hover > .issues-status-tip,
.issues-status-dd__opt:focus-visible > .issues-status-tip,
.issues-menu__opt:hover > .issues-status-tip,
.issues-menu__opt:focus-visible > .issues-status-tip,
.issues-status-host:hover > .issues-status-tip,
.issues-status-host:focus-visible > .issues-status-tip { display: block; }
.issues-menu--status { overflow: visible; }
.issues-menu--status .issues-status-tip { left: auto; right: calc(100% + 6px); }
.issues-prop .issues-status-tip { left: auto; right: 0; top: calc(100% + 4px); transform: none; }
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
.issues-prio {
  display: inline-block;
  min-width: 1.25rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  font-size: 0.75rem;
  font-variant-numeric: tabular-nums;
  text-align: center;
}
.issues-prio--1 { color: var(--color-danger); }
.issues-prio--2 { color: var(--color-warn); }
.issues-prio--3 { color: var(--color-accent); }
.issues-prio--4, .issues-prio--5 { color: var(--color-muted); }
.issues-st--wip { color: var(--color-warn); }
.issues-st--qas { color: var(--color-accent-2); }
.issues-st--done, .issues-st--eval { color: var(--color-ok); }
.issues-st--diss, .issues-st--todo { color: var(--color-muted); }
.issues-detail {
  flex: 0 0 var(--issues-detail-w, 380px);
  width: var(--issues-detail-w, 380px);
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
.issues-prop--fixed { cursor: default; display: inline-flex; align-items: center; gap: 4px; }
.issues-meta { margin: 0; font-size: 0.75rem; }
.issues-talk { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.issues-deadline { display: flex; gap: 6px; flex-wrap: wrap; }
.issues-deadline select { min-width: 5.5rem; }
.issues-subs { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.issues-subs h3 { margin: 8px 0 0; font-size: 0.875rem; }
.issues-sub { display: flex; align-items: center; gap: 8px; min-width: 0; padding: 4px 6px; border: 0; border-radius: var(--radius-sm); background: transparent; color: inherit; text-align: start; cursor: pointer; }
.issues-sub:hover { background: color-mix(in srgb, currentColor 8%, transparent); }
.issues-sub .issues-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.issues-sub-add { display: flex; gap: 6px; }
.issues-sub-add input { flex: 1; min-width: 0; }
.issues-talk h3 { margin: 8px 0 0; font-size: 0.875rem; }
.issues-talk__h { display: flex; align-items: center; gap: 8px; min-width: 0; }
/* SPL-963: titles = one line, 5 rows = at most 5 lines, full = all of it */
.issues-comment__title { margin: 2px 0 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.list-clip--rows .issues-comment__body { max-height: calc(5 * 1.45em); overflow: hidden; }
.issues-comment { min-width: 0; }
.issues-comment__body { margin-top: 2px; min-width: 0; }
.issues-detail__rendered {
  min-width: 0;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
}
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
