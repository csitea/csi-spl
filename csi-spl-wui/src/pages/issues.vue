<!-- Issues (topic 9c19bfe9). Two panes: the rail and this sheet.
     SPL-1027 (owner, prd t1 topic 89485c7a): the right pane is gone - above
     820 px an opened issue is a modal (IssueDetailFrame), and the sheet is
     fully CRUD in place (a new row on top, every cell edited, a row delete).
     Phones keep the level-3 full screen (SPL-992). The description is only
     in the opened issue.
     Deadline is a calendar with a time, stored UTC. The hub contract is
     issues-v1: GET /v1/view/issues, POST /v1/issues, PATCH. -->
<template>
  <div ref="pageEl" class="issues-page" data-test="issues-page">
    <div class="issues-list" data-test="issues-list">
      <header class="feed-header issues-head">
        <!-- SPL-992: on a phone the list is level 2; Back goes to the sections (level 1) -->
        <MobileBack class="issues-mback" data-test="issues-back" />
        <h2 data-test="issues-heading">{{ epicTitle || t('issues.title') }}</h2>
        <!-- SPL-978: "just a button with + the google way": a round accent button, the plus only.
             SPL-992: on a phone it floats bottom right (CSS), and hides while an issue is open -->
        <button v-show="!(phone && form)" type="button" class="issues-fab" data-test="issues-new" :aria-label="t('issues.new')" :title="t('issues.new')" @click="startCreate()">
          <UiIcon name="plus" :size="22" :stroke-width="2.5" />
        </button>
        <!-- topic e5b17522 (owner): the highlighted view-toggle buttons sit
             ~1.5 cm (57px @96dpi) to the right of the + button, on the header
             row (SPL-1028 list / status views). Moving them up here vacates the
             old tools row below so the issues table rises by its height.
             Desktop only; the phone keeps its own bar. -->
        <div v-if="!phone" class="issues-views issues-head__views" role="radiogroup" :aria-label="t('issues_views.label')" data-test="issues-views">
          <button
            v-for="v in ISSUES_VIEWS"
            :key="v"
            type="button"
            role="radio"
            class="issues-views__opt"
            data-test="issues-view"
            :data-value="v"
            :aria-checked="viewBy === v ? 'true' : 'false'"
            @click="pickView(v)"
          >
            <UiIcon :name="v === 'list' ? 'list' : 'issues'" :size="16" />
            <span>{{ t('issues_views.' + v) }}</span>
          </button>
        </div>
        <button v-if="!phone" type="button" class="btn ghost issues-head__clear" data-test="issues-filter-clear" @click="clearFilters">{{ t('issues.filter_clear') }}</button>
        <!-- owner b82f3853 (SPL-1226): the epic/feature actions button, on the
             title row next to the view toggle + Clear filters. It acts on the
             epic/feature being viewed (?epic=); disabled with a tooltip when the
             view is not filtered to one. Same menu component as the row's
             right-click, so Copy link / Archive / Delete behave identically. -->
        <button
          v-if="!phone"
          type="button"
          class="btn ghost issues-head__menu"
          data-test="issues-epic-menu"
          :aria-disabled="selectedEpic ? undefined : 'true'"
          :data-disabled="selectedEpic ? undefined : 'true'"
          :aria-haspopup="'menu'"
          :aria-label="selectedEpic ? t('issues_menu.epic_actions', { key: epicF }) : t('issues_menu.select_epic')"
          :title="selectedEpic ? t('issues_menu.epic_actions', { key: epicF }) : t('issues_menu.select_epic')"
          @click="openEpicMenu($event)"
        >
          <UiIcon name="menu" :size="16" />
        </button>
      </header>
      <p v-if="!phone" class="issues-shortcuts muted" data-test="issues-shortcuts">{{ t('issues_crud.shortcuts') }}</p>
      <!-- SPL-992 (epic SPL-988): a phone gets Filters (a bottom sheet), Sort (a
           menu) and the epics as a chip strip in place of the sheet's header rows -->
      <template v-if="phone">
        <div class="issues-mbar" data-test="issues-mbar">
          <button type="button" class="btn ghost issues-mbar__btn" data-test="issues-filters-open" :data-active="filtersActive ? 'true' : 'false'" aria-haspopup="dialog" @click="filtersOpen = true">
            <span>{{ t('issues_mobile.filters') }}</span><i v-if="filtersActive" class="issues-mbar__dot" aria-hidden="true" />
          </button>
          <button type="button" class="btn ghost issues-mbar__btn issues-mbar__sort" data-test="issues-sort-open" aria-haspopup="listbox" @click="sortOpen = true">
            <span class="issues-mbar__sortlabel">{{ t('issues_mobile.sort') }}: {{ sortShown }}</span>
          </button>
        </div>
        <nav v-if="epics.length" class="issues-chips" data-test="issues-epic-chips" :aria-label="t('sidebar.epics')">
          <button type="button" class="issues-chip" data-test="issues-epic-chip" data-key="" :aria-pressed="epicF ? 'false' : 'true'" @click="pickEpic('')">{{ t('issues_mobile.epics_all') }}</button>
          <button
            v-for="e in epics"
            :key="e.key"
            type="button"
            class="issues-chip"
            data-test="issues-epic-chip"
            :data-key="e.key"
            :aria-pressed="epicF === e.key ? 'true' : 'false'"
            :title="`${e.key} ${e.title}`"
            @click="pickEpic(e.key)"
          >{{ e.title }}</button>
        </nav>
        <p v-if="saveError && !form" class="issues-error issues-merror" role="alert" data-test="issues-list-error">{{ t(saveError) }}</p>
      </template>
      <!-- owner, topic e00da93b: "it should look like a gsheet with columns and a
           table". The list is a table: row 1 the column names, row 2 each
           column's filter (sticky, like a sheet's filter row), then one issue
           per row in the same columns. A header click sorts by that column
           (▲, ▼, then back to Updated newest first). On a phone the table
           scrolls sideways inside its pane. -->
      <!-- topic e5b17522 (owner): the SPL-1028 view toggle (list / by status)
           and Clear filters moved UP onto the title row; the tools row that
           held them is gone so the table rises by its height. Only the list
           error keeps a spot here, and it renders nothing unless there is one. -->
      <p v-if="!phone && saveError && !modalOpen" class="issues-error issues-list-error" role="alert" data-test="issues-list-error">{{ t(saveError) }}</p>
      <div ref="scrollerEl" class="issues-scroll">
        <table v-if="!phone" class="issues-table" :class="colWidthClasses(colWidths)" :style="colWidthVars(colWidths)" data-test="issues-table">
          <thead ref="theadEl" class="issues-filters" data-test="issues-filters">
            <tr class="issues-names">
              <th
                v-for="c in sheetColumns"
                :key="c.col"
                scope="col"
                :class="c.cls"
                :data-col="c.col"
                :aria-sort="sheetSort.col === c.col ? (sheetSort.dir === 'asc' ? 'ascending' : 'descending') : 'none'"
              >
                <button
                  type="button"
                  class="issues-sort-h"
                  :data-test="'issues-sort-' + c.col"
                  :data-sorted="sheetSort.col === c.col ? sheetSort.dir : undefined"
                  @click="toggleSort(c.col)"
                  @keydown.alt.left="onGripKey($event, c.col)"
                  @keydown.alt.right="onGripKey($event, c.col)"
                >{{ c.name }}<span class="issues-sort-mark" aria-hidden="true">{{ sheetSort.col === c.col ? (sheetSort.dir === 'asc' ? '▲' : '▼') : '' }}</span></button>
                <!-- owner, topic beb4024f: drag the edge to resize; arrows on focus; double-click = automatic -->
                <span
                  class="issues-col-grip"
                  role="separator"
                  aria-orientation="vertical"
                  tabindex="0"
                  :aria-label="t('issues_view.col_resize', { col: c.name })"
                  :aria-valuenow="colWidths[c.col] || undefined"
                  :aria-valuemin="colMin(c.col)"
                  :aria-valuemax="COLW_MAX"
                  :data-test="'issues-col-grip-' + c.col"
                  :data-resized="colWidths[c.col] ? 'true' : undefined"
                  @pointerdown="onGripDown($event, c.col)"
                  @keydown="onGripKey($event, c.col)"
                  @click.stop
                />
              </th>
              <!-- SPL-1027: the row actions (delete); no name, no sort -->
              <th scope="col" class="issues-c-act" :aria-label="t('issues_crud.delete')" />
            </tr>
            <tr class="issues-frow">
              <th data-col="key" class="issues-c-key" />
              <th data-col="title" />
              <th data-col="status">
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
              <th data-col="priority">
                <select v-model="priorityF" data-test="issues-filter-priority" :aria-label="t('issues.filter_priority')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="n in ISSUE_PRIORITIES" :key="n" :value="String(n)">{{ n }}</option>
                </select>
              </th>
              <th data-col="level">
                <select v-model="levelF" data-test="issues-filter-level" :aria-label="t('issues.filter_level')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="n in ISSUE_LEVELS" :key="'lv' + n" :value="String(n)" :title="t(levelKey(n))">{{ n }}</option>
                </select>
              </th>
              <th data-col="assignee">
                <select v-model="assigneeF" class="issues-filter-assignee" data-test="issues-filter-assignee" :aria-label="t('issues.filter_assignee')" :title="assigneeTitle">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option value="me">{{ t('issues.filter_me') }}</option>
                  <option value="none">{{ t('issues.filter_unassigned') }}</option>
                  <option v-for="p in assigneeOptions" :key="p.id" :value="p.id">{{ p.label }}</option>
                </select>
              </th>
              <th data-col="label">
                <select v-model="labelF" data-test="issues-filter-label" :aria-label="t('issues.filter_label')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="l in labels" :key="l.id" :value="l.id">{{ l.name }}</option>
                </select>
              </th>
              <!-- owner, topic 778ad161: the calendar control, YYYY-MM-DD HH:MM; due on or before that minute -->
              <th data-col="deadline" role="group" :aria-label="t('issues.field_deadline')" data-test="issues-filter-deadline">
                <DeadlinePicker v-model="dueF" :label="t('issues.field_deadline')" test-id="issues-filter-deadline-date" time-test-id="issues-filter-deadline-time" default-time="23:59" />
              </th>
              <th data-col="updated" />
              <th class="issues-c-act" />
            </tr>
          </thead>
          <!-- SPL-1027 CREATE: the new issue is a row on top of the sheet, typed in
               place - the title, then any cell; Enter stores it, Esc drops it -->
          <tbody v-if="creating && !phone" class="issues-newbody">
            <tr class="issues-row issues-newrow" data-test="issues-newrow" :data-kind="draft.kind">
              <td data-col="key" class="issues-c-key">
                <button type="button" class="issues-pill issues-newrow__kind" data-test="issues-kind" :data-kind="draft.kind" @click="toggleKind">{{ t('issues.kind_' + draft.kind) }}</button>
              </td>
              <td data-col="title" class="issues-c-title">
                <span class="issues-title-cell">
                  <input
                    ref="newTitleEl"
                    v-model="draft.title"
                    class="issues-cell-input"
                    data-test="issues-newrow-title"
                    :placeholder="t('issues.title_placeholder')"
                    :aria-label="t('issues.title_placeholder')"
                    @keydown.enter.prevent="createIssue"
                    @keydown.esc.stop.prevent="cancelCreate"
                  >
                  <button v-if="!isTopKind(draft.kind)" type="button" class="issues-pill issues-epic-tag" data-test="issues-epic" :title="draft.epic ? epicLabel(draft.epic) : t('issues.no_epic')" @click="openMenu('epic', detailOrDraft(), $event)">{{ draft.epic ? epicTitleOf(draft.epic) : t('issues.no_epic') }}</button>
                </span>
              </td>
              <td data-col="status">
                <button type="button" class="issues-iconbtn issues-row-status" data-test="issues-newrow-status" :data-status="draft.status" :aria-label="t('issues.filter_status')" :title="t(statusHintKey(draft.status))" @click="openMenu('status', detailOrDraft(), $event)">
                  <IssueGlyph :name="statusIcon(draft.status)" :size="14" :class="'issues-st issues-st--' + draft.status" />
                  <span class="issues-status-code">{{ statusLabel(draft.status) }}</span>
                </button>
              </td>
              <td data-col="priority">
                <select class="issues-cell-select issues-prio" :class="'issues-prio--' + draft.priority" data-test="issues-newrow-priority" :aria-label="t('issues.field_priority')" :value="String(draft.priority)" @keydown.stop @change="onDetailPriority">
                  <option v-for="n in ISSUE_PRIORITIES" :key="'np' + n" :value="String(n)">{{ n }}</option>
                </select>
              </td>
              <td data-col="level"><span class="issues-level" data-test="issues-newrow-level" :title="t(levelKey(isTopKind(draft.kind) ? 1 : 2))">{{ isTopKind(draft.kind) ? 1 : 2 }}</span></td>
              <td data-col="assignee">
                <button type="button" class="issues-person" data-test="issues-newrow-assignee" :aria-label="t('issues.field_assignee')" @click="openMenu('assign', detailOrDraft(), $event)">
                  <SpoolAvatar v-if="draft.assignee" :id="draft.assignee" :box="boxOf(draft.assignee)" :size="20" />
                  <HumanName v-if="draft.assignee" :id="draft.assignee" :box="boxOf(draft.assignee)" />
                  <span v-else class="muted">{{ t('issues.no_assignee') }}</span>
                </button>
              </td>
              <td data-col="label">
                <span class="issues-pills">
                  <button v-for="id in draft.labels" :key="id" type="button" class="issues-pill" data-test="issues-newrow-label" @click="openMenu('label', detailOrDraft(), $event)">
                    <i class="issues-dot" :style="dotStyle(id)" />{{ labelText(id) }}
                  </button>
                  <button v-if="!draft.labels.length" type="button" class="issues-cellbtn" data-test="issues-newrow-label-add" :aria-label="t('issues.add_label')" :title="t('issues.add_label')" @click="openMenu('label', detailOrDraft(), $event)">
                    <UiIcon name="plus" :size="14" />
                  </button>
                </span>
              </td>
              <td data-col="deadline">
                <DeadlinePicker v-model="draft.deadlineLocal" :label="t('issues.field_deadline')" test-id="issues-newrow-deadline" time-test-id="issues-newrow-deadline-time" />
              </td>
              <td data-col="updated" />
              <td class="issues-c-act">
                <span class="issues-newrow__acts">
                  <button type="button" class="issues-iconbtn" data-test="issues-create" :disabled="busy || !draft.title.trim()" :aria-label="t('issues.create')" :title="t('issues.create')" @click="createIssue">
                    <UiIcon name="check" :size="16" />
                  </button>
                  <button type="button" class="issues-iconbtn" data-test="issues-newrow-cancel" :aria-label="t('common.cancel')" :title="t('common.cancel')" @click="cancelCreate">
                    <UiIcon name="x" :size="16" />
                  </button>
                </span>
              </td>
            </tr>
          </tbody>
          <tbody v-if="(loading && !issues.length) || loadError || !rowCount">
            <tr>
              <td colspan="10" class="issues-note">
                <p v-if="loading && !issues.length" class="muted" data-test="issues-loading">{{ t('issues.loading') }}</p>
                <p v-else-if="loadError" class="issues-error" role="alert" data-test="issues-error">{{ t(loadError) }}</p>
                <p v-else class="muted" data-test="issues-empty">{{ t('issues.empty') }}</p>
              </td>
            </tr>
          </tbody>
          <tbody
            v-for="g in shownGroups"
            :key="g.status || 'all'"
            class="issues-group"
            data-test="issues-group"
            :data-status="g.status"
            :data-drop="dropStatus && dropStatus === g.status ? 'true' : undefined"
            @dragover="onGroupDragOver($event, g.status)"
            @dragleave="onGroupDragLeave($event, g.status)"
            @drop="onGroupDrop($event, g.status)"
          >
              <!-- SPL-1028: a status group's header - its glyph, name and count;
                   a click folds it, + files a new issue straight into it -->
              <tr v-if="g.status" class="issues-group__h" data-test="issues-group-h" :data-status="g.status" :data-count="g.count">
                <th colspan="10" scope="colgroup">
                  <span class="issues-group__hin">
                    <button
                      type="button"
                      class="issues-group__fold"
                      data-test="issues-group-fold"
                      :aria-expanded="folded.includes(g.status) ? 'false' : 'true'"
                      :title="t(folded.includes(g.status) ? 'issues_views.expand' : 'issues_views.collapse', { name: statusLabel(g.status) })"
                      @click="toggleFold(g.status)"
                    >
                      <UiIcon :name="folded.includes(g.status) ? 'chevron-down' : 'chevron-up'" :size="14" />
                      <IssueGlyph :name="statusIcon(g.status)" :size="14" :class="'issues-st issues-st--' + g.status" />
                      <span class="issues-status-code">{{ statusLabel(g.status) }}</span>
                      <span class="issues-group__n" data-test="issues-group-count">{{ g.count }}</span>
                    </button>
                    <button type="button" class="issues-cellbtn" data-test="issues-group-add" :aria-label="t('issues_views.add_in', { name: statusLabel(g.status) })" :title="t('issues_views.add_in', { name: statusLabel(g.status) })" @click="startCreate(g.status)">
                      <UiIcon name="plus" :size="14" />
                    </button>
                  </span>
                </th>
              </tr>
              <tr
                v-for="issue in (g.status && folded.includes(g.status) ? [] : g.issues)"
                :key="issue.key"
                class="issues-row"
                role="button"
                tabindex="0"
                :draggable="viewBy === 'status' ? 'true' : undefined"
                data-test="issues-row"
                :data-key="issue.key"
                :data-priority="issue.priority"
                :data-level="issue.level"
                :data-selected="cursorKey === issue.key ? 'true' : 'false'"
                @click="onRowActivate(issue)"
                @keydown.enter.self.prevent="choose(issue)"
                @contextmenu="onRowContext(issue, $event)"
                @pointerdown="onRowPointerDown(issue, $event)"
                @pointermove="rowPress.move($event)"
                @pointerup="rowPress.up()"
                @pointercancel="rowPress.cancel()"
                @dragstart="onRowDragStart($event, issue)"
                @dragend="onRowDragEnd"
              >
                <td class="issues-c-key" v-bind="cellAttrs(issue, 'key')"><span class="issues-key">{{ issue.key }}</span></td>
                <!-- SPL-1027 UPDATE: the title is edited in place (the pencil, or
                     Enter on the cell); Enter or leaving saves, Esc cancels -->
                <td class="issues-c-title" v-bind="cellAttrs(issue, 'title')">
                  <input
                    v-if="titleEdit.key === issue.key"
                    v-model="titleEdit.text"
                    class="issues-cell-input"
                    data-test="issues-row-title-input"
                    :aria-label="t('issues_crud.edit_title')"
                    @click.stop
                    @keydown.stop="onRowTitleKey($event, issue)"
                    @blur="commitRowTitle(issue)"
                  >
                  <span v-else class="issues-title-cell issues-title-cell--edit">
                    <span class="issues-title" :title="issue.title">{{ issue.title }}</span>
                    <button type="button" class="issues-title-edit" data-test="issues-row-title-edit" :aria-label="t('issues_crud.edit_title')" :title="t('issues_crud.edit_title')" @click.stop="startTitleEdit(issue)">
                      <UiIcon name="pencil" :size="14" />
                    </button>
                    <button v-if="!epicF && issue.epic" type="button" class="issues-pill issues-epic-tag" data-test="issues-row-epic" :title="epicTitleOf(issue.epic)" @click.stop="openMenu('epic', issue, $event)">{{ epicTitleOf(issue.epic) }}</button>
                  </span>
                </td>
                <td v-bind="cellAttrs(issue, 'status')">
                  <button type="button" class="issues-iconbtn issues-row-status" data-test="issues-row-status" :data-status="issue.status" :aria-label="t('issues.filter_status')" :title="t(statusHintKey(issue.status))" @click.stop="openMenu('status', issue, $event)">
                    <IssueGlyph :name="statusIcon(issue.status)" :size="14" :class="'issues-st issues-st--' + issue.status" />
                    <span class="issues-status-code">{{ statusLabel(issue.status) }}</span>
                  </button>
                </td>
                <!-- owner, topic e0f6f074 (SPL-972): prio and level are select boxes in the sheet -->
                <td v-bind="cellAttrs(issue, 'priority')" @click.stop>
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
                <td v-bind="cellAttrs(issue, 'level')" @click.stop>
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
                <td v-bind="cellAttrs(issue, 'assignee')">
                  <button type="button" class="issues-person" data-test="issues-row-assignee" :data-assignee="issue.assignee" :aria-label="t('issues.field_assignee')" @click.stop="openMenu('assign', issue, $event)">
                    <SpoolAvatar v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" :size="20" />
                    <HumanName v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" />
                    <span v-else class="muted">{{ t('issues.no_assignee') }}</span>
                  </button>
                </td>
                <td v-bind="cellAttrs(issue, 'label')">
                  <span class="issues-pills">
                    <button v-for="id in issue.labels" :key="id" type="button" class="issues-pill" data-test="issues-row-label" @click.stop="openMenu('label', issue, $event)">
                      <i class="issues-dot" :style="dotStyle(id)" />{{ labelText(id) }}
                    </button>
                    <!-- an empty Labels cell still opens the picker -->
                    <button v-if="!issue.labels.length" type="button" class="issues-cellbtn" data-test="issues-row-label-add" :aria-label="t('issues.add_label')" :title="t('issues.add_label')" @click.stop="openMenu('label', issue, $event)">
                      <UiIcon name="plus" :size="14" />
                    </button>
                  </span>
                </td>
                <td v-bind="cellAttrs(issue, 'deadline')" :data-deadline-edit="deadlineEditKey === issue.key ? 'true' : undefined" @click.stop>
                  <DeadlinePicker
                    v-if="deadlineEditKey === issue.key"
                    :model-value="deadlineToLocalInput(issue.deadline)"
                    :label="t('issues.field_deadline')"
                    test-id="issues-row-deadline-input"
                    time-test-id="issues-row-deadline-time"
                    @update:model-value="onRowDeadline(issue, $event)"
                  />
                  <button v-else type="button" class="issues-cellbtn issues-cellbtn--when" data-test="issues-row-deadline" :aria-label="t('issues_crud.set_deadline')" :title="t('issues_crud.set_deadline')" @click="startDeadlineEdit(issue)">
                    <time v-if="issue.deadline" class="issues-when" :datetime="issue.deadline">{{ when(issue.deadline) }}</time>
                    <UiIcon v-else name="calendar" :size="14" />
                  </button>
                </td>
                <td v-bind="cellAttrs(issue, 'updated')"><time v-if="issue.updated_at" class="issues-when issues-updated" :datetime="issue.updated_at">{{ when(issue.updated_at) }}</time></td>
                <!-- SPL-1027 DELETE: a row action and the one destructive confirm (SPL-1001) -->
                <td class="issues-c-act" v-bind="cellAttrs(issue, 'actions')">
                  <button type="button" class="issues-iconbtn issues-row-delete" data-test="issues-row-delete" :aria-label="t('issues_crud.delete')" :title="t('issues_crud.delete')" @click.stop="askDelete(issue)">
                    <UiIcon name="delete" :size="16" />
                  </button>
                </td>
              </tr>
          </tbody>
        </table>
        <!-- SPL-992: the phone's list - one card per issue, a tap opens it full screen -->
        <ul v-else class="issues-cards" data-test="issues-cards">
          <li v-if="(loading && !issues.length) || loadError || !rowCount" class="issues-note">
            <p v-if="loading && !issues.length" class="muted" data-test="issues-loading">{{ t('issues.loading') }}</p>
            <p v-else-if="loadError" class="issues-error" role="alert" data-test="issues-error">{{ t(loadError) }}</p>
            <p v-else class="muted" data-test="issues-empty">{{ t('issues.empty') }}</p>
          </li>
          <li v-for="issue in (rowCount ? flat : [])" :key="issue.key">
            <button
              type="button"
              class="issues-card"
              data-test="issues-card"
              :data-key="issue.key"
              :data-priority="issue.priority"
              :data-selected="cursorKey === issue.key ? 'true' : 'false'"
              @click="onRowActivate(issue)"
              @contextmenu="onRowContext(issue, $event)"
              @pointerdown="onRowPointerDown(issue, $event)"
              @pointermove="rowPress.move($event)"
              @pointerup="rowPress.up()"
              @pointercancel="rowPress.cancel()"
            >
              <span class="issues-card__top">
                <span class="issues-key" data-test="issues-card-key">{{ issue.key }}</span>
                <span class="issues-card__status" data-test="issues-card-status" :data-status="issue.status">
                  <IssueGlyph :name="statusIcon(issue.status)" :size="14" :class="'issues-st issues-st--' + issue.status" />
                  <span class="issues-status-code">{{ statusLabel(issue.status) }}</span>
                </span>
                <span class="issues-prio" :class="'issues-prio--' + issue.priority" data-test="issues-card-priority" :aria-label="t('issues.field_priority')">{{ issue.priority }}</span>
                <time v-if="issue.deadline" class="issues-when issues-card__due" data-test="issues-card-deadline" :datetime="issue.deadline">{{ when(issue.deadline) }}</time>
              </span>
              <span class="issues-card__title" data-test="issues-card-title">{{ issue.title }}</span>
              <span class="issues-card__meta">
                <span class="issues-card__who" data-test="issues-card-assignee" :data-assignee="issue.assignee">
                  <SpoolAvatar v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" :size="20" />
                  <HumanName v-if="issue.assignee" :id="issue.assignee" :box="boxOf(issue.assignee)" />
                  <span v-else class="muted">{{ t('issues.no_assignee') }}</span>
                </span>
                <span v-if="!epicF && issue.epic" class="issues-pill issues-epic-tag">{{ epicTitleOf(issue.epic) }}</span>
                <span v-for="id in issue.labels" :key="id" class="issues-pill"><i class="issues-dot" :style="dotStyle(id)" />{{ labelText(id) }}</span>
              </span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    <!-- SPL-992: the filter row of the sheet, as a bottom sheet on a phone -->
    <template v-if="phone && (filtersOpen || sortOpen)">
      <div class="issues-scrim" data-test="issues-sheet-scrim" @pointerdown.stop @click="filtersOpen = false; sortOpen = false" />
      <section v-if="filtersOpen" class="issues-sheet" role="dialog" aria-modal="false" :aria-label="t('issues_mobile.filters')" data-test="issues-filter-sheet">
        <header class="issues-sheet__h">
          <!-- SPL-1133: the X at the chosen corner (Mac = start, the default) -->
          <UiCloseButton side="start" :size="20" class="icon-btn issues-sheet__x" data-test="issues-filter-sheet-close" @click="filtersOpen = false" />
          <h3>{{ t('issues_mobile.filters') }}</h3>
          <UiCloseButton side="end" :size="20" class="icon-btn issues-sheet__x" data-test="issues-filter-sheet-close" @click="filtersOpen = false" />
        </header>
        <!-- the status filter keeps its hints (topic e00da93b): one tappable row per status -->
        <div class="issues-sheet__f" role="radiogroup" :aria-label="t('issues.filter_status')" data-test="issues-filter-status-m">
          <span>{{ t('issues.filter_status') }}</span>
          <div class="issues-sheet__st">
            <button type="button" role="radio" class="issues-chip" data-test="issues-filter-status-m-opt" data-value="" :aria-checked="statusF ? 'false' : 'true'" @click="statusF = ''">{{ t('issues.filter_all') }}</button>
            <button
              v-for="st in ISSUE_STATUSES"
              :key="'ms' + st"
              type="button"
              role="radio"
              class="issues-chip"
              data-test="issues-filter-status-m-opt"
              :data-value="st"
              :aria-checked="statusF === st ? 'true' : 'false'"
              :title="t(statusHintKey(st))"
              @click="statusF = st"
            >{{ statusLabel(st) }}</button>
          </div>
        </div>
        <label class="issues-sheet__f">
          <span>{{ t('issues.filter_priority') }}</span>
          <select v-model="priorityF" data-test="issues-filter-priority" :aria-label="t('issues.filter_priority')">
            <option value="">{{ t('issues.filter_all') }}</option>
            <option v-for="n in ISSUE_PRIORITIES" :key="'mp' + n" :value="String(n)">{{ n }}</option>
          </select>
        </label>
        <label class="issues-sheet__f">
          <span>{{ t('issues.filter_level') }}</span>
          <select v-model="levelF" data-test="issues-filter-level" :aria-label="t('issues.filter_level')">
            <option value="">{{ t('issues.filter_all') }}</option>
            <option v-for="n in ISSUE_LEVELS" :key="'ml' + n" :value="String(n)">{{ n }} - {{ t(levelKey(n)) }}</option>
          </select>
        </label>
        <label class="issues-sheet__f">
          <span>{{ t('issues.filter_assignee') }}</span>
          <select v-model="assigneeF" data-test="issues-filter-assignee" :aria-label="t('issues.filter_assignee')">
            <option value="">{{ t('issues.filter_all') }}</option>
            <option value="me">{{ t('issues.filter_me') }}</option>
            <option value="none">{{ t('issues.filter_unassigned') }}</option>
            <option v-for="p in assigneeOptions" :key="'ma' + p.id" :value="p.id">{{ p.label }}</option>
          </select>
        </label>
        <label class="issues-sheet__f">
          <span>{{ t('issues.filter_label') }}</span>
          <select v-model="labelF" data-test="issues-filter-label" :aria-label="t('issues.filter_label')">
            <option value="">{{ t('issues.filter_all') }}</option>
            <option v-for="l in labels" :key="'mlb' + l.id" :value="l.id">{{ l.name }}</option>
          </select>
        </label>
        <div class="issues-sheet__f" role="group" :aria-label="t('issues.field_deadline')" data-test="issues-filter-deadline">
          <span>{{ t('issues.field_deadline') }}</span>
          <DeadlinePicker v-model="dueF" :label="t('issues.field_deadline')" test-id="issues-filter-deadline-date" time-test-id="issues-filter-deadline-time" default-time="23:59" />
        </div>
        <div class="issues-sheet__foot">
          <button type="button" class="btn ghost" data-test="issues-filter-clear" @click="clearFilters">{{ t('issues.filter_clear') }}</button>
          <button type="button" class="btn" data-test="issues-filter-sheet-done" @click="filtersOpen = false">{{ t('picker.done') }}</button>
        </div>
      </section>
      <section v-if="sortOpen" class="issues-sheet" role="listbox" :aria-label="t('issues_mobile.sort')" data-test="issues-sort-sheet">
        <header class="issues-sheet__h">
          <UiCloseButton side="start" :size="20" class="icon-btn issues-sheet__x" data-test="issues-sort-sheet-close" @click="sortOpen = false" />
          <h3>{{ t('issues_mobile.sort') }}</h3>
          <UiCloseButton side="end" :size="20" class="icon-btn issues-sheet__x" data-test="issues-sort-sheet-close" @click="sortOpen = false" />
        </header>
        <button
          v-for="o in sortChoices"
          :key="o.value"
          type="button"
          role="option"
          class="issues-menu__opt"
          data-test="issues-sort-opt"
          :data-value="o.value"
          :aria-selected="o.value === sortValue ? 'true' : 'false'"
          @click="pickSort(o.value)"
        >{{ o.label }}</button>
      </section>
    </template>
    <!-- SPL-1027: > 820 px the opened issue is a modal (UiDialog: Esc, X,
         backdrop, focus trapped and handed back); a phone keeps level 3 -->
    <IssueDetailFrame
      :modal="!phone"
      :open="phone ? Boolean(form) : modalOpen"
      :title="form && !creating ? form.key : ''"
      class="issues-detail"
      :aria-label="t('issues.title')"
      @close="closeDetail"
    >
      <!-- CLE-77806 (owner, topic 260d2cbb): the issue's actions live in the
           modal header (⋯ -> Copy link / Status / Assignee / Archive / Delete),
           so Delete left the body. Desktop only; the phone header carries its own. -->
      <template v-if="!phone && detail && !creating" #tools>
        <button type="button" class="issues-detail__menu" data-test="issues-detail-actions" :aria-label="t('issues_menu.label')" :title="t('issues_menu.label')" aria-haspopup="menu" @click="openDetailMenu($event)">
          <UiIcon name="menu" :size="18" />
        </button>
      </template>
      <div v-if="form" class="issues-detail-in" data-test="issues-detail" :data-modal="phone ? 'false' : 'true'">
      <header v-if="phone" class="issues-detail__h">
        <!-- SPL-992: level 3 on a phone - Back goes to the list, like browser Back and a swipe right -->
        <MobileBack class="issues-mback" data-test="issues-detail-back" />
        <span class="issues-key" data-test="issues-detail-key">{{ creating ? t('issues.new') : form.key }}</span>
        <span class="issues-detail__hgap" />
        <button v-if="detail && !creating" type="button" class="issues-detail__menu" data-test="issues-detail-actions" :aria-label="t('issues_menu.label')" :title="t('issues_menu.label')" aria-haspopup="menu" @click="openDetailMenu($event)">
          <UiIcon name="menu" :size="20" />
        </button>
      </header>
      <!-- CLE-77806 (owner, topic 260d2cbb): two columns above 820 px - the
           left ~70% holds title + description + subtasks + discussion, the right
           ~30% is the property panel (one control per row, label|value aligned).
           On a phone the panel stacks below the description (single column). -->
      <div class="issues-detail-cols">
        <div class="issues-detail-main">
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
            class="issues-detail-desc"
            :text="form.description"
            :save="saveDescription"
            :keep-open="creating"
            @draft="onDescriptionDraft"
            @submit="onDescriptionSubmit"
          />
          <p v-if="saveError" class="issues-error" role="alert" data-test="issues-save-error">{{ t(saveError) }}</p>
          <button v-if="creating" type="button" class="btn issues-detail-create" data-test="issues-create" :disabled="busy || !draft.title.trim()" @click="createIssue">{{ busy ? t('issues.creating') : t('issues.create') }}</button>
        </div>
        <!-- the property panel: one property per row, label | control, aligned.
             CLE-77806: on a phone it stacks right under the description (owner:
             "the panel stacks below the description"), before the subtasks and
             discussion; on desktop CSS grid puts it in the right column. -->
        <aside class="issues-detail-side" data-test="issues-detail-side">
          <div class="issues-panel" data-test="issues-props">
            <!-- Parent (an epic for an issue/feature, the parent for a subtask) -->
            <div v-if="(!isTopKind(form.kind) && form.kind !== 'subtask') || (form.kind === 'subtask' && detail)" class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.parent_issue') }}</span>
              <button v-if="!isTopKind(form.kind) && form.kind !== 'subtask'" type="button" class="issues-pctl" data-test="issues-epic" @click="openMenu('epic', detailOrDraft(), $event)">
                <span class="issues-pctl__v">{{ form.epic ? epicLabel(form.epic) : t('issues.no_epic') }}</span>
              </button>
              <button v-else type="button" class="issues-pctl" data-test="issues-parent" @click="openParent">
                <span class="issues-pctl__v">{{ detail ? detail.parent : '' }}</span>
              </button>
            </div>
            <!-- Status -->
            <div class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.field_status') }}</span>
              <button type="button" class="issues-pctl issues-pctl--status" data-test="issues-status" @click="openMenu('status', detailOrDraft(), $event)">
                <IssueGlyph :name="statusIcon(form.status)" :size="16" />
                <span class="issues-status-host" :title="t(statusHintKey(form.status))">
                  <span class="issues-status-code">{{ statusLabel(form.status) }}</span>
                  <span class="issues-status-tip" role="tooltip">{{ t(statusHintKey(form.status)) }}</span>
                </span>
              </button>
            </div>
            <!-- Priority. owner, topic e0f6f074 (SPL-972): a select box on desktop;
                 SPL-992: on a phone a button that opens a bottom sheet -->
            <div class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.field_priority') }}</span>
              <button v-if="phone" type="button" class="issues-pctl" data-test="issues-priority-btn" :data-priority="form.priority" @click="openMenu('priority', detailOrDraft(), $event)">
                <span class="issues-prio" :class="'issues-prio--' + form.priority">{{ form.priority }}</span>
              </button>
              <select v-else class="issues-pctl issues-cell-select" data-test="issues-priority" :aria-label="t('issues.field_priority')" :value="String(form.priority)" @keydown.stop @change="onDetailPriority">
                <option v-for="n in ISSUE_PRIORITIES" :key="'dp' + n" :value="String(n)">{{ n }}</option>
              </select>
            </div>
            <!-- Level. SPL-949: derived from the tree; nobody picks it (a phone
                 without a sheet gets a button, SPL-992) -->
            <div class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.field_level') }}</span>
              <button v-if="phone && !creating" type="button" class="issues-pctl" data-test="issues-level-btn" :data-level="form.level" @click="openMenu('level', detailOrDraft(), $event)">
                <span class="issues-level">{{ levelShort(form.level) }}</span>
              </button>
              <span v-else class="issues-pval" data-test="issues-level" :data-level="form.level" :title="t(levelKey(form.level))">
                <span class="issues-level">{{ levelShort(form.level) }}</span>
              </span>
            </div>
            <!-- Assignee -->
            <div class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.field_assignee') }}</span>
              <button type="button" class="issues-pctl" data-test="issues-assignee" @click="openMenu('assign', detailOrDraft(), $event)">
                <SpoolAvatar v-if="activeAssignee" :id="activeAssignee" :box="boxOf(activeAssignee)" :size="20" />
                <HumanName v-if="activeAssignee" :id="activeAssignee" :box="boxOf(activeAssignee)" />
                <span v-else class="issues-pctl__v">{{ t('issues.no_assignee') }}</span>
              </button>
            </div>
            <!-- Kind. Editable while creating (SPL cycle epic/feature/issue),
                 read-only once the tree fixes it -->
            <div class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.field_kind') }}</span>
              <button v-if="creating" type="button" class="issues-pctl" data-test="issues-kind" :data-kind="draft.kind" @click="toggleKind">
                <span class="issues-pctl__v">{{ t('issues.kind_' + draft.kind) }}</span>
              </button>
              <span v-else class="issues-pval" data-test="issues-kind" :data-kind="form.kind">
                <span class="issues-pctl__v">{{ t('issues.kind_' + form.kind) }}</span>
              </span>
            </div>
            <!-- Deadline. owner, topic 778ad161: a calendar plus a 24-hour time,
                 shown and typed as YYYY-MM-DD HH:MM in every locale -->
            <div class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.field_deadline') }}</span>
              <DeadlinePicker
                class="issues-deadline"
                :model-value="form.deadline"
                :label="t('issues.field_deadline')"
                test-id="issues-deadline"
                time-test-id="issues-deadline-time"
                @update:model-value="applyDeadline"
              />
            </div>
            <!-- Labels -->
            <div class="issues-prow">
              <span class="issues-prow__k">{{ t('issues.field_labels') }}</span>
              <button type="button" class="issues-pctl" data-test="issues-labels" @click="openMenu('label', detailOrDraft(), $event)">
                <span class="issues-pctl__v">{{ activeLabels.length ? activeLabels.map(labelText).join(', ') : t('issues.add_label') }}</span>
              </button>
            </div>
          </div>
          <div v-if="!creating && (form.created_by || form.updated_by)" class="issues-detail-meta">
            <p v-if="form.created_by" class="muted issues-meta">{{ t('issues.created_by', { name: person(form.created_by) }) }}</p>
            <p v-if="form.updated_by" class="muted issues-meta">{{ t('issues.updated_by', { name: person(form.updated_by) }) }}</p>
          </div>
        </aside>
        <!-- SPL-18: a level-2 issue's subtasks (left column on desktop, below the panel on a phone) -->
        <section v-if="!creating && form.kind === 'issue'" class="issues-subs issues-detail-subs" data-test="issues-subtasks">
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
        <section v-if="!creating && form.task_id" class="issues-talk issues-detail-talk" data-test="issues-talk">
          <!-- SPL-963: the discussion takes its titles / 5 rows / full -->
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
            :editable="canEdit(c)"
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
                @blur="commentMp.close(); onCommentBlur()"
                @keydown="commentMp.onKeydown($event) || onSubmitKey($event, sendComment)"
              />
              <MentionList :picker="commentMp" placement="above" />
            </span>
          </label>
        </section>
      </div>
      </div>
    </IssueDetailFrame>
    <UiConfirm
      :open="Boolean(delTarget)"
      :title="t('issues_crud.delete_title', { key: delTarget ? delTarget.key : '' })"
      testid="issues-delete"
      :confirm-label="t('issues_crud.delete')"
      :busy-label="t('issues_crud.deleting')"
      :busy="delBusy"
      :error="delError"
      :body-attrs="{ 'data-key': delTarget ? delTarget.key : '' }"
      @update:open="onDeleteOpen"
      @confirm="confirmDelete"
    >
      <p class="issues-del-title">{{ delTarget ? delTarget.title : '' }}</p>
      <p>{{ t('issues_crud.delete_body') }}</p>
    </UiConfirm>
    <!-- SPL-1226: the right-click / long-press context menu, shared with the
         epics sidebar; the page owns the actions -->
    <IssueRowMenu
      :open="Boolean(ctxTarget)"
      :x="ctxPoint.x"
      :y="ctxPoint.y"
      :items="ctxItems"
      :over-modal="ctxOverModal"
      @close="onCtxClose"
      @choose="onCtxChoose"
    />
    <!-- SPL-1226: archive / delete a whole epic or feature, stating the count -->
    <UiConfirm
      :open="Boolean(actConfirm)"
      :title="actConfirm ? t(actConfirmTitleKey, { key: actConfirm.target.key, count: actConfirm.count }) : ''"
      testid="issues-cascade"
      :confirm-label="t(actConfirm && actConfirm.action === 'archive' ? 'issues_menu.archive' : 'issues_crud.delete')"
      :busy-label="t(actConfirm && actConfirm.action === 'archive' ? 'issues_menu.archiving' : 'issues_crud.deleting')"
      :busy="actBusy"
      :error="actError"
      :body-attrs="{ 'data-key': actConfirm ? actConfirm.target.key : '', 'data-count': actConfirm ? String(actConfirm.count) : '0' }"
      @update:open="onActConfirmOpen"
      @confirm="runAction"
    >
      <p class="issues-del-title">{{ actConfirm ? actConfirm.target.title : '' }}</p>
      <p v-if="actConfirm && actConfirm.count > 0">{{ t(actConfirm.action === 'archive' ? 'issues_menu.archive_cascade_body' : 'issues_menu.delete_cascade_body', { count: actConfirm.count }) }}</p>
      <p v-else>{{ t(actConfirm && actConfirm.action === 'archive' ? 'issues_menu.archive_body' : 'issues_crud.delete_body') }}</p>
    </UiConfirm>
    <!-- SPL-992: on a phone every picker is a bottom sheet over a scrim -->
    <div v-if="menu && phone" class="issues-scrim" data-test="issues-sheet-scrim" @pointerdown.stop @click="menu = null" />
    <!-- SPL-1027: over the issue modal the picker rides above the backdrop -->
    <Teleport to="body" :disabled="!menuOverModal">
    <div
      v-if="menu"
      class="issues-menu"
      :class="{ 'issues-menu--status': menu.kind === 'status', 'issues-sheet': phone, 'issues-menu--modal': menuOverModal }"
      role="listbox"
      data-test="issues-menu"
      :data-kind="menu.kind"
      :style="phone ? undefined : menuStyle"
      @click.stop
    >
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
    </Teleport>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useMentionPoke } from '~/composables/useMentionPoke'
import { useMessageEdit } from '~/composables/useMessageEdit'
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
import { useCopyText } from '~/composables/useCopyText'
import { useMobileStack } from '~/composables/useMobileStack'
import { useOmniboxStore } from '~/stores/omnibox'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { ISSUES_VIEWS, type IssuesView } from '~/utils/view-prefs.mjs'
import { useIssueColumns } from '~/composables/useIssueColumns'
import { COLW_MAX, colMin, colWidthClasses, colWidthVars, dragWidth, keyWidth, loadColWidths, saveColWidths, withColWidth } from '~/utils/issues-colw.mjs'
import { ISSUE_STATUSES, PRIO_DEFAULT, createMockIssues, isTopKind, normalizeIssue, normalizeLabel } from '~/utils/issues.mjs'
import { createLongPress } from '~/utils/touch-ui.mjs'
import { useIssueMenu, type IssueMenuTarget } from '~/composables/useIssueMenu'
import type { IssueMenuItem } from '~/components/IssueRowMenu.vue'
import {
  ISSUE_LEVELS,
  ISSUE_PRIORITIES,
  LEVEL_SHORT,
  applyIssueFrame,
  applyLabelFrame,
  deadlineToLocalInput,
  groupIssues,
  hubSort,
  nextSort,
  sortFromQuery,
  sortSheet,
  levelKey,
  localInputToDeadline,
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
const router = useRouter()
const session = useSessionStore()
const roster = useRosterStore()
const people = useHumanNames()
const api = useSpoolApi()
if (api.mock) api.bindIssuesMock((me: string) => createMockIssues({ me }))
const live = useLive()
/* SPL-982: a comment is a message card like any other, so its own author may
   edit / delete it. Same gate as the channel feed (LiveFeed): the shared
   MessageCard menu, double-click and Delete key all follow this. */
const { canEdit } = useMessageEdit()

const issues = ref<Issue[]>([])
const labels = ref<IssueLabel[]>([])
const loading = ref(false)
const busy = ref(false)
const loadError = ref('')
const saveError = ref('')
/* owner, topics e65c0f60 + e00da93b + 3a589b54: one flat list, sorted by a
   header click; the sort lives in ?sort=&dir=. With no ?sort= the list opens
   with the person's PER-TENANT default (issues_sort claim, SPL-1181), else the
   product default (priority ascending, applied by sortSheet/hubSort). */
function initialSort(): { col: string, dir: string } {
  const q = sortFromQuery(route.query as Record<string, unknown>)
  if (q.col) return q
  const stored = session.claims?.issues_sort
  if (stored && stored.col && stored.dir) return sortFromQuery({ sort: stored.col, dir: stored.dir })
  return { col: '', dir: '' }
}
const sheetSort = ref(initialSort())
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
const newTitleEl = ref<HTMLInputElement | null>(null)
const descEl = ref<{ edit: () => Promise<void> } | null>(null)
const scrollerEl = ref<HTMLElement | null>(null)
const theadEl = ref<HTMLElement | null>(null)
const pageEl = ref<HTMLElement | null>(null)
/* SPL-1027: the sheet's cell cursor (the row is cursorKey), the title being
   edited in place, the row whose deadline picker is open, the delete asked */
const SHEET_COLS = ['key', 'title', 'status', 'priority', 'level', 'assignee', 'label', 'deadline', 'updated', 'actions'] as const
const cursorCol = ref('')
const titleEdit = reactive({ key: '', text: '' })
const deadlineEditKey = ref('')
const delTarget = ref<Issue | null>(null)
const delBusy = ref(false)
const delError = ref('')
/* SPL-1226: the right-click / long-press context menu (shared with the epics
   sidebar) and its cascade archive/delete confirm */
const { target: ctxTarget, point: ctxPoint, openAt: openCtxMenu, close: closeCtxMenu } = useIssueMenu()
/* owner b82f3853: the same menu opened from the title-row button, not a
   right-click. Then it omits "Open" (the epic is already the view) and it
   right-aligns under the button. */
const ctxFromButton = ref(false)
/* CLE-77806: the same menu opened from the open issue's header actions button,
   which floats over the modal - the popover has to sit above --z-modal. */
const ctxOverModal = ref(false)
const { copy: copyText } = useCopyText()
const actConfirm = ref<{ target: IssueMenuTarget, action: 'archive' | 'delete', count: number } | null>(null)
const actBusy = ref(false)
const actError = ref('')
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
/* owner b82f3853: the epic/feature the view is filtered to (?epic=), as a menu
   target for the title-row actions button. null when the view is not filtered
   to one epic - then the button is disabled with a tooltip. A level-1 top row;
   the kind comes from the epics summary (epic vs feature), defaulting to epic. */
const selectedEpic = computed<IssueMenuTarget | null>(() => {
  const key = epicF.value
  if (!key) return null
  const e = epics.value.find((x) => x.key === key)
  return { key, kind: e?.kind || 'epic', level: 1, title: e?.title || key, top: true }
})
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
/* SPL-1028: the view. Signed in it is the person's (session claim, rdb 0072);
   signed out (the mock tenant) a click still switches this page. Phones keep
   the card list (SPL-992). */
const viewPrefs = useViewPrefs()
const viewLocal = ref<IssuesView | ''>('')
const viewBy = computed<IssuesView>(() => {
  if (phone.value) return 'list'
  return session.state === 'in' ? viewPrefs.issuesView.value : (viewLocal.value || 'list')
})
async function pickView(v: IssuesView) {
  if (session.state === 'in') { await viewPrefs.save('issues_view', v); return }
  viewLocal.value = v
}
const groups = computed(() => {
  const kept = groupIssues(issues.value, { sort: 'updated', filter: serverFilter(), me: meId(), by: 'none' })[0].issues
  const rows = sortSheet(kept, sheetSort.value, { name: person, labelName: labelText })
  if (viewBy.value !== 'status') return [{ status: '', count: rows.length, issues: rows }]
  /* Linear's "group by status": every status in the workflow order, its
     count, the sheet's sort inside each group; an empty group stays as a drop target */
  return ISSUE_STATUSES.map((status) => {
    const inGroup = rows.filter((i) => i.status === status)
    return { status, count: inGroup.length, issues: inGroup }
  })
})
/* folded status groups: a per-browser convenience (localStorage), not a hub setting */
const FOLD_KEY = 'spool.issues-folded'
const folded = ref<string[]>([])
function toggleFold(status: string) {
  folded.value = folded.value.includes(status) ? folded.value.filter((s) => s !== status) : [...folded.value, status]
  try { localStorage.setItem(FOLD_KEY, JSON.stringify(folded.value)) } catch { /* private window: this visit only */ }
}
/* drag a row onto another status group = that status (the Status cell does the same) */
const dragKey = ref('')
const dropStatus = ref('')
function onRowDragStart(ev: DragEvent, issue: Issue) {
  if (viewBy.value !== 'status') return
  dragKey.value = issue.key
  if (ev.dataTransfer) { ev.dataTransfer.effectAllowed = 'move'; ev.dataTransfer.setData('text/plain', issue.key) }
}
function onRowDragEnd() {
  dragKey.value = ''
  dropStatus.value = ''
}
function onGroupDragOver(ev: DragEvent, status: string) {
  if (!dragKey.value || !status) return
  ev.preventDefault()
  if (ev.dataTransfer) ev.dataTransfer.dropEffect = 'move'
  dropStatus.value = status
}
function onGroupDragLeave(ev: DragEvent, status: string) {
  const to = ev.relatedTarget
  if (dropStatus.value === status && !(to instanceof Node && (ev.currentTarget as HTMLElement).contains(to))) dropStatus.value = ''
}
function onGroupDrop(ev: DragEvent, status: string) {
  const key = dragKey.value || ev.dataTransfer?.getData('text/plain') || ''
  onRowDragEnd()
  if (!key || !status) return
  ev.preventDefault()
  const issue = issues.value.find((i) => i.key === key)
  if (issue && issue.status !== status) void save(issue.key, { status })
}
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
/* owner, topic beb4024f: resizable columns. A width set by dragging a
   header's edge (or the arrow keys on it) is the PERSON's (SPL-1132: the
   issues_columns claim kept on the hub, one PUT per gesture); signed out it
   is kept per browser. A column with no width keeps the automatic layout.
   colWidths is what the table draws: a drag writes it on every move, the
   store only on release. */
const issueCols = useIssueColumns({ load: loadColWidths, save: saveColWidths })
const colWidths = ref<Record<string, number>>({})
let colDragging = false
watch(issueCols.widths, (w) => { if (!colDragging) colWidths.value = { ...w } })
function setColWidth(col: string, px: number) {
  colWidths.value = withColWidth(colWidths.value, col, px)
  issueCols.save(colWidths.value)
}
function headerWidth(grip: EventTarget | null): number {
  const th = grip instanceof HTMLElement ? grip.closest('th') : null
  return th ? th.getBoundingClientRect().width : 0
}
function isRtl(el: EventTarget | null): boolean {
  return el instanceof HTMLElement && getComputedStyle(el).direction === 'rtl'
}
/* preventDefault on pointerdown (no text selection while dragging) also
   swallows the browser's dblclick, so a second press on the same grip
   within the double-click time is the double-click */
let lastGripDown = { col: '', at: 0 }
function onGripDown(ev: PointerEvent, col: string) {
  if (ev.button !== 0) return
  const grip = ev.currentTarget as HTMLElement
  ev.preventDefault()
  ev.stopPropagation()
  const now = ev.timeStamp || Date.now()
  if (lastGripDown.col === col && now - lastGripDown.at < 400) {
    lastGripDown = { col: '', at: 0 }
    void fitColumn(col)
    return
  }
  lastGripDown = { col, at: now }
  const startX = ev.clientX
  const startW = headerWidth(grip)
  const rtl = isRtl(grip)
  grip.setPointerCapture?.(ev.pointerId)
  grip.dataset.dragging = 'true'
  colDragging = true
  const move = (e: PointerEvent) => {
    const w = dragWidth(startW, e.clientX - startX, rtl, col)
    if (w != null) colWidths.value = withColWidth(colWidths.value, col, w)
  }
  const end = () => {
    grip.removeEventListener('pointermove', move)
    grip.removeEventListener('pointerup', end)
    grip.removeEventListener('pointercancel', end)
    delete grip.dataset.dragging
    colDragging = false
    issueCols.save(colWidths.value)
  }
  grip.addEventListener('pointermove', move)
  grip.addEventListener('pointerup', end)
  grip.addEventListener('pointercancel', end)
}
/* A double-click fits the column to its content: every cell of it is
   shrunk to its floor for one synchronous measure, and each cell asks for
   its width plus whatever its content still overflows by (a clipped title,
   an ellipsised name). Nothing paints in between. */
async function fitColumn(col: string) {
  colWidths.value = withColWidth(colWidths.value, col, 0)
  await nextTick()
  const table = pageEl.value?.querySelector<HTMLElement>('.issues-table')
  if (!table) return
  const cells = [...table.querySelectorAll<HTMLElement>(`[data-col="${col}"]`)]
  const saved = cells.map((el) => el.style.cssText)
  for (const el of cells) {
    el.style.width = '1%'
    el.style.minWidth = '0'
    el.style.maxWidth = 'none'
  }
  let need = 0
  for (const el of cells) {
    let over = 0
    for (const d of [el, ...el.querySelectorAll<HTMLElement>('*')]) {
      /* only an element that clips (overflow not visible) hides content; an
         inline span reads clientWidth 0 and must not count */
      if (d.scrollWidth > d.clientWidth + 1 && getComputedStyle(d).overflowX !== 'visible') over = Math.max(over, d.scrollWidth - d.clientWidth)
    }
    need = Math.max(need, el.getBoundingClientRect().width + over)
  }
  cells.forEach((el, i) => { el.style.cssText = saved[i] })
  if (need > 0) setColWidth(col, Math.ceil(need))
}
function onGripKey(ev: KeyboardEvent, col: string) {
  const w = keyWidth(colWidths.value[col] || headerWidth(ev.currentTarget), ev.key, isRtl(ev.currentTarget), col)
  if (w == null) return
  ev.preventDefault()
  ev.stopPropagation()
  setColWidth(col, w)
}
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
const shownGroups = computed(() => (rowCount.value || viewBy.value === 'status' ? groups.value : []))
/* J / K walk the rows in the order the sheet shows them */
const flat = computed(() => groups.value.flatMap((g) => (g.status && folded.value.includes(g.status) ? [] : g.issues)))
const activeAssignee = computed(() => creating.value ? draft.assignee : (detail.value?.assignee || ''))
const activeLabels = computed(() => creating.value ? draft.labels : (detail.value?.labels || []))
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

/* SPL-992 (epic SPL-988): at <= 820 px the page is the phone's level 2 and
   the open issue its level 3 - M1's useMobileStack owns levels and history */
const stack = useMobileStack()
const phone = computed(() => stack.isMobile.value)
const filtersOpen = ref(false)
const sortOpen = ref(false)
/* SPL-1027: above 820 px an opened issue is the modal; its pickers ride above it */
const modalOpen = computed(() => !phone.value && Boolean(detail.value) && !creating.value)
const menuOverModal = computed(() => import.meta.client && modalOpen.value && Boolean(menu.value))
stack.rightPanel(() => phone.value && Boolean(form.value), closeDetail)
/* SPL-994: each sheet is the top level while open - Back closes it first */
stack.overlay(() => phone.value && filtersOpen.value, () => { filtersOpen.value = false })
stack.overlay(() => phone.value && sortOpen.value, () => { sortOpen.value = false })
stack.overlay(() => phone.value && Boolean(menu.value), () => { menu.value = null })
const filtersActive = computed(() => Boolean(statusF.value || priorityF.value || levelF.value || assigneeF.value || labelF.value || dueF.value))
const sortChoices = computed(() => [
  { value: ':', label: t('issues_mobile.sort_default') },
  ...sheetColumns.value.flatMap((c) => [
    { value: `${c.col}:asc`, label: `${c.name} ▲` },
    { value: `${c.col}:desc`, label: `${c.name} ▼` },
  ]),
])
const sortValue = computed(() => `${sheetSort.value.col}:${sheetSort.value.dir}`)
const sortShown = computed(() => sortChoices.value.find((o) => o.value === sortValue.value)?.label || '')
function pickSort(value: string) {
  const [sort = '', dir = ''] = value.split(':')
  sheetSort.value = sortFromQuery({ sort, dir })
  sortOpen.value = false
}
/* an epic chip is the side panel's epic row: ?epic= on the same entry */
function pickEpic(key: string) {
  const query: Record<string, string> = {}
  new URL(window.location.href).searchParams.forEach((v, k) => { query[k] = v })
  if (key) query.epic = key
  else delete query.epic
  void router.replace({ query })
}

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
  /* SPL-1027: > 820 px Back and Forward walk these entries, so the router's
     own record of each must match its URL - a bare replaceState kept the
     router's old path and a later Back brought a closed ?issue= back */
  if (!phone.value) {
    const query = currentQuery()
    if (key) query.issue = key
    else delete query.issue
    void router.replace({ query })
    return
  }
  if (key) url.searchParams.set('issue', key)
  else url.searchParams.delete('issue')
  window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash)
}
/* SPL-1027: above 820 px opening an issue is a history entry (?issue=SPL-n),
   so Back closes the modal and a deep link opens it. A phone keeps
   replaceState: useMobileStack owns its levels and history (SPL-992). */
let pushedIssue = false
/* the router writes ?issue= a tick (or, on a loaded machine, much longer)
   after the modal shows: a close inside that window waits for the push to
   land, then steps Back over it, and the late route change must not reopen
   what was just closed */
let pendingPush: Promise<unknown> | null = null
let suppressKey = ''
function currentQuery(): Record<string, string> {
  const query: Record<string, string> = {}
  new URL(window.location.href).searchParams.forEach((v, k) => { query[k] = v })
  return query
}
function pushIssueQuery(key: string) {
  if (!import.meta.client) return
  if (phone.value || modalOpen.value || issueLinkKey() === key) { writeIssueQuery(key); return }
  pushedIssue = true
  const push = router.push({ query: { ...currentQuery(), issue: key } })
  pendingPush = push
  void push.finally(() => { if (pendingPush === push) pendingPush = null })
}
function choose(issue: Issue, fromLink = false) {
  const wasOpen = modalOpen.value
  cursorKey.value = issue.key
  creating.value = false
  openKey.value = issue.key
  menu.value = null
  if (fromLink || wasOpen) writeIssueQuery(issue.key)
  else pushIssueQuery(issue.key)
  detail.value = issue
}
function closeDetail() {
  const wasModal = modalOpen.value
  const closedKey = detail.value?.key || ''
  creating.value = false
  openKey.value = ''
  detail.value = null
  menu.value = null
  if (wasModal && pushedIssue && pendingPush) {
    pushedIssue = false
    suppressKey = closedKey
    void pendingPush.then(() => { if (issueLinkKey()) router.back() }, () => { suppressKey = '' })
    return
  }
  if (wasModal && pushedIssue && issueLinkKey()) {
    pushedIssue = false
    router.back()
    return
  }
  pushedIssue = false
  writeIssueQuery('')
}
function startCreate(status = '') {
  creating.value = true
  openKey.value = ''
  detail.value = null
  writeIssueQuery('')
  draft.title = ''
  draft.description = ''
  draft.status = (ISSUE_STATUSES as readonly string[]).includes(status) ? status : 'todo'
  draft.priority = PRIO_DEFAULT
  draft.assignee = ''
  draft.labels = []
  draft.deadlineLocal = ''
  draft.kind = 'issue'
  draft.epic = epicF.value || epics.value.find((e) => e.status !== 'done' && e.status !== 'diss')?.key || epics.value[0]?.key || ''
  menu.value = null
  saveError.value = ''
  cursorCol.value = ''
  /* SPL-1027: > 820 px the new issue is the sheet's top row */
  void nextTick(() => (phone.value ? titleEl.value : newTitleEl.value)?.focus())
}
function cancelCreate() {
  creating.value = false
  saveError.value = ''
  menu.value = null
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
  if (kind === 'epic') return [{ value: '', label: t('issues.no_epic'), hint }, ...epics.value.map((e) => ({ value: e.key, label: `${e.key} ${e.title}`, hint }))]
  if (kind === 'level') return ISSUE_LEVELS.map((n) => ({ value: String(n), label: `${n} ${t(levelKey(n))}`, hint }))
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
  /* open aligned under the trigger; the real right-edge clamp runs once the
     menu has a measured width (CLE-77806: the property panel sits near the
     viewport's right edge, so a fixed guess over-shifted the picker there). */
  menuPos.value = {
    top: r ? r.bottom + 4 : 120,
    left: Math.max(8, r ? r.left : 80),
  }
  menu.value = { kind, key: issue?.key || '' }
  menuIndex.value = 0
  labelName.value = ''
  void nextTick(clampMenuIntoView)
}
/* keep the open picker inside the viewport by its actual width, shifting left
   only when it would truly overflow the right edge (a phone sheet is full-width
   via CSS, so its inline left is ignored - nothing to clamp). */
function clampMenuIntoView() {
  if (phone.value) return
  const el = document.querySelector('[data-test=issues-menu]') as HTMLElement | null
  if (!el) return
  const w = el.getBoundingClientRect().width
  const maxLeft = window.innerWidth - 8 - w
  if (menuPos.value.left > maxLeft) menuPos.value.left = Math.max(8, maxLeft)
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
  if (creating.value && !busy.value && draft.title.trim()) void createIssue()
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
  moveLevel(issue, want, ev)
}
function moveLevel(issue: Issue, want: number, ev?: Event) {
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
  /* SPL-992: the phone's level sheet moves like the sheet's level box; a move
     that needs a parent opens the next sheet */
  if (kind === 'level') { menu.value = null; moveLevel(issue, Number(value)); return }
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
  if (!title || busy.value) return
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
  else if (draft.epic) body.parent = draft.epic /* W16: no epic = a lone level-2 issue */
  const deadline = localInputToDeadline(draft.deadlineLocal)
  if (deadline) body.deadline = deadline
  try {
    const data = await withSessionRetry(api, () => api.createIssue(body))
    const created = normalizeIssue(data.issue)
    hold(created)
    void poke({ text: `${title}\n${String(body.description || '')}`, where: { issue: true, issueKey: created.key } })
    creating.value = false
    if (!phone.value) {
      /* SPL-1027: the row stays in the sheet; the cursor moves on to its cells */
      cursorKey.value = created.key
      cursorCol.value = 'status'
      focusCell()
      return
    }
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

/* ---- SPL-1027: the sheet's cells, in place ------------------------------------ */
function cellAttrs(issue: Issue, col: string) {
  return {
    'data-col': col,
    'data-cell-on': cursorKey.value === issue.key && cursorCol.value === col ? 'true' : undefined,
    tabindex: -1,
  }
}
function cellEl(key: string, col: string): HTMLElement | null {
  return pageEl.value?.querySelector(`[data-test=issues-row][data-key="${CSS.escape(key)}"] [data-col="${col}"]`) || null
}
function focusCell() {
  void nextTick(() => {
    if (!cursorKey.value || !cursorCol.value) return
    cellEl(cursorKey.value, cursorCol.value)?.focus()
  })
}
function stepCol(delta: number) {
  if (!cursorKey.value) cursorKey.value = flat.value[0]?.key || ''
  if (!cursorKey.value) return
  const at = SHEET_COLS.indexOf(cursorCol.value as typeof SHEET_COLS[number])
  const from = at < 0 ? (delta > 0 ? 0 : 1) : at
  cursorCol.value = SHEET_COLS[Math.max(0, Math.min(SHEET_COLS.length - 1, from + (at < 0 ? 0 : delta)))]
  focusCell()
}
/* Enter on a cell: the key and Updated open the issue, every other cell edits */
function editCell(issue: Issue, col: string) {
  const td = cellEl(issue.key, col)
  const at = td ? { currentTarget: td } as unknown as Event : undefined
  if (col === 'title') { startTitleEdit(issue); return }
  if (col === 'status') { openMenu('status', issue, at); return }
  if (col === 'assignee') { openMenu('assign', issue, at); return }
  if (col === 'label') { openMenu('label', issue, at); return }
  if (col === 'deadline') { startDeadlineEdit(issue); return }
  if (col === 'actions') { askDelete(issue); return }
  if (col === 'priority' || col === 'level') {
    const sel = td?.querySelector('select') as (HTMLSelectElement & { showPicker?: () => void }) | null
    sel?.focus()
    try { sel?.showPicker?.() } catch { /* focus is enough: the arrows pick */ }
    return
  }
  choose(issue)
}
function startTitleEdit(issue: Issue) {
  cursorKey.value = issue.key
  cursorCol.value = 'title'
  menu.value = null
  titleEdit.key = issue.key
  titleEdit.text = issue.title
  void nextTick(() => {
    const el = pageEl.value?.querySelector<HTMLInputElement>('[data-test=issues-row-title-input]')
    el?.focus()
    el?.select()
  })
}
function commitRowTitle(issue: Issue) {
  if (titleEdit.key !== issue.key) return
  const value = titleEdit.text.trim()
  titleEdit.key = ''
  if (value && value !== issue.title) void save(issue.key, { title: value })
}
function onRowTitleKey(ev: KeyboardEvent, issue: Issue) {
  if (ev.key === 'Enter') { ev.preventDefault(); commitRowTitle(issue); focusCell(); return }
  if (ev.key === 'Escape') { ev.preventDefault(); titleEdit.key = ''; focusCell() }
}
function startDeadlineEdit(issue: Issue) {
  cursorKey.value = issue.key
  cursorCol.value = 'deadline'
  menu.value = null
  deadlineEditKey.value = issue.key
  void nextTick(() => pageEl.value?.querySelector<HTMLInputElement>('[data-test=issues-row-deadline-input]')?.focus())
}
function onRowDeadline(issue: Issue, local: string) {
  deadlineEditKey.value = ''
  const deadline = localInputToDeadline(local)
  if (deadline === null || deadline === (issue.deadline || '')) { focusCell(); return }
  void save(issue.key, { deadline })
  focusCell()
}
function askDelete(issue: Issue) {
  menu.value = null
  delError.value = ''
  delTarget.value = issue
}
function onDeleteOpen(open: boolean) {
  if (!open && !delBusy.value) delTarget.value = null
}
function deleteErrKey(err: { status?: number, token?: string }) {
  if (err?.token === 'issue_has_children') return 'issues_crud.err_has_children'
  if (Number(err?.status) === 403) return 'issues_crud.err_delete_forbidden'
  return errorKey(err, 'one')
}
async function confirmDelete() {
  const issue = delTarget.value
  if (!issue || delBusy.value) return
  delBusy.value = true
  delError.value = ''
  try {
    await withSessionRetry(api, () => api.deleteIssue(issue.key))
    const at = flat.value.findIndex((i) => i.key === issue.key)
    issues.value = issues.value.filter((i) => i.key !== issue.key)
    subtasks.value = subtasks.value.filter((i) => i.key !== issue.key)
    refreshEpics()
    if (detail.value?.key === issue.key) closeDetail()
    if (cursorKey.value === issue.key) cursorKey.value = flat.value[Math.min(at, flat.value.length - 1)]?.key || ''
    delTarget.value = null
  } catch (e) {
    delError.value = t(deleteErrKey(e as { status?: number, token?: string }))
  } finally {
    delBusy.value = false
  }
}

/* ---- SPL-1226: the right-click / long-press context menu ------------------ */
function issueTarget(i: Issue): IssueMenuTarget {
  return { key: i.key, kind: i.kind, level: i.level, title: i.title, top: isTopKind(i.kind) }
}
/* one long-press machine for every row; the row it fired on is remembered on
   pointerdown (createLongPress only reports the point) */
let pressTarget: IssueMenuTarget | null = null
const rowPress = createLongPress({ onPress: (x, y) => { if (pressTarget) openCtxMenu(pressTarget, x, y) } })
function onRowContext(issue: Issue, ev: MouseEvent) {
  ev.preventDefault()
  ev.stopPropagation()
  openCtxMenu(issueTarget(issue), ev.clientX, ev.clientY)
}
function onRowPointerDown(issue: Issue, ev: PointerEvent) { pressTarget = issueTarget(issue); rowPress.down(ev) }
/* the click the finger sends when a long-press lifts must not also open the row */
function onRowActivate(issue: Issue) { if (rowPress.takeClick()) return; choose(issue) }

const ctxItems = computed<IssueMenuItem[]>(() => {
  const tg = ctxTarget.value
  if (!tg) return []
  const items: IssueMenuItem[] = []
  /* from the title-row button the epic is already the open view - no "Open" */
  if (!ctxFromButton.value) items.push({ id: 'open', icon: 'open', labelKey: 'issues_menu.open' })
  items.push({ id: 'copy', icon: 'copy', labelKey: 'issues_menu.copy_link' })
  /* CLE-77806: from the open issue's header menu, status and assignee already
     have their own rows in the property panel - no need to repeat them here */
  if (!tg.top && !ctxOverModal.value) {
    items.push({ id: 'status', icon: 'pencil', labelKey: 'issues_menu.status' })
    items.push({ id: 'assign', icon: 'user', labelKey: 'issues_menu.assign' })
  }
  items.push({ id: 'archive', icon: 'archive', labelKey: 'issues_menu.archive' })
  items.push({ id: 'delete', icon: 'delete', labelKey: 'issues_menu.delete', danger: true })
  return items
})
/* owner b82f3853: the title-row actions button opens the same menu, targeting
   the epic/feature the view is filtered to, right-aligned under the button. */
function openEpicMenu(ev: MouseEvent) {
  const tg = selectedEpic.value
  if (!tg) return
  const r = (ev.currentTarget as HTMLElement).getBoundingClientRect()
  ctxFromButton.value = true
  openCtxMenu(tg, Math.max(8, r.right - 176), r.bottom + 4)
}
/* CLE-77806 (owner, topic 260d2cbb): the open issue's actions live in the modal
   header (⋯), not as a Delete button in the body. It opens the same shared menu
   - Copy link / Status / Assignee / Archive / Delete - aimed at the open issue,
   dropped just under the button and lifted above the modal. */
function openDetailMenu(ev: MouseEvent) {
  if (!detail.value) return
  const r = (ev.currentTarget as HTMLElement).getBoundingClientRect()
  ctxFromButton.value = true
  ctxOverModal.value = true
  openCtxMenu(issueTarget(detail.value), Math.max(8, r.right - 176), r.bottom + 4)
}
function onCtxClose() { closeCtxMenu(); ctxFromButton.value = false; ctxOverModal.value = false }
/* the shareable link for a menu target: an epic/feature opens its filtered
   view (?epic=), a plain issue deep-links itself (?issue=) */
function issueLinkFor(tg: IssueMenuTarget): string {
  const q = tg.top ? `?epic=${encodeURIComponent(tg.key)}` : `?issue=${encodeURIComponent(tg.key)}`
  const rel = `/issues${q}`
  if (import.meta.client) { try { return new URL(rel, window.location.origin).href } catch { /* fall through */ } }
  return rel
}
function onCtxChoose(id: string) {
  const tg = ctxTarget.value
  if (!tg) return
  const pt = { ...ctxPoint.value }
  if (id === 'copy') { void copyText(issueLinkFor(tg), tg.key); return }
  if (id === 'open') {
    if (tg.top) { void router.push({ query: { ...route.query, epic: tg.key } }); return }
    const issue = issues.value.find((i) => i.key === tg.key)
    if (issue) choose(issue)
    return
  }
  if (id === 'status' || id === 'assign') {
    const issue = issues.value.find((i) => i.key === tg.key)
    if (!issue) return
    openMenu(id === 'status' ? 'status' : 'assign', issue)
    menuPos.value = { top: pt.y, left: Math.max(8, Math.min(pt.x, window.innerWidth - 240)) }
    return
  }
  /* CLE-77806: from the modal header, Delete removes the one open issue with the
     same single-issue confirm the body's Delete button used (which refuses when
     it still has live subtasks); Archive keeps the shared cascade path. */
  if (id === 'delete' && ctxOverModal.value && detail.value) { askDelete(detail.value); return }
  if (id === 'archive' || id === 'delete') askAction(id, tg)
}
/* the count the confirm states: for an epic / feature the issues under it, else
   the subtasks held under it. Counted from the loaded list (immediate, in step
   with what is shown); the epics summary is a fallback for when the list is
   filtered to another epic (the summary read is debounced, so it can lag). */
function descendantCount(tg: IssueMenuTarget): number {
  if (tg.top) {
    const inList = issues.value.filter((i) => i.epic === tg.key).length
    return Math.max(inList, epics.value.find((e) => e.key === tg.key)?.total || 0)
  }
  return issues.value.filter((i) => i.parent === tg.key).length
}
function askAction(action: 'archive' | 'delete', tg: IssueMenuTarget) {
  closeCtxMenu()
  actError.value = ''
  actConfirm.value = { target: tg, action, count: descendantCount(tg) }
}
function onActConfirmOpen(open: boolean) {
  if (!open && !actBusy.value) actConfirm.value = null
}
/* the confirm's error text. A cascade archive/delete hits endpoints a hub
   older than SPL-1226 does not have: POST .../archive is 404/405, and
   DELETE ?cascade=1 is ignored so a parent comes back 409 issue_has_children.
   Both must read as "the server is not updated yet", never a silent no-op or
   the misleading "move its issues first" (CLE-001, owner b82f3853). */
function actErrorKey(err: { status?: number, token?: string }, cascade: boolean) {
  const s = Number(err?.status)
  if (s === 404 || s === 405 || s === 501) return 'issues_menu.err_unavailable'
  if (cascade && err?.token === 'issue_has_children') return 'issues_menu.err_unavailable'
  if (s === 403) return 'issues_crud.err_delete_forbidden'
  return errorKey(err, 'one')
}
async function runAction() {
  const c = actConfirm.value
  if (!c || actBusy.value) return
  actBusy.value = true
  actError.value = ''
  /* a level-1 row (or one with children) takes its subtree with it */
  const cascade = c.target.top || c.count > 0
  try {
    const res = c.action === 'archive'
      ? await withSessionRetry(api, () => api.archiveIssue(c.target.key, { cascade }))
      : await withSessionRetry(api, () => api.deleteIssue(c.target.key, { cascade }))
    const gone = new Set<string>([c.target.key, ...((res.descendants as string[] | undefined) || [])])
    issues.value = issues.value.filter((i) => !gone.has(i.key))
    subtasks.value = subtasks.value.filter((i) => !gone.has(i.key))
    refreshEpics()
    if (detail.value && gone.has(detail.value.key)) closeDetail()
    if (cursorKey.value && gone.has(cursorKey.value)) cursorKey.value = flat.value[0]?.key || ''
    actConfirm.value = null
  } catch (e) {
    /* keep the confirm open with a clear message - never a silent no-op */
    actError.value = t(actErrorKey(e as { status?: number, token?: string }, cascade))
  } finally {
    actBusy.value = false
  }
}
const actConfirmTitleKey = computed(() => {
  const c = actConfirm.value
  if (!c) return ''
  if (c.count > 0) return c.action === 'archive' ? 'issues_menu.archive_cascade_title' : 'issues_menu.delete_cascade_title'
  return c.action === 'archive' ? 'issues_menu.archive_title' : 'issues_menu.delete_title'
})

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
/* one comment into the issue's discussion (is_parent 0 on its task) - the
   discussion box and, on a phone, the bottom dock's GO */
async function postComment(issue: Issue, text: string) {
  const sock = live.ensure()
  if (sock) {
    await sock.send({ task_id: issue.task_id, kind: 'note', body: text, files: [], channel: issue.channel || ISSUE_CHANNEL, is_parent: 0 })
  } else {
    await api.sendMessage({ text, task_id: issue.task_id, channel: issue.channel || ISSUE_CHANNEL, is_parent: 0 })
  }
  void poke({ text, where: { issue: true, issueKey: issue.key } })
  await loadComments(issue)
}

async function sendComment() {
  const issue = detail.value
  const text = commentMp.encode(commentText.value).trim()
  if (!issue || !issue.task_id || !text) return
  busy.value = true
  saveError.value = ''
  try {
    await postComment(issue, text)
    commentText.value = ''
  } catch {
    saveError.value = 'issues.save_failed'
  } finally {
    busy.value = false
  }
}

/* owner, prd t1 topic 110d842c: a comment saves when the box loses focus (a
   click elsewhere), like the issue description autosaves - not only on Enter.
   MentionList swallows its own mousedown, so picking a name keeps the focus
   and never blur-posts a half-typed @token. */
function onCommentBlur() {
  if (busy.value) return
  if (!commentMp.encode(commentText.value).trim()) return
  void sendComment()
}

/* (owner, prd t1 topic 110d842c: "In issues on mobile, clicking on
   the omnibox, typing and clicking the GO button does not create a
   comment"). /issues registered no omnibox send target, so the phone dock's
   GO had nowhere to send and did nothing. With an issue open on a phone
   (level 3) the dock now comments on it; the list stays search-only.
   Desktop keeps its Omnibox as search - the discussion box is on screen. */
const omniboxStore = useOmniboxStore()
const commentOwner = Symbol('issue-comment')
async function sendDockComment(text: string, files: File[]) {
  const issue = detail.value
  if (!issue || !issue.task_id) return
  /* a comment carries no attachment (the discussion box has none): refuse
     rather than post the text and drop the file on the floor */
  if (files.length) throw Object.assign(new Error('issue comments take no files'), { token: 'files' })
  const body = text.trim()
  if (!body) return
  busy.value = true
  try {
    await postComment(issue, body)
  } finally {
    busy.value = false
  }
  /* the discussion is below the fold on a phone: without this the only sign
     of the post was an empty dock - the owner's "does not create a comment"
     again. Comments are oldest first, so the new one is the last card. */
  await nextTick()
  const cards = document.querySelectorAll('[data-test=issues-comment]')
  cards[cards.length - 1]?.scrollIntoView({ block: 'center' })
}
const dockComment = computed(() => Boolean(phone.value && detail.value && detail.value.task_id && !creating.value))
watch(dockComment, (on) => {
  if (!on) { omniboxStore.unregister(commentOwner); return }
  omniboxStore.register({
    owner: commentOwner,
    placeholder: () => t('composer.target_comment', { target: detail.value?.key || '' }),
    dock: () => ({ reply: true, target: detail.value?.key || '', comment: true }),
    send: sendDockComment,
    busy: () => busy.value,
  })
}, { immediate: import.meta.client })
onBeforeUnmount(() => omniboxStore.unregister(commentOwner))

/* SPL-1027: a picker opened by S / P / A / L sits under its control - the
   modal's field, or the row's cell - never at a fixed corner of the page */
const KEY_ANCHOR: Record<string, [string, string]> = {
  status: ['issues-status', 'status'],
  priority: ['issues-priority', 'priority'],
  assign: ['issues-assignee', 'assignee'],
  label: ['issues-labels', 'label'],
}
function keyAnchor(kind: string, issue: Issue): Event | undefined {
  const [field, col] = KEY_ANCHOR[kind] || ['', '']
  const el = modalOpen.value
    ? document.querySelector(`[data-test=issues-detail] [data-test=${field}]`)
    : (!phone.value && issue.key && issue.key !== 'draft' ? cellEl(issue.key, col) : null)
  return el ? { currentTarget: el } as unknown as Event : undefined
}
function typingTarget(el: EventTarget | null) {
  if (!(el instanceof HTMLElement)) return false
  const tag = el.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable
}
/* SPL-1027: the issue modal is the ONE open dialog and holds the issue */
function issueModal(): HTMLElement | null {
  const open = document.querySelectorAll<HTMLElement>('[aria-modal="true"]')
  return open.length === 1 && open[0].querySelector('[data-test=issues-detail]') ? open[0] : null
}
/* Esc inside the issue modal: a picker closes first, then a text area is
   left (the description saves on blur, a comment draft stays), and only then
   UiDialog closes the modal. Capture phase: UiDialog's own keydown stops Esc
   before the page sees it. */
function onDocKeyCapture(ev: KeyboardEvent) {
  if (ev.key !== 'Escape' || phone.value || !modalOpen.value) return
  const modal = issueModal()
  if (!modal) return
  if (menu.value) { ev.preventDefault(); ev.stopPropagation(); menu.value = null; return }
  const el = ev.target
  if (el instanceof HTMLTextAreaElement && modal.contains(el)) {
    ev.preventDefault()
    ev.stopPropagation()
    el.blur()
    modal.focus() /* focus stays in the dialog, so the next Esc closes it */
  }
}
function onDocKey(ev: KeyboardEvent) {
  if (tabForPath(route.path) !== 'issues') return
  const inModal = Boolean(document.querySelector('[aria-modal="true"]'))
  if (inModal && !issueModal()) return
  const key = ev.key
  const typing = typingTarget(ev.target)
  const menuOpen = Boolean(menu.value)
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return
  /* focus outside the panel (a click on its padding): UiDialog never saw it */
  if (inModal && key === 'Escape') { ev.preventDefault(); if (menuOpen) menu.value = null; else closeDetail(); return }
  if (key === 'Escape' && deadlineEditKey.value) { ev.preventDefault(); deadlineEditKey.value = ''; focusCell(); return }
  if (key === 'Escape' && (filtersOpen.value || sortOpen.value)) { ev.preventDefault(); filtersOpen.value = false; sortOpen.value = false; return }
  if (key === 'Escape' && (menuOpen || statusOpen.value)) { ev.preventDefault(); menu.value = null; statusOpen.value = false; return }
  if (key === 'Escape' && typing) { (ev.target as HTMLElement).blur(); ev.preventDefault(); return }
  if (key === 'Escape') {
    ev.preventDefault()
    if (statusOpen.value) { statusOpen.value = false; return }
    if (menuOpen) menu.value = null
    else if (creating.value && !phone.value) cancelCreate()
    else if (cursorCol.value) { cursorCol.value = ''; (ev.target as HTMLElement)?.blur?.() }
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
  /* in the issue modal only its own keys: E and the S / P / A / L pickers */
  if (inModal && !['e', 's', 'p', 'a', 'l'].includes(k)) return
  if (k === 'j' || key === 'ArrowDown') { move(1); focusCell(); ev.preventDefault(); return }
  if (k === 'k' || key === 'ArrowUp') { move(-1); focusCell(); ev.preventDefault(); return }
  /* SPL-1027: Left / Right move the cell cursor, Enter edits the cell */
  if (!phone.value && (key === 'ArrowRight' || key === 'ArrowLeft')) { stepCol(key === 'ArrowRight' ? 1 : -1); ev.preventDefault(); return }
  if (key === 'Enter') {
    const issue = flat.value.find((i) => i.key === cursorKey.value) || flat.value[0]
    if (issue && cursorCol.value && !phone.value) editCell(issue, cursorCol.value)
    else if (issue) choose(issue)
    ev.preventDefault()
    return
  }
  if (k === 'c') { startCreate(); ev.preventDefault(); return }
  if (k === 'e' && form.value) { void descEl.value?.edit(); ev.preventDefault(); return }
  const kind = { s: 'status', p: 'priority', a: 'assign', l: 'label' }[k]
  const issue = creating.value ? detailOrDraft() : (detail.value || flat.value.find((i) => i.key === cursorKey.value) || flat.value[0])
  if (kind && issue) { openMenu(kind, issue, keyAnchor(kind, issue)); ev.preventDefault() }
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
  choose(issue, true)
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
}, (key) => {
  /* the push of an issue closed before it landed: not a request to open it */
  if (key && suppressKey && key.toLowerCase() === suppressKey.toLowerCase()) { suppressKey = ''; return }
  if (!key) suppressKey = ''
  /* SPL-1027: Back past the entry the modal pushed closes it */
  if (!key && modalOpen.value) {
    pushedIssue = false
    openKey.value = ''
    detail.value = null
    menu.value = null
    return
  }
  void openLinkedIssue()
})
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
/* owner, topic e0f6f074 (SPL-972): every pop-up list closes on a click outside it */
function onDocPointer(ev: Event) {
  const t = ev.target
  const inside = (sel: string) => {
    const el = pageEl.value?.querySelector(sel)
    return Boolean(el && t instanceof Node && el.contains(t))
  }
  /* the menu may ride over the issue modal, teleported out of the page */
  const menuEl = document.querySelector('[data-test=issues-menu]')
  if (statusOpen.value && !inside('[data-test=issues-filter-status]')) statusOpen.value = false
  if (menu.value && !(menuEl && t instanceof Node && menuEl.contains(t))) menu.value = null
  if (deadlineEditKey.value && !inside('[data-deadline-edit="true"]')) deadlineEditKey.value = ''
}
onMounted(() => {
  colWidths.value = { ...issueCols.widths.value }
  try {
    const raw = JSON.parse(localStorage.getItem(FOLD_KEY) || '[]')
    if (Array.isArray(raw)) folded.value = raw.filter((x): x is string => typeof x === 'string' && (ISSUE_STATUSES as readonly string[]).includes(x))
  } catch { /* none folded */ }
  useTopicStore().close()
  useLiveFeed('pane').close()
  document.addEventListener('keydown', onDocKey)
  document.addEventListener('keydown', onDocKeyCapture, true)
  document.addEventListener('pointerdown', onDocPointer)
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
  document.removeEventListener('keydown', onDocKeyCapture, true)
  document.removeEventListener('pointerdown', onDocPointer)
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
/* topic e5b17522 (owner): the highlighted view toggle starts ~1.5 cm (57px
   @96dpi) to the right of the + button. The 8px header gap already sits
   between them, so the extra margin is 57 - 8 = 49px. Clear filters then flows
   right after the toggle with the normal header gap. */
.issues-head__views { margin-inline-start: 49px; }
.issues-head__clear { flex: 0 0 auto; }
/* owner b82f3853: the epic/feature actions button (three-line menu glyph).
   "not next to it, but just 5 mm right from the screen edge" - it sits at the
   inline END of the title row, ~5 mm (19px @96dpi) from the content's right
   edge; margin-inline-* are logical, so RTL mirrors it to the left edge. It
   stays enabled-looking but dims and blocks its click when nothing is selected,
   so the tooltip explaining why still shows on hover (a real [disabled] button
   suppresses the title). */
.issues-head__menu { flex: 0 0 auto; margin-inline-start: auto; margin-inline-end: 19px; display: inline-flex; align-items: center; justify-content: center; padding-inline: 8px; }
.issues-head__menu[data-disabled='true'] { opacity: .45; cursor: default; }
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
/* owner, topic beb4024f: a resized column - the width the reader dragged,
   exactly (min = max), its body cells clipped with an ellipsis; header
   controls shrink with it. Unset columns keep the automatic layout. */
.issues-table.issues-w-key [data-col="key"] { width: var(--iw-key); min-width: var(--iw-key); max-width: var(--iw-key); }
.issues-table.issues-w-title [data-col="title"] { width: var(--iw-title); min-width: var(--iw-title); max-width: var(--iw-title); }
.issues-table.issues-w-status [data-col="status"] { width: var(--iw-status); min-width: var(--iw-status); max-width: var(--iw-status); }
.issues-table.issues-w-priority [data-col="priority"] { width: var(--iw-priority); min-width: var(--iw-priority); max-width: var(--iw-priority); }
.issues-table.issues-w-level [data-col="level"] { width: var(--iw-level); min-width: var(--iw-level); max-width: var(--iw-level); }
.issues-table.issues-w-assignee [data-col="assignee"] { width: var(--iw-assignee); min-width: var(--iw-assignee); max-width: var(--iw-assignee); }
.issues-table.issues-w-label [data-col="label"] { width: var(--iw-label); min-width: var(--iw-label); max-width: var(--iw-label); }
.issues-table.issues-w-deadline [data-col="deadline"] { width: var(--iw-deadline); min-width: var(--iw-deadline); max-width: var(--iw-deadline); }
.issues-table.issues-w-updated [data-col="updated"] { width: var(--iw-updated); min-width: var(--iw-updated); max-width: var(--iw-updated); }
.issues-table[class*="issues-w-"] td[data-col] { overflow: hidden; text-overflow: ellipsis; }
.issues-table[class*="issues-w-"] .issues-frow th[data-col] select { max-width: 100%; }
.issues-col-grip {
  position: absolute;
  inset-block: 0;
  inset-inline-end: -4px;
  width: 8px;
  cursor: col-resize;
  z-index: 4;
  touch-action: none;
}
.issues-col-grip::after {
  content: '';
  position: absolute;
  inset-block: 4px;
  inset-inline-start: 3px;
  width: 2px;
  border-radius: var(--radius-pill);
  background: transparent;
}
.issues-col-grip:hover::after,
.issues-col-grip:focus-visible::after,
.issues-col-grip[data-dragging="true"]::after { background: var(--color-accent, currentColor); }
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
/* SPL-1027: the frame (the phone's aside, or UiDialog's body) scrolls; the
   content is one column, capped for reading in the wide modal */
.issues-detail {
  min-width: 0;
  min-height: 0;
  overflow: auto;
  background: var(--color-bg);
}
.issues-detail-in {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
  padding: 12px;
}
.issues-detail-in[data-modal="true"] { padding: 16px 20px 20px; max-width: 1040px; margin-inline: auto; box-sizing: border-box; width: 100%; }
/* CLE-77806 (owner, topic 260d2cbb): the modal is two columns above 820 px -
   description ~70% left, the property panel ~30% right. A phone (aside) keeps
   the single column, so this only shapes the modal. */
.issues-detail-in[data-modal="true"] .issues-detail-cols {
  display: grid;
  grid-template-columns: minmax(0, 1fr) clamp(240px, 30%, 320px);
  grid-template-areas: "main side" "subs side" "talk side";
  align-items: start;
  column-gap: 24px;
  row-gap: 12px;
}
.issues-detail-in[data-modal="true"] .issues-detail-main { grid-area: main; min-width: 0; }
.issues-detail-in[data-modal="true"] .issues-detail-subs { grid-area: subs; min-width: 0; }
.issues-detail-in[data-modal="true"] .issues-detail-talk { grid-area: talk; min-width: 0; }
.issues-detail-in[data-modal="true"] .issues-detail-side { grid-area: side; min-width: 0; border-inline-start: 1px solid var(--color-border); padding-inline-start: 20px; }
/* the phone stacks one column, in DOM order: description, panel, subtasks, discussion */
.issues-detail-cols { display: flex; flex-direction: column; gap: 12px; }
.issues-detail-main { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.issues-detail-desc { min-height: 6.5rem; }
.issues-detail-create { align-self: flex-start; }
/* the property panel: one property per row, label | control aligned in a grid.
   Every row uses the same track sizes, so the label edges and the control left
   edges line up down the panel (owner: "vertically aligned"). */
.issues-panel { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.issues-prow { display: grid; grid-template-columns: 5.5rem minmax(0, 1fr); align-items: center; column-gap: 10px; min-width: 0; }
.issues-prow__k { font-size: 0.75rem; color: var(--color-muted); overflow: hidden; text-overflow: ellipsis; }
.issues-pctl, .issues-pval {
  box-sizing: border-box;
  width: 100%;
  min-height: 34px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 5px 9px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
  text-align: start;
  min-width: 0;
}
button.issues-pctl { cursor: pointer; }
button.issues-pctl:hover, select.issues-pctl:hover { border-color: var(--color-border-strong); }
button.issues-pctl:focus-visible, select.issues-pctl:focus-visible { border-color: var(--color-accent); outline: none; }
.issues-pval { cursor: default; background: transparent; }
.issues-pctl__v { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
select.issues-pctl { appearance: auto; }
/* the status tooltip drops under the control, like the old chip's (was .issues-prop) */
.issues-pctl--status { position: relative; }
.issues-pctl .issues-status-tip { left: auto; right: 0; top: calc(100% + 4px); transform: none; }
.issues-pctl .issues-status-host { min-width: 0; overflow: hidden; }
.issues-pctl .issues-status-code { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
/* the deadline picker fills its row's control column; the text input shrinks so
   the calendar button always stays inside the panel */
.issues-prow .issues-deadline { width: 100%; flex-wrap: nowrap; }
.issues-prow .issues-deadline :deep(.dlp__text) { flex: 1 1 auto; min-width: 0; }
.issues-detail-meta { margin-top: 14px; padding-top: 10px; border-top: 1px solid var(--color-border); display: flex; flex-direction: column; gap: 2px; }
/* CLE-77806: the header actions button (⋯), in the dialog header on desktop and
   in the phone's top bar */
.issues-detail__menu {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 32px;
  min-height: 32px;
  padding: 0;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
}
.issues-detail__menu:hover, .issues-detail__menu:focus-visible { color: var(--color-fg); border-color: var(--color-border); outline: none; }
.issues-detail__hgap { flex: 1 1 auto; }
/* SPL-1027: the sheet's CRUD cells */
.issues-c-act { width: 1%; white-space: nowrap; text-align: center; }
.issues-cell-input {
  width: 100%;
  min-width: 10rem;
  box-sizing: border-box;
  padding: 3px 6px;
  border: 1px solid var(--color-accent);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-fg);
  font: inherit;
}
/* the pencil takes its own track: the cell grows by it, the title keeps its room */
.issues-title-cell--edit { grid-template-columns: minmax(0, 1fr) auto auto; gap: 4px; min-width: calc(10rem + 28px); }
.issues-title-edit, .issues-cellbtn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 4px;
  min-width: 24px;
  min-height: 24px;
  padding: 0 4px;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  font: inherit;
  cursor: pointer;
}
.issues-cellbtn--when { color: inherit; }
.issues-cellbtn--when .ui-icon { color: var(--color-muted); }
.issues-title-edit { opacity: 0; }
.issues-row:hover .issues-title-edit,
.issues-row[data-selected="true"] .issues-title-edit,
.issues-title-edit:focus-visible { opacity: 1; }
.issues-title-edit:hover, .issues-cellbtn:hover, .issues-title-edit:focus-visible, .issues-cellbtn:focus-visible { color: var(--color-fg); border-color: var(--color-border); }
.issues-row-delete { color: var(--color-muted); }
.issues-row-delete:hover, .issues-row-delete:focus-visible { color: var(--color-danger); }
/* the cell cursor is the focused cell: the one global focus ring marks it */
.issues-newrow { background: var(--color-selected); }
.issues-newrow__acts { display: inline-flex; gap: 2px; }
.issues-newrow__kind { cursor: pointer; }
.issues-del-title { font-weight: 600; }
.issues-detail-del { align-self: flex-start; }
.issues-menu.issues-menu--modal { z-index: calc(var(--z-modal) + 1); }
/* SPL-1028: the view switch (a segmented control) and the status groups */
.issues-views { display: inline-flex; border: 1px solid var(--color-border); border-radius: var(--radius-sm); overflow: hidden; }
.issues-views__opt {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 10px;
  border: 0;
  background: transparent;
  color: var(--color-muted);
  font: inherit;
  cursor: pointer;
}
.issues-views__opt + .issues-views__opt { border-inline-start: 1px solid var(--color-border); }
.issues-views__opt[aria-checked="true"] { background: var(--color-selected); color: var(--color-fg); }
.issues-group__h th { padding: 0; text-align: start; background: var(--color-bg-2); position: static; }
.issues-group__hin { display: flex; align-items: center; gap: 6px; padding: 4px 8px; min-width: 0; }
.issues-group__fold {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: 28px;
  padding: 0 6px;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: inherit;
  font: inherit;
  font-weight: 600;
  cursor: pointer;
}
.issues-group__n { color: var(--color-muted); font-weight: 400; font-variant-numeric: tabular-nums; }
.issues-group[data-drop="true"] { outline: 2px dashed var(--color-accent); outline-offset: -2px; }
.issues-row[draggable="true"] { cursor: grab; }
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
/* SPL-992 (epic SPL-988): phones and small tablets. The page is level 2 of
   M1's stack: a card list, Filters / Sort / epic chips on top, the + floating
   bottom right; an open issue is level 3, full screen; every picker is a
   bottom sheet. Targets are >= 44 px (--tap). Nothing here reaches > 820 px. */
@media (max-width: 820px) {
  .issues-head { min-height: var(--tap, 44px); }
  .issues-mback { flex: 0 0 auto; min-width: var(--tap, 44px); min-height: var(--tap, 44px); display: inline-flex; align-items: center; justify-content: center; }
  .issues-fab {
    position: fixed;
    inset-inline-end: 16px;
    /* SPL-1005: the composer dock is on every phone page now - stay above it */
    bottom: calc(16px + max(var(--composer-dock-h, 0px), env(safe-area-inset-bottom, 0px)));
    z-index: 15;
    width: 56px;
    height: 56px;
    box-shadow: 0 3px 5px rgba(0, 0, 0, 0.2), 0 6px 10px rgba(0, 0, 0, 0.14), 0 1px 18px rgba(0, 0, 0, 0.12);
  }
  .issues-mbar { flex: 0 0 auto; display: flex; gap: 8px; padding: 0 12px 8px; min-width: 0; }
  .issues-mbar__btn { min-height: var(--tap, 44px); display: inline-flex; align-items: center; gap: 6px; min-width: 0; }
  .issues-mbar__sort { flex: 1 1 auto; justify-content: flex-start; }
  .issues-mbar__sortlabel { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .issues-mbar__dot { width: 8px; height: 8px; border-radius: var(--radius-pill); background: var(--color-accent); }
  /* the strip scrolls inside itself; the page never scrolls sideways */
  /* flex: none - a scrolling row in the list's column would otherwise shrink
     under a long card list and the cards would cover the chips */
  .issues-chips {
    flex: 0 0 auto;
    display: flex;
    gap: 8px;
    padding: 0 12px 8px;
    min-width: 0;
    overflow-x: auto;
    overscroll-behavior-x: contain;
    scrollbar-width: none;
  }
  .issues-chip {
    flex: 0 0 auto;
    max-width: 14rem;
    min-height: var(--tap, 44px);
    padding: 0 14px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-pill);
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: 0.875rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    cursor: pointer;
  }
  .issues-sheet__st { display: flex; flex-wrap: wrap; gap: 8px; }
  .issues-chip[aria-pressed="true"], .issues-chip[aria-checked="true"] { background: var(--color-selected); border-color: var(--color-accent); }
  .issues-merror { padding: 0 12px 8px; }
  .issues-cards { list-style: none; margin: 0; padding: 0 0 88px; min-width: 0; }
  .issues-cards .issues-note { padding: 8px 12px; }
  .issues-card {
    display: flex;
    flex-direction: column;
    gap: 4px;
    width: 100%;
    min-width: 0;
    min-height: var(--tap, 44px);
    padding: 10px 12px;
    border: 0;
    border-bottom: 1px solid var(--color-border);
    background: transparent;
    color: inherit;
    font: inherit;
    text-align: start;
    cursor: pointer;
  }
  .issues-card[data-selected="true"] { background: var(--color-selected); box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring); }
  .issues-card__top, .issues-card__meta { display: flex; align-items: center; gap: 8px; min-width: 0; flex-wrap: wrap; font-size: 0.8125rem; }
  .issues-card__status { display: inline-flex; align-items: center; gap: 4px; font-size: 0.75rem; }
  .issues-card__due { margin-inline-start: auto; }
  .issues-card__title { font-weight: 600; overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .issues-card__who { display: inline-flex; align-items: center; gap: 4px; min-width: 0; max-width: 60%; overflow: hidden; white-space: nowrap; }
  .issues-card .issues-prio { padding: 0 4px; }
  /* level 3: the issue, full screen under the top bar */
  .issues-detail {
    position: fixed;
    inset-inline: 0;
    top: var(--top-bar-h, 0px);
    bottom: 0;
    width: 100%;
    max-width: 100%;
    z-index: 20;
    box-shadow: none;
    border-inline-start: 0;
    padding-bottom: calc(12px + env(safe-area-inset-bottom, 0px));
  }
  .issues-detail__h { justify-content: flex-start; }
  .issues-detail__title { min-height: var(--tap, 44px); }
  .issues-prop, .issues-pctl, .issues-pval, .issues-sub, .issues-sub-add { min-height: var(--tap, 44px); }
  .issues-detail__menu { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
  .issues-sub-add { min-width: var(--tap, 44px); }
  /* the sheets: filters, sort and every picker */
  .issues-scrim { position: fixed; inset: 0; z-index: 38; background: rgb(0 0 0 / .4); }
  .issues-sheet,
  .issues-menu.issues-sheet {
    position: fixed;
    inset-inline: 0;
    top: auto;
    bottom: 0;
    left: 0;
    z-index: 39;
    width: 100%;
    min-width: 0;
    max-width: 100%;
    max-height: 75vh;
    max-height: 75dvh;
    overflow: auto;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 8px 16px calc(16px + env(safe-area-inset-bottom, 0px));
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-bottom: 0;
    border-radius: var(--radius-md) var(--radius-md) 0 0;
    box-shadow: 0 -8px 24px rgb(0 0 0 / .3);
  }
  .issues-menu.issues-sheet { gap: 0; }
  .issues-sheet__h { display: flex; align-items: center; gap: 8px; }
  .issues-sheet__h h3 { flex: 1 1 auto; min-width: 0; margin: 0; font-size: 1rem; }
  .issues-sheet__x { min-width: var(--tap, 44px); min-height: var(--tap, 44px); display: inline-flex; align-items: center; justify-content: center; }
  .issues-sheet__f { display: flex; flex-direction: column; gap: 4px; min-width: 0; font-size: 0.8125rem; color: var(--color-muted); }
  .issues-sheet__f select {
    min-height: var(--tap, 44px);
    width: 100%;
    background: var(--color-bg-2);
    color: var(--color-fg);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    padding: 4px 8px;
    font: inherit;
    font-size: 1rem;
  }
  .issues-sheet__foot { display: flex; justify-content: flex-end; gap: 8px; }
  .issues-sheet__foot .btn { min-height: var(--tap, 44px); }
  .issues-sheet .issues-menu__opt { min-height: var(--tap, 44px); display: flex; align-items: center; gap: 8px; }
  .issues-sheet .issues-status-tip { display: inline; position: static; transform: none; border: 0; box-shadow: none; padding: 0; background: none; color: var(--color-muted); white-space: normal; }
  .issues-menu__add input, .issues-menu__add .btn { min-height: var(--tap, 44px); }
  .issues-talk textarea { font-size: 1rem; }
}
</style>
