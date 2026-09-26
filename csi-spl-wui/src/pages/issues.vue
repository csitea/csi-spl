<!-- Issues (GRK-3519, topic 9c19bfe9). Three panes stay: the rail, this list,
     and the detail on the right. The description is only in the detail.
     Deadline is a calendar with a time, stored UTC. The hub contract is
     issues-v1 (CLE-34993): GET /v1/view/issues, POST /v1/issues, PATCH. -->
<template>
  <div ref="pageEl" class="issues-page" data-test="issues-page" :style="detailStyle">
    <div class="issues-list" data-test="issues-list">
      <header class="feed-header issues-head">
        <h2 data-test="issues-heading">{{ epicTitle || t('issues.title') }}</h2>
        <!-- SPL-978: "just a button with + the google way": a round accent button, the plus only -->
        <button type="button" class="issues-fab" data-test="issues-new" :aria-label="t('issues.new')" :title="t('issues.new')" @click="startCreate">
          <UiIcon name="plus" :size="22" :stroke-width="2.5" />
        </button>
      </header>
      <p class="issues-shortcuts muted" data-test="issues-shortcuts">{{ t('issues.shortcuts') }}</p>
      <!-- owner, topic e00da93b: "it should look like a gsheet with columns and a
           table". The list is a table: row 1 the column names, row 2 each
           column's filter (sticky, like a sheet's filter row), then one issue
           per row in the same columns. A header click sorts by that column
           (▲, ▼, then back to Updated newest first). On a phone the table
           scrolls sideways inside its pane. -->
      <div class="issues-tools" data-test="issues-tools">
        <button type="button" class="btn ghost" data-test="issues-filter-clear" @click="clearFilters">{{ t('issues.filter_clear') }}</button>
        <p v-if="saveError && !form" class="issues-error" role="alert" data-test="issues-list-error">{{ t(saveError) }}</p>
      </div>
      <div ref="scrollerEl" class="issues-scroll">
        <table class="issues-table" data-test="issues-table">
          <thead ref="theadEl" class="issues-filters" data-test="issues-filters">
            <tr class="issues-names">
              <th
                v-for="c in sheetColumns"
                :key="c.col"
                scope="col"
                :class="c.cls"
                :aria-sort="sheetSort.col === c.col ? (sheetSort.dir === 'asc' ? 'ascending' : 'descending') : 'none'"
              >
                <button
                  type="button"
                  class="issues-sort-h"
                  :data-test="'issues-sort-' + c.col"
                  :data-sorted="sheetSort.col === c.col ? sheetSort.dir : undefined"
                  @click="toggleSort(c.col)"
                >{{ c.name }}<span class="issues-sort-mark" aria-hidden="true">{{ sheetSort.col === c.col ? (sheetSort.dir === 'asc' ? '▲' : '▼') : '' }}</span></button>
              </th>
            </tr>
            <tr class="issues-frow">
              <th class="issues-c-key" />
              <th />
              <th>
                <div class="issues-status-dd" data-test="issues-filter-status">
                  <button
                    type="button"
                    class="issues-status-dd__btn"
                    data-test="issues-filter-status-btn"
                    :aria-label="t('issues.filter_status')"
                    :aria-expanded="statusOpen ? 'true' : 'false'"
                    :title="statusF ? t(statusHintKey(statusF)) : undefined"
                    @click="statusOpen = !statusOpen"
                  >{{ statusF ? statusLabel(statusF) : t('issues.filter_all') }}</button>
                  <div v-show="statusOpen" class="issues-status-dd__list" role="listbox">
                    <button type="button" class="issues-status-dd__opt" data-test="issues-filter-status-all" @click="pickStatus('')">
                      {{ t('issues.filter_all') }}
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
              </th>
              <th>
                <select v-model="priorityF" data-test="issues-filter-priority" :aria-label="t('issues.filter_priority')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="n in ISSUE_PRIORITIES" :key="n" :value="String(n)">{{ n }}</option>
                </select>
              </th>
              <th>
                <select v-model="levelF" data-test="issues-filter-level" :aria-label="t('issues.filter_level')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="n in ISSUE_LEVELS" :key="'lv' + n" :value="String(n)" :title="t(levelKey(n))">{{ n }}</option>
                </select>
              </th>
              <th>
                <select v-model="assigneeF" class="issues-filter-assignee" data-test="issues-filter-assignee" :aria-label="t('issues.filter_assignee')" :title="assigneeTitle">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option value="me">{{ t('issues.filter_me') }}</option>
                  <option value="none">{{ t('issues.filter_unassigned') }}</option>
                  <option v-for="p in assigneeOptions" :key="p.id" :value="p.id">{{ p.label }}</option>
                </select>
              </th>
              <th>
                <select v-model="labelF" data-test="issues-filter-label" :aria-label="t('issues.filter_label')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="l in labels" :key="l.id" :value="l.id">{{ l.name }}</option>
                </select>
              </th>
              <!-- owner, topic 778ad161: the calendar control, YYYY-MM-DD HH:MM; due on or before that minute -->
              <th role="group" :aria-label="t('issues.field_deadline')" data-test="issues-filter-deadline">
                <DeadlinePicker v-model="dueF" :label="t('issues.field_deadline')" test-id="issues-filter-deadline-date" time-test-id="issues-filter-deadline-time" default-time="23:59" />
              </th>
              <th />
            </tr>
          </thead>
          <tbody v-if="(loading && !issues.length) || loadError || !rowCount">
            <tr>
              <td colspan="9" class="issues-note">
                <p v-if="loading && !issues.length" class="muted" data-test="issues-loading">{{ t('issues.loading') }}</p>
                <p v-else-if="loadError" class="issues-error" role="alert" data-test="issues-error">{{ t(loadError) }}</p>
                <p v-else class="muted" data-test="issues-empty">{{ t('issues.empty') }}</p>
              </td>
            </tr>
          </tbody>
          <tbody v-for="g in shownGroups" :key="g.status || 'all'" class="issues-group" :data-status="g.status">
              <tr
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
                <td class="issues-c-key"><span class="issues-key">{{ issue.key }}</span></td>
                <td class="issues-c-title">
                  <span class="issues-title-cell">
                    <span class="issues-title" :title="issue.title">{{ issue.title }}</span>
                    <button v-if="!epicF && issue.epic" type="button" class="issues-pill issues-epic-tag" data-test="issues-row-epic" :title="epicTitleOf(issue.epic)" @click.stop="openMenu('epic', issue, $event)">{{ epicTitleOf(issue.epic) }}</button>
                  </span>
                </td>
                <td>
                  <button type="button" class="issues-iconbtn issues-row-status" data-test="issues-row-status" :data-status="issue.status" :aria-label="t('issues.filter_status')" :title="t(statusHintKey(issue.status))" @click.stop="openMenu('status', issue, $event)">
                    <IssueGlyph :name="statusIcon(issue.status)" :size="14" :class="'issues-st issues-st--' + issue.status" />
                    <span class="issues-status-code">{{ statusLabel(issue.status) }}</span>
                  </button>
                </td>
                <!-- owner, topic e0f6f074 (SPL-972): prio and level are select boxes in the sheet -->
                <td @click.stop>
                  <select
                    class="issues-cell-select issues-prio"
                    :class="'issues-prio--' + issue.priority"
                    data-test="issues-row-priority"
                    :data-priority="issue.priority"
                    :aria-label="t('issues.field_priority')"
                    :value="String(issue.priority)"
                    @keydown.stop
                    @change="onRowPriority(issue, $event)"
                  >
                    <option v-for="n in ISSUE_PRIORITIES" :key="n" :value="String(n)">{{ n }}</option>
                  </select>
                </td>
                <td @click.stop>
                  <select
                    class="issues-cell-select"
                    data-test="issues-row-level"
                    :data-level="issue.level"
                    :aria-label="t('issues.field_level')"
                    :title="t(levelKey(issue.level))"
                    :value="String(issue.level)"
                    @keydown.stop
                    @change="onRowLevel(issue, $event)"
                  >
                    <option v-for="n in ISSUE_LEVELS" :key="'rl' + n" :value="String(n)" :title="t(levelKey(n))">{{ n }}</option>
                  </select>
                </td>
                <td>
                  <button type="button" class="issues-person" data-test="issues-row-assignee" :data-assignee="issue.assignee" :aria-label="t('issues.field_assignee')" @click.stop="openMenu('assign', issue, $event)">
                    <SpoolAvatar v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" :size="20" />
                    <HumanName v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" />
                    <span v-else class="muted">{{ t('issues.no_assignee') }}</span>
                  </button>
                </td>
                <td>
                  <span class="issues-pills">
                    <button v-for="id in issue.labels" :key="id" type="button" class="issues-pill" data-test="issues-row-label" @click.stop="openMenu('label', issue, $event)">
                      <i class="issues-dot" :style="dotStyle(id)" />{{ labelText(id) }}
                    </button>
                  </span>
                </td>
                <td><time v-if="issue.deadline" class="issues-when" :datetime="issue.deadline">{{ when(issue.deadline) }}</time></td>
                <td><time v-if="issue.updated_at" class="issues-when issues-updated" :datetime="issue.updated_at">{{ when(issue.updated_at) }}</time></td>
              </tr>
          </tbody>
        </table>
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
      <!-- SPL-975: rendered markdown; a click or `e` edits, a click elsewhere saves -->
      <IssueDescription
        ref="descEl"
        :key="form.key || 'new'"
        :text="form.description"
        :save="saveDescription"
        :keep-open="creating"
        @draft="onDescriptionDraft"
        @submit="onDescriptionSubmit"
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
        <!-- owner, topic e0f6f074 (SPL-972): a select box, like the sheet's prio cells -->
        <label class="issues-prop issues-prop--select">
          <span>{{ t('issues.field_priority') }}</span>
          <select class="issues-cell-select" data-test="issues-priority" :aria-label="t('issues.field_priority')" :value="String(form.priority)" @keydown.stop @change="onDetailPriority">
            <option v-for="n in ISSUE_PRIORITIES" :key="'dp' + n" :value="String(n)">{{ n }}</option>
          </select>
        </label>
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
        <!-- SPL-974: one plus+hierarchy icon; the subtask UI is a modal -->
        <div class="issues-subs__h">
          <h3>{{ t('issues.subtasks') }}</h3>
          <button
            type="button"
            class="issues-sub-add"
            data-test="issues-subtask-open"
            :title="t('issues.add_subtask')"
            :aria-label="t('issues.add_subtask')"
            aria-haspopup="dialog"
            @click="subtaskOpen = true"
          >
            <UiIcon name="subtask-add" :size="18" />
          </button>
        </div>
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
        <!-- not Lazy: a click before a lazy chunk lands mounts the dialog
             already open, so UiDialog's open watch never runs (no focus, no trap) -->
        <IssueSubtaskDialog v-model:open="subtaskOpen" :parent-key="form.key" :assignees="assigneeOptions" @created="onSubtaskCreated" />
      </section>
      <section v-if="!creating && form.task_id" class="issues-talk" data-test="issues-talk">
        <!-- SPL-963: the discussion sits in the right pane and takes its titles / 5 rows / full -->
        <div class="issues-talk__h">
          <h3>{{ t('issues.discussion') }}</h3>
          <LazyCardClipControl pane="thread" />
        </div>
        <p v-if="!comments.length" class="muted" data-test="issues-comment-empty">{{ t('issues.comment_empty') }}</p>
        <!-- SPL-982 (owner, topic 8296eeec): a comment is a message card like every
             other one: the same header, the emoji 5px after the time, reactions,
             the row menu, and the thread's titles / 5 rows / full clip -->
        <MessageCard
          v-for="c in comments"
          :key="c.msg_id"
          class="issues-comment"
          data-test="issues-comment"
          :data-clip-mode="clipMode"
          :msg="c"
          :clip-mode="clipMode"
          @edited="onCommentEdited"
          @deleted="onCommentDeleted"
          @reacted="onCommentReacted"
        />
        <label class="issues-field">
          <span class="sr-only">{{ t('issues.comment_placeholder') }}</span>
          <!-- owner, topic 593a804a (SPL-973): no Comment button. Which key
               sends is Settings -> Behaviour -> "Text fields" (SPL-976) -->
          <!-- SPL-985: @ opens the shared picker; Enter / Tab pick while it is open -->
          <span class="mention-anchor">
            <textarea
              ref="commentEl"
              v-model="commentText"
              data-test="issues-comment-input"
              rows="2"
              :placeholder="t(sk('issues_view.comment_hint'))"
              :disabled="busy"
              @input="commentMp.sync"
              @click="commentMp.sync"
              @keyup="commentMp.sync"
              @blur="commentMp.close"
              @keydown="commentMp.onKeydown($event) || onSubmitKey($event, sendComment)"
            />
            <MentionList :picker="commentMp" placement="above" />
          </span>
        </label>
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
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useMentionPoke } from '~/composables/useMentionPoke'
import type { EpicSummary, Issue, IssueFilter, IssueLabel } from '~/utils/issues.mjs'
import { useSessionStore } from '~/stores/session'
import { useRosterStore } from '~/stores/roster'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useHumanNames } from '~/composables/useHumanNames'
import { useLive } from '~/composables/useLive'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { applyEdit } from '~/utils/msg-edit.mjs'
import { applyReactions as patchReactions } from '~/utils/emoji.mjs'
import { withoutMsg } from '~/utils/feed.mjs'
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { ISSUE_CHANNEL } from '~/utils/parent-section.mjs'
import { tabForPath } from '~/utils/sidebar-tabs.mjs'
import { shownPerson } from '~/utils/channel-feed.mjs'
import { useCardClip } from '~/composables/useCardClip'
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
  hubSort,
  nextSort,
  sortFromQuery,
  sortSheet,
  levelKey,
  loadIssuePane,
  localInputToDeadline,
  saveIssuePane,
  controlLabel,
  statusHintKey,
  statusLabel,
  stepKey,
} from '~/utils/issues-view.mjs'

/* an issue comment is the whole message row (MessageCard reads kind, to,
   reactions, edited_at ...), with the fields the page reads made safe */
type Note = SpoolMessage

const STATUS_ICON: Record<string, string> = {
  eval: 'status-backlog',
  todo: 'status-todo',
  wip: 'status-progress',
  diss: 'status-canceled',
  blocked: 'status-blocked',
  onhold: 'status-onhold',
  qas: 'status-review',
  done: 'status-done',
}
function statusIcon(status: string): string {
  return STATUS_ICON[status] || 'status-backlog'
}

const { t } = useI18n({ useScope: 'global' })
/* SPL-976: every text field's Enter follows Settings -> Behaviour -> "Text fields" */
const { onKeydown: onSubmitKey, hintFor: sk } = useSubmitKey()
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
/* owner, topics e65c0f60 + e00da93b: one flat list, sorted by a header click;
   the default is Updated, newest first. The sort lives in ?sort=&dir=. */
const sheetSort = ref(sortFromQuery(route.query as Record<string, unknown>))
const statusF = ref('')
const statusOpen = ref(false)
const priorityF = ref('')
const levelF = ref('')
const assigneeF = ref('')
const labelF = ref('')
const dueF = ref('')
const cursorKey = ref('')
const openKey = ref('')
const creating = ref(false)
const detail = ref<Issue | null>(null)
const comments = ref<Note[]>([])
const commentText = ref('')
const commentEl = ref<HTMLTextAreaElement | null>(null)
const commentMp = useMentionPicker({ text: commentText, el: commentEl })
/* SPL-985 (spec 042 §3): whoever a stored description, comment or new issue
   newly mentions gets a DM asking them to act; issues are tenant-wide (K4) */
const { poke } = useMentionPoke()
const menu = ref<{ kind: string, key: string } | null>(null)
const menuIndex = ref(0)
const menuPos = ref({ top: 80, left: 80 })
const labelName = ref('')
const titleEl = ref<HTMLInputElement | null>(null)
const descEl = ref<{ edit: () => Promise<void> } | null>(null)
const scrollerEl = ref<HTMLElement | null>(null)
const theadEl = ref<HTMLElement | null>(null)
const pageEl = ref<HTMLElement | null>(null)
const detailW = ref(ISSUE_PANE_DEFAULT)
const detailRoom = ref(720)
const draft = reactive({
  title: '', description: '', status: 'todo', priority: PRIO_DEFAULT,
  assignee: '', labels: [] as string[], deadlineLocal: '',
  epic: '', kind: 'issue' as 'issue' | 'epic' | 'feature',
})
const subtasks = ref<Issue[]>([])
const subtaskOpen = ref(false)
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
/* SPL-974: the dialog created it; show it now, then re-read the list */
function onSubtaskCreated(sub: Issue) {
  void poke({ text: sub.title, where: { issue: true, issueKey: sub.key } })
  const parent = detail.value
  if (!parent || sub.parent !== parent.key) return
  if (!subtasks.value.some((s) => s.key === sub.key)) subtasks.value = [...subtasks.value, sub]
  void loadSubtasks(parent)
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
const groups = computed(() => {
  const kept = groupIssues(issues.value, { sort: 'updated', filter: serverFilter(), me: meId(), by: 'none' })[0].issues
  const rows = sortSheet(kept, sheetSort.value, { name: person, labelName: labelText })
  return [{ status: '', count: rows.length, issues: rows }]
})
const sheetColumns = computed(() => [
  { col: 'key', name: t('issues_view.col_key'), cls: 'issues-c-key' },
  { col: 'title', name: t('issues_view.col_title'), cls: 'issues-c-title' },
  { col: 'status', name: t('issues.filter_status'), cls: '' },
  { col: 'priority', name: t('issues.filter_priority'), cls: '' },
  { col: 'level', name: t('issues.filter_level'), cls: '' },
  { col: 'assignee', name: t('issues.filter_assignee'), cls: '' },
  { col: 'label', name: t('issues.filter_label'), cls: '' },
  { col: 'deadline', name: t('issues.field_deadline'), cls: '' },
  { col: 'updated', name: t('issues.sort_updated'), cls: '' },
])
const serverSort = computed(() => hubSort(sheetSort.value))
function toggleSort(col: string) {
  sheetSort.value = nextSort(col, sheetSort.value)
}
watch(sheetSort, (v) => {
  if (!import.meta.client) return
  const url = new URL(window.location.href)
  if (v.col) { url.searchParams.set('sort', v.col); url.searchParams.set('dir', v.dir) }
  else { url.searchParams.delete('sort'); url.searchParams.delete('dir') }
  window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash)
})
const rowCount = computed(() => groups.value.reduce((n, g) => n + g.count, 0))
/* the table keeps its header and filter row when nothing matches; the note says so */
const shownGroups = computed(() => (rowCount.value ? groups.value : []))
/* J / K walk the rows in the order the sheet shows them */
const flat = computed(() => groups.value[0].issues)
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
    const data = await withSessionRetry(api, () => api.listIssues({ filter: serverFilter(), sort: serverSort.value }))
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
  sheetSort.value = { col: '', dir: '' }
  statusF.value = ''
  statusOpen.value = false
  priorityF.value = ''
  levelF.value = ''
  assigneeF.value = ''
  labelF.value = ''
  dueF.value = ''
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
  /* SPL-972 level moves: to 2 under which epic / feature, to 3 under which issue */
  if (kind === 'move-epic') return epics.value.filter((e) => e.key !== menu.value?.key).map((e) => ({ value: e.key, label: `${e.key} ${e.title}`, hint }))
  if (kind === 'move-parent') return levelTwoParents(menu.value?.key || '').map((i) => ({ value: i.key, label: `${i.key} ${i.title}`, hint }))
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
  if (!row) return
  scrollRowToTop(scroller, row)
  /* the sticky names + filter rows cover the top of the scroller */
  scroller.scrollTop -= theadEl.value?.getBoundingClientRect().height || 0
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
function onDraftInput(ev: Event, field: 'title') {
  if (!creating.value) return
  draft[field] = (ev.target as HTMLInputElement).value
}
function onTitle(ev: Event) {
  const value = (ev.target as HTMLInputElement).value
  if (creating.value) { draft.title = value; return }
  if (!detail.value || value === detail.value.title) return
  void save(detail.value.key, { title: value })
}
/* the submit key in the description: a new issue is created, an existing
   one's text is already saved by IssueDescription */
function onDescriptionSubmit() {
  if (creating.value && !busy.value && draft.title.trim() && (isTopKind(draft.kind) || draft.epic)) void createIssue()
}
function onDescriptionDraft(value: string) {
  if (creating.value) draft.description = value
}
/* IssueDescription's save: true when stored, so a failure keeps its editor */
async function saveDescription(value: string) {
  if (creating.value) { draft.description = value; return true }
  if (!detail.value) return false
  if (value === detail.value.description) return true
  const key = detail.value.key
  const before = detail.value.description
  await save(key, { description: value })
  if (!saveError.value) void poke({ text: value, before, where: { issue: true, issueKey: key } })
  return !saveError.value
}
function applyDeadline(local: string) {
  if (creating.value) { draft.deadlineLocal = local; return }
  if (!detail.value) return
  const deadline = localInputToDeadline(local)
  if (deadline === null) return
  void save(detail.value.key, { deadline })
}
function onRowPriority(issue: Issue, ev: Event) {
  const n = Number((ev.target as HTMLSelectElement).value)
  if (n && n !== issue.priority) void save(issue.key, { priority: n })
}
function onDetailPriority(ev: Event) {
  const n = Number((ev.target as HTMLSelectElement).value)
  if (creating.value) { draft.priority = n; return }
  if (detail.value && n && n !== detail.value.priority) void save(detail.value.key, { priority: n })
}
/* level-2 issues an issue can go under (SPL-972): same epic first, never itself */
function levelTwoParents(key: string) {
  const me = issues.value.find((i) => i.key === key)
  const twos = issues.value.filter((i) => i.level === 2 && i.key !== key)
  const same = me?.epic ? twos.filter((i) => i.epic === me.epic) : []
  return same.length ? same : twos
}
/*
 * owner, topic e0f6f074: "add the dropboxes for the level column as well".
 * The level is the tree's (SPL-949), so a new level MOVES the issue:
 *   -> 1  it becomes a feature at the top (kind feature, no parent)
 *   -> 2  from 3: straight under its epic; from 1: pick the epic / feature
 *   -> 3  pick the level-2 issue it goes under
 * The hub still judges the tree (an epic with issues cannot drop a level) and
 * its refusal is shown; the box snaps back to the real level either way.
 */
function onRowLevel(issue: Issue, ev: Event) {
  const sel = ev.target as HTMLSelectElement
  const want = Number(sel.value)
  sel.value = String(issue.level)
  if (!want || want === issue.level) return
  if (want === 1) { void save(issue.key, { kind: 'feature' }); return }
  if (want === 2 && issue.level === 3 && issue.epic) { void save(issue.key, { parent: issue.epic }); return }
  openMenu(want === 2 ? 'move-epic' : 'move-parent', issue, ev)
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
  /* the row the menu was opened on, not whichever issue the detail shows */
  const issue = issues.value.find((i) => i.key === menu.value?.key) || detail.value
  if (!issue || !issue.key) return
  const body: Record<string, unknown> = {}
  if (kind === 'status') body.status = value
  else if (kind === 'priority') body.priority = Number(value)
  else if (kind === 'assign') body.assignee = value
  else if (kind === 'epic') body.parent = value /* issues-v1: parent is the epic; an older hub knows only parent */
  else if (kind === 'move-epic') { body.kind = 'issue'; body.parent = value }
  else if (kind === 'move-parent') { if (issue.level === 1) body.kind = 'issue'; body.parent = value }
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
    void poke({ text: `${title}\n${String(body.description || '')}`, where: { issue: true, issueKey: created.key } })
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

/* the page's own copy of the comments; the card already told the stores */
function onCommentEdited(row: SpoolMessage) {
  comments.value = applyEdit(comments.value, row) as Note[]
}
function onCommentDeleted(row: { msg_id?: string }) {
  comments.value = withoutMsg(comments.value, String(row?.msg_id || '')) as Note[]
}
function onCommentReacted(update: ReactionUpdate) {
  comments.value = patchReactions(comments.value, update) as Note[]
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
      ...(m as unknown as SpoolMessage),
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
    void poke({ text, where: { issue: true, issueKey: issue.key } })
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
  if (key === 'Escape' && (menuOpen || statusOpen.value)) { ev.preventDefault(); menu.value = null; statusOpen.value = false; return }
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
  if (k === 'e' && form.value) { void descEl.value?.edit(); ev.preventDefault(); return }
  const kind = { s: 'status', p: 'priority', a: 'assign', l: 'label' }[k]
  const issue = creating.value ? detailOrDraft() : (detail.value || flat.value.find((i) => i.key === cursorKey.value) || flat.value[0])
  if (kind && issue) { openMenu(kind, issue); ev.preventDefault() }
}

watch([statusF, priorityF, levelF, assigneeF, labelF, dueF, serverSort, epicF], () => { void load() })
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
let offCommentEdit = () => {}
let offCommentDelete = () => {}
let offCommentReact = () => {}
let detailObserver: ResizeObserver | null = null
/* owner, topic e0f6f074 (SPL-972): every pop-up list closes on a click outside it */
function onDocPointer(ev: Event) {
  const t = ev.target
  const inside = (sel: string) => {
    const el = pageEl.value?.querySelector(sel)
    return Boolean(el && t instanceof Node && el.contains(t))
  }
  if (statusOpen.value && !inside('[data-test=issues-filter-status]')) statusOpen.value = false
  if (menu.value && !inside('[data-test=issues-menu]')) menu.value = null
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
  offCommentEdit = live.onEdited((m) => onCommentEdited(m as unknown as SpoolMessage))
  offCommentDelete = live.onDeleted((m) => onCommentDeleted(m as { msg_id?: string }))
  offCommentReact = live.onReaction((m) => onCommentReacted(m as unknown as ReactionUpdate))
})
onUnmounted(() => {
  document.removeEventListener('keydown', onDocKey)
  document.removeEventListener('pointerdown', onDocPointer)
  detailObserver?.disconnect()
  offIssue()
  offLabel()
  offMsg()
  offBack()
  offCommentEdit()
  offCommentDelete()
  offCommentReact()
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
/* SPL-978: Material-style round + (accent fill, elevation, hover lift, press ripple) */
.issues-fab {
  position: relative;
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 2.5rem;
  height: 2.5rem;
  padding: 0;
  border: 0;
  border-radius: 50%;
  overflow: hidden;
  background: var(--color-accent);
  color: var(--color-on-accent);
  cursor: pointer;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3), 0 1px 2px rgba(0, 0, 0, 0.2);
  transition: box-shadow 0.15s ease, background-color 0.15s ease, transform 0.1s ease;
}
.issues-fab:hover {
  background: var(--color-accent-pressed);
  box-shadow: 0 3px 6px rgba(0, 0, 0, 0.3), 0 2px 4px rgba(0, 0, 0, 0.22);
}
.issues-fab:active { transform: scale(0.96); }
.issues-fab::after {
  content: '';
  position: absolute;
  inset: 0;
  border-radius: 50%;
  background: currentColor;
  opacity: 0;
  transform: scale(0);
  transition: transform 0.3s ease, opacity 0.45s ease;
  pointer-events: none;
}
.issues-fab:active::after { opacity: 0.2; transform: scale(1); transition: none; }
@media (prefers-reduced-motion: reduce) {
  .issues-fab, .issues-fab::after { transition: none; }
  .issues-fab:active { transform: none; }
}
.issues-shortcuts {
  margin: 0;
  padding: 0 12px 6px;
  font-size: 0.75rem;
  min-width: 0;
}
.issues-tools {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 6px 10px;
  padding: 0 12px 8px;
  min-width: 0;
}
.issues-filters select,
.issues-filters input,
.issues-tools select,
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
.issues-fcell { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.issues-fcell__name { font-size: 0.75rem; color: var(--color-muted); white-space: nowrap; }
.issues-filters select, .issues-tools select { field-sizing: content; }
.issues-filters .issues-filter-assignee {
  max-width: 13em;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
/* owner, topic e0f6f074 (SPL-972): prio / level cells are select boxes, the same box as the filter row's */
.issues-cell-select {
  min-width: 3.25rem;
  padding: 2px 6px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
}
select.issues-cell-select.issues-prio { display: inline-block; min-width: 3.25rem; font-size: 0.875rem; text-align: start; }
.issues-prop--select { display: inline-flex; align-items: center; gap: 6px; cursor: default; }
.issues-row-status { display: inline-flex; align-items: center; gap: 4px; font-size: 0.75rem; white-space: nowrap; }
.issues-status-dd { position: relative; }
.issues-status-dd__btn { cursor: pointer; text-align: start; }
/* the Status filter reads as the same control as the selects beside it (topic e00da93b) */
.issues-frow .issues-status-dd__btn {
  appearance: none;
  padding-inline-end: 22px;
  background-image: linear-gradient(45deg, transparent 50%, currentColor 50%), linear-gradient(135deg, currentColor 50%, transparent 50%);
  background-position: calc(100% - 12px) 55%, calc(100% - 8px) 55%;
  background-size: 4px 4px, 4px 4px;
  background-repeat: no-repeat;
}
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
/* owner, topic e00da93b: a sheet - gridlines, a sticky names + filter row */
.issues-table {
  border-collapse: separate;
  border-spacing: 0;
  min-width: 100%;
  font-size: 0.875rem;
}
.issues-table th,
.issues-table td {
  border-inline-end: 1px solid var(--color-border);
  border-bottom: 1px solid var(--color-border);
  padding: 4px 8px;
  text-align: start;
  vertical-align: middle;
  white-space: nowrap;
}
.issues-table thead th { position: sticky; z-index: 2; background: var(--color-bg); }
.issues-names th { top: 0; height: 1.75rem; font-size: 0.75rem; font-weight: 600; color: var(--color-muted); }
.issues-frow th { top: 1.75rem; font-weight: normal; }
.issues-c-key { width: 1%; }
/* a sheet's frozen first column: the key stays in view when the table scrolls sideways */
.issues-table .issues-c-key { position: sticky; inset-inline-start: 0; z-index: 1; background: var(--color-bg); }
.issues-table thead .issues-c-key { z-index: 3; }
.issues-table { width: 100%; }
/* the Title column takes what is left and gives it up first (owner screenshot,
   topic e00da93b): the cell asks for 100% of the table, and its grid's
   minmax(0, 1fr) makes its smallest width the 10rem floor, not the whole
   title - so Label / Deadline / Updated stay in view beside an open issue */
.issues-table td.issues-c-title { width: 100%; }
.issues-title-cell { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 6px; min-width: 10rem; }
.issues-title-cell .issues-epic-tag { max-width: 8rem; }
.issues-table .issues-person { max-width: 10rem; }
.issues-table .issues-pill { max-width: 7rem; }
/* owner, topic e00da93b: sort by a header click; only the sorted column shows its triangle */
.issues-sort-h {
  display: inline-block;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  font: inherit;
  cursor: pointer;
  white-space: nowrap;
}
.issues-sort-h::first-letter { text-transform: uppercase; }
.issues-sort-mark { display: inline-block; min-width: 0.75em; margin-inline-start: 4px; font-size: 0.625rem; color: var(--color-fg); }
.issues-sort-h:not([data-sorted]):hover .issues-sort-mark::before,
.issues-sort-h:not([data-sorted]):focus-visible .issues-sort-mark::before { content: '▲'; opacity: 0.35; }
.issues-note { white-space: normal; }
.issues-note p { margin: 4px 0; }
.issues-group__cell { padding: 0; background: var(--color-bg); }
.issues-row { cursor: pointer; }
.issues-row:hover td { background: var(--color-surface-hover); }
.issues-row[data-selected="true"] td { background: var(--color-selected); }
.issues-row[data-selected="true"] td:first-child { box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring); }
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
.issues-person { max-width: 12rem; overflow: hidden; }
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
.issues-st--blocked { color: var(--color-danger); } /* the SPL-952 blocker red */
.issues-st--onhold { color: var(--color-muted); }
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
.issues-props { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 6px; min-width: 0; }
/* the deadline takes a row of its own: a chip beside it would stretch to its height */
.issues-props > .issues-field { flex-basis: 100%; }
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
.issues-subs__h { display: flex; align-items: center; gap: 8px; min-width: 0; }
.issues-sub-add { display: inline-flex; align-items: center; justify-content: center; min-width: 28px; min-height: 28px; margin-top: 8px; padding: 0; border: 1px solid transparent; border-radius: var(--radius-sm); background: transparent; color: var(--color-muted); cursor: pointer; }
.issues-sub-add:hover, .issues-sub-add:focus-visible { color: var(--color-fg); border-color: var(--color-border); }
.issues-talk h3 { margin: 8px 0 0; font-size: 0.875rem; }
.issues-talk__h { display: flex; align-items: center; gap: 8px; min-width: 0; }
/* SPL-963: titles = one line, 5 rows = at most 5 lines, full = all of it */
.issues-comment { min-width: 0; }
.mention-anchor { position: relative; display: flex; flex-direction: column; min-width: 0; }
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
