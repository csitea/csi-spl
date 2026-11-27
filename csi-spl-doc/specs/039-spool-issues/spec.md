# Feature Specification: Issues, the Way Linear Keeps Them

**Feature ID**: `039-spool-issues` · **Milestone**: M3 · **Status**: Implemented (MVP; "Next" list open)
**Created**: 2026-09-26 · **Lane**: issues (CLE-34993 lead, GRK-3519 web UI)
**Authority**: this file for the behaviour and its rules;
`contracts/issues-v1.md` for the wire; `tasks.md` for what is built, with the
sha and the check for each item. Status vocabulary: `../README.md` §2.3.

Builds on `003` (the hub, the view door, the browser socket), `005` (the
3-pane WUI), `025` (tenant roles), `033` (message levels), rdb 0021
(fail-closed RLS) and 0028 (the read door).

## The owner's request, verbatim (2026-09-26, prd #spool-hub-devel, topic 9c19bfe9)

> after the event log we must create the issues section in the left most bar ,
> the issues those must be shown the way Linear shows the issues , keeping
> still this 3 vertical lines structurre though , but with the attributes and
> behavious on how linear does that

Refined the same morning (binding where it differs from the first request):

> each issue must have prio , deadline , level , titgle , description ( which
> will be shown only on the right side always ), the deadline must be a
> calendar control , which has also time , one opened in the right side , one
> shoud be able to sor t the issues by prio , level , filter them by each
> attribute , once the agents start working on somehting instead of writing a
> "task" type of msg , they should formulate the issues and start working on
> them ... aka discussions where things are communicated should go into the
> discussions toipics and msgs , but concrete work , which has been specsed and
> advancedments of it must go to the issues section . The issues section should
> be third actually after the channels and not after the event log . Whenever
> something is not clear how it should wor on the issues - it should work as in
> the Linear SAAS , becuase it is he best

**Rule of interpretation (owner):** when this spec is silent, behave like Linear.

## Layout (SPL-1027: 2 panes and a modal on desktop / tablet)

- **Rail**: an `Issues` tab, the THIRD tab, directly after Channels.
- **Middle pane**: the issue sheet (a table: column names, a filter row, one
  issue per row). A row shows the key, the title, the status, the priority,
  the level, the assignee, the labels, the deadline, when it was updated and
  a delete action. It never shows the description. Every cell but the key and
  Updated is edited in place (FR-010).
- **No right pane** (owner 2026-09-28, prd t1 topic 89485c7a: "the
  right-most panel could be removed"). Above 820 px an opened issue is a
  MODAL dialog (FR-011): title and description (markdown) edited in place,
  every attribute as a picker, the deadline as a calendar control with time,
  the subtasks, then the issue's discussion with its composer.
- **Phones (<= 820 px, SPL-992)**: unchanged. The sheet is a card list (level
  2) and an opened issue is the full-screen level 3, which is what a modal is
  on a phone.
- **The opened issue's hierarchy (issues-06, SPL-3072)**: the title is the
  pane's heading (1.25rem, no box until hovered or focused), then the
  description, then the property panel (beside them above 820 px, below them
  on a phone). The panel is a grid: one label column width for every row
  (`--issues-meta-k`), 12 px between rows, every value on one edge; the
  created / updated lines sit under it on that value edge. Tests:
  `tests/unit/issue-detail-layout.test.mjs`, and
  `tests/e2e/issue-detail-layout.test.mjs` at 412x915 and 1280x800, light
  and dark.

## Attributes (FR-001)

| attribute | values | notes |
|---|---|---|
| key | `<prefix>-<number>`, e.g. `SPL-12` | one team per tenant for now, prefix `SPL`; numbers from a per-tenant counter, never reused |
| title | 1..255 characters | required |
| description | markdown, <= 20000 characters | the issue dialog only (was the right pane) |
| status | 01-eval, 02-todo, 03-wip, 03-diss, 05-blocked, 06-onhold, 07-qas, 09-done (ids `eval todo wip diss blocked onhold qas done`; a hover gives the long name) | the owner's set, 2026-09-26 (rdb 0055, 0061 SPL-966; old names normalize); default eval |
| prio | the number 1..5 | the owner's scale, 2026-09-26 (rdb 0054 + 0055); old 0 became 5. A new issue's prio when its create names none: [lane issue and docs](../../doc/md/lane-issue-and-docs.md) section 1.1b (SPL-4725) |
| level | 1 epic / feature, 2 issue, 3 subtask | the row's place in the tree, derived by the hub (owner 2026-09-26, SPL-949, rdb 0056); was a 0..5 t-shirt estimate |
| assignee | a member `HUM-*` or a roster agent, or nobody | an id nobody in the tenant can act on is refused |
| labels | the tenant's label catalogue (name + colour), <= 20 per issue | |
| deadline | date AND time; stored UTC, shown in local time | a calendar + time control |
| parent | another issue of the tenant | sub-issues; no cycles. UI next |
| created by / at, updated by / at | | stamped by the hub |
| completed at / canceled at | | set when the status enters done / diss, cleared when it leaves |
| discussion | an ordinary spool topic on the issue's `task_id` under the reserved channel id `issues` (§Discussion space) | comments are reply-level messages (033 level 2), so edit, emoji, files and agents work unchanged, and they never become cards in any feed. In the open issue the comment box sits right under the comments with a visible "Comment" label, above the linked discussions (SPL-5710) |

## Behaviour

- **FR-002** List grouped by status in workflow order, with counts per group.
- **FR-003** Sort by priority (default; urgent first, no priority last), level
  (largest first), deadline (soonest first, none last), updated, created
  (newest first). Ties: the newest number first.
- **FR-004** Filter by EVERY attribute: status, priority, level, assignee
  (incl. `me` and `none`), label, deadline range. The hub answers the same
  filters (`GET /v1/view/issues?...`) so an agent gets what a person sees.
- **FR-005** Keyboard (list focused), Linear's keys: `C` create, `J`/`K`
  move, `Enter` open, `S` status, `P` priority, `L` label, `A` assign, `Esc`
  back. The same pickers inline on the row and in the issue dialog. In the
  sheet (SPL-1027) the arrows move a cell cursor: Up / Down between rows,
  Left / Right between cells; `Enter` edits the cell (opens the issue on the
  key cell), `Esc` cancels an edit, `Tab` moves on to the next control.
  The three parent pickers (Parent and the two level moves, SPL-4610) open a
  focused search box above the list: typing filters by key and title in any
  case, non-ASCII too; Up / Down, `Enter` and `Esc` work; "No epic" is the
  first row and can be typed; no match shows a line. The desktop menu and the
  phone sheet alike; the other pickers stay plain lists.
- **FR-006** Every change reaches every open tab of the tenant as a live
  `issue` / `issue_label` frame: no reload. A reload shows the same state.
- **FR-007** Access: every member reads (`topics.read`); a member writes with
  `notes.send` (every role, like Linear's "anyone on the team files an issue").
  A non-member reads nothing (403 at the tenant door, as every view); an
  issue number of another tenant reads 404.
- **FR-007a** A comment is edited like any message (SPL-6480; HUM-24
  csitea 5c9dcfe7; owner HUM-10 csitea c707c7a5: "everyone who has write
  access to the Issues must be able to change their own comments too. But
  there must be a mark that the comment was changed"; t1 66f4500c: the edit
  shows in History). Its author edits it (`PATCH /v1/messages/{id}`: author
  only, `notes.send`; a reader and another author get 403), from the card
  menu, a double-click or `e`; delete follows the message rule. The card
  shows the message's "(edited)" mark. Each saved edit is one History row,
  `comment_edited`: who and when, no old text (read from
  `message_revisions`, no table of its own). The card menu of a comment opens
  OVER the issue modal (`useInModal`: UiDialog provides it, MessageMenu lifts
  its panel); before this it opened under the dialog, in the DOM but not
  clickable, which was the reported "inactive menu".
- **FR-008** Agents do concrete, specced work as issues (owner): a seated
  agent creates and updates issues and posts its progress as a comment on the
  issue, over its own box socket, as itself (the agent must be one its box
  announced). Talk stays in topics and messages. Front ends: `spool issue`,
  the MCP tool, `do_spl_issue_*` desk actions.
- **FR-009** Delete (SPL-1027, revises "no delete"): a row action, confirmed
  with the one destructive confirm (UiConfirm, SPL-1001). The hub soft
  deletes (rdb 0071 `deleted_at` / `deleted_by`; the number stays taken, the
  discussion stays, the way back is one UPDATE) and from then on treats the
  issue as absent (404, never listed, never a parent). Who may: the member
  who created it, or a role with `tenant.settings` (admin, owner); anyone
  else gets 403 `forbidden`. An issue with live children is refused, 409
  `issue_has_children` (delete or move them first). Canceled stays the
  workflow's terminal status.
- **FR-010** The sheet is fully CRUD, inline (owner 2026-09-28, topic
  89485c7a: "the grid should be fully CRUD"). CREATE: the round + (or `C`)
  puts a new row at the top of the sheet with its title typed in place;
  `Enter` stores it (status, priority, assignee, labels, deadline, epic and
  kind are set on that row before or after), `Esc` drops it. READ: the
  columns, the header sort and the filter row. UPDATE: every cell in place -
  the title (`Enter` or a double click; `Enter` / leaving saves, `Esc`
  cancels), status, priority and level select boxes (SPL-972), assignee,
  labels (an empty cell still opens the picker) and the deadline picker.
  DELETE: FR-009. The hub decides every write; a refusal is shown and the
  cell shows the stored value.
- **FR-011** Above 820 px opening an issue (a row click, `Enter`, a deep
  link `?issue=SPL-n`) opens it in a modal dialog (UiDialog, large): `Esc`,
  the X and a backdrop click close it, focus is trapped inside and returns to
  the row. The URL carries `?issue=SPL-n` while it is open (Back closes it,
  a deep link opens it). In the dialog `S` / `P` / `A` / `L` open the pickers
  and `E` edits the description; `Esc` with a picker open closes the picker
  only.

- **FR-012** Views (SPL-1028, owner 2026-09-28 topic 89485c7a: "the
  Linear-style grouping of issues in views, i.e. the default is a list, but
  there could be a view by status as well"). Above 820 px a switch in the
  sheet's toolbar: **List** (the default, FR-010) | **By status**: one group
  per status in the workflow order (01-eval .. 09-done, 05-blocked and
  06-onhold included), each with its count and a + that files a new row
  straight into it, the same CRUD rows and header sort inside. Every group is
  shown, the empty ones too (a drop target). A group folds (per browser). A
  row dragged onto another group takes that status (the Status cell does the
  same). The chosen view is the person's: `humans.issues_view` (rdb 0072,
  list | status, NULL = list), the `issues_view` session claim and `PUT
  /api/v1/auth/preferences`, like the rdb 0070 layout keys. The column-header
  sort stays; the removed Sort / Group-by dropdowns (topic e65c0f60) do not
  come back. Phones keep the card list.
- **Links in a description** (SPL-2425, owner HUM-10 t1 cb8a9c73: "the
  links to the spec must be clickable"): an issue key (`SPL-n`) opens the
  issue, a repo doc path the doc (SPL-1592), and a spec folder written as
  text, `Spec: csi-spl-doc/specs/<NNN-slug>`, opens its `spec.md` on
  `/docs` when the docs store lists it (`utils/doc-paths.mjs`); else text.

- **FR-013** The list's full state is in its URL (SPL-4648, owner HUM-10, t1
  e04820a5: "the full state of the issues listing should be setable from the
  URL of it", "point to a certain set of issues by simply copy asting the
  url"). `utils/issues-list-url.ts` reads and writes it,
  `composables/useIssueListUrl.ts` keeps the page and the address together;
  a change uses `router.replace`, so Back and Forward walk the entries the
  page already had.

  | parameter | values | what it sets |
  |---|---|---|
  | `view` | `list`, `status` | List or By status (a phone keeps its card list) |
  | `sort`, `dir` | a sheet column; `asc`, `desc` | the sheet's sort |
  | `unread` | `1` | Unread (the viewer's own unread issues) |
  | `status` | a status | the Status filter |
  | `priority` | `1`..`5` | the Priority filter |
  | `level` | `1`..`3` | the Level filter |
  | `assignee` | a person id, `me`, `none` | the Assignee filter |
  | `label` | a label id | the Label filter |
  | `deadline` | `YYYY-MM-DDTHH:MM`, the reader's local time | due on or before that minute |
  | `epic` | an epic key | the epic the list is narrowed to |
  | `fold` | statuses, comma separated | the folded status groups |
  | `issue` | an issue key | the open issue (FR-011) |

  - A URL with `view` is complete: what it does not name is off, and the
    reader's stored sort and folds do not apply. A URL without it (an older
    link, the Issues tab) takes the stored choices, and the address is then
    completed with them, so what is copied always names the whole list.
  - A parameter beats a stored choice and does not change it; picking a view
    still saves it as the person's own.
  - The "me" filter is written as the viewer's id, so a pasted link names the
    same person for its reader. `unread` stays the reader's own.
  - A value that cannot be used (a bad value, a label, epic or person this
    workspace does not hold) is ignored with no error and leaves the address.
  - A pick that also closes its phone sheet lands too: the sheet's Back
    cancels the replace, which is sent once more when the route has landed.
  - No replace starts while a move to another page is on its way: it would
    cancel that move. If the move is refused, the address then catches up,
    also when the move cancelled a replace already sent or a phone sheet closed
    on the way.
  - Clear filters clears the sort and the filters; `view`, `epic` and `fold`
    are not filters and stay.
  - Left out, on purpose: column widths (personal layout, stored per person),
    how many pages Load more has read, the row selection, the keyboard cursor
    and an open sheet or picker (they do not decide which rows the list holds).

### Selection: the select phase (SPL-6646)

The list's ticks (owner HUM-10, t1 53ab04e7, msg 14b0e604: "the issues
listing should have checkboxes to perform multiple actions the same way as
in gmail") behave as the topics' select phase, spec 186 section 4.1 step 1
(owner HUM-10, t1 11d7836d, 2026-11-26, msgs 926d0a46 and 2e9c4cdf: "make
the selection for the issues work and behave as the selections for the
topics", "they should not be shown be default").

- **Off by default.** The list shows no box: no row box, no page box. On a
  desktop a row's box shows on hover and on focus, as a topic card's does;
  a phone card shows none.
- **Entering.** The header's select tick (a phone: the bar above the cards)
  ticks exactly the issues listed, all of them with no filter, the filtered
  ones under a filter. A row menu's Select (right after Edit), a hovered
  row's box and `x` on the focused row tick one row.
- **In the phase** (one row or more checked): every row and card shows its
  box, the bulk bar takes the header's place with the page box, Gmail's
  "Select all N matching" and the bulk actions; shift-click checks a run;
  `x` toggles the focused row; a phone tap on a card toggles it and does
  not open the issue.
- **Leaving.** Esc, Clear, unchecking the last row, a finished delete or
  archive of every checked row, or another filter (unlike topics, a filter
  change clears: the issues are one list) end the phase, and the boxes hide
  again. The list's keys (C, J/K, S, P, A, L) are unchanged.
- Code: `pages/issues.vue`, `composables/useIssueBulk.ts`; the tick rules
  are the shared `utils/issues-bulk.ts`. Tests: `tests/e2e/issues.test.mjs`
  (17a..18d), `tests/e2e/issues-frow-density.test.mjs` (5).

## Epic panel: order, sort, filter (FR-014, SPL-6455)

Owner HUM-10, t1 topic 7132e969, 2026-11-24:

> one should be able to order the order of the EPICS in the issues section by
> drag and dropping , which will be their priority (msg 5c3eccd3)

> there should be sorter and filterred on the top of the left list where the
> epic issues are -sort alphabetically , by prio , by time modified , by time
> created (msg c92589ce)

> there should be also filter of the issues based on the silar type of fitler
> as in the issues view on the right (msg 45a3831a)

Status: specified, not built (build rows T017, `tasks.md`).

### FR-014.0 What is there today

Measured on origin/master `2924c633f`:

| what | where | command -> answer |
|---|---|---|
| the panel: one link row per level-1 row, no sort, no filter, no drag | `csi-spl-wui/src/components/IssueEpicsPanel.vue` | `wc -l` -> 97 |
| its order: open before done / canceled, then by number | `csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go` | `grep -n "func epicSummaries"` -> 836; `grep -n "sort.SliceStable(out"` -> 865 |
| the summary row: key, kind, number, title, status, total, done, canceled, counts; no priority, no times | same file, `type epicSummary` | `grep -n "type epicSummary struct"` -> 822 |
| archived and deleted rows are never in it | `csi-spl-api/src/go/spool-hub-api/internal/store/issues_postgres.go` | `grep -n "archived_at IS NULL"` -> 416 |
| a frame re-reads the summary, 400 ms debounced | `csi-spl-wui/src/pages/issues.vue` | `grep -n "function refreshEpics"` -> 1610 |
| the phone's epic chip strip reads the same summary | same file | `grep -n 'data-test="issues-epic-chips"'` -> 111 |
| the sheet's filter row and the phone filter sheet | same file | `grep -n 'class="issues-frow"'` -> 180; `grep -n 'data-test="issues-filter-sheet"'` -> 616 |
| the filter state | `csi-spl-wui/src/composables/useIssueFilters.ts` | `grep -n "export function useIssueFilters"` -> 204 |
| the client-side match on every attribute | `csi-spl-wui/src/utils/issues.mjs` | `grep -n "export function matchIssue"` -> 176 |
| a pointer drag with before / after places, a hold that opens the row menu first | `csi-spl-wui/src/utils/tree-drag.ts` | `grep -n "export type TreeDropPlace"` -> 23 |
| the per-person default sort of the sheet (membership settings, rdb 0078) | `csi-spl-api/src/go/spool-hub-api/internal/auth/issues_sort.go` | `grep -n "^var IssuesSortColumns"` -> 21 |
| an own priority change is stamped (rdb 0273) | `csi-spl-api/src/go/spool-hub-api/internal/store/issues.go` | `grep -n "if p.PriorityOwn && old.Priority"` -> 807 |
| the precedent for a dragged order: a rank inside a priority, the drop takes the neighbour's priority | `csi-spl-doc/specs/153-monitoring-lanes-tab/spec.md` 3.22.7, rdb 0323 | `grep -n "3.22.7 Drag"` -> 1846 |

### FR-014.1 The manual order is the epics' priority

The panel has ONE shared order per workspace, the **manual order**, and it is
the level-1 rows' priority read top-down.

**D1, what is stored.** The existing `priority` (1..5, FR-001) stays the
priority, and a new rank orders the rows inside one priority:
`issues.epic_rank` (bigint, NULL = never placed), `epic_rank_by`,
`epic_rank_at`. The manual order is:

1. open rows, then closed rows (done, diss), as today;
2. priority, 1 first;
3. ranked rows first, lower rank first;
4. then by number, lower first (today's tie-break).

On deploy no row is ranked yet, so open epics of different priorities move
into priority order (today the hub ignores priority, `hub/issues.go:865`);
within one priority today's by-number order stays.

Why both, and how they relate: the owner said the dragged order "will be their
priority". A rank alone would leave two orders that can disagree (the panel
says A above B, the priority column says B is 1 and A is 3), and every other
place that reads priority (the sheet's sort, the filters, the agents' issue
reads) would not see the drag. Mapping the position onto 1..5 alone cannot hold
a 12-epic order in five numbers. So a drop does both, the way the fleet queue
already does (spec 153 3.22.7, owner-accepted):

- **the moved row takes the priority of the row it now sits directly above**
  (of the row above it, when it lands last). A drop across a priority line is
  therefore what it looks like, and read top-down the priorities never go
  back up. The write is the row's own priority change (`PriorityOwn`, stamps
  `priority_set_at`, writes an issue history line), so it beats an older
  discussion priority (spec 150 3.4 item 4) and shows wherever priority shows.
  After the transaction commits, the move calls `spreadIssuePriority`
  exactly as the PATCH path does (`hub/issues.go:468-470`,
  `hub/topic_priority_spread.go`): the epic's discussions and their issues
  follow it, the same as for a priority picked in the sheet. The move writes
  the priority and the rank in one UPDATE, so its own priority write does not
  clear the rank it sets (D4);
- it gets a rank between its two neighbours. Every unranked open row of that
  priority above it gets a rank in its current order (a rank cannot sit below
  an unranked row); those rows get no `epic_rank_by` and no history line,
  because nothing visible about them changed;
- a drop between two rows of the same priority changes only the rank: no
  priority write, no history line;
- ranks use gaps of 1024; when a gap runs out, that priority's ranks are
  renumbered in the same transaction.

**D2, per workspace, not per user.** The rank is a column of the issue row,
under the tenant's RLS like every issue column. Why: priority is the
workspace's, so an order that IS the priority cannot be one person's. A person
who wants another view picks a sort (FR-014.2), which is theirs.

**D3, a new epic.** No rank: it lands after the ranked rows of its priority,
by number (rule 4), so the newest epic of a priority is its last. Why: an
epic nobody placed yet must not jump above ones somebody did place.

**D4, a priority change by any other path** (the picker, the sheet cell, an
agent's update, a newer discussion priority) clears the row's rank: a new
decision, the row joins its new priority by rule 4. Stored as: an update that
changes the priority sets `epic_rank = NULL` in the same UPDATE (store
`UpdateIssue`). A discussion priority reaches an issue only through that
same write (`applyIssuePriority` -> `UpdateIssue`,
`hub/topic_priority_follow.go:280-286`), so it clears the rank the same way.
Nothing is overlaid at read time: unlike `fleet_asks` (spec 153), the issue
list never reads `topic_priorities`. Other rows keep theirs.

**D5, open and closed rows.** Only open rows (every status but done and diss)
are dragged, and only among open rows; closed rows stay under them, dimmed, as
today. A closed row keeps its rank, so reopening it puts it back where it was
(its priority unchanged). A drop below the last open row lands as the last open
row. Why: the panel is a work list; a finished epic has no priority to set.

**D6, a level change or a delete.** A row that stops being level 1 (kind
`issue`) loses its rank in the same UPDATE. An archived or deleted row keeps
its columns; it is not in the summary, and the gaps it leaves are harmless.

**D7, who may reorder.** Any member who may change an issue's priority, in
the browser: the route uses the PATCH path's own gate, `issueWriter`
(`hub/issues.go:951`: `notes.send` (FR-007), `topics.manage` (spec 077 G3),
and a paid workspace). An agent has no position door in this
version: it changes an epic's priority with the existing update, which clears
the rank (D4). Why: a drag is a person's act on a list they see; an agent
cannot see the neighbours the position names.

**D8, not only a mouse** (HTML drag does not fire on a phone and has no
keyboard):

- **Mouse**: a row lifts after 5 px of travel (`TREE_DRAG_START_PX`), a
  line between rows shows where it drops, `Esc` cancels.
- **Touch and pen** (`tree-drag.ts:139` treats a pen as touch): the hold
  already opens the row menu (SPL-1226, long-press);
  a finger that then moves lifts the row instead (`tree-drag.ts`'s rule), so
  the menu still opens without a drag. A finger that moves before the hold
  scrolls the list.
- **Keyboard**: on a focused row, `Alt+ArrowUp` / `Alt+ArrowDown` move it one
  place. An `aria-live` line says "SPL-17 moved to place 3 of 12".
- **Row menu** (right-click, long-press): Move up, Move down, Move to top.
  All of them are the same position call.

The drop is shown at once; a refusal puts the row back and shows the hub's
reason under the panel heading (the FR-010 rule: the hub decides every write).

### FR-014.2 The sorter

A toolbar under the panel's heading holds the sort and the filter.

| sort | order | default direction |
|---|---|---|
| Manual (the default) | FR-014.1 | fixed |
| Name | the title, `Intl.Collator` of the UI locale, numeric | A to Z |
| Priority | priority, then the manual order inside it | 1 first |
| Updated | the row's own `updated_at` | newest first |
| Created | the row's own `created_at` | newest first |

- A direction button flips every sort but Manual.
- In every sort, closed rows stay under the open ones. Why: the panel is a
  work list (D5).
- Updated and Created are the epic row's own stamps, the same values the
  sheet's Updated column shows; a change to a child issue does not count. Why:
  one meaning of "modified" everywhere.
- Priority ascending lists the same open rows as Manual; it is kept because
  the owner named it, and descending (5 first) differs.
- **The choice is remembered per person per workspace**: membership setting
  `issues_epics_sort` `{col: manual|title|priority|updated|created, dir:
  asc|desc}` (rdb 0078 column, no migration), written with `PUT
  /api/v1/auth/preferences` and read from the session claim, like
  `issues_sort`. Null or never picked = Manual. Why: a sort is a way to look,
  not the workspace's order.
- Not in the URL: FR-013's URL names the rows the list holds, and the panel's
  sort does not change them.

### FR-014.3 The filter

A filter button beside the sort opens the same fields the sheet filters by
(FR-004), applied to the level-1 rows themselves:

| field | values | note |
|---|---|---|
| text | part of the key or the title, any case, non-ASCII too | the parent pickers' match (FR-005); the panel has no column header to sort or find by |
| kind | epic, feature, both | replaces Level: every row here is level 1 |
| status | any status, plus Open (not done / diss) and Closed | the owner's "open / done" need without a new control |
| priority | 1..5 | |
| assignee | `me`, `none`, a person | |
| label | a label of the workspace | |
| deadline | due on or before a minute (`YYYY-MM-DDTHH:MM`, local time) | the sheet's deadline picker, default time 23:59 (FR-013 `deadline`) |

- **One filter code**: the rows are matched with `matchIssue`
  (`utils/issues.mjs`) on the summary rows, which therefore carry the epic's
  own priority, assignee, labels and deadline (FR-014.5). The text field
  is matched outside `matchIssue`, with the parent pickers' match (FR-005). The status,
  priority, assignee, label and deadline controls move out of the sheet's
  filter row into one component per field, used by the sheet's filter row,
  the phone filter sheet and this panel. No second filter is written. Why:
  the owner asked for "the silar type of fitler as in the issues view".
- The filter does not change the issue list on the right; picking an epic
  still does (`?epic=`).
- An active filter shows a dot on its button and a line "4 of 12 epics";
  Clear resets it.
- **Not remembered**: kept for the browser tab, never stored, not in the URL.
  Why: a stored filter would hide epics on the next visit with nothing on
  screen saying why.

### FR-014.4 Drag only in the manual order, unfiltered

Dragging (and Move up / down / to top, and `Alt+Arrow`) works only while the
sort is Manual and no filter hides a row. Otherwise rows show no drag
affordance, a press does not lift, and the Move items are disabled with the
hint "Switch to Manual order and clear the filter to reorder". Why: in another
sort the place a row is dropped is not a place in the manual order; under a
filter the neighbours on screen are not the stored neighbours, so the call
would be refused as stale.

### FR-014.5 Contracts

**Store (rdb, next free number at build, `do_rdb_migration_next`).**
`ALTER TABLE issues ADD COLUMN IF NOT EXISTS epic_rank bigint CHECK (epic_rank > 0)`,
`epic_rank_by text`, `epic_rank_at timestamptz`. Nullable, no backfill, no
rewrite; `SET LOCAL lock_timeout = '5s'` like rdb 0323. The running image
ignores the columns, so the file rolls before the hub that writes them. RLS:
the table's existing policies cover new columns. Both drivers (memory and
Postgres) implement `SetEpicPosition`.

**Hub, the summary.** `epics[]` of `GET /v1/view/issues` (issues-v1 §8) is
listed in the manual order (FR-014.1) and each row gains:

```json
{"priority": 2, "rank": 3072, "assignee": "HUM-10", "labels": ["lbl-1"],
 "deadline": "2026-12-01T09:00:00Z",
 "created_at": "2026-10-02T08:11:00Z", "updated_at": "2026-11-24T16:20:21Z"}
```

`rank` is null when unranked. Unset values have the issue JSON's shapes
(`toIssueJSON`, `hub/issues.go:140-145`): `assignee` `""`, `labels` `[]`
(never null), `deadline` `""`; `matchIssue` relies on them
(`issue.labels.some`, `assignee === ''` for `none`). The WUI sorts
and filters client-side: the summary is every level-1 row of the workspace,
tens of rows, already sent whole.

**Hub, the move.** `PUT /v1/issues/{ref}/position`, browser session, body
`{"before": "<key>"|null, "after": "<key>"|null}`: the row's two neighbours as
the page saw them (`before` = the row now above it). In one transaction, with
the workspace's open level-1 rows locked (`FOR UPDATE`):

| case | answer |
|---|---|
| done | 200 `{"issue": <issue JSON>, "epics": [<summary>]}`; an `issue` frame for every row whose priority or rank changed |
| `{ref}` not level 1 | 400 `not_epic` |
| both neighbours null, or one is `{ref}` | 400 `bad_position` |
| `{ref}` or a neighbour closed | 409 `epic_closed` |
| a neighbour no longer adjacent, or gone | 409 `stale_position`; nothing changes, the page re-reads and says so |
| refused by `issueWriter` (D7) | 403 `forbidden`; 402 on an unpaid workspace, as PATCH |
| `{ref}` of another tenant | 404 `not_found` |

The PATCH path (FR-010) clears `epic_rank` when it changes the priority or the
kind (D4, D6).

**Hub, CORS.** This is the first `PUT` under `/v1/issues`: `OPTIONS
/v1/issues/{ref}/position` is registered beside the other write paths
(`hub/issues.go:893-900`), and `issuesPreflight` (`hub/issues.go:1246`)
allows `POST, PATCH, PUT, DELETE` (issues-v1 §1, its OPTIONS row, says the
same). Without it a browser on another origin cannot send the move.

**Hub, the preference.** `issues_epics_sort` joins `MembershipSettings` and
the preferences body, its shape checked like `parseIssuesSort` (an unknown
column or direction: 400 `unsupported_issues_epics_sort`).

**WUI.** `IssueEpicsPanel.vue` gains the toolbar (sort select, direction
button, filter button with its popover) and the drag through `tree-drag.ts`
with only the `before` / `after` places. The panel's displayed list (sort,
then filter) and the sort and filter state live in one shared composable,
`useEpicPanelList` (`useState`), imported only by `IssueEpicsPanel.vue` and
`pages/issues.vue`: on a phone at level 2 the lazy panel may not be mounted,
and the chip strip still reads the same list.

**WUI, first-paint budget.** The initial JS stays at or under the
`ci_initial_gzip_kb` ceiling, 155.0 KB
(`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`; last
metric there 151.9 KB, about 3 KB of room). `IssueEpicsPanel.vue` is lazy
(`<LazyIssueEpicsPanel v-if="tab === 'issues'" />`,
`components/ChannelSidebar.vue:508`), so everything new stays behind it or
behind the Issues page: `useEpicPanelList`, the T017e filter components,
`utils/issues.mjs` and `tree-drag.ts` are never imported by
`ChannelSidebar.vue`, a layout or any other module of the entry chunk. The
eager side gains only the `issues_epics_sort` key in the session's settings
type and the preferences call (a few hundred bytes); the check is
`csi-spl-wui/src/node/test/bundle-size.mjs` on a mock generate.

**Phone (<= 820 px, SPL-992).** The panel is level 1, full width; the toolbar
is two 44 px icon buttons (sort, filter) that open bottom sheets like the
issue list's. Rows drag by hold-then-move (D8); the row menu has the Move
items. The epic chip strip (`pages/issues.vue`) shows the panel's sorted and
filtered list, "All" first; chips do not drag (a horizontal strip of chips is
no place to set an order): reorder in the panel.

**Help.** `csi-spl-doc/doc/help/issues.md`, its Epics line: the order is the
priority, how to drag, sort and filter. It is the export of a qto doc: the
change is made there and exported (T017h).


## MVP now / next

- **Now**: FR-001..FR-013.
- **Specified, not built**: FR-014, the epic panel's order, sort and filter
  (build rows T017).
- **Next**: sub-issue UI, several teams / prefixes per tenant, cycles and
  projects, bulk select (`X`), an undelete in the UI, archive, an activity history per issue,
  `is:issue` in the omnibox (with the search lane, CLE-34992).

## Discussion space (SPL-68)

Owner, 2026-09-26: "the tasks channel should be removed - issues should be
used for it".

Until hub 0.7.2 an issue's discussion was a topic in `#tasks`, a default
channel. `#tasks` is gone; the discussion is stored under the reserved
channel id `issues` (`store.ChannelIssues`), which is NOT a channel:

| rule | how |
|---|---|
| never listed | no `channels` row; `GET /v1/view/channels` drops it; no sidebar, picker or channel page shows it |
| never created | `CreateChannel` refuses it (`ChannelReserved`), and rdb 0050 adds `CHECK (channel_id NOT IN ('issues', 'tasks'))`, like `general` |
| readable | by every member of the tenant, exactly as the issue list is (topics.read): the read doors treat it as public (`store.PublicChannels`), so who may read the issue may read its thread |
| writable | a browser `send` with the issue's `task_id` and `channel` `issues` (the hub knows the id without a row); an agent comments through the `issue` frame, never by posting a box envelope into it (no agent is a member) |
| out of lists | `TopicQuery.NoIssues` still hides the topic from every list (§7 of issues-v1) |

The retired id `tasks` stays public, hidden and reserved in the hub so a hub
could roll before the data moved. rdb `0050_issue_channel_replaces_tasks.sql`
then moved every issue topic's messages (task or parent task = an issue's
`task_id`) to `issues`, moved every other `#tasks` message to `#lobby` (all of
them were live-proof artefacts, measured per env before writing it), dropped
`tasks` from the tenant seed trigger and deleted every tenant's `#tasks` row.

Live proof, 2026-09-26 (hub 0.7.2 d33f8a0d, WUI d33f8a0d, rdb 0050 applied
dev 09:28Z / prd 09:30Z; n = 1 per env):

| check | dev t1 | prd e2e |
|---|---|---|
| `tasks-gone-live.proof.mjs`: hub channel list and sidebar show neither `tasks` nor `issues` | PASS | PASS |
| an issue commented BEFORE the move shows every comment (dev SPL-7, 2; prd SPL-2, 1) | PASS | PASS |
| a new comment from the right pane is signed into `issues` | PASS | PASS |
| stored `messages.channel` of those comments (do_spl_db_query by msg_id) | `issues` x3 | `issues` x2 |
| `issues-live.proof.mjs` (create in the UI, edit, live second tab, comment, reload, deep link) | 12/12 (SPL-11) | 12/12 (SPL-6) |
| a new tenant is seeded lobby, alerts, feedback only (`do_spl_tenant_create`, throwaway `spl68-093728`) | PASS | - |
| `tasks` rows left in `channels` / `messages`, any tenant | 0 / 0 | 0 / 0 |

prd t1 is the owner's tenant and gets no scripted sign-in; its data checks are
the SQL rows above (0 `tasks`, 22 messages under `issues`). A signed envelope
keeps the channel it was signed with, so a comment from before the move still
reads `tasks` in the topic read's `env`; the stored channel, which the read
door uses, is `issues`, and the WUI treats both as the issue channel.

## Data

rdb `0047_issues.sql`: `issue_counters`, `issue_labels`, `issues`; RLS in the
0021 fail-closed form plus the operator policy on all three. Applied to dev
and prd with `do_spl_db_bootstrap` before any hub that reads them rolled.

Every issue links to one or more discussions (rdb 0194); one with no other
links its workspace's "Issue backlog" topic, t1 included since rdb 0310
(SPL-6212): [issues-v1](contracts/issues-v1.md) section 2.2.

## Changing a workspace's prefix (SPL-3570)

A key shows the workspace's CURRENT prefix (`issue_counters.prefix`), so a
prefix change (csitea `SPL` -> `CSI`, owner HUM-10, csitea topic 26a21b5a)
renames every key in the Issues view at once. The text written before it,
messages, issue titles and descriptions, workspace docs, still says
`SPL-n`, and t1 uses `SPL` for its own numbers: csitea's old `SPL-44` and
t1's `SPL-44` are different issues. A blind replace would break every t1
reference.

`cd csi-spl-orc && ENV=prd TENANT_ID=csitea ./run -a do_spl_issue_ref_scan`
reads all of it (one READ ONLY transaction, the env's service account) and
sorts each old key into one of three classes, rules in
`csi-spl-orc/src/bash/scripts/issue-ref-scan.py`:

| class | when | reasons |
|---|---|---|
| rewrite | the key is the workspace's own | `link` (an issues link on its own host, or its markdown label, n within the workspace's counter), `named` (the line names the workspace), `plain` (a live number, and no key above the workspace's range in that text) |
| keep | not the workspace's | `other-link` (an issues link on another host), `foreign-link` (an issues link on its own host, n above the counter: rewritten it would be a dead link, SPL-5073; every one is listed), `not-ours` (n above the workspace's counter) |
| ambiguous | listed apart, never rewritten | `mixed` (the text also holds a t1-range key), `names-other` (t1, the spool-hub project, "on dev"), `commit` (a commit scope or `Closes:` trailer), `deleted` |
| archived | a would-be rewrite key in the title or description of an archived or deleted issue: listed apart, never in the plan | the hub's update path finds only live issues and answers `not_found` (csitea CSI-20, SPL-3821) |

It prints the counts per source, samples per class and every ambiguous, archived and foreign-link hit,
and writes a plan (ids and offsets, no text) for a writer. It writes nothing:
the owner OKs the scan before anything is changed, and the change then goes
through the hub's own edit paths (a message edit keeps its revision), never
raw SQL. Test: `csi-spl-orc/src/bash/tests/spl-issue-ref-scan.tst.sh`.

### The writer (SPL-3821)

After the owner's OK (csitea topic 26a21b5a, msg 642a2179: rewrite the
plan, leave the ambiguous ones),
`ENV=prd TENANT_ID=csitea SCAN_PLAN=<plan> ./run -a do_spl_issue_ref_rewrite`
re-reads each planned field's current text (READ ONLY), re-checks every key
at its offset, prints before/after per key and routes the field
(`csi-spl-orc/src/bash/scripts/issue-ref-rewrite.py`):

| route | the field | with DRY_RUN=0 |
|---|---|---|
| edit | a message this host's desk box sent | `do_spl_desk_edit` as its author; the hub keeps the old body as a revision |
| issue | an issue title or description | `do_spl_issue_update` as `ISSUE_AGENT`, only when it is set; an agent this box's desk announces, else the hub refuses `from_not_announced` |
| other-box | a message another live desk box sent | nothing: run the action on that box |
| human | a message typed in the WUI (`box-wui`) | nothing: its author, the owner or an admin edits it in the WUI |
| no-pin | a message from a box whose pin is revoked | nothing: no box can re-sign it |
| done / stale / gone | already new / changed since the scan / deleted | skipped; scan again for stale |
| archived | an archived or deleted issue | nothing: its keys stay (the owner's choice for csitea's CSI-20, archived on 2026-10-12) |

Only the planned keys change; every other byte stays. A plan holding a key
above the workspace's `last_number` is refused whole (exit 2, SPL-5073). Dry run unless
`DRY_RUN=0`. Test: `csi-spl-orc/src/bash/tests/spl-issue-ref-rewrite.tst.sh`.

<!-- version: 0.11.2 · updated: 2026-11-25 · last-edit: 2026-11-25T09:50:00Z -->
