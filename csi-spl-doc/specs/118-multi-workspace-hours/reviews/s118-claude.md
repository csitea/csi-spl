signed against cdf9136c9

# Spec 118 review, seat s118-claude (c-782), also the panel's editor

Reviewed: `csi-spl-doc/specs/118-multi-workspace-hours/spec.md` at `cdf9136c9`
(36 lines, REQ-1..4, D1..D4, section 4 pointing to spec 119). Read against
spec 107 (`specs/107-hours-tracking/spec.md` v2.0-draft, sections 1, 3, 4, 6,
14) and spec 119 (`specs/119-personal-realm/spec.md` v0.1, at `7f6da1a7f`), and
the code on `origin/master` `77b835091`. D1..D4 are settled; nothing below
reopens them.

Facts from the code that the proposals rest on (each with its check):

- A person has ONE id across every workspace: `humans.human_id` (`HUM-<n>`,
  hub-wide, `0006_users_and_memberships.sql`), and `hours_*.member_id` is that
  same HUM-* (`grep -n member_id csi-spl-rdb/src/sql/postgres/spool-hub/0151_hours.sql`).
  No new person id is needed.
- The person's workspaces are `tenant_memberships (tenant_id, human_id)`,
  already listed by `GET /v1/auth/session` as `tenants`
  (`internal/auth/handler.go:558`), with `access_until` (rdb 0113).
- Every hours read today runs in ONE workspace's scope: `inTenant` sets
  `app.tenant_id` per transaction (`internal/store/rls.go:37`), the three
  `hours_*` tables are FORCE RLS with `tenant_scope` (0151:79..100).
- `hours_entries` stores **minutes per (day, target), no time of day**
  (0151:45..56). The time of day exists only in `hours_minutes` (one row per
  minute), which is **pruned at the freeze and at 45 days** (107 4.2), and in
  the timer's `{start, end}`, which is folded into minutes and not kept
  (107 1.5). This is the gap that decides proposal 2.2.

## 1. Verdict per requirement and decision

| item | verdict | one line |
|---|---|---|
| REQ-1 | **change** | "A tracked minute counts in one workspace only" contradicts the next sentence; write "A tracked minute counts **once within** a workspace; the same wall-clock minute may be entered in several workspaces." |
| REQ-2 | agree | The limit is the person's, on the cross-workspace total; foremen and time-accountants see only their workspace. Add: "the total used is the **actual** time (D3)". |
| REQ-3 | agree | Matches 107 FR-14 (per workspace, person override inside a workspace). Add: there is **no** cross-workspace standard day; the personal view shows each workspace's own. |
| REQ-4 | **missing** | No flow for entering into several workspaces, no rule for a partial failure. Proposal 2.4. |
| D1 | agree | Needs a time of day on every entry to compute "actual" (proposal 2.2); today's entries have none. |
| D2 | agree | No split. A copy action ("Also enter in …") is convenience, not a split: owner question OQ4. |
| D3 | agree | The warning is computed in the person's view only, never written to a workspace (proposal 2.3, test T-D3-2). |
| D4 | agree | "job/site label" exists only with 107 v2 jobs (FR-18); in v1 the label must not be a topic subject (content). Contract C4. |
| section 4 | **missing** | Names what lives in the realm but not what 118 needs from it. Proposal 2.6 is that contract. |
| status/version | **change** | Header says "Draft", footer says `version: 0.5.0`, the brief says v0.1: make them one value. |

## 2. Proposals

### 2.1 Data model and the cross-workspace read under RLS

**No new cross-workspace table, no copy of hours into the realm while the
person is a member.** The unified view is computed on read from each
workspace's own rows, each read in that workspace's own RLS scope, as the
person.

**The read path** (hub, one new realm route, contract C2):

1. Authenticate the human session (no `X-Spool-Tenant`: the realm route is
   not in a workspace). Refuse under act-as (spec 054) unless the owner
   decides otherwise (OQ6).
2. List the caller's live memberships: `tenant_memberships WHERE human_id =
   $caller AND (access_until IS NULL OR access_until > now())`, excluding a
   membership whose only role is `time_accountant` (107 FR-21: such a seat has
   no own hours). Cap: 20 workspaces per call, a 21st is reported as
   `truncated`, never silently dropped.
3. For each workspace, **sequentially**, one `inTenant(ws)` transaction
   calling the existing store reads with `member = $caller` (never `""`, the
   store's "every member", 107 6.3 privacy rule): entries, period rows, and
   the new spans (below). Sequential, not parallel: the hub pool is 8 and the
   DB `max_connections` 25; 20 short transactions in a row are within one
   request's budget, to be measured (T-PERF).
4. `app.person_id` (119) is **never set in the same transaction** as
   `app.tenant_id` (119 section 5 "never set together"): the realm reads
   (limit, zone, receipts) are their own transaction(s).
5. Merge in Go, compute proposal 2.2, answer. Nothing is written.

A per-workspace `inTenant` with `member = $caller` is what makes the read "as
the person": the RLS policy confines it to the workspace, the predicate to the
person, and the caller id comes only from the session, never from a parameter.
The route takes **no** `member=` parameter.

**The one new workspace table: `hours_entry_spans`** (in the 0098 / 0151
shape: `tenant_id` first, `ENABLE` + `FORCE ROW LEVEL SECURITY`,
`tenant_scope` with the `NULLIF(current_setting('app.tenant_id', true), '')`
guard, `operator_scope`). It keeps the time of day of an approved entry after
the freeze prunes `hours_minutes`.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | HUM-* |
| `day`, `target` | date, text | FK `(tenant_id, member_id, day, target)` -> `hours_entries`, cascade |
| `span` | tstzrange | `[start, end)`, whole minutes, `CHECK (NOT isempty(span))`, length <= 1440 min |
| `src` | text | `block` (a 107 suggestion block), `timer`, `plan`, `clock` (107 v2 FR-16/24), `manual` |

- `EXCLUDE USING gist (tenant_id WITH =, member_id WITH =, span WITH &&)`
  (needs `btree_gist`, available on Cloud SQL): **the database itself forbids
  double counting inside one workspace** (REQ-1), across targets too.
  Across workspaces there is no constraint, which is REQ-1's allowance.
- Written in the same transaction as the entry: at approval of a suggestion
  (its blocks, already computed by `spansJSON`, `hub/hours_me.go:367`), by the
  timer stop (its interval, split at local midnight as 107 1.5 does), by the
  v2 plan or clock (start..end minus the break).
- Sum rule: `sum(span minutes) <= hours_entries.minutes`. An edit **down**
  trims the latest spans first; an edit **up** (`+15`) leaves the excess
  **unplaced** (no time of day). A manual `+ Add` without a start time is
  wholly unplaced.
- Privacy (107 1.7): spans are served only to the member (`/v1/me/hours*`
  and the realm route), **never** to `hours.read` / `hours.approve` / the
  download. A foreman sees minutes, as today.
- Retention: deleted with the entry (cascade) and by 107 FR-34's sweep.
- Migration: one forward-only file, the next free number, DDL first and
  applied to dev and prd before any code reads it.

This reuses 107's model unchanged: `hours_entries` (what was decided),
`hours_periods` (freeze, approval, approver `decided_by`), `hours_minutes`
(raw, unchanged); only spans are added.

### 2.2 Reported vs actual: the overlap computation (D1)

A pure function in `internal/hours` (`Overlap(window, items) Result`), no
I/O, table-tested. It runs **in the hub's realm route**, the one authority;
the WUI draws its result and computes nothing (no TypeScript twin to drift).

Input: for the window `[from, to)` (a week or a month in the person's view
zone), per workspace, per entry: `minutes`, `state`, `spans[]`.

1. **Reported** = sum over workspaces of approved `hours_entries.minutes`
   (default; open suggestions shown as a separate "+ open" number, OQ1).
2. **Placed** = all spans of the counted entries, clipped to the window, as
   UTC instants. **Unplaced** = per entry `minutes - sum(spans)`.
3. **Sweep line**: sort the 2n endpoints (start +1, end -1, ends before starts
   on a tie, so `[09:00,10:00)` and `[10:00,11:00)` do not overlap); walk them
   keeping the depth and the set of open workspaces. **Actual placed** = time
   with depth >= 1; **overlap segments** = the intervals with depth >= 2, each
   with its workspace set. Inside one workspace depth is at most 1 (the
   EXCLUDE constraint), so depth = number of workspaces. O(n log n).
4. **Actual** = actual placed + sum(unplaced). Unplaced minutes are assumed
   **not** to overlap (an upper bound), and the day shows `≈` when it has any:
   the person is never shown a lower number than the truth may be. OQ2 asks
   whether to require a start time instead.
5. **Overlap minutes** = reported placed - actual placed (the minutes counted
   twice or more). Reported - actual = overlap when nothing is unplaced.

Edge cases:

- **Time zones.** Each workspace's day comes from the membership's zone
  (107 1.6), which may differ per workspace. Overlap is computed on UTC
  instants, never on civil days. The personal view buckets by the **realm's
  view zone** (C3; default: the browser's). A span over the view zone's
  midnight is split for display only. An unplaced entry keeps its workspace's
  civil date (it has no instant to move).
- **Entries over midnight.** Already split at the member's local midnight by
  107 (1.6, the timer in 1.5); two adjacent spans `[23:00,00:00)` +
  `[00:00,01:00)` join in the sweep, with no false overlap (tie rule).
- **Open timer.** It lives in the device's localStorage per workspace (107
  1.5) and the hub never sees it. The view shows it as a separate line
  "running 0:42 in <workspace>", **not** in reported or actual until stopped.
  No hub change, no leak of a running timer.
- **Edits after approval.** Before the freeze the entry changes and the next
  read shows it (computed on read, nothing cached). A frozen or approved
  period cannot change (107 4.2). A returned period can: the view is current
  on the next read. The view never stores a total, so it is never stale.
- **Rejected rows** count 0 and are excluded. **A day above 1440** is
  impossible per workspace (107 3.2); the cross-workspace reported total may
  exceed 24 h, which is exactly D1's case and is shown, not refused.
- **A workspace that fails to read** (store error, timeout): the result
  carries `{workspace, error}`, its numbers are absent, the totals are marked
  `partial`. Never a silent zero.
- **Left workspaces**: receipts (C4) count in reported and, having no spans
  unless OQ3 says so, as unplaced in actual.

Output per day: `reported`, `actual`, `approx` (bool), `overlap_minutes`,
`overlap[]` (`{start, end, workspaces[]}`), per workspace `{minutes, open,
state}`; per window the same totals plus the limit state (2.3).

### 2.3 UI of the personal view

Lives in the realm (119), reached from the user menu **"My hours"**, and from
the calendar's hours panel Mine tab as a link "All workspaces" when the person
has 2+ workspaces (107 5.4). Lazy chunk, nothing in the initial bundle.

Desktop (> 820 px):

```
 My hours · all workspaces                    Week 41   < >   [Week|Month]
 ┌──────────────────────────────────────────────────────────────────────┐
 │ Reported 46:30   Actual 41:00   Overlap 5:30   Limit 45:00 ✓         │
 └──────────────────────────────────────────────────────────────────────┘
            Mon     Tue     Wed     Thu     Fri     Sat  Sun
 Acme       8:00    8:00    4:00    8:00    6:30     -    -    34:30  std 8:00
 Beta       4:00    -       4:00    -       4:00     -    -    12:00  std 4:00
 ─────────────────────────────────────────────────────────────────────
 Reported  12:00    8:00    8:00    8:00   10:30               46:30
 Actual    10:00    8:00    8:00    8:00    7:00≈              41:00
 Overlap   ▒2:00                            ▒3:30               5:30
```

- One row per workspace (name, its standard day), one column per day; the
  three total rows **Reported**, **Actual**, **Overlap** (D1). An overlap
  cell is hatched in the one accent colour; its tap/hover lists the
  overlapping intervals and their workspaces ("09:00-11:00 Acme + Beta").
- A day's cell opens the day: a 24 h timeline with one lane per workspace and
  the overlap bands across lanes, plus the unplaced minutes as a separate
  chip ("0:30 without a time").
- Per-workspace state per cell: open dot, approved, frozen lock, Final (the
  107 5.1 marks, same glyphs). A left workspace's row reads "left · receipt".
- **Limit (D3)**: the header shows `Limit 45:00 ✓` or `⚠ 2:30 over`
  against **actual**, from the person's limit (C3), daily and/or weekly as
  set. Shown nowhere else; no workspace screen ever shows it.
- `≈` on any total with unplaced minutes, with the one-line why.
- A `partial` banner when a workspace failed to read, naming it, with Retry.

Phone (<= 820 px, 390 px): no grid. A week strip with one card per day:
Reported / Actual / Overlap and the per-workspace minutes as chips; the
header card carries the week totals and the limit state; a day card opens the
day sheet (the 106 sheet pattern) with the lanes stacked vertically. No
sideways scroll, controls 44..48 px (the 106 rules).

### 2.4 Entering hours into several workspaces from one screen (REQ-4)

- **Where**: the day sheet / day timeline of 2.3, button **+ Add**.
- **Pick the workspace first**: a segmented control of the person's live
  workspaces (the last one used preselected, else the order of the session's
  `tenants`). Then the existing `HoursTargetPicker.vue` (107 5.3) **scoped to
  that workspace**: its search calls carry that workspace's
  `X-Spool-Tenant`, so a target from Acme is never offered for Beta.
- **Time**: start and end (default: from the end of the day's last span,
  30 min), or "minutes only" (unplaced, shows `≈`). The overlap with other
  workspaces shows live while editing ("overlaps Beta 09:00-10:00"),
  informational only (D2: allowed). An overlap within the **same** workspace
  is refused before save; the EXCLUDE constraint is the backstop (409
  `hours_overlap`).
- **Edit / approve existing rows** of any workspace from the same timeline:
  the actions of 107 5.2 (approve day, +15, reject, note), each addressed to
  its own workspace.
- **Save**: the WUI groups the dirty rows by workspace and sends **one
  existing `PUT /v1/me/hours` per workspace** with that workspace's
  `X-Spool-Tenant` (the route, its RBAC `self.keys`, its 409
  `period_frozen`, its 1440 cap, all unchanged), plus `spans[]` on each entry
  (a new optional field). Sequential, in the order shown. **Not atomic across
  workspaces, by design**: each workspace is its own accounting record (REQ-1).
- **A workspace refuses** (409 `period_frozen`, 409 `hours_overlap`, 403
  membership gone, 5xx): its rows stay dirty with the reason on each row
  ("Beta: week 41 is frozen"); the other workspaces' rows are saved and show
  saved. A banner "Saved in Acme · not saved in Beta [Retry]". Retry resends
  only the failed workspace; the writes are `ON CONFLICT` upserts (107 3.2),
  so a retry after a lost answer is idempotent.
- **Timer**: Start in the realm view asks the workspace, then the target, and
  stores the running timer under that workspace's localStorage key (107 1.5),
  so the workspace's own header shows it too; Stop posts to that workspace's
  `POST /v1/me/hours/timer`.

### 2.5 Tests (each names the REQ/D it proves)

Store / Postgres (`PRE_PUSH_TIER=full`, as the runtime RLS role, never a
superuser):

- **T-RLS-1** (REQ-1, privacy): person P in Acme and Beta, person Q in Acme:
  the realm read for P returns only P's rows of Acme and Beta, never Q's.
- **T-RLS-2** (non-member): P is not in Gamma, Gamma holds rows with
  `member_id = P` (seeded as operator): the realm read never returns Gamma.
- **T-RLS-3** (left / expired): P's Beta membership has `access_until` in the
  past: no live Beta rows, only the receipt (C4).
- **T-RLS-4** (scopes apart): a trace of the realm route shows no
  transaction that sets both `app.tenant_id` and `app.person_id`.
- **T-RLS-5** (red control): the same read with the `member_id` predicate
  removed returns Q's rows: proves T-RLS-1 can fail.
- **T-SPAN-1** (REQ-1 within): two spans of P in Acme overlapping, across two
  targets: the second insert fails on the EXCLUDE constraint.
- **T-SPAN-2** (REQ-1 across): the same span in Acme and in Beta: both saved.
- **T-SPAN-3** (privacy): `GET /v1/hours` and the export, as `hours.read`,
  carry no span field (a key-set assertion plus a planted-span control).

Pure function (`internal/hours`, table tests):

- **T-OV-1..8** (D1): no overlap; full overlap of two; three workspaces at
  depth 3; touching intervals `[a,b)+[b,c)` = no overlap; a span over
  midnight in the view zone; two workspaces in different zones; unplaced
  minutes give `approx` and actual = placed + unplaced; a rejected row
  counts 0.
- **T-OV-9** (D2): one hour entered in two workspaces: reported 2:00, actual
  1:00, overlap 1:00, no split anywhere in the output.

Hub routes:

- **T-REQ2-1** (REQ-2, D3): the limit state uses actual, not reported:
  reported 46:30 / actual 41:00 / limit 45:00 = not over.
- **T-D3-1** (D3, foreman): as P's foreman in Acme (`hours.read` +
  `hours.approve`), every Acme route (`GET /v1/hours`, export, periods) holds
  no cross-workspace total, no Beta minute and no limit field (key-set
  assertion); and the realm route refuses any `member=` parameter.
- **T-D3-2** (nothing flows down): after P sets a limit and exceeds it, no row
  in any workspace table changed (row count and `max(updated_at)` per table).
- **T-REQ3-1** (REQ-3): Acme 480, Beta 240 standard day: the view shows each
  workspace's own; no cross-workspace standard day field exists.
- **T-REQ4-1** (REQ-4): one save with rows for Acme and Beta writes each
  entry in its own workspace (read back with `inTenant` per workspace).
- **T-REQ4-2** (REQ-4 partial): Beta's period frozen: Acme saved, Beta 409,
  Acme untouched by the Beta failure; after a Return, the retry saves Beta
  once (idempotent).
- **T-REQ4-3** (picker scope): the target search for Beta never returns an
  Acme topic.
- **T-D4-1** (D4): P leaves Beta: the receipt holds days, minutes, workspace
  name, label, period state and approver; it holds no topic subject, message,
  channel name or content target id (key-set assertion plus a content control).
- **T-ACTAS-1**: under act-as (spec 054) the realm route answers 403 (or
  logs, per OQ6).

WUI (e2e on the generated bundle, phone 390 px and desktop):

- **T-UI-1** (D1): the three totals and a hatched overlap cell for a seeded
  overlap; its detail names both workspaces.
- **T-UI-2** (D3): the limit warning shows in My hours and in **no** workspace
  view (calendar, hours panel Mine/Team), asserted by text and testid absence
  with a positive control.
- **T-UI-3** (REQ-4): add a row for Beta from the realm view, save, see it in
  Beta's own calendar Working hours line.
- **T-UI-4**: the realm chunk is lazy: `perf-budget.py` initial chunk
  unchanged.
- **T-PERF**: the realm route with 20 workspaces x a month, timed on dev, n
  recorded; the budget is set from the measurement, not guessed.

### 2.6 The contract 118 needs from the personal realm (spec 119)

- **C1 identity**: the realm's person is `humans.human_id`; `app.person_id`
  = that HUM-*. No second person id (119 REQ-1's profile hangs off it).
- **C2 route home**: `GET /v1/me/realm/hours?from=&to=&zone=` (the name to
  align with 119) lives in the realm's route group: no `X-Spool-Tenant`,
  session only, no `member=` parameter. Its body is 2.1 / 2.2; 119 owns the
  group's auth and act-as policy.
- **C3 settings** (119 REQ-3, schema `personal`): `hours_limit`
  `{daily_minutes?: 0..1440, weekly_minutes?: 0..10080}` and
  `hours_view_zone` (IANA, null = the browser's). Read only by the person,
  never joined into a workspace transaction.
- **C4 receipts** (D4, 119 REQ-4/5): at leave (membership removed or
  `access_until` passed), the hub copies, per (workspace, day): minutes,
  period state, approver display name (from `hours_periods.decided_by`),
  workspace name, and the label = the 107 v2 **job name / site** when the
  target is a `job:`, else only the **target kind** (`topic`, `channel`,
  `meeting`, `other`), never a topic subject or channel name (content,
  D4 / 119 REQ-5). Copy first, then remove the membership; idempotent (keyed
  `(person, workspace, day, label)`); two transactions (scopes apart); a
  failed copy holds the leave and is retried: never a leaver with no receipt.
  `access_until` passing removes nothing by itself, so its copy runs in the
  sweep that notices it.
- **C5 receipts in the view**: the realm route reads receipts for left
  workspaces in the realm transaction and merges them (2.2 "left").
- **C6 nothing flows down** (119 REQ-6): no realm value (limit, totals,
  warnings, zone) is ever written into a workspace table; test T-D3-2.

Contradictions and loose ends for the fold:

- **119 Q3 (B)** says the job/site label is "as defined in Spec 118"; 118
  does not define it, 107 v2 FR-18 does (jobs). C4 settles the v1 case.
- **119 section 5** "Receipts are strict COPIES ... no FK into workspace
  data" agrees with C4; "operator access is strictly logged" needs the
  act-as decision (OQ6).
- **107 FR-37** delegates cross-workspace tracking here: consistent.
  **107 1.1 rule 5** ("a minute is never counted twice") is within one
  workspace: consistent with REQ-1 once REQ-1's wording is fixed.
- **107 6.1 / 1.7**: spans are a raw signal; 118 must not widen what
  `hours.read` sees (T-SPAN-3).

## 3. Owner questions (not decided here; the seat's recommendation first)

- **OQ1** "Reported" counts: A) approved entries only, open suggestions as a
  separate "+ open" number (recommended); B) approved + open in one number.
- **OQ2** An entry with no time of day (manual minutes) when the person has 2+
  workspaces: A) allowed, counted as not overlapping, the total marked `≈`
  (recommended); B) a start time is required.
- **OQ3** Receipts keep the time of day (spans) so a past overlap stays
  exact: A) no, minutes per day only, as D4 lists (recommended); B) yes.
- **OQ4** An "Also enter in …" action that copies one row to another
  workspace (not a split, D2): A) yes, one tap, the copy is a separate entry
  (recommended); B) no, each workspace is entered by hand.
- **OQ5** A receipt after leave when the workspace later approves or returns
  that period: A) frozen at leave time, its state as then (recommended:
  nothing flows after leave); B) refreshed once at the period's final approval.
- **OQ6** Operator act-as (spec 054) on the realm routes: A) refused, 403
  (recommended: a person-only view); B) allowed and logged.

<!-- last-edit: 2026-10-10T12:00:00Z -->
