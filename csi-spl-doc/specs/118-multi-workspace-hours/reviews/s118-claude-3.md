signed against cdf9136c9

# 118 review, seat s118-claude-3

**Seat**: s118-claude-3 (c-784) · **Reviewed**: [../spec.md](../spec.md) at `cdf9136c9` (its footer reads `version: 0.5.0`; the brief calls it v0.1, same text) · **Read beside it**: [107](../../107-hours-tracking/spec.md) v2.0-draft, [119](../../119-personal-realm/spec.md) v0.1, rdb `0006_users_and_memberships.sql`, `0151_hours.sql`, `internal/store/rls.go`, `internal/auth/handler.go` (session), `internal/hub/resolve.go`.

Owner decisions D1..D4 are settled; nothing below reopens them. Everything in sections 3..6 is a proposal, concrete enough to build from.

## 1. Facts from the code that shape the proposals

| fact | where | consequence for 118 |
|---|---|---|
| A person is one `HUM-*` id in every workspace; `hours_*.member_id` is that id | `humans.human_id`, `tenant_memberships (tenant_id, human_id)` (rdb 0006) | no id mapping is needed: "as the person" = `member_id = session human` in each workspace |
| Hours RLS is **per workspace only** (`app.tenant_id`); the person filter is in the query | `0151_hours.sql` policies, `store/hours_postgres.go` | the cross-workspace read is N `inTenant(W)` transactions, each filtered by the session human |
| A human session has **one active workspace**; `X-Spool-Tenant` is for boxes | `resolve.go` lines 15..23, auth `session` (`active_tenant`, `tenants[]`) | `GET/PUT /v1/me/hours` cannot reach a second workspace; 118 needs its own route that names the workspace per row, checked against `tenants[]` |
| `hours_entries` holds **minutes per (day, target)**, no start or end | `0151_hours.sql`, 107 section 3.2 | D1's overlap cannot be computed from 107 v1 data alone (section 3) |
| 107 v2 FR-32 adds a day record **start, end, break** per (member, day), not per entry; the stopped timer has `{start, end}` but is folded into a day row | 107 sections 14.10, 6.3 | the intervals exist only at day-span level, and the timer's are thrown away |
| The day is the member's local day **in each workspace's zone** | 107 section 1.6 | one physical minute can sit on different dates in two workspaces |
| Hub pool 8 connections, db-f1-micro | estate | the fan-out over workspaces must be bounded |

## 2. REQ and D, one line each

| item | verdict | line |
|---|---|---|
| REQ-1 | **change** | Reword the first two sentences, which read as a contradiction: "**Within** a workspace a minute counts for one target, once (107 1.1 rule 5); **across** workspaces the same minute may be entered in each." Add the within-workspace guard for timed entries (section 3.4). |
| REQ-2 | **agree** | Add: an external accountant seat (107 FR-21) and a foreman (FR-22) get no field, route or export that carries a cross-workspace number. |
| REQ-3 | **agree** | Say "the person's **resolved** standard day per workspace (107 FR-14: person override, else the workspace's)"; the personal view never sums standard days into one target. |
| REQ-4 | **change** | Add: each entry obeys its own workspace's rules unchanged (freeze 4.2, day total <= 1440, its targets, its permissions); a refusal in one workspace never blocks another (section 5). |
| D1 | **agree** | Missing: what an entry **without times** counts as (section 3.3, owner question O1) and which zone the personal day uses (O3). |
| D2 | **agree** | Missing: a test that no split field exists (section 6, T-D2). |
| D3 | **agree** | Missing: the limit's unit (day, week or both, O2) and that the limit lives only in the realm (section 4.1). |
| D4 | **agree** | Missing: what "job/site label" is for a **topic, channel or DM target** (its title is content: the receipt carries the target type only, section 4.2), and receipts on a workspace **deletion** (O5). |
| section 4 (realm) | **agree** | Add the contract of section 4 below, so 118 and 119 build against one interface. |

## 3. Proposals 1 and 2: data model, read as the person, overlap

### 3.1 Read, as the person, one workspace at a time

- **Route** (realm namespace, 119): `GET /v1/me/realm/hours?from=<date>&to=<date>` (at most 62 days). Human session only; **refused under act-as (054)** and for agents and box tokens (403 `person_only`).
- **Which workspaces**: the session's memberships (the same list auth `session` returns as `tenants[]`), minus memberships whose only role is `time_accountant` (107 FR-21; the 4.2 sweep skips them too). The request **cannot name** a workspace: the hub never queries one the person is not a member of.
- **How**: for each workspace W, one `inTenant(W)` transaction (`app.tenant_id = W`; never `asOperator`, never `app.rls_scope = operator`), running the existing store reads with `member_id = <session human>`: `HoursEntries`, `HoursPeriods`, and (v2) the FR-32 day records and the timed intervals of 3.2. The workspace name comes from the membership list. At most **2 workspaces in flight** at a time (pool 8, shared with the rest of the hub); at most 20 workspaces per call, then 400 `too_many_workspaces`.
- **What it returns**: per workspace and day: reported minutes per target (approved and open rows, each with its state), the period state, the resolved standard day, the timed intervals; and per personal day the computed `reported`, `actual`, `overlap` (3.3). Never raw `hours_minutes`, never another member's row.
- **No new workspace table for the read.** Spec 107's tables are the source (107 sections 3.1, 3.2); 118 adds nothing to a workspace except 3.2.

### 3.2 The one addition 118 needs from 107: keep the intervals

D1 needs times. The proposal lands in 107's store (107's lane; a change request, not a 118 table):

- **`hours_intervals`** (0098 shape: `tenant_id` first, FORCE RLS, `tenant_scope` with the NULLIF guard, `operator_scope`): `tenant_id`, `member_id`, `day` (the workspace day of `start_at`), `target`, `start_at timestamptz`, `end_at timestamptz`, `CHECK (end_at > start_at)`, `source` (`timer`, `clock`, `plan`, `self`). PK `(tenant_id, member_id, start_at)`.
- Written by: the stopped timer (107 `POST /v1/me/hours/timer`, which today folds `{start, end}` into a day row and drops the times), clock in/out (FR-24), a plan prefill when approved (FR-16), and an entry made with start and end on the 118 screen (section 5).
- The day row in `hours_entries` stays the approved number; the intervals of a (day, target) **explain** it. When an edit changes the minutes so they no longer equal the intervals' sum, the intervals of that (day, target) are dropped and the row becomes **untimed** (3.3).
- Kept with the entries under FR-34 retention, never pruned at the freeze (unlike `hours_minutes`).

### 3.3 The overlap computation (D1)

It runs **in the hub**, in one pure function in `internal/hours` (e.g. `Across(days []WorkspaceDay, tz, now) []PersonalDay`), called by the 3.1 route after the reads and table-tested without a database. The WUI only draws it. With one implementation, the phone, the desktop and the D3 warning agree.

Per personal day D (in the person's realm zone, O3):

1. For each workspace W, take its **timed** intervals that intersect D, clipped to D's bounds (an interval crossing midnight contributes to both days, split at the person's midnight, not the workspace's).
2. `reported(D) = Σ_W Σ_targets minutes`, timed and untimed rows alike (D1: the sum of all workspaces). Rejected rows count 0, as in 107.
3. `timedUnion(D) = |∪_W intervals(W, D)|`, the interval union in minutes (sort by start, merge, sum).
4. `untimed(D) = Σ_W untimed minutes on D` (rows with no interval, e.g. 107 v1 activity rows). Untimed minutes are **assumed not to overlap** (O1): they are added in full.
5. `actual(D) = timedUnion(D) + untimed(D)`; `overlap(D) = reported(D) - actual(D)`, never negative.
6. The **marks**: every merged sub-interval covered by 2 or more workspaces is returned as `{start, end, workspaces[]}` for the view to hatch.
7. Week: `actual(week) = Σ_D actual(D)`; the same for reported.

Assuming no overlap for untimed minutes makes `actual` too high, never too low, so the D3 warning comes early rather than late.

Edge cases:

| case | rule |
|---|---|
| **open timer** | the running timer lives in the WUI until stopped (107 6.3). The view adds it as a provisional interval `[start, now)` in its workspace, drawn dashed, counted in `actual` and in the D3 warning, **not** in `reported` (it is not entered yet). Two timers running in two workspaces overlap like any intervals. |
| **crossing midnight** | split at the person's midnight (step 1); the workspace keeps its own split at its own midnight (107 1.6) for approval. The two splits can differ; the personal view says so on hover ("entered on Tue in W2"). |
| **different zones** | timed intervals are re-bucketed to the person's zone; an untimed row cannot be, so it stays on its workspace date, marked "no times". |
| **DST day** | interval arithmetic is in UTC instants, so a 23 h or 25 h day needs no special case; the day bounds come from the zone database. |
| **edit after approval** | the view reads live state: a 107 Return (4.3) and a resubmit change the numbers and the marks on the next read; a frozen or approved period shows its state per workspace. Nothing is a snapshot except the D4 receipt. |
| **a workspace fails the read** | (removed mid-request, a timeout) the view shows that workspace as "not available now" and computes over the rest, marking the day **incomplete**; a partial number is never presented as complete. |
| **left a workspace** | its rows come from the receipt (4.2), which has no intervals: they count as untimed. |

### 3.4 Within one workspace, a minute once (REQ-1)

107's PK `(tenant_id, member_id, day, target)` and the <= 1440 day check do not stop two **timed** entries of one workspace from overlapping on two targets. With 3.2 in place, the 107 store refuses an interval that overlaps another interval of the same member in the same workspace: 409 `overlap_in_workspace`. Across workspaces nothing is refused (D2).

## 4. The boundary with spec 119: what 118 needs from the realm

118 consumes; 119 owns. The contract:

### 4.1 Personal settings

- `personal.settings` (119's one `personal` schema, `person_id` key, FORCE RLS on `app.person_id`): `hours_limit_day_minutes int NULL`, `hours_limit_week_minutes int NULL` (O2), `tz text NULL` (O3; the personal day's zone, default the browser's).
- Read and written only by `GET/PUT /v1/me/realm/settings`, as the person. **No** `tenants.settings` key, no 098 registered key, no workspace column for the limit (D3).
- The warning is computed in the WUI from `actual` (3.3) and the limit, and is never sent, logged or stored anywhere.

### 4.2 Receipts (D4)

- `personal.hours_receipts`: `person_id`, `tenant_id` (text, **no FK**, 119 section 5), `workspace_name`, `day`, `minutes`, `label`, `kind` (107 FR-27, `work` by default), `period_start`, `period_end`, `approval_state`, `approver_name`, `copied_at`. PK `(person_id, tenant_id, day, label)`.
- **`label`**: for a `job:` target, the job name and site (107 FR-18); for `t:`, `ch:`, `dm:`, `cal:` targets, only the type (`topic`, `channel`, `direct message`, `meeting`), never a title; for `ws`, `workspace`. The entry `note` is never copied (it is content).
- **When**: on membership removal, the removal path copies first, then removes. Two transactions, never one (119: workspace scope and realm scope are never set together): read under `inTenant(W)` for that member, write under the person's realm scope. The copy is idempotent (`ON CONFLICT DO NOTHING` on the PK), so a retried removal copies once. A failed copy blocks the removal and is retried; nothing is removed without a receipt.
- A rejoin does not merge receipts back: the new membership's live rows are read as usual and the old receipts stay.

### 4.3 The unified view's home

The 3.1 read route and the 5.2 write route sit under `/v1/me/realm/*` and on the realm's page in the WUI (119 REQ-2). 118 specifies their behaviour; 119 the page frame, navigation and identity.

### 4.4 Contradictions flagged

| with | what | proposal |
|---|---|---|
| 119 REQ-6 and section 2 ("Nothing flows from the personal realm down to the workspaces") | REQ-4 writes entries into workspaces **from the realm screen** | 119 should say: no realm **data** (limit, actual, other workspaces' hours, receipts) flows down; an entry the person makes on the realm screen is an ordinary member write into that workspace, under that workspace's rules. |
| 119 Q3 B (receipt = hours, dates, workspace name, job/site label) | D4 (settled) also lists **approval state and approver** | 119 follows D4; its Q3 is answered by D4. |
| 107 section 3.2 (no times on entries) and 6.3 (the timer drops its times) | D1 needs intervals | section 3.2: `hours_intervals`, a 107 change. Without it, `actual` equals `reported` on every untimed day and D1's marks are empty. |
| 107 section 1.6 (the day in the workspace's zone) | one personal day across workspaces | section 3.3 re-buckets timed intervals; untimed rows stay on their workspace date. |
| 107 FR-37 | none: FR-37 hands cross-workspace tracking to this spec | consistent. |
| 119 section 5 "reads each workspace under its own RLS context as that person" | none | consistent with 3.1. |

## 5. Proposals 3 and 4: the personal view, and entering into several workspaces

### 5.1 What the person sees

**Desktop** (realm page "My time"): a week grid, one row per day. Columns: one per workspace (its colour and name, the day's minutes, its period state as a small lock or check), then **Reported** and **Actual**. A day with overlap shows `overlap 1:30` between the two numbers. Below the grid, the selected day's **timeline** (00..24) with one lane per workspace and the overlapping stretches hatched across the lanes (the 3.3 marks). Header: the week's Reported and Actual, the limit (if set) and its warning, "Actual 52:00 · your limit 48:00" in the warning colour, visible to the person only. Untimed rows show as a block in the lane's margin labelled "no times".

**Phone**: a list of day cards for the week (swipe for the previous or next week). Each card: the date, **Reported 10:00 · Actual 8:30**, a thin stacked bar per workspace with the overlap hatched, and the workspaces as chips with their minutes. Tapping a card opens the day: the timeline as on the desktop, one workspace lane under another. The week totals and the limit warning sit in a sticky header.

Both: a day view and a week view (the default); no month view in 118. Loaded lazily (not in the initial chunk). An incomplete day (3.3) shows "W2 not available now" instead of a number for that workspace.

### 5.2 Entering hours into several workspaces from one screen (REQ-4)

- **+ Add hours** on a day (card or grid row) opens a sheet. **Workspace** comes first, as chips of the person's workspaces (the last used one preselected; a workspace whose period for that day is frozen shows disabled with "frozen"). Then the **target**, offered by that workspace's own pickers (its jobs, topics, `ws`), read lazily under that workspace. Then **minutes** (stepper ±15, as 107 4.1) or **start..end** (writes an interval, 3.2), and an optional note.
- Several rows may be added before saving, each with its own workspace. There is **no "split"** control and no percentage (D2): entering the same hour in two workspaces means two rows, each picked by hand.
- **Save**: `PUT /v1/me/realm/hours` with `[{tenant_id, op_id, day, target, minutes | start, end, note}]`. The hub groups the rows by workspace. For each workspace it checks the workspace is among the session's memberships (else that group fails 403 `not_a_member`), then runs **one `inTenant(W)` transaction** through 107's existing entry write (`PutHoursEntries`, its freeze check, its <= 1440 check, its target checks). Workspaces are written one after another. **There is no cross-workspace atomicity**, on purpose: each workspace is its own boundary.
- **Response**: 200 with a result per row: `ok`, or the workspace's own refusal (`period_frozen`, `day_over_1440`, `overlap_in_workspace`, `unknown_target`, `not_a_member`). The sheet keeps each refused row open with its reason next to it and closes the saved ones. `op_id` makes a retry idempotent (107 FR-35's pattern), so a retry after a partial failure never writes a row twice.
- Editing or rejecting an existing row from the personal view goes through the same route with that row's workspace. The approval actions (Approve day, Approve week) stay in each workspace's calendar dialog (107 5.2) and are not duplicated in 118.

## 6. Proposal 5: tests

Store tests on Postgres (`PRE_PUSH_TIER=full`), hub route tests, the pure function's table test, WUI e2e. Each RLS test needs its red control.

| id | proves | test |
|---|---|---|
| T-R1a | REQ-1, D1 | `Across` table test: W1 09:00..12:00, W2 10:00..13:00 -> reported 6:00, actual 4:00, overlap 2:00, one mark 10:00..12:00 [W1, W2] |
| T-R1b | REQ-1 | within one workspace, a second interval overlapping the first -> 409 `overlap_in_workspace`; the same interval in another workspace -> 200 |
| T-R1c | D1 edges | `Across` cases: crossing midnight (split at the person's midnight), two zones, a DST day (23 h and 25 h), untimed rows (added in full), an open timer (in actual, not in reported), a rejected row (0) |
| T-R2a | REQ-2, D3 | as a foreman with crew rights in W1, and as an external accountant seat: `GET /v1/hours?member=<person>` returns W1 rows only, and no response field, export column or report carries `actual`, `overlap`, the limit or another workspace's id (assert on the JSON keys and the CSV header) |
| T-R2b | D3 | no table outside `personal` and no `tenants.settings` key holds a limit: a catalogue test lists every column and registered key matching `limit` and fails on any outside `personal.settings` |
| T-R3 | REQ-3 | W1 standard day 480, W2 240 with a person override of 300: the view shows 480 and 300 per workspace, never a summed 780 |
| T-R4a | REQ-4 | one save with rows for W1 and W2 -> each row lands in its own workspace (read back under `inTenant(W1)` and `inTenant(W2)`) |
| T-R4b | REQ-4 | W2's period frozen: the W1 rows save, the W2 rows return `period_frozen`, W1 is not rolled back; a replay with the same `op_id`s writes nothing new |
| T-D2 | D2 | the write route refuses an unknown field (`split`, `share`, `percent`) with 400; the sheet has no split control (e2e: no such element) |
| T-D4a | D4 | remove the person from W2: one receipt row per (day, label) with workspace name, minutes, approval state, approver name; **no** topic title, channel name or note (assert the label set equals the type names for non-job targets) |
| T-D4b | D4 | after removal `GET /v1/me/hours` with W2 active -> 403; the realm view shows W2 from receipts only; a failed receipt copy blocks the removal |
| T-RLS1 | RLS negative | person A's realm read never returns person B's rows, B being a member of the same two workspaces (seed both, assert every returned `member_id` = A) |
| T-RLS2 | RLS negative | person A is not a member of W3: the realm read issues no query for W3 (a store spy counts the `inTenant` calls = A's memberships), and a write naming W3 -> 403 `not_a_member`, 0 rows in W3 |
| T-RLS3 | RLS negative | the realm routes never call `asOperator` (store spy) and are refused under act-as and with a box token (403 `person_only`) |
| T-RLS4 | realm isolation | `personal.settings` and `personal.hours_receipts` under `app.person_id = B` return 0 rows of A; with `app.person_id` empty, 0 rows (the NULLIF guard) |
| T-CTL | red control | each RLS test runs once against a deliberately widened query (the person filter removed, or `asOperator`) on a throwaway branch and must fail; the control's run id goes into the tasks file |
| T-PERF | bound | 20 workspaces x 31 days: the read keeps at most 2 transactions in flight (pool spy); 21 workspaces -> 400 |
| T-E2E | UI | phone and desktop: a week with one overlap shows both numbers, the hatched mark and the limit warning; adding rows for two workspaces, one of them frozen, shows one saved and one refused row |

## 7. Questions that are the owner's call

| # | question | options (the seat's lean first; not decided) |
|---|---|---|
| O1 | An entry **without times** (107 v1 activity rows, a typed number): how does it count in "actual"? | A: assumed not to overlap, added in full, marked "no times" (actual errs high, the warning comes early) · B: the 118 screen requires start and end for every new entry; old rows as A |
| O2 | The person's working-time **limit**: per day, per week, or both? | A: both, each optional · B: week only · C: day only |
| O3 | The personal view's **day** when the workspaces' zones differ? | A: one personal zone from the realm settings (timed entries re-bucketed) · B: each workspace's own date, no re-bucketing |
| O4 | An "**Also enter in…**" shortcut that copies a row into another workspace as a new entry (each still saved and approved on its own): within D2, or too close to a split? | A: allowed, it is two entries · B: not offered, each row typed separately |
| O5 | A **deleted** workspace (the tenant delete cascades every `hours_*` row): do its members get receipts as D4 leavers do? | A: yes, the delete copies receipts first · B: no, D4 covers leaving only |
| O6 | The 107 change of section 3.2: add `hours_intervals` and keep the timer's times, so D1 can mark overlaps? Without it, D1's marks are empty on every untimed day. | A: yes, a 107 store change inside 118's build · B: day spans from FR-32 only (coarser: one interval per workspace-day) |
