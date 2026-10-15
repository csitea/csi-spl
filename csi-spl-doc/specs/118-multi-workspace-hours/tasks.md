# 118 Multi-workspace hours tracking: tasks

Authority for what is built. `spec.md` holds the behaviour; this file follows
its sections 5 (data model and cross-workspace read under RLS), 6 (reported vs
actual: overlap computation), 7 (entering hours across workspaces), 8 (UI of
the personal view), 9 (the contract with spec 119 C1..C7) and 10 (tests).
Each task is one small lane: its layer, its agent kind, what it waits on, the
files it owns, the files it must not touch, and a Done line with its tests from
`spec.md` section 10. Status vocabulary: `../README.md` item 3 (`[x]` Implemented,
`[~]` Partial / in progress in a live lane, `[ ]` Planned).

Version **v1.0**, built from `spec.md` v1.1 (`8dd75db9c` / `00cc58fac`). The owner's
answers: "Yes all a" to Q1..Q10 (owner, 2026-10-11, msg 23d782e1), and Q8 decided B
(msg 9d7436e5). Owner go to start building: "A - Yes, start now, alongside the open issues"
(HUM-10, t1 cee5a73e, msg c2b5a855).

**Path prefixes:**

- `GO/` is `csi-spl-api/src/go/spool-hub-api/internal/`.
- `RDB/` is `csi-spl-rdb/src/sql/postgres/`.
- `RUN/` is `csi-spl-orc/src/bash/run/`; `OT/` is `csi-spl-orc/src/bash/tests/`.
- `WUI/` is `csi-spl-wui/src/`.

**Rules for every lane:**

- Store, RLS and auth tests run on Postgres as the runtime role
  (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`), never as the owner or a
  superuser. Every RLS test has its red control (`spec.md` 10), made on a
  throwaway branch, never on trunk.
- A file is owned by exactly one lane below. A lane that needs a change in a
  file it does not own asks that lane's agent, or the orchestrator if that
  lane has landed.
- Run the cheap gate for touched tree before push; pre-push gate green.
- No cross-workspace numbers leaked to workspace views, routes or exports (REQ-2, D3).
- WUI: `/me/hours` is a lazy chunk within the 160 KB initial bundle budget (`perf-budget.py`).
- Phone e2e tests at 390 px: no sideways scroll, controls 44..48 px.
- Deploy dev and prd, then prove it live: `./run -a do_check_deploy_lag`.

## The owner decisions (Q1..Q10)

All ten questions in `spec.md` section 12 are decided by the owner (msg 23d782e1 "Yes all a",
and msg 9d7436e5 Q8 B). Every lane builds on these decided answers:

| # | Decided | Summary | Lanes it touches |
|---|---|---|---|
| Q1 | A | Spans in 107 store (`hours_entry_spans`) ahead of 118 | T001 (DONE: 3074fed45, 3ce86889a, rdb 0176) |
| Q2 | A | Entry without times allowed, unplaced, marked `≈` | T002 (Lane A), T003 (Lane B), T006 (Lane E) |
| Q3 | A | Database-side member guard (`app.member_id`, `member_scope`) | T001 (DONE: 3074fed45, rdb 0176) |
| Q4 | A | "Also enter in …" shortcut copies start/end to new row | T007 (Lane F) |
| Q5 | A | Receipts keep no times (minutes per day only) | 119 T001, 119 T004, T003 (Lane B) |
| Q6 | A | One `rev = 1` refresh when the last open period freezes | 119 T004, 119 T006, T003 (Lane B) |
| Q7 | A | A deleted workspace copies receipts for its members first | 119 T007, T003 (Lane B) |
| Q8 | B | Approver name kept as long as the receipt | 119 C5, T003 (Lane B) |
| Q9 | A | No summed standard-day line in personal view | T003 (Lane B), T006 (Lane E) |
| Q10 | A | No personal download in v1 | none (no download route / button) |

## Dependencies on Spec 107 and Spec 119

- **Spec 107 store dependency is DONE** (`3074fed45`, `3ce86889a`, rdb `0176_hours_entry_spans.sql`):
  `hours_entry_spans` table with `EXCLUDE USING gist` per member-workspace; `member_scope`
  restrictive RLS policy on `hours_entries`, `hours_entry_spans`, `hours_minutes`;
  store `inMember`, `HoursEntry.Spans` written in `PutHoursEntries`, `HoursEntrySpans` reads;
  timer and suggestion approvals write spans.
- **Spec 119 contract (C1..C7)**:
  - **C1 identity**: hub-wide `HUM-*` id (`humans.human_id`), `app.person_id` matches.
  - **C2 route home**: `/v1/me/realm/*` routes live in the realm group; human session only,
    refuses act-as (403 `person_only`), box tokens, agents; 400 on `X-Spool-Tenant` or `member=`.
  - **C3 settings**: `hours_limit_day_minutes` and `hours_limit_week_minutes` in `personal.settings`
    read under `inPerson`.
  - **C4 zone**: personal zone in `personal.profile.time_zone` read under `inPerson`.
  - **C5 / C6 receipts**: leaver rows read from `personal.hours_receipts` under `inPerson`.
  - **C7 isolation**: no cross-workspace data flows into workspace tables; writes from the realm
    screen execute as regular member writes under `inTenant(W)`.

## Order

T001 (spec 107 spans and member guard) is already landed and applied on dev and prd.
T002 (Lane A: pure Go overlap engine) has no dependencies and can build immediately.
T003 (Lane B: cross-workspace read route) waits on T002 and 119 T002 (`inPerson` + realm store).
T004 (Lane C: multi-workspace save & targets routes) waits on 119 T002; runs in parallel with T003 (disjoint files).
T005 (Lane D: WUI overlap engine, shared fixture test, API client) waits on T002, T003, T004.
T006 (Lane E: WUI `/me/hours` view, timeline, entry points) waits on T005 and 119 T009 (realm frame).
T007 (Lane F: WUI multi-workspace entry dialog & "Also enter in …") waits on T006.
T008 (Lane G: E2E verification & live proof) runs after T003, T004, T007 are deployed on dev and prd.

## Tasks

- [x] T000 **doc** (a-443): this file. `spec.md` status line notes it.

- [x] T001 **Spec 107 store dependency: spans & member guard** (rdb 0176, `3074fed45`, `3ce86889a`; claude; DONE).
  Spec 107 v2.3 changes required by 118 Q1 A and Q3 A:
  - `0176_hours_entry_spans.sql`: `hours_entry_spans` (FK to `hours_entries`, cascade;
    `EXCLUDE USING gist` per member-workspace preventing double-counting inside workspace; 0098 RLS shape);
    restrictive `member_scope` policy on `hours_entries`, `hours_entry_spans`, `hours_minutes`
    checking `app.member_id`.
  - Store: `inMember`, `execMember`, `queryMember` setting `app.member_id`; `HoursEntry.Spans`
    written in `PutHoursEntries`; `HoursEntrySpans` reads spans.
  - Hub: timer (`POST /v1/me/hours/timer`) and suggestion approvals (`PUT /v1/me/hours`) write spans.
  Files (owns): `RDB/spool-hub/0176_hours_entry_spans.sql`, `GO/store/hours_spans_test.go`,
  `GO/hub/hours_spans_test.go`.
  Tests: T-R1b (EXCLUDE constraint in 0176, 409 `overlap_in_workspace`), T-S3 (spans privacy:
  never exposed in `hours.read` or `/v1/me/hours`).
  Done: landed on master (`3074fed45`, `3ce86889a`), applied on dev and prd.

- [x] T002 **Lane A: pure Go overlap computation & shared fixture** (SPL-1711, 2de0e7185; claude or mistral, pure Go;
  waits on nothing; DONE). Spec 6.1, 6.2, 6.3:
  - Pure function `Across(days []WorkspaceDay, zone *time.Location, now time.Time) []PersonalDay`
    in `GO/hours/across.go`, no I/O, table-driven tests in `GO/hours/across_test.go`.
  - Algorithm: sweep line over span endpoints (as UTC instants); overlap intervals
    `{start, end, workspaces[]}` where 2+ workspaces open; `reported` = sum of entries' minutes
    (approved + open suggestions); `actual` = |union of spans| + sum of unplaced minutes (`approx`, `≈`);
    `overlap` = reported - actual, never negative.
  - Edge cases: open timer (dashed, provisional in actual, not reported), crossing midnight
    (split at personal zone midnight), different zones (re-bucketed to personal zone),
    DST (UTC instants), unplaced minutes (typed rows, no times), left workspace receipts
    (reported, actual as unplaced), workspace unavailable (`incomplete`).
  - Shared JSON fixture in `GO/hours/testdata/overlap_fixture.json` run by both Go test suite
    and WUI test suite (T-OV-JS).
  Files (owns): `GO/hours/across.go`, `GO/hours/across_test.go`,
  `GO/hours/testdata/overlap_fixture.json` (all *new*).
  Must not touch: `GO/hours/suggest.go`, `GO/store/*`, `GO/hub/*`, `WUI/*`.
  Tests: T-R1a, T-OV, T-OV-JS (Go half), T-OV-RO.
  Done: `go test ./internal/hours/...` green; shared JSON fixture validated.

- [x] T003 **Lane B: the cross-workspace read route** (c-160, SPL-1925, 321f6a2a4; claude, hub + auth; waits on T002,
  119 T002; DONE). Spec 5.2, C2, C5, C6:
  - `GET /v1/me/realm/hours?from=<date>&to=<date>` (max 62 days) in the realm route group.
  - Human session only: 403 `person_only` under act-as (054), box token, agent, time-accountant-only
    seat; 400 on `X-Spool-Tenant` or `member=`.
  - Workspaces: reads `Memberships(ctx, caller)` (max 20 workspaces, 21 is 400 `too_many_workspaces`).
  - Fan-out: runs `inTenant(W)` per workspace (max 2 in flight) reading `HoursEntries`,
    `HoursPeriods`, `HoursEntrySpans`, and today's `HoursMinutes` for open suggestions.
  - Reads 119 realm settings (`hours_limit_*`), profile (`time_zone`) and receipts
    (`personal.hours_receipts`) for left workspaces under `inPerson(ctx, caller)` in a separate
    transaction (never nested with `inTenant`).
  - Calls `Across(...)` to compute personal days. Failed workspace -> `{"state":"unavailable"}`.
  - Zero cross-workspace leak to workspace routes or exports (T-R2a).
  Files (owns): `GO/hub/realm_hours_read.go`, `GO/hub/realm_hours_read_test.go` (*new*).
  Must not touch: `GO/hub/realm.go` (119 T003 owns `realm.go`), `GO/hub/hours_me.go`,
  `GO/store/rls.go`, Lane C's files.
  Tests: T-R1c, T-R2a, T-R2b, T-R3, T-RLS1, T-RLS2, T-RLS3, T-RLS4, T-RLS5, T-RLS6, T-PERF.
  Done: green on Postgres; deployed dev and prd (`do_check_deploy_lag`).
  Built (321f6a2a4): `GO/hub/realm_hours_read.go`, its test (10 tests, Memory and Postgres),
  the `openapi.json` operation `getMeRealmHours`, and one registration line in
  `GO/hub/channel_order.go` `routeMe` (no realm route group exists yet; 119 T003 may move it
  into `realm.go`). Answer: `{tz, tz_source, from, to, workspaces[{id, name, state}], days,
  totals, incomplete, limits[]}`; `days` is `hours.Across`'s `PersonalDay`, one per day of the
  window; `limits` are the person's own settings rows over the window, the warning is the WUI's.
  Open in this row, each named: `standard_day` stays 0 (107 FR-14's resolved standard day has no
  store yet, so T-R3 waits on it); the `time_accountant` refusal is coded but no such rbac role
  exists yet; receipts are served by a test spy until 119 T004 writes them; T-R2b (catalogue)
  and T-PERF on dev (20 x 31 days, n) are T008's live proof; T-RLS4/T-RLS5 hold by
  construction (the route calls only `Memberships`, the 107 reads and the 119 `inPerson`
  reads) and by 119 T002's `personal_rls_test.go`.

- [x] T004 **Lane C: multi-workspace save & targets routes** (c-536, `b6d1e5bf3`; claude, hub + auth; waits on
  119 T002; BUILD). Spec 7.1, 7.2:
  - `GET /v1/me/realm/targets?workspace=<W>&q=` checks W in caller's memberships; reads targets
    under `inTenant(W)`.
  - `PUT /v1/me/realm/hours` with `[{workspace, op_id, day, target, minutes | start, end, note}]`.
  - Groups rows by workspace. For each group checks W in `Memberships(caller)` (else 403
    `not_a_member`, 0 rows in W). Runs one `inTenant(W)` transaction through 107's entry write
    (`PutHoursEntries`) plus spans (409 `overlap_in_workspace`).
  - No cross-workspace atomicity: each workspace executes independently, partial refusals return
    per-row status (`ok`, `period_frozen`, `day_over_1440`, `overlap_in_workspace`, `unknown_target`,
    `not_a_member`).
  - Idempotent retry via `op_id`. Refuses `split`/`share`/`percent` with 400 (D2).
  - Timer stop writes `{start, end}` split at midnight.
  Files (owns): `GO/hub/realm_hours_write.go`, `GO/hub/realm_hours_write_test.go` (*new*).
  Must not touch: Lane B's files, `GO/hub/realm.go`, `GO/hub/hours_me.go`, `GO/hub/server.go`.
  Tests: T-D2, T-R4a, T-R4b, T-R4c.
  Done: green on Postgres; deployed dev and prd.
  Built (c-536, SPL-1930): body is a bare JSON array of rows; answer `200 {rows: [{op_id,
  workspace, status, detail?, replayed?}]}` in request order, plus `bad_row` (a day after today,
  bad times) and `unavailable` (store error, retry). A group's refusal is the status of every
  row of that workspace (one transaction). A seat without `self.keys` (no `time_accountant` role
  exists yet) is `not_a_member`. Timed rows add their minutes to the row and keep a `manual`
  span; a replay answers `replayed: true`. `GET /v1/me/realm/targets` answers `{workspace,
  targets: [{target, label, kind}]}`. The `OPTIONS /v1/me/realm/hours` preflight is T003's (GET,
  PUT).

- [ ] T005 **Lane D: WUI overlap engine, shared fixture & API client** (grok or mistral;
  waits on T002, T003, T004; BUILD). Spec 6.1, 6.3, T-OV-JS:
  - Pure client-side overlap logic for today's running timer in `WUI/utils/hours-across.mjs`,
    verified against shared fixture `GO/hours/testdata/overlap_fixture.json` (passes in Go and JS).
  - API client `WUI/utils/realm-hours-api.mjs` for `GET /v1/me/realm/hours`, `PUT /v1/me/realm/hours`,
    `GET /v1/me/realm/targets`.
  - Composable `WUI/composables/useRealmHours.ts`: cross-workspace hours state, today's provisional
    timer span, limit warning evaluation (amber at 90%, red past 100%).
  Files (owns): `WUI/utils/hours-across.mjs`, `WUI/utils/realm-hours-api.mjs`,
  `WUI/composables/useRealmHours.ts`, `WUI/tests/unit/hours-across.test.mjs` (all *new*).
  Must not touch: any Go file, `WUI/pages/me/*`, `WUI/stores/realm.ts`.
  Tests: T-OV-JS (JS half: shared fixture passes unit tests), composable unit tests.
  Done: `pnpm run test:unit`, `pnpm run typecheck` green.

- [ ] T006 **Lane E: the `/me/hours` view, timeline & entry points** (grok or mistral;
  waits on T005, 119 T009; BUILD). Spec 8.1, 8.2, 8.3:
  - Lazy chunk within 160 KB budget (`perf-budget.py`).
  - Desktop view (> 820 px): week grid by default, month toggle. Rows: workspaces with colour chips,
    resolved standard days (never summed, REQ-3, Q9 A); Reported, Actual, Overlap hatched cells;
    intervals on hover.
  - Timeline (00..24) on day click: lanes per workspace, hatched overlaps, running timer dashed,
    unplaced stubs.
  - Limit bar (D3): actual vs person's limit (from 119 realm settings); amber at 90%, red past 100%.
    Shown only in `/me/hours`, never in workspace views.
  - Phone view (<= 820 px, 390 px): sticky header with week's Reported/Actual/limit bar; day cards
    with stacked bars; swipe week; day sheet.
  - Entry points: link in person menu; "All my workspaces" link in workspace hours panel
    (`CalendarHoursPanel.vue`) and Working hours dialog (`CalendarEventDialog.vue`) for members
    with 2+ workspaces.
  Files (owns): `WUI/pages/me/hours.vue`, `WUI/components/RealmHoursTimeline.vue` (*new*);
  entry point links in `WUI/components/CalendarHoursPanel.vue` and `WUI/components/TopBar.vue`;
  `realm_hours.*` i18n keys in `csi-spl-wui/i18n/locales/*`.
  Must not touch: `WUI/pages/me/index.vue`, `WUI/pages/me/settings.vue`, `WUI/pages/me/receipts.vue`,
  Lane F's files.
  Language rule: new strings get agy review before shipping.
  Tests: T-R2a, T-R2b, T-R2c, T-R3, T-E2E (view half).
  Done: `pnpm run typecheck`; `BASE_URL=<bundle> pnpm run test:e2e`; deployed dev and prd.

- [ ] T007 **Lane F: multi-workspace entry sheet & "Also enter in …"** (grok or mistral;
  waits on T006; BUILD). Spec 7.1, 7.3, 7.4:
  - + Add hours form/dialog: workspace chips, target picker (`GET /v1/me/realm/targets`),
    start..end or stepper ±15, note. Inline overlap error within same workspace; info mark for
    overlap with other workspace. No split control (T-D2).
  - Partial refusal handling: saved rows close, refused rows stay dirty with reason; banner
    with [Retry B].
  - "Also enter in …" shortcut (Q4 A): one tap copies start/end to new row for another workspace,
    target picked there.
  - Running timer: start timer per workspace, stored in localStorage per workspace.
  Files (owns): `WUI/components/RealmHoursEntryDialog.vue`, `WUI/utils/realm-hours-entry.mjs` (*new*);
  entry integration in `WUI/pages/me/hours.vue`.
  Must not touch: 119 WUI files, `CalendarHoursDay.vue`.
  Tests: T-D2, T-R4b, T-R4c, T-E2E (entry & retry half).
  Done: `pnpm run typecheck`; `BASE_URL=<bundle> pnpm run test:e2e`; deployed dev and prd.

- [ ] T008 **Lane G: E2E verification & live proof** (claude or agy; waits on T003, T004,
  T007 deployed on dev+prd; BUILD). Spec 10 acceptance:
  - End-to-end multi-workspace scenario on dev and prd at 390 and 1440 px: 2+ workspaces,
    cross-workspace overlap with hatched marks, multi-workspace save, partial refusal with retry
    banner, working-time limit warning (amber/red), leaver receipts rendered as read-only.
  - Verifies no cross-workspace data in workspace routes/exports (T-R2a).
  - Verifies lazy bundle within 160 KB budget (`perf-budget.py`).
  - `do_check_deploy_lag`, release note links for dev and prd.
  Files (owns): `WUI/tests/e2e/realm-hours.test.mjs` (*new*), evidence report in dispatch.
  Tests: T-E2E, T-PERF, live proof dev+prd.
  Done: live proof green on dev and prd.

## Lanes at a glance

| id | lane | agent | waits on | 118 / 119 | state |
|---|---|---|---|---|---|
| T000 | doc: this file | agy | nothing | spec 118 v1.1 | DONE |
| T001 | 107 spans & member guard | claude | nothing | Q1 A, Q3 A | DONE (rdb 0176) |
| T002 | A: pure Go overlap engine | claude / mistral | nothing | Q2 A | DONE (2de0e7185) |
| T003 | B: cross-workspace read route | claude | T002, 119 T002 | Q2 A, Q5..Q9 | DONE (321f6a2a4) |
| T004 | C: multi-workspace save & targets | claude | 119 T002 | none | DONE (`b6d1e5bf3`) |
| T005 | D: WUI engine & API client | grok / mistral | T002, T003, T004 | none | BUILD |
| T006 | E: `/me/hours` view & timeline | grok / mistral | T005, 119 T009 | Q2 A, Q9 A | BUILD |
| T007 | F: entry sheet & "Also enter in …" | grok / mistral | T006 | Q4 A | BUILD |
| T008 | G: E2E verification & live proof | claude / agy | T003, T004, T007 deployed | all | BUILD |

<!-- version: 1.0.0 · updated: 2026-10-13 · last-edit: 2026-10-13 -->
