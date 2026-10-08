# 107 Hours tracking: tasks

Authority for what is built (`spec.md` holds the behaviour; section numbers below are its sections). Each task is one lane: one agent, one task, the files it owns, the tests that prove it, its dependencies. Status vocabulary: `../README.md` §2.3.

**Unanimous panel consensus v1.0 (seats s107-1..4, `spec.md` section 12).** Build starts at once (owner rule 10-05); the owner questions of `spec.md` section 13 run on the panel's recommendation, and each names the one task its answer changes.

Paths: `api/` = `csi-spl-api/src/go/spool-hub-api/`, `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `wui/` = `csi-spl-wui/`, `doc/` = `csi-spl-doc/`.

## Rules for every task

- **No 089 / 097 / 106 file and no issue code changes.** Calendar and issue tables are read only (sections 7, 8). The later hooks C1..C4, I1..I4, P1 are not v1 tasks.
- **Store tasks run on Postgres**: `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store and migration touched).
- **Gate before every push, and again after the mandatory rebase**: `cd csi-spl-iac && ./run -a do_check_pre_push`; for `api/`: `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; for `wui/`: `pnpm run test:unit`, `pnpm run typecheck`, the task's e2e against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), `perf-budget.py` (initial chunk <= 155 KB).
- **No always-on client code in the initial chunk** (spec 5.1, 1.2): the Hours page and the tab recorder are lazy chunks.
- **Privacy line** (spec 1.7): only the hours store file and the hub's post-write upsert name `hours_minutes`; only `/v1/me/hours*` returns raw minutes or unapproved suggestions.
- **Phone e2e** at 360x780 and 390x844, dark and light, font levels 1, 3, 5: no sideways scroll (`scrollLeft == 0`), controls 44..48 px.
- **Deploy dev and prd, then prove it live**: `./run -a do_check_deploy_lag`; `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for both envs.

## Order and parallelism

```
T001 spec ─┬─► T002 migration + perms ──► T004 store ─┬─► T005 hub post upsert
           │                                          ├─► T006 me routes ──► T010 view badge field ──► T011 rail + page shell ─┬─► T013 Mine: cards + approve
           └─► T003 suggestion engine (pure) ─────────┘                                                                      ├─► T014 Mine: edit, add, why
                                                      ├─► T007 freeze sweep ──┐                                               ├─► T015 Team + download
                                                      ├─► T008 team routes ◄──┘ ──► T009 export                               └─► T012 tab recorder
                                                      └─► T016 settings keys + reading toggle (wui)
                                     T005..T016 ──► T017 help ──► T018 live proof
```

T002 and T003 run in parallel. After T004: T005, T006, T007, T016 in parallel. After T011: T012..T015 in parallel (T015 also needs T008, T009).

---

### Phase 0: Specification
- [x] T001 **spec + tasks**: `spec.md` v1.0 (fold of s107-2..4, unanimous consensus recorded, owner Q1..Q7) and this file.

### Phase 1: Hub foundations (parallel)
- [x] T002 **migration + permissions** (spec 3.2, 3.3, 6.1). One forward-only `rdb/NNNN_hours.sql` (next free number): `hours_minutes`, `hours_entries`, `hours_periods` in the 0098 RLS shape (ENABLE + FORCE, `tenant_scope` NULLIF guard, `operator_scope`), `hours_entries` PK `(tenant_id, member_id, day, target)`, the `minute` and `target` CHECKs of spec 3.2; `hours.read` and `hours.approve` permission rows granted to `biz_owner`; widen `member_activity_kind_check` with `hours_returned` (0148 pattern, the 90-day auth sweep keeps it); widen `humans_rail_order_check` with a 12-entry branch adding `hours` (0133 pattern). `api/internal/rbac/rbac.go`: the two constants and `Defaults`. Tests: migration applies on a fresh and a current DB; RLS fail-closed and cross-tenant tests for the three tables (the `rls_failclosed_test.go` / `crosstenant_test.go` pattern); `rbac_test.go` biz_owner holds both, other roles neither. Owner Q5 = B: also grant `admin`. Depends: T001.
- [x] T003 **suggestion engine, pure Go** (spec 1.1, 1.3, 1.4, 1.6). `api/internal/hours/suggest.go`: minutes (with `src`, target) + meetings + N + zone -> per-day rows. Blocks with gaps <= N bridged, no idle tail; 3-min floor for tab-only blocks; precedence meeting > post > tab; meeting union, earliest start wins on overlap; `topic_id` meetings to their topic; bridged minutes to the previous target; per-target sums; fold < 5 min into `ws`; split at local midnight; DST days. Owns that file and `suggest_test.go`. Tests: the spec 1.1 worked example (0:21; 0:01 when 09:46 is a post); two overlapping meetings never exceed wall-clock; a post inside a meeting goes to the meeting; floor before fold; 23 h and 25 h days. No DB, no routes. Depends: T001.

### Phase 2: Store and hub (after T002 / T003)
- [x] T004 **store** (spec 3.2, 4.2). `api/internal/store/hours.go` (+ `hours_postgres.go`, `hours_memory.go`): upsert minutes with post-over-tab (`ON CONFLICT ... WHERE src = 'tab'`), minutes of a member's range, entries CRUD with the 1440-min day cap, period rows (create, set state), the effective-freeze check (a row `frozen`/`approved`, or no row and end + grace passed in `hours.tz`; `returned` editable). Register the four 098 keys `hours.period`, `hours.freeze_grace_days`, `hours.idle_minutes`, `hours.tz` with their ranges. Tests on Postgres and memory: precedence, freeze with and without a row, returned is editable, the cap. Owner Q3 = B: add a membership-settings override of N. Depends: T002, T003.
- [x] T005 **hub post-minute upsert** (spec 1.2). On the existing store paths for a `box-wui` post, an edit and a reaction by a HUM-*: upsert that minute (`src = 'post'`, `t:<task_id>`, zone per 1.6) in the same transaction. Tests: a post writes one row; a post over a tab minute takes the target; a tab write after a post does not; an agent post writes none; a write failure of the upsert fails nothing it should not (same transaction semantics as the post). Depends: T004.
- [ ] T006 **member routes** (spec 2, 6.3). `PUT /v1/me/hours/minutes` (<= 60 rows, one `tz`, refused for frozen days), `GET /v1/me/hours?period=` (suggestions via T003 from `hours_minutes` + the member's accepted meetings of kind `other` (owner Q6 = B: any kind); none for frozen or returned days; entries; deltas; period state), `PUT /v1/me/hours` (approve / edit / reject / add / resubmit batch; 409 `period_frozen`). Every read filtered `member_id = caller`. Tests: route tests per verb; a frozen day is 409 with and without a sweep row; no suggestions in a returned period; a second member never sees the first's minutes. Depends: T003, T004.
- [ ] T007 **freeze sweep** (spec 4.2). In the hub's existing sweep: at end + grace, a `frozen` row for every current human member plus any member with entries or minutes in the period (0 minutes allowed; agents never), then prune that period's `hours_minutes`; prune any minute older than 45 days; `hours.period` changes start after the member's latest `period_end`. Tests: a removed member with minutes gets a row; a member with nothing gets a 0 row; week -> month switch does not pull passed days; idempotent re-run. Owner Q2 = B: write `approved` entries from open suggestions before the prune. Depends: T004.
- [ ] T008 **team routes** (spec 4.3, 4.4, 6.3). `GET /v1/hours?period=&member=&target=` (`hours.read`: approved entries + period rows, never minutes or suggestions), `PUT /v1/hours/periods` (`hours.approve`: approve, return with required note, Approve all, Return all; `member_activity` `hours_returned` per return; only `frozen` rows can be approved or returned). Tests: permission refusals; return reopens one member only; resubmit (T006) brings it back to `frozen`; the no-leak test (a `hours.read` holder never receives a raw minute or an unapproved suggestion). Depends: T004, T007.
- [ ] T009 **export** (spec 6.2). `GET /v1/hours/export?period=&format=csv|xlsx&final=` (`hours.read`): the spec's columns, one line per approved entry, final-only default; XLSX one sheet via a new `api/internal/xlsx` package on `archive/zip` + `encoding/xml`, no new dependency, numeric cells `t="n"`, the spec's `Content-Type` / `Content-Disposition`. Tests: CSV golden file; the XLSX opens (zip structure, `[Content_Types].xml`, one sheet, a parse back of the cells); a second workspace exports nothing of the first. Depends: T008.
- [ ] T010 **badge field** (spec 5.1). `hours_open_days` on the view the rail already loads: closed days of the member's open periods with open suggestions or deltas, plus 1 for a returned period. Computed cheaply (a count, not the full suggestion rows); 0 when the tables are absent (the `to_regclass` probe pattern of `human_status.go`). Tests: count matches the T006 page on a fixture; the view's existing cost test stays within its bound. Depends: T006.

### Phase 3: WUI (after T010 / T011)
- [ ] T011 **rail item + page shell** (spec 5.1). `Hours` rail entry with the badge from T010; `utils/rail-order.mjs` `parseRailOrder` appends `hours` to stored 11-entry orders; lazy `/hours` page with the Mine and Team tabs (Team only with `hours.read`). Tests: unit for `parseRailOrder` (6..11-entry inputs); e2e: the rail shows Hours with a badge, the page opens at 390 and 1440 px; `perf-budget.py` unchanged within 155 KB. Depends: T010.
- [ ] T012 **tab-minute recorder** (spec 1.2). A lazy chunk started where read-sync starts: visible + `hasFocus()` + input in the last 60 s; the open target from the route; in-memory buffer; flush every 5 min, on hidden, on `pagehide` with `keepalive`; off when "Count my reading time" is off. Owns `wui/src/utils/hours-recorder.mjs` and its test. Tests: unit with a fake clock (no input -> no minute; unfocused -> no minute; flush moments); e2e: two minutes of scripted input write two rows through the mock. Owner Q1 = B: this task is dropped. Depends: T006, T011.
- [ ] T013 **Mine: day cards and approve** (spec 4.1, 5.2). Day cards newest first, banner with [Approve N days], Approve day / Approve week on closed days only with the open count, today's Approve so far, one-tap delta accept, reject with 10 s Undo, frozen lock, Final, returned note + Resubmit. Tests: e2e the common case in 2 taps from the rail at 390 and 1440 px; Friday-morning Approve week leaves today open; phone rules. Depends: T006, T011.
- [ ] T014 **Mine: edit, add, why** (spec 1.5, 5.2, 5.3). Stepper in place (±15, type), `+15` extend, `+ Add` with target picker (recent topics, issues by key or title, channels; search), the "why" sheet with the row's blocks. Tests: e2e edit, add, why at 390 and 1440 px; the 1440-min refusal is shown. Depends: T006, T011.
- [ ] T015 **Team tab and download** (spec 4.4, 5.4, 6.2). Grid (desktop) / member cards (phone), per-target breakdown, state per member, Approve / Return (note) / Approve all / Return all for `hours.approve`, filters member / target type / issue, Download CSV / XLSX with Final only. Tests: e2e biz owner approves, returns, downloads; a member without `hours.read` sees no Team tab. Depends: T008, T009, T011.
- [x] T016 **settings** (spec 1.2, 4.2). Workspace settings: the four `hours.*` keys through the existing tenant settings page (`tenant.settings` only); member settings: "Count my reading time" in membership settings, default on. Tests: e2e set period to `month`, read back; toggle off stops the recorder (with T012). Depends: T004. Done: Tenant settings -> General -> Hours and Settings -> Behaviour (hub pref `hours_reading`, null = on); the recorder half of the test is pending with T012.

### Phase 4: Docs and proof
- [ ] T017 **help page** (`doc/doc/help/`): what counts as time worked (spec 1.1 in plain words), approving, the freeze, the biz owner's approval, who sees what, the reading-time switch. Gates: `./run -a do_check_dist_hygiene`, `lint-mdlinks`. Depends: T013..T016.
- [ ] T018 **live proof on dev and prd** (spec 9 acceptance): the seeded scenario end to end on dev, then prd, at 390 and 1440 px; CSV and XLSX downloaded and checked; cross-workspace read refused; footer / `build.json` show the commit's version; `do_check_deploy_lag`; release-note links for both envs. Depends: T002..T017.

---

## Later (not v1; each a task for the owning lane when the owner asks)

| id | hook | owning lane | needs |
|---|---|---|---|
| C1 | Hours lane in the desktop Day / Week calendar | calendar (089 / 097) | `GET /v1/me/hours` |
| C2 | Hours lane in the phone Day view | calendar phone (106) | `GET /v1/me/hours` |
| C3 | "Log this" in the event pop-over / peek | calendar | `PUT /v1/me/hours` |
| C4 | Freeze date marker in the month view | calendar | period settings |
| I1 | "Booked h:mm" in the issue's right pane | issues (039) | `GET /v1/hours?target=` |
| I2 | Booked vs `level` on the issue list | issues | as I1 |
| I3 | Issue field edits as activity | issues | an issue-history table |
| I4 | Team filter / grouping by epic | hours | issue parents |
| P1 | Reminder pop-up with [Approve N days] | WUI notifications | a pop-up path that is not the calendar's |

<!-- version: 1.0.0 · updated: 2026-10-07 · last-edit: 2026-10-07T22:00:00Z -->
