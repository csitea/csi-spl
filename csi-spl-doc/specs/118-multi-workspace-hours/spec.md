# 118 Multi-Workspace Hours Tracking

**Status**: v1.0 (panel consensus of four seats; signed, section 11.4; owner questions open, section 12)

Read beside it: [107 hours tracking](../107-hours-tracking/spec.md) (v2.0-draft: the per-workspace model this spec reuses), [119 personal realm](../119-personal-realm/spec.md) (v0.1: where the personal view lives). The panel's seat files: [reviews/](reviews/).

## 1. Context and Goals
The goal is to allow each person to individually report and track their own hours across multiple workspaces at once, in a unified view. Each person sees and tracks (enters, not read-only) their own hours across all workspaces they belong to. Cross-workspace reads remain person-only and RLS-safe.

## 2. Requirements

- **REQ-1 (Workspace Scope & Overlaps)**: Hours stay per workspace for approval and accounting. **Within** a workspace a minute counts once, for one target (107 1.1 rule 5); two entries of one person whose times overlap in the same workspace are refused (section 5.3). **Across** workspaces the same wall-clock minute may be entered in each (e.g., a component invoiced to two organizations). Double counting across workspaces is allowed, but double counting within a single workspace is forbidden. *(v1.0: the v0.1 wording "a tracked minute counts in one workspace only" contradicted the next sentence; reworded by all three claude seats.)*
- **REQ-2 (Working-Time Limits)**: Working-time limits are evaluated on the cross-workspace **actual** total (D1, D3) by the person themselves. Foremen, time-accountants and the external accountant seat (107 FR-21, FR-22) see only inside their own workspace and cannot enforce global cross-workspace limits: no field, route, export or report of a workspace carries a cross-workspace number. A workspace's own overtime flag (107 FR-28) is unchanged.
- **REQ-3 (Standard Days)**: The standard day is set and configured on a per-workspace basis (e.g., 8 hours in Workspace A, and 4 hours in Workspace B): the person's **resolved** standard day per workspace (107 FR-14: the person override, else the workspace's). The personal view shows each workspace's own and never sums them into one target.
- **REQ-4 (Unified Tracking UI)**: The user must be able to see and track (enter) their hours from multiple workspaces in one unified place. Each entry is saved into its respective workspace **under that workspace's own rules unchanged** (freeze 107 4.2, day total <= 1440, its targets, its permissions); a refusal in one workspace never blocks or rolls back another (section 7).

## 3. Owner Decisions

**D1: Visibility of Double Counting (REQ-1)**
The personal view shows two numbers: **reported time** (sum of all workspaces) and **actual time** (overlapping minutes counted once). It visually marks overlapping hours so the user can stand behind both invoices. This is shown on the PERSONAL view only, never a workspace view.

**D2: Splitting Hours Across Workspaces (REQ-1)**
There is **NO split option**. The system does not track customer cost-sharing consent, so the system only records actual time worked per workspace, allowing the same physical hour to be billed to multiple workspaces simultaneously if the user chooses to enter it in both.

**D3: Working-Time Limit Warnings (REQ-2)**
The working-time warning is a **person-only UI warning** based on actual time versus a person-set limit. There is no reporting of this limit or warning to any workspace, and no data is shared with the foremen.

**D4: Retaining Access After Leaving a Workspace (REQ-4)**
A leaver keeps a read-only receipt of their own hours (days/weeks, hours, workspace name, job/site label, approval state, and approver). They do NOT keep the workspace content behind them. 

## 4. Architectural Dependency: The Personal Realm (Spec 119)
As decided by the owner, there will be a **Personal Realm** (a person-level layer above workspaces), which will be defined in a separate **Spec 119**. 
For Spec 118, the following components **live in the Personal Realm** (and do not need to be designed here):
- The cross-workspace unified view.
- The person's limit setting (for the working-time warnings).
- The leaver's read-only receipts of their own past hours.

What 118 needs from the realm is the contract in section 9: the 118 side of the 118/119 interface, for the 119 review panel to answer.

## 5. Data model and the cross-workspace read under RLS

### 5.1 Facts from the code (each with its check)

| fact | where | consequence |
|---|---|---|
| A person is one `HUM-*` id in every workspace; `hours_*.member_id` is that id | `humans.human_id`, `tenant_memberships (tenant_id, human_id)` (rdb `0006_users_and_memberships.sql`); `grep -n member_id csi-spl-rdb/src/sql/postgres/spool-hub/0151_hours.sql` | no id mapping: "as the person" = `member_id = session human` in each workspace |
| Hours RLS is per workspace only (`app.tenant_id`); the person filter is in the query | `0151_hours.sql` policies, `internal/store/rls.go:37` `inTenant` | the read is one `inTenant(W)` transaction per workspace, filtered by the session human |
| A human's workspace is the session's **active** one; `X-Spool-Tenant` is for boxes | `internal/hub/resolve.go:15..26` | `PUT /v1/me/hours` cannot reach a second workspace from one session: 118 needs its own realm routes that name the workspace per row (5.2, 7.2) |
| The person's memberships are read by `Memberships(ctx, humanID)`, the one allow-listed operator-scoped read of `tenant_memberships`, which leaves out a membership past `access_until` (rdb 0113) | `internal/store/memberships.go:99..111`, `TestOperatorScopeCallers` | 118 adds **no** new operator-scoped read |
| `hours_entries` holds **minutes per (day, target), no time of day**; `hours_minutes` (per minute) is pruned at the freeze and at 45 days; the timer's `{start, end}` is folded into minutes and dropped | `0151_hours.sql:45..56`, 107 sections 3.2, 4.2, 1.5 | D1's "actual" cannot be computed from 107's data: section 5.3 (found independently by s118-claude, -2, -3) |
| Hub pool 8 connections, db-f1-micro, `max_connections` 25 | estate | the per-workspace fan-out is bounded (5.2) |

### 5.2 The read, as the person

- **Route**: `GET /v1/me/realm/hours?from=<date>&to=<date>` (at most 62 days) in the realm's route group (C2). Human session only. Refused with 403 `person_only` under act-as (spec 054), for agents and for box tokens; refused with 400 if it carries `X-Spool-Tenant` or a `member=` parameter.
- **Which workspaces**: `Memberships(ctx, caller)`, minus a membership whose only role is `time_accountant` (107 FR-21: no own hours). The request cannot name a workspace. At most 20 workspaces per call, a 21st is 400 `too_many_workspaces`, never silently dropped.
- **How**: for each workspace W, one `inTenant(W)` transaction (never `asOperator`, never `app.rls_scope = operator`) running the existing 107 store reads with `member = caller` (never `""`, the store's "every member"): `HoursEntries`, `HoursPeriods`, the spans of 5.3, and today's `HoursMinutes` for the open suggestions. At most **2 workspaces in flight** (pool 8, shared with the hub).
- `app.person_id` (119) is **never set in the same transaction** as `app.tenant_id` (119 section 5): the realm reads (limit, zone, receipts) are their own transaction.
- **A failed workspace read** (store error, timeout, membership removed mid-request) returns that workspace as `{"state":"unavailable"}`; the totals are marked `incomplete`. Never a silent zero, never retried under a broader scope.
- **Privacy**: never raw `hours_minutes` rows, never another member's row. The reads go through the existing hours store functions, so 107's 1.7 grep test stays green unchanged.
- Nothing is written by the read.

### 5.3 Spans: the one addition, a change request to 107's store

**`hours_entry_spans`** (the name of two seats; s118-claude-3 called it `hours_intervals`): 107's store and lane, built inside 118's tasks. Shape of 107 3.2: `tenant_id` first, `ENABLE` + `FORCE ROW LEVEL SECURITY`, `tenant_scope` with the `NULLIF(current_setting('app.tenant_id', true), '')` guard, `operator_scope`.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | HUM-* |
| `day`, `target` | date, text | FK `(tenant_id, member_id, day, target)` -> `hours_entries`, cascade |
| `start_at`, `end_at` | timestamptz | whole minutes (`date_trunc('minute', …)` CHECKs), `end_at > start_at`, length <= 1440 min |
| `src` | text | `activity` (a 107 suggestion block), `timer`, `plan`, `clock` (107 v2 FR-16, FR-24), `manual` |

- PK `(tenant_id, member_id, start_at)`. `EXCLUDE USING gist (tenant_id WITH =, member_id WITH =, tstzrange(start_at, end_at) WITH &&)` (`btree_gist`, available on Cloud SQL): **the database refuses double counting inside one workspace** (REQ-1), across targets too: 409 `overlap_in_workspace`. Across workspaces nothing is refused (D2).
- **Written** in the same transaction as the entry: at approval of a suggestion (its blocks, already computed for the "why" sheet, `hub/hours_me.go` `spansJSON`), by the stopped timer (its interval, split at the member's local midnight as 107 1.5 does), by the v2 plan or clock, by an entry made with start and end (section 7).
- **Minutes and spans disagree** (an edit by minutes only): `placed = min(minutes, total span length)`, the spans taken from the earliest one onward and the last one used cut short; `unplaced = minutes - placed`. An entry with no span (a pre-118 row, a typed number, an absence) is wholly unplaced.
- **Privacy** (107 1.7): spans are served only to the member (`/v1/me/hours*`, the realm routes), never to `hours.read`, `hours.approve` or the download; 107 decides separately whether its Team view shows start and end.
- **Retention**: kept with the entries under 107 FR-34, never pruned at the freeze (unlike `hours_minutes`); deleted by cascade with the entry.
- **Migration**: one forward-only file, the next free number, DDL first, applied to dev and prd before any code reads it.

Without spans, "actual" equals "reported" on every frozen week and D1's mark is empty exactly where an invoice needs it. Whether to build it is owner question **Q1**.

## 6. Reported vs actual: the overlap computation (D1)

### 6.1 Where it runs

One pure Go function in `internal/hours` (`Across(days []WorkspaceDay, zone, now) []PersonalDay`), no I/O, table-tested, called by the 5.2 route. **Nothing is stored**, not in a workspace, not in the realm: every read recomputes, so an edit, a return or a resubmit shows on the next read. The WUI draws the result; its only arithmetic is the running timer of today (6.3), checked against the Go function by one shared JSON fixture file run by both test suites.

### 6.2 Algorithm, per personal day D in the person's zone Z (C4)

1. For each workspace W, take the spans of its counted entries that intersect D, clipped to `[D 00:00 Z, D+1 00:00 Z)`, as UTC instants.
2. **Reported(D)** = Σ over W of the entries' minutes: approved plus open suggestions, the open part shown as "of which open h:mm". Rejected rows count 0.
3. Within each W its spans never overlap (5.3); an overlap found in old data is counted as `data_error_minutes`, logged and shown to the person as a fix-me mark, never hidden.
4. **Sweep line** over the endpoints of all workspaces' spans, sorted, an end before a start at the same instant (`[09:00,10:00)` and `[10:00,11:00)` do not overlap), keeping the set of open workspaces. Each stretch where the set holds 2 or more is an **overlap interval** `{start, end, workspaces[]}`. O(k log k); a heavy month is under 1,000 spans.
5. **Actual(D)** = |union of the spans| + Σ unplaced minutes. Unplaced minutes are **assumed not to overlap**, so actual errs high, never low, and the D3 warning comes early rather than late. A day with unplaced minutes shows `≈` and "h:mm without times, overlap not checked".
6. **Overlap(D)** = reported(D) - actual(D), never negative.
7. A week or a month is the sum of its days, never a second union path.

### 6.3 Edge cases

| case | rule |
|---|---|
| **open timer** | It lives in the device's localStorage per workspace until stopped (107 1.5) and the hub never sees it. The view adds `[start, now)` as a provisional span of its workspace, drawn dashed: counted in **actual** and in the D3 warning, **not** in reported (it is not entered yet). Two timers running in two workspaces are allowed (D2) and show as a live overlap. |
| **crossing midnight** | Spans are absolute; the personal view splits at the person's midnight (step 1). The workspace keeps its own split at its own midnight for approval (107 1.6); when the two differ the view says so on hover ("entered on Tue in B"). |
| **different zones** | The memberships' zones (rdb 0078 `time_zone`) may differ. Spans are re-bucketed to the personal zone; an unplaced entry has no instant and stays on its workspace's date, marked "no times". |
| **DST** | UTC instants: a 23 h or 25 h day needs no special case; the bounds come from the zone database. 107's 1440-minute cap is per workspace and untouched. |
| **edit after approval** | Frozen and approved periods cannot change (107 4.2); a Return (107 4.3) and a resubmit show on the next read. Only the D4 receipt is a snapshot. |
| **a day above 24 h** | Impossible per workspace (107 3.2); the cross-workspace reported total may exceed 24 h, which is D1's case: shown, never refused. |
| **left workspace** | Its rows come from the receipt (C5): reported counts them, actual counts them as unplaced (unless Q5 keeps spans in receipts). |
| **workspace unavailable** | Computed over the rest, the day marked `incomplete`, the workspace named (5.2). |

### 6.4 Output

Per personal day: `reported`, `open`, `actual`, `overlap`, `unplaced`, `approx`, `incomplete`, `data_error_minutes`, `overlap_intervals[]`, and per workspace `{minutes, open, state, standard_day, spans[]}`; per window the same totals. No limit field: the warning is the WUI's (8.1).

## 7. Entering hours into several workspaces from one screen (REQ-4)

### 7.1 The screen

**+ Add hours** on a day of the personal view (a sheet on the phone, a dialog on desktop). Each row:
1. **Workspace** first: chips of the person's workspaces where they enter hours (not a time-accountant-only seat). Preselected: the workspace of the row above, else the last used, else the one the person came from. A workspace whose period for that day is frozen shows disabled, "frozen".
2. **Target**, offered by **that workspace's** pickers only (its jobs, topics, channels, meetings, `ws`; 107 `HoursTargetPicker.vue`) read through `GET /v1/me/realm/targets?workspace=<W>&q=`, which checks W against the caller's memberships and reads under `inTenant(W)`. Changing the workspace clears the target: a target from A is never offered in B.
3. **Start..end** (preferred: it writes a span) or **minutes only** (stepper ±15; unplaced, shows `≈`).
4. **Note** (optional, <= 500, 107 5.2).

While typing, the day strip marks a new overlap **with another workspace** as information ("also in B 10:00-11:00", D2 allows it). An overlap **within the same workspace** is an inline error and that row cannot be saved (REQ-1). There is **no split control, no percentage** (D2): the same hour in two workspaces is two rows, each picked by hand.

### 7.2 Save

- `PUT /v1/me/realm/hours` with `[{workspace, op_id, day, target, minutes | start, end, note}]`. The hub groups rows by workspace. For each group it checks the workspace is among `Memberships(caller)` (else that group fails 403 `not_a_member`, 0 rows written there), then runs **one `inTenant(W)` transaction** through 107's existing entry write (`PutHoursEntries`: freeze 409 `period_frozen`, the 1440 cap, the target checks) plus the spans (409 `overlap_in_workspace`). Groups run one after another.
- **No cross-workspace atomicity, on purpose**: each workspace is its own accounting record (REQ-1) and a transaction across tenant scopes is what 119 forbids. The screen says so.
- **Response**: 200 with a result per row: `ok` or the workspace's own refusal (`period_frozen`, `day_over_1440`, `overlap_in_workspace`, `unknown_target`, `not_a_member`). `op_id` makes a retry idempotent (107 FR-35's pattern) and the writes are 107's `ON CONFLICT` upserts.
- Unknown fields (`split`, `share`, `percent`) are 400.

### 7.3 When one workspace refuses

- Saved rows close and show their state; **refused rows stay in the form, dirty, with the reason** in the person's language: "Week 41 in B is closed. Ask B's approver to return it." / "Overlaps your 10:00-11:00 in B." / "You are no longer a member of B." / offline: "Saved on this device; will send when online" (FR-35 queue).
- A banner: "Saved in A and C. 1 row not saved in B. [Retry B]". Retry resends only B's rows. Nothing in A is rolled back.

### 7.4 Editing, timers, approvals

- Edit or reject an existing row from the personal view: the same route, that row's workspace. The workspace of an existing row cannot change: moving an hour is delete in A plus add in B, two visible writes.
- **Timer**: Start in the personal view asks the workspace, then the target, and stores the running timer under that workspace's localStorage key (107 1.5), so the workspace's own header shows it too. One timer is for one workspace; several may run (D2). Stop writes through `PUT /v1/me/realm/hours` with `{start, end}`, split at the member's midnight in that workspace, as 107's timer does.
- **Approve day / Approve week** stay in each workspace's calendar dialog (107 5.2); the personal view links there and does not duplicate them.
- "Also enter in …" (a one-tap copy into another workspace as a new row): owner question **Q4**.

## 8. UI of the personal view

A realm page, **My hours** (`/me/hours`), one lazy chunk: nothing in the initial bundle (the 160 KB budget, `perf-budget.py`). Entry points: the person menu, and an "All my workspaces" link in each workspace's hours panel and Working hours dialog (107 5.2, 5.4) for a person with 2+ workspaces. The link carries no cross-workspace number into the workspace.

### 8.1 Desktop (> 820 px)

```
 My hours · all workspaces                    Week 41   < >   [Week|Month]
 ┌──────────────────────────────────────────────────────────────────────┐
 │ Reported 46:30   Actual 41:00   5:30 in more than one workspace      │
 │ Actual 41:00 of your 45:00 week                                      │
 └──────────────────────────────────────────────────────────────────────┘
            Mon     Tue     Wed     Thu     Fri     Sat  Sun
 Acme       8:00    8:00    4:00    8:00    6:30     -    -    34:30  std 8:00
 Beta       4:00    -       4:00    -       4:00     -    -    12:00  std 4:00
 ─────────────────────────────────────────────────────────────────────
 Reported  12:00    8:00    8:00    8:00   10:30               46:30
 Actual    10:00    8:00    8:00    8:00    7:00≈              41:00
 Overlap   ▒2:00                            ▒3:30               5:30
```

- One row per workspace (its colour chip, name and resolved standard day; each cell its minutes and the 107 state mark: open dot, approved, frozen lock, Final, returned); then **Reported**, **Actual**, **Overlap** (D1). A left workspace's row reads "left · receipt"; an unavailable one is grey with "could not be read, retry".
- An overlap cell is hatched in the one accent colour; hover/tap lists the intervals **with the workspaces named** ("10:00-11:30 Acme + Beta").
- A day opens its **timeline** (00..24): one lane per workspace, overlap bands hatched across the lanes involved, the running timer dashed, unplaced minutes as a grey stub "1:00, no times".
- **Limit (D3)**: when the person set one (C3), the header bar "Actual 41:00 of your 45:00 week" turns amber at 90 % and red past 100 %, with text, not colour alone. Shown on this page only; no workspace screen ever shows it. The WUI computes it from `actual` and the limit; it is never sent, logged, pushed or stored.
- Week view by default; a month toggle shows a grid with Reported, Actual and an overlap dot per day.

### 8.2 Phone (<= 820 px, 390 px)

No grid. A sticky header with the week's Reported and Actual and the limit bar; one card per day ("Mon · actual 8:30 · reported 10:00 · 1:30 overlap", a thin stacked bar per workspace with the overlap hatched, the workspaces as chips with their minutes); swipe for the previous or next week. A card opens the day sheet (the 106 sheet pattern) with the lanes stacked vertically and each row's **Edit** (section 7). No sideways scroll, controls 44..48 px.

### 8.3 Empty and single cases

With one workspace the page works and Reported = Actual. With none it explains where hours come from.

## 9. The contract 118 needs from the personal realm (spec 119)

The 118 side of the 118/119 interface; the 119 panel (orch ask `e7b7320c`) answers it. 118 consumes, 119 owns.

| # | 118 needs | notes |
|---|---|---|
| **C1 identity** | The realm's person is `humans.human_id` (`HUM-*`); `app.person_id` = that id. No second person id, no mapping table. | 119 does not yet say what `person_id` is. |
| **C2 route home** | `GET /v1/me/realm/hours`, `PUT /v1/me/realm/hours`, `GET /v1/me/realm/targets` (5.2, 7) live in the realm's route group: human session only, no `X-Spool-Tenant`, refused under act-as (054), for agents and box tokens. The page `/me/hours` is a realm page; 119 owns its frame and navigation. | |
| **C3 settings** | In 119's one `personal` schema (FORCE RLS on `app.person_id`): `hours_limit_day_minutes` (NULL = off, 60..1440) and `hours_limit_week_minutes` (NULL = off, 60..10080), each optional; read and written only by the person. No `tenants.settings` key, no 098 registered key, no workspace column. | D3, REQ-2 |
| **C4 zone** | The personal view's zone in the realm profile, `personal.profile.time_zone` (IANA, NULL = the browser's; name aligned with the 119 editor, c-787). | 6.2, 6.3 |
| **C5 receipts** | `personal.hours_receipts`: `person_id` (`REFERENCES public.humans (human_id) ON DELETE CASCADE`: hub-wide identity, not a workspace), `workspace_id` (text, the copied workspace id, **no FK to any workspace table**; never named `tenant_id`, so the RLS gates and `do_spl_db_rls_check` never take a realm table for a workspace table: 119 bans `tenant_id` in `personal.*`), `workspace_name`, `day`, `minutes`, `label`, `kind` (107 FR-27), `period_start`, `period_end`, `approval_state`, `approver_name`, `copied_at`, `rev` (`smallint NOT NULL DEFAULT 0 CHECK (rev IN (0,1))`); PK `(person_id, workspace_id, day, label, rev)`. Append-only: the runtime role has INSERT only, no UPDATE or DELETE (the 0157 rev-log shape); the view reads `max(rev)` per key. The leave copy is rev 0; under Q6-A the one refresh of the last open period is rev 1, for that period's days only; under Q6-B rev stays 0 (shape agreed with the 119 editor, c-787). **Label**: a `job:` target's job name and site (107 FR-18); for `t:`, `ch:`, `dm:`, `cal:` only the type (`topic`, `channel`, `direct message`, `meeting`), never a title; `ws` = `workspace`. The entry note is never copied (content). **When**: on membership removal, copy first, then remove; two transactions (read under `inTenant(W)` for that member, write in the realm scope); idempotent (`ON CONFLICT DO NOTHING` per rev); a failed copy blocks the removal and is retried, never a leaver without a receipt; `access_until` passing is copied by the sweep that notices it. A rejoin does not merge receipts back. | D4, 119 REQ-4/5, Q5..Q8 |
| **C6 receipts in the view** | The realm route reads the person's receipts in the realm transaction and merges them as "left" workspaces (6.3). | |
| **C7 nothing flows down** | No realm data (limit, actual, overlap, other workspaces' hours, receipts, zone) is ever written into a workspace. A person's own entry made on the realm screen is an ordinary member write into that workspace, through 107's write, under that workspace's rules: proposed wording for 119 REQ-6. | see 9.1 |

### 9.1 Contradictions found with 107 and 119

| with | what | settled as |
|---|---|---|
| 107 3.2 (no times on entries), 107 1.5 (the timer drops its times) | D1 needs intervals | 5.3 `hours_entry_spans`, a 107 store change: owner question Q1 |
| 107 1.6 (the day in each workspace's zone) | one personal day across workspaces | 6.3: spans re-bucketed to the personal zone, unplaced rows stay on their workspace date |
| 107 1.1 rule 5 ("a minute is never counted twice") | none once REQ-1 is reworded: it is within one workspace | REQ-1 v1.0 |
| 107 FR-37 | none: it hands cross-workspace tracking to this spec | consistent |
| 107 1.7 / 6.1 (raw signals are the member's) | spans are a raw signal | 5.3: spans never reach `hours.read`, test T-S3 |
| 119 Q3 B | leaves out D4's approval state and approver; says the label is "as defined in Spec 118", but 107 FR-18 defines jobs | C5: D4's list in full; the label per C5 |
| 119 REQ-6 "nothing flows from the realm down" | read literally, forbids REQ-4's writes from the realm screen | C7's wording |
| 119 section 5 "operator access is strictly logged" | the realm routes refuse act-as | C2 (119 may decide its own other routes) |
| 119 `app.person_id` | no relation to the hub id stated | C1 |

## 10. Tests

Store tests on Postgres (`PRE_PUSH_TIER=full`) as the runtime RLS role, never a superuser; each RLS test has a red control run on a throwaway branch, its run id recorded in the tasks file.

| id | proves | test |
|---|---|---|
| T-R1a | REQ-1, D1 | `Across`: A 09:00..12:00, B 10:00..13:00 -> reported 6:00, actual 4:00, overlap 2:00, one interval 10:00..12:00 [A, B] |
| T-R1b | REQ-1 within | two overlapping spans of P in A, on two targets -> 409 `overlap_in_workspace` (red control: drop the constraint, the test fails) |
| T-R1c | REQ-1 across, D2 | the same span in A and in B -> both saved; each workspace's own `GET /v1/me/hours` shows only its row |
| T-OV | D1 edges | `Across` table: disjoint (actual = reported); touching `[a,b)+[b,c)` (no overlap); three workspaces in a chain; across midnight in `Europe/Helsinki`; two zones (UTC and UTC+3); the DST days of March and October; unplaced minutes (`approx`, added in full); minutes edited down and up against spans (the placement rule); a rejected row (0); `data_error_minutes` |
| T-OV-JS | D1 timer | the shared JSON fixture passes in Go and in the WUI's today/timer function; an open timer counts in actual and not in reported, and sends nothing until stopped |
| T-OV-RO | D1 | return + resubmit: the next read shows it; no 118 table holds a computed total (there is none) |
| T-D2 | D2 | `PUT /v1/me/realm/hours` with `split`/`share`/`percent` -> 400; the sheet has no split control (e2e, with a positive control) |
| T-R2a | REQ-2, D1, D3 | as P's foreman in A (crew `hours.approve`), a `hours.read` holder and an external accountant seat: every A route and export (`GET /v1/hours`, export CSV/XLSX, periods) carries no `actual`, `overlap`, limit, B id, B name or B minute (assertion on JSON keys and the CSV header, with a planted-field control) |
| T-R2b | D3 | catalogue test: no column or registered key matching `limit` outside `personal`; after P sets a limit and exceeds it, no workspace table changed (row count and `max(updated_at)`), no `member_activity` row, no Web Push sent, no log line carries it |
| T-R2c | REQ-2 | limit 45:00, reported 46:30, actual 41:00 -> no warning; limit 40:00 -> red (actual, not reported) |
| T-R3 | REQ-3 | A 480, B 240 with a person override of 300 -> the view shows 480 and 300, never 780 |
| T-R4a | REQ-4 | one save with rows for A and B -> each lands in its own workspace (read back under `inTenant(A)`, `inTenant(B)`) |
| T-R4b | REQ-4 partial | B's period frozen -> A saved, B `period_frozen`, A not rolled back; a replay with the same `op_id`s writes nothing new; after a Return, B saves once |
| T-R4c | REQ-4 picker | `GET /v1/me/realm/targets?workspace=B` never returns an A target; a write of an A target into B -> `unknown_target` |
| T-RLS1 | RLS | P and Q both in A and B: P's realm read returns only rows with `member_id = P` |
| T-RLS2 | RLS | P not in C, C holding rows with `member_id = P` (seeded as operator): no `inTenant(C)` call (store spy counts calls = P's memberships); a write naming C -> 403 `not_a_member`, 0 rows in C |
| T-RLS3 | RLS | P's membership of B past `access_until`: no live B rows, only the receipt |
| T-RLS4 | scopes apart | no transaction of the realm routes sets both `app.tenant_id` and `app.person_id`; the routes never call `asOperator`; `TestOperatorScopeCallers` unchanged |
| T-RLS5 | realm | `personal.*` under `app.person_id = Q` returns 0 rows of P; with it empty, 0 rows (the NULLIF guard) |
| T-RLS6 | access | under act-as, with a box token, as an agent, as a time-accountant-only seat: 403 `person_only` / 404; `X-Spool-Tenant` or `member=` -> 400 |
| T-S3 | privacy | `GET /v1/hours` and the export as `hours.read` carry no span field (a planted-span control); 107's 1.7 `hours_minutes` grep test unchanged |
| T-D4a | D4 | P leaves B: one receipt row per (day, label) with workspace name, minutes, approval state, approver name; no topic title, channel name or note (label set = the type names for non-job targets, with a content control) |
| T-D4b | D4 | after leaving, B's routes -> 403; the receipt is readable only by P (Q, a foreman, an admin -> 404); a failed copy blocks the removal; no FK from `personal.hours_receipts` into a workspace table and no `tenant_id` column in `personal.*` (catalogue query; the FK to `public.humans` is the one allowed) |
| T-PERF | bound | 20 workspaces x 31 days timed on dev with n recorded, at most 2 transactions in flight (pool spy); 21 workspaces -> 400. The latency budget is set from the measurement, not guessed |
| T-E2E | UI | phone 390 px and desktop: a week with one overlap shows both numbers, the hatched mark naming both workspaces and the limit bar; the limit appears on no workspace screen (text and testid absence, positive control); adding rows for two workspaces, one frozen, shows one saved and one refused row; the new row shows in that workspace's own calendar Working hours line; the realm chunk is lazy (`perf-budget.py` initial chunk unchanged) |

## 11. Panel and consensus

Seats, each signed against `cdf9136c9`: **s118-claude** (c-782, editor, `42bb5c7bb`), **s118-claude-2** (c-783, `6f2b324f8`), **s118-claude-3** (c-784, `8b09843ec`), **s118-mistral** (m-785, `3b5c123c4`). Guard: `git show --stat` of each seat commit lists only its own review file.

### 11.1 Agreed by all four seats

- D1..D4 as written; the cross-workspace read is one per-workspace read as the person, never a service read across workspaces; spec 107's tables are reused; the personal view is person-only and hosted by 119; D2 has no split.
- The overlap is an interval union across workspaces; edits recompute on read.

### 11.2 Agreed by the three claude seats (mistral silent or differing, 11.3)

- REQ-1 reworded (within / across); REQ-4 gets the per-workspace rules and the no-rollback rule.
- 107 stores durations, not times of day: D1 needs spans (5.3), one table, one owner question (Q1).
- The computation runs in the hub as a pure function; unplaced minutes count as not overlapping, marked.
- Receipts are copied before removal, in two transactions, without content; `person_id = HUM-*`; 119 REQ-6 and Q3 need the wording of C5, C7.
- Personal zone for the view; at most 20 workspaces, bounded fan-out; act-as refused.

### 11.3 Disagreements and how they were settled

| point | seats | settled as | why |
|---|---|---|---|
| Spans exist in 107 (mistral: "merge overlapping intervals" of `hours_entries`) | mistral vs the three claude | spans must be added (5.3) | `0151_hours.sql:45..56` has no start or end: checked |
| Where the overlap runs | mistral: client-side; claude x3: hub | hub (6.1), the WUI only for today's running timer, with a shared fixture | one implementation for phone, desktop and the warning |
| Write path | s118-claude, -2: the existing `PUT /v1/me/hours` per workspace with `X-Spool-Tenant`; -3: a realm route naming the workspace per row | `PUT /v1/me/realm/hours` (7.2), 107's write inside | `resolve.go:15..26`: `X-Spool-Tenant` names a box's tenant, a human's is the session's active one. -3 was right |
| Cross-workspace atomicity | mistral: roll back all if one refuses; claude x3: none | none (7.2) | each workspace is its own accounting record; a transaction across tenant scopes is what 119 forbids |
| One entry into several workspaces at once | mistral: multi-select, one write per picked workspace; claude x3: one row per workspace | one row per workspace, each picked by hand; a copy shortcut is Q4 | D2: no automatic duplication |
| Open timer | s118-claude: not counted until stopped; -2, -3: provisional in actual | provisional in actual, not in reported (6.3) | 2 of 3, and the D3 warning should come early |
| Reported includes open suggestions | s118-claude: approved only, open separately; -2, -3: approved + open, marked; mistral: approved only | approved + open, the open part shown | the person sees the week before approving; the open part stays visible, so the approved-only number is still read off |
| Spans table name | `hours_entry_spans` (-1, -2) vs `hours_intervals` (-3) | `hours_entry_spans` | 2 of 3, same shape |
| Receipt label for a topic target | -2: the target's display name; -1, -3: type only | type only (C5) | a topic subject is content (D4: no content) |
| Memberships read | s118-claude: a new query on `tenant_memberships`; -2: the existing `Memberships` | `Memberships` (5.2) | it is the one allow-listed operator read; no new one |
| Limit unit | -3 asked (O2); -1, -2: day and week, each optional | both, each optional (C3) | 2 of 3 answered the same |
| Mistral's owner questions: timer to several workspaces at once; marks per workspace or plain; leaver rows kept or fetched | mistral | one workspace per timer (7.4); the marks name the workspaces (8.1); copied (C5, D4) | answered by D2, D1 and D4 with the claude seats' detail |

### 11.4 Signatures of this fold

Each seat replied on `dispatch-cee5a73e` with "s118-<seat> signs <sha>" against the v1.0-rc fold `43f4fbd84`. v1.0 adds only the C4/C5 realm alignment agreed with the 119 editor (c-787), in section 13.

| seat | agent | signed sha |
|---|---|---|
| s118-claude | c-782 | `43f4fbd84` (the editor, who folded it) |
| s118-claude-2 | c-783 | `43f4fbd84` (msg `a15696a5`; withdrew its per-workspace PUT for 11.3's realm route) |
| s118-claude-3 | c-784 | signed by file (`reviews/s118-claude-3.md`, `8b09843ec`); the seat retired per its brief, and its position is folded in full (11.3). Recorded on c-001@sat's call (msg `5cbb13c0`) |
| s118-mistral | m-785 | `43f4fbd84` (msg `64663848`) |

## 12. Questions for the owner (one list, deduplicated from the four seats; the panel's recommendation first)

| # | question | options | from |
|---|---|---|---|
| **Q1** | Keep times of day: add `hours_entry_spans` to 107's store (5.3) and keep the timer's, plan's and clock's times, so D1 can compute actual and mark overlaps? | **A (recommended)**: yes, a 107 store change inside 118's build. B: no; D1 only where raw minutes still exist (the open period, <= 45 days), actual = reported on every frozen week. C: v2 day spans only (FR-32, one interval per workspace-day, coarse) | -1 (2.1), -2 OQ-1, -3 O6 |
| **Q2** | An entry **without times** (a typed number, old rows) when the person has 2+ workspaces | **A (recommended)**: allowed, counted as not overlapping, marked `≈`. B: the 118 screen requires start and end for every new entry (old rows as A) | -1 OQ2, -3 O1 |
| **Q3** | A **database-side member guard**: an `app.member_id` setting beside `app.tenant_id` and a `member_scope` policy on `hours_entries`, `hours_entry_spans`, `hours_minutes`, so a dropped `member_id` predicate still reads 0 foreign rows | **A (recommended)**: yes, with the 0098-shape tests. B: the route filter only, as 107 does today | -2 OQ-5 |
| **Q4** | An "**Also enter in …**" shortcut: copy a saved row's start and end into another workspace as a new row, its target picked there | **A (recommended)**: yes, one tap, a separate entry, never automatic. B: no, each row typed by hand | -1 OQ4, -2 4.4, -3 O4 |
| **Q5** | Do **receipts keep times of day** (spans), so a past overlap stays exact? | **A (recommended)**: no, minutes per day as D4 lists. B: yes | -1 OQ3, -2 OQ-3 |
| **Q6** | A receipt whose last period was **still open at leave time** | **A (recommended)**: refreshed once when that period freezes or is approved, then fixed. B: frozen at leave time | -1 OQ5, -2 C3 |
| **Q7** | A **deleted workspace** (the tenant delete cascades every `hours_*` row): do its members get receipts? | **A (recommended)**: yes, the delete copies receipts first. B: no, D4 covers leaving only | -3 O5 |
| **Q8** | How long the realm keeps the **approver's name** (another person's name) in a receipt | **A (recommended)**: the workspace's `hours.retention_years` at copy time (107 FR-34). B: as long as the receipt | -2 OQ-6 |
| **Q9** | A "standard" line in the personal view across workspaces | **A (recommended)**: none, only per workspace (REQ-3). B: also the sum of the workspaces' standard days as a reference line, with no warning | -2 OQ-2, mistral Q4 |
| **Q10** | A **personal download** (CSV of the person's own rows across workspaces, receipts included) | **A (recommended)**: not in the first version. B: yes, person-only | -2 OQ-4 |

## 13. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-10-10 | draft | REQ-1..4, owner decisions D1..D4, the realm pointer (footer read 0.5.0) |
| 1.0-rc | 2026-10-10 | c-782 (editor) | panel fold of s118-claude, -2, -3 and s118-mistral: REQ-1 and REQ-4 reworded; data model and RLS read (5), spans (5.3), overlap computation (6), multi-workspace entry (7), personal view (8), the 119 contract C1..C7 (9), tests (10), panel and consensus (11), owner questions Q1..Q10 (12); D1..D4 unchanged |

| 1.0 | 2026-10-10 | c-782 (editor) | signed by s118-claude, -2 and mistral on `43f4fbd84`, and -3 by file (11.4); the realm contract aligned with the 119 editor c-787 (msgs `1965e1cf`, `db70a9d1`): C4 `personal.profile.time_zone`; C5 `personal.hours_receipts` gets `workspace_id` (not `tenant_id`), `person_id` FK to `public.humans`, and an append-only `rev` (0 = leave copy, 1 = the one Q6-A refresh) in the PK; one endpoint name `/v1/me/realm/*`; 118 Q5..Q8 offered to 119 verbatim |

<!-- version: 1.0.0 · updated: 2026-10-10 · last-edit: 2026-10-10T08:50:00Z -->
