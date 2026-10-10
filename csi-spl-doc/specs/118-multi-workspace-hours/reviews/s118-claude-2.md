signed against cdf9136c9

# Spec 118 review: seat s118-claude-2

**Reviewed**: `csi-spl-doc/specs/118-multi-workspace-hours/spec.md` at `cdf9136c9` (the brief calls it v0.1; its footer reads `version: 0.5.0`). `git log origin/master -- csi-spl-doc/specs/118-multi-workspace-hours` -> one commit, `cdf9136c9`: nothing changed since.
**Read beside it**: spec 107 at origin/master (v2.0-draft, sections 1.1, 1.3, 1.6, 1.7, 3.2, 4, 6.3, 14.1 FR-37, 14.10 FR-32, 16 Q8), spec 119 v0.1 (`7f6da1a7f`), and the hub code: `internal/store/rls.go` (`inTenant`), `internal/store/memberships.go` (`Memberships`), `internal/store/hours_postgres.go` (`HoursEntries`, `PutHoursEntries`).
**Seat**: claude, one of the panel. Owner decisions D1..D4 are settled; nothing below reopens them.

## 0. The one finding that shapes everything else

**Spec 107 stores durations, not times of day, so D1's "actual time" cannot be computed from what 107 keeps.**

- `hours_entries` (107 section 3.2) is one row per `(tenant_id, member_id, day, target)` holding `minutes`. It has no start or end.
- The only exact-minute record, `hours_minutes`, is pruned **when the period freezes, and after 45 days at most** (107 section 1.7). `grep -n "hours_minutes" csi-spl-api/src/go/spool-hub-api/internal/store/hours_postgres.go` shows the upsert and the range read; nothing else keeps the minute.
- The header timer (`POST /v1/me/hours/timer`, 107 section 6.3) has `{start, end}`, but it is folded into the day's `minutes` and the times are dropped.
- v2's day record (FR-32) keeps one start, one end and a break per (member, day). That is a span for the day, not per entry, and it is still a draft.

Overlap is a property of **intervals**. Without spans, "actual" for any frozen week is the reported sum, and the D1 overlap mark is empty exactly where an invoice needs it. Proposal 1.3 below adds spans to 107's model. That is a change to **107's tables**, so it goes to 107's lane as a change request, not into a 118 migration alone.

## 1. Per requirement and decision

| item | verdict | one line |
|---|---|---|
| REQ-1 | **change** | The wording contradicts itself ("a tracked minute counts in one workspace only. However, ... the same minute may count in multiple"). Say: "within one workspace a minute counts once (107 1.1 rule 5); across workspaces the same minute may count in each". Add: "within one workspace, two entries whose spans overlap are refused" (today only the 1440-minute day cap exists). |
| REQ-2 | **agree** | Missing: say the per-workspace overtime flag of 107 FR-28 stays as it is. It is a workspace's own threshold, not the cross-workspace limit, so a foreman still sees overtime inside their workspace. |
| REQ-3 | **agree** | Cite 107 FR-14 (`hours.standard_day_minutes` plus the person's override). Missing: what the personal view shows as "standard" across workspaces (owner question OQ-2). |
| REQ-4 | **agree, missing detail** | No flow, no target picker, no error rule for a partial save. Proposal 4. |
| D1 | **agree** | Not buildable on 107's data as it stands (section 0). Needs spans (proposal 1.3) and the algorithm in proposal 2. |
| D2 | **agree** | Consequence to state: entering the same hour in two workspaces is two separate writes the person makes. The optional "also enter in..." shortcut (4.4) copies only on a tap, never by itself. |
| D3 | **agree** | Missing: where the limit lives (the realm, contract C2), and that the warning is computed on read and never stored, sent or pushed. |
| D4 | **agree** | Contradiction with 119 Q3: 119's option B leaves out the **approval state** and the **approver** that D4 lists. 119 must take D4's list as given. Missing: when the receipt is taken if the last period is not final at leave time (107 Q8 is open). See C3. |
| section 4 (realm pointer) | **agree, missing contract** | 118 has to say what it needs from 119. Contract C1..C5 below. |

## 2. Contradictions and gaps against 107 and 119

1. **107 keeps no spans** (section 0). This blocks D1.
2. **119 Q3 against 118 D4**: approval state and approver are missing from 119's recommended receipt. D4 is settled, so 119 should align.
3. **119 Q3 "job/site label (as defined in Spec 118)"**: 118 defines no job. The label is 107 FR-18's job `name` plus `site`, or the target's display name for v1 targets (`t:`, `ch:`, `cal:`, `ws`). 119 should cite 107 FR-18.
4. **119 REQ-6 "data must not flow from the personal realm into workspaces"** read literally forbids REQ-4: entering hours from the realm screen writes into workspaces. Proposed wording for 119: "no realm data is copied into a workspace; the person's own entries are written through the workspace's own routes, in that workspace's scope, exactly as from inside the workspace".
5. **119 `app.person_id`** has no stated relation to the hub's identity. Hours rows key on `member_id` = the hub-wide `HUM-*` human id (107 section 3.2; `humans` and `human_identities` are hub-wide, see `internal/store/human_keys.go:12`). 119 should say `person_id = humans.human_id`. A second id means a mapping table and a new place to leak.
6. **107 section 1.7** says only `/v1/me/hours*` serves raw minutes and unapproved suggestions, and a test pins `hours_minutes` to the hours store file. The 118 read must go through the existing store functions (`HoursEntries`, `HoursMinutes`) and add no SQL on those tables elsewhere. Then the test stays green unchanged.
7. **107 section 1.7, "RLS separates workspaces, not members"**: in a workspace table the database does not enforce "the person's own rows". The route's `member_id = caller` filter does. 118's promise "as the person" therefore rests on the route filter, as 107's does. Proposal 1.2 adds a database-side guard as an option.

## 3. Proposals

### 1. Data model: the cross-workspace read, as the person

**1.1 Which workspaces.** The list is the caller's live memberships: `Memberships(ctx, humanID)` (`internal/store/memberships.go:111`). This is the one existing operator-scoped read. It reads `tenant_memberships` for this one human, already leaves out a membership past `access_until` (rdb 0113), and is on the `TestOperatorScopeCallers` allow-list. It reads **membership rows, never hours**. 118 adds **no new operator-scoped read**. Agents (`AGT-*`) and a time-accountant-only seat (107 FR-21) have no personal hours view.

**1.2 Each workspace, in its own scope.** For each membership, one `inTenant(ctx, tenant, ...)` transaction (`rls.go:37`, `app.tenant_id` set transaction-local) runs the existing reads with `member = caller`:
- `HoursEntries(tenant, caller, from, to)` -> entries and their spans (1.3);
- `HoursPeriods(tenant, caller, from, to)` -> period state per day;
- `HoursMinutes(tenant, caller, from, to)` -> open, unapproved suggestions only, for the "today so far" line.

Rules:
- One workspace per transaction. A workspace scope and the realm scope are **never set in the same transaction** (119 section 5). The realm read (the limit, C2) is its own transaction.
- Sequential, or at most 2 at a time. The hub pool is 8 connections on a `db-f1-micro` with `max_connections` 25, and one person with 6 workspaces must not hold 6.
- The range is capped at 62 days per call, so a month view plus a neighbour fits.
- A failed workspace read returns that workspace as `{"state":"unavailable"}` and the rest of the view still renders. It never fails the whole view, and it is never retried under a broader scope.
- **Optional database guard** (owner question OQ-5): an `app.member_id` setting put next to `app.tenant_id` on these reads, and a `member_scope` policy on `hours_minutes` and `hours_entries`: `member_id = NULLIF(current_setting('app.member_id', true), '')` when that setting is present. Then a store bug that drops the `member_id` predicate still reads zero foreign rows. It costs one policy per table and the 0098-shape tests.

**1.3 Spans: the change request to 107.** A new table in the 107 section 3.2 shape (`tenant_id` first, `ENABLE` + `FORCE ROW LEVEL SECURITY`, `tenant_scope` with the `NULLIF` guard, `operator_scope`):

`hours_entry_spans`

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | `HUM-*` |
| `day` | date | the entry's day (FK to `hours_entries (tenant_id, member_id, day, target)`, cascade) |
| `target` | text | as the entry |
| `start_at` | timestamptz | `CHECK (start_at = date_trunc('minute', start_at))` |
| `end_at` | timestamptz | `CHECK (end_at > start_at)`, same minute truncation |
| `src` | text | `activity`, `timer`, `plan`, `clock`, `manual` |

PK `(tenant_id, member_id, start_at)`. An exclusion constraint `EXCLUDE USING gist (tenant_id WITH =, member_id WITH =, tstzrange(start_at, end_at) WITH &&)` (needs `btree_gist`) makes **double counting within one workspace impossible in the database** (REQ-1). Another seat may prefer a check in the store over a new extension; either is fine as long as a test proves the refusal.

Written when an entry is approved, from:
- the blocks of `hours_minutes` that make up that target's minutes (107 section 5.2 already shows them as `09:12-10:40`);
- a stopped timer's `{start, end}`;
- v2's plan or clock (FR-16, FR-24);
- spans the person types in the 118 entry screen (proposal 4).

They survive the freeze and the `hours_minutes` prune, and they follow 107's retention (FR-34).

**Placement rule when minutes and spans disagree** (an entry edited by minutes only):
- `placed = min(minutes, total span length)`. Spans are taken from the earliest one onward, and the last one used is cut short.
- `unplaced = minutes - placed`.
- A duration-only entry (no span, e.g. a pre-118 row or an absence) is entirely `unplaced`.

Nothing in 107's workspace views changes. Spans are read only by the member's own routes and by 118. They stay out of the `hours.read` team view and the export, which 107 owns (it decides whether to show start and end there).

### 2. Reported against actual: the overlap computation (D1)

**2.1 Where it runs.** In the hub, as one pure Go function (proposed home `internal/hours/overlap`) called by the personal-view route (C1). It gets the per-workspace rows from 1.2 and returns per day: `reported`, `actual`, `overlap`, `unplaced`, the overlap intervals with the workspaces involved, and per workspace `minutes` and `state`. **Nothing is stored**: not in the workspaces, not in the realm. Every read recomputes, so an edit, a return or a resubmit shows on the next read. The WUI adds only the live open timer (2.3) and does no other arithmetic.

**2.2 Algorithm** (per day `d` in the person's zone `Z`, see 2.3):
1. For each workspace `w`, take every span `[start_at, end_at)` of its entries, clipped to `[d 00:00 Z, d+1 00:00 Z)`.
2. Within each `w`, merge its spans into a union. With the 1.3 constraint they never overlap. Any overlap found here is counted as `data_error_minutes` and logged, never hidden.
3. Sweep line over the endpoints of all workspaces' unions, sorted (an end sorts before a start at the same instant, so `[9,10)` and `[10,11)` do not overlap). Keep a set of active workspaces. Each stretch where the set has 2 or more members is an **overlap interval**, tagged with that set.
4. `reported(d) = Σ_w minutes_w(d)`: the entries' `minutes`, approved plus open suggestions, each shown with its state.
5. `actual(d) = |⋃_w spans_w(d)| + Σ_w unplaced_w(d)`.
6. `overlap(d) = reported(d) - actual(d)`. It is 0 when nothing overlaps, so the two numbers say so.
7. A week is the sum of its days. It is never a union of the week's spans, which would give the same result but in a second code path.

**Unplaced minutes count as not overlapping.** So `actual` is an **upper bound** whenever `unplaced > 0`, and the view says so ("2:00 without times, overlap not checked"). This is honest. Guessing a time of day for an unplaced minute would put a false mark on an invoice.

Cost: O(k log k) for k spans in the range. A heavy month is about 6 workspaces x 22 days x 6 spans, under 1,000.

**2.3 Edge cases.**

| case | rule |
|---|---|
| **open timer** | It is client state until stopped (107 1.5, Q7 = B). The WUI adds `[start, now)` as a provisional span of its workspace, recomputes overlap for today live, and marks it "running". It is never sent until the stop, which then writes its span (1.3). Two timers running in two workspaces at once are allowed (D2) and show as a live overlap. |
| **entry across midnight** | Spans are absolute (`timestamptz`), so the personal view splits them at the person's midnight (step 1). The workspace's own entry stays on its own day: 107 1.6 already splits a block at the member's midnight in that workspace. |
| **time zones** | The personal view uses **one zone**: the realm profile's zone (C4), else the zone the WUI sends. Workspaces can each have their own member zone (rdb 0078 `time_zone`). So one span can fall on Monday in workspace A's day and on Tuesday in the personal view. The view shows the workspace's own day as a secondary label ("A: Mon"). Unplaced minutes have no instant and are drawn on the workspace's own date. |
| **DST** | Lengths are `end_at - start_at` in absolute minutes. A 23 h or 25 h day is just that. 107's 1440-minute day cap is per workspace and is untouched here. |
| **edits after approval** | 107 freezes approved periods. Return and resubmit reopen them, and 2.1 recomputes on read. Receipts (C3) are snapshots and do not change. |
| **leaver** | A workspace with no live membership comes from the receipts (C3), with `unplaced` only unless OQ-3 keeps spans in receipts. |
| **suggestions not approved** | They count in `reported`, marked "open", so the person sees the week before approving. They have no span yet, so they count as unplaced, except today's raw `hours_minutes` blocks, which give provisional spans. |
| **within-workspace overlap in old data** | `data_error_minutes` on that day, shown to the person as a fix-me marker, and an alarm in the log. |

### 3. UI of the personal view

Hosted by the realm (C1). Route proposal `/me/time`, loaded lazily as its own chunk: nothing in the 160 KB initial chunk (`perf-budget.py`). Entry points: the person menu, and a "All my workspaces" link in each workspace's Working hours dialog (107 5.2), which only links and shows no cross-workspace number inside the workspace.

**Desktop: one week.**
- A header with two big numbers, **Reported 46:30** and **Actual 41:00**, and the difference as **5:30 counted in more than one workspace**. If `unplaced > 0`, a muted note: "3:00 without times, not checked".
- Under it, a limit bar if a limit is set (D3): "Actual 41:00 of your 40:00 week". It turns amber at 90 % and red past 100 %. Text, not colour alone.
- One row per day. Columns: one per workspace (its name and colour chip; the cell shows its minutes and a state icon: open, approved, frozen, final, returned), then Reported, Actual, Overlap.
- Under each row, a **timeline strip**: 00..24 with one lane per workspace that had spans that day. Overlap intervals are **hatched** across the lanes involved, with a tooltip "10:00-11:30 in A and B". Unplaced minutes show as a grey stub at the end of the lane: "1:00, no times".
- Navigation: week, previous, next, today. A month toggle shows a calendar grid with Reported, Actual and an overlap dot per day.

**Phone.**
- The two numbers on top, then the limit bar, then one card per day: "Mon · actual 8:30 · reported 10:00 · 1:30 overlap" with workspace chips.
- Tapping a day opens a sheet with the timeline as vertical stacked lanes and the per-workspace rows, each with **Edit**, which opens proposal 4 prefilled.
- Targets are at least 44 px. The week swipes left and right.

**Shared.**
- Only the person ever sees this page. There is no share, export or print to a workspace. A **personal CSV download** (own rows, all workspaces) is useful for the person's own records: owner question OQ-4.
- A workspace that failed to load (1.2) shows a grey column: "A could not be read, retry". Its minutes are not guessed.
- An empty state for 0 or 1 workspace: with one workspace the page still works, and Reported equals Actual.

### 4. Entering hours into several workspaces from one screen (REQ-4)

**4.1 The screen.** "Add time" on `/me/time` (a day sheet on the phone, a dialog on desktop). Each row has:
1. **Workspace**: chips of the person's live memberships where the person can enter hours (not a time-accountant-only seat, 107 FR-21). Default: the workspace of the row above, else the last used, else the workspace the person came from.
2. **Target**: the picker is **scoped to that workspace**. Its topics, channels, meetings, jobs (FR-18) and "other" come from that workspace's existing reads under its own `X-Spool-Tenant`. Changing the workspace clears the target. A target from workspace A is never offered in B.
3. **Time**: start and end (preferred; it creates a span) or a duration only (then it is unplaced, as 1.3 says).
4. **Note** (optional, 500 characters, 107 5.2).

While typing, the strip from 3 updates live and marks a new overlap **with another workspace** as information ("also in B 10:00-11:00"). An overlap **within the same workspace** is an inline error, and Save stays disabled for that row (REQ-1).

**4.2 Save.**
- Rows are grouped by workspace. Each group is **one** `PUT /v1/me/hours` with that workspace's `X-Spool-Tenant`, carrying an operation id (107 FR-35 idempotent replay), and runs in that workspace's own transaction.
- Groups are sent one after another. **There is no cross-workspace atomicity and the screen says so**: it would need a transaction across tenant scopes, which 119 forbids and the hub does not have.
- The server checks each group exactly as from inside the workspace: freeze (409 `period_frozen`), day cap 1440, spans not overlapping within the workspace (proposed 409 `span_overlap`), membership live, and the target belonging to that workspace.

**4.3 When one workspace refuses.**
- Rows that saved turn to their state (approved or open). Refused rows **stay in the form, dirty**, with the reason in the person's language:
  - `period_frozen`: "Week 41 in B is closed. Ask B's approver to return it."
  - `span_overlap`: "Overlaps your 10:00-11:00 in B."
  - 403: "You are no longer a member of B."
  - network: "Saved on this device; will send when online", using FR-35's queue.
- A summary banner: "Saved in A and C. 1 row not saved in B. [Retry B]".
- Nothing is rolled back in A when B refuses. The rows were independent from the start (D2).

**4.4 "Also enter in..." (D2 helper, optional).** On a saved row: copy the same start and end into another workspace as a **new** row, with the target picked fresh there. This is the person's explicit, one-tap version of D2. There is never an automatic copy, and never a split (D2 says no split).

**4.5 Editing.** Edit from the personal view opens the same form on that row. The workspace cannot be changed on an existing row: moving an hour between workspaces is delete in A plus add in B, two writes, both visible.

### 5. Tests

Store tests run on Postgres (`PRE_PUSH_TIER=full`), as for 107's `hours_rls_test.go`.

**REQ-1 and D2**
- T1: two overlapping spans for the same person in **one** workspace are refused, by the database constraint or the store check (a red control: drop the constraint and the test fails).
- T2: the same span entered in workspaces A and B is accepted in both, and each workspace's own `GET /v1/me/hours` shows exactly its own row.
- T3: there is no route or field that splits one entry across workspaces. A grep test on the route table finds no `split`.

**D1 (the overlap function, pure unit tests, table-driven)**
- T4: disjoint spans give `actual = reported`, overlap 0.
- T5: full overlap of 1 h in A and B gives reported 2:00, actual 1:00, overlap 1:00, interval tagged {A, B}.
- T6: touching spans `[9,10)` and `[10,11)` give no overlap.
- T7: three workspaces in a partial chain give the correct union.
- T8: a span across midnight in `Europe/Helsinki` splits at local midnight, and the two days add up to the span length.
- T9: a DST day (the last Sunday of March and of October, Europe zones) has correct lengths.
- T10: workspace zone UTC, personal zone UTC+3: the span lands on the personal day, and the workspace day label shows.
- T11: an entry edited from 2:00 to 1:30 with a 2:00 span: placed 1:30 from the earliest span, unplaced 0. Edited to 2:30: placed 2:00, unplaced 0:30, and the "not checked" note is set.
- T12: an open timer in the WUI (component test): a live overlap with a stopped entry in B appears and grows, and no request is sent until stop.
- T13: return, resubmit with new minutes: the next read reflects it, and nothing was stored by 118 (assert no new rows in any 118-owned table, because there are none).

**D1, D3: personal only**
- T14: every workspace route (`/v1/hours*`, `/v1/me/hours*` with `X-Spool-Tenant`) answers with that workspace's rows only. A fixture person in A and B with overlap: no response under A contains B's id, name, minutes or an overlap number (a field-level grep of the JSON).
- T15: a **foreman** (crew-scoped `hours.approve`, FR-22) and a `hours.read` holder in A, reading the person: they get A's approved rows only, never `actual`, `overlap`, the limit or anything from B.
- T16: the limit is stored only in the realm table (C2). No workspace table, no `member_activity` row, no Web Push, and no log line carries it or the warning (assert on the store calls and the push stub).

**RLS negatives**
- T17: person P calls the personal view: workspaces where P is not a member are absent, even when another person's spans overlap P's in time.
- T18: person P never reads person Q's rows in a shared workspace. A store-level test calls the 118 read path with a crafted member id and gets an error or 0 rows (with OQ-5, the database policy alone refuses; red control: unset `app.member_id`).
- T19: a membership past `access_until` is not read live. It appears only through receipts (C3).
- T20: an agent (`AGT-*`) and a time-accountant-only seat get 404 or 403 on the personal view.
- T21: `TestOperatorScopeCallers`: the 118 code adds no operator-scoped caller.
- T22: 107's 1.7 grep test stays green: `hours_minutes` appears only in the hours store file and the post upsert.

**REQ-2, REQ-3**
- T23: 8 h standard in A and 4 h in B (FR-14) are both shown per workspace. The personal view applies neither to the other.
- T24: a person-set weekly limit of 40:00 with actual 41:00 shows the red bar, with reported 46:30 and overlap 5:30. A limit of 45:00 with reported 46:30 and actual 41:00 shows **no** warning (actual, not reported: D3).

**REQ-4**
- T25: one save with rows for A and B sends two PUTs, each with its own tenant header, and both land in their own workspaces.
- T26: B's week is frozen: A's rows save, B's rows stay dirty with `period_frozen`, the banner says "1 row not saved in B", and A is not rolled back.
- T27: the target picker for workspace B never lists a target from A (component test plus a server-side refusal of a foreign target, 422).
- T28: offline save queues both groups and replays them idempotently by operation id (FR-35). A replay never double-writes.

**D4 (with 119)**
- T29: on leaving, a receipt row per (day, target) holds exactly D4's fields and no topic text, note or message.
- T30: no foreign key from realm receipts into workspace tables (a catalogue query).
- T31: after leaving, B's content routes answer 403, while the receipt is still readable in the realm and only by that person. Another person, a foreman and an admin get 404.
- T32: a receipt taken while the last period was still open is updated once that period freezes or is approved, then never again (C3).

## 4. Contract: what 118 needs from the personal realm (spec 119)

118 specifies the **need**. 119 (seat a-778) designs the realm.

| # | 118 needs | notes |
|---|---|---|
| **C1** | A realm route and page for the personal view: `GET /v1/me/time?from=&to=&tz=`, authenticated by the hub session, **refusing an `X-Spool-Tenant` header** (400), so no workspace context can ever carry it. It returns the 2.1 shape. The WUI page `/me/time` is a realm page. | The route lives under the realm. It reads workspaces as 1.2 says and the realm as C2 says, in separate transactions. |
| **C2** | A person-scoped setting for the working-time limit: `weekly_minutes` (0 = off, 60..10080) and `daily_minutes` (0 = off, 60..1440), with optional effective dates. Read and written only by the person (`app.person_id` RLS). | D3. It is never copied, sent or pushed. |
| **C3** | Receipts: on leaving (membership removed, or `access_until` passed), copy per (day, target): date, minutes, workspace display name, target label (107 FR-18 job name and site, else the target's display name), approval state and approver, as D4 lists. Read in the workspace's scope in one transaction, written in the realm scope in another. No foreign key. **Refresh** the leaver's last period's rows when that period later freezes or is approved (107 Q8 is open, so the last period may still be open at leave time). After that the receipt is fixed. | Contradiction 2.2 above (119 Q3). Whether spans are kept: OQ-3. |
| **C4** | The person's zone for the personal view, in the realm profile. Absent: the WUI sends its zone. | 2.3 time zones. |
| **C5** | `person_id = humans.human_id` (`HUM-*`), so the hours' `member_id` and the realm's key are one identity. | Contradiction 2.5 above. |

## 5. Owner questions (not decided here)

- **OQ-1: change 107's model to keep spans (1.3)?** Without spans, "actual" equals "reported" for every frozen week, and the D1 mark only works on the current open period, from raw minutes. A: add `hours_entry_spans` to 107 (recommended by this seat). B: keep durations, and show D1 only where raw minutes still exist (at most 45 days, and never after a freeze).
- **OQ-2: "standard" in the personal view.** A: none, only per workspace (as REQ-3). B: also show the sum of the workspaces' standard days as a reference line.
- **OQ-3: do receipts keep times of day?** D4 lists days and weeks and hours. With spans, a leaver's past overlap stays visible. Without them, past workspaces count as unplaced.
- **OQ-4: a personal CSV download** of the person's own rows across workspaces, receipts included. A: yes, person-only. B: not in the first version.
- **OQ-5: the database-side member guard (1.2)**, the `app.member_id` policy on `hours_minutes` and `hours_entries`, or the route filter only, as 107 does today.
- **OQ-6: the approver's name in a receipt.** D4 keeps it. How long the realm keeps a copy of another person's name after the leaver leaves: forever, or 107 FR-34's retention years.

<!-- version: 0.1.0 · updated: 2026-10-10 · seat s118-claude-2 · last-edit: 2026-10-10 -->
