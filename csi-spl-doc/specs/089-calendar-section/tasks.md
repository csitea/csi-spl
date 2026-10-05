# 089 the Calendar section: tasks

Authority for what is built (`spec.md` holds the behaviour; its section 1.1 holds the owner decisions of 2026-10-05). Each task is one lane: one agent, one task, the files it owns, the tests that prove it, its dependencies. Status vocabulary: `../README.md` §2.3. Implementation topic: `819d8610-4fc9-442a-9916-ef2fd691da5f`.

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `api/` = `csi-spl-api/src/go/spool-hub-api/`, `wui/` = `csi-spl-wui/`, `doc/` = `csi-spl-doc/`.

## Rules for every task

- **Gate before every push, and again after the mandatory rebase**: `cd csi-spl-iac && ./run -a do_check_pre_push`, plus the gate for the tree the task touches (repo `CLAUDE.md`):

  | tree | gate |
  |---|---|
  | `rdb/`, `api/internal/store/` | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store tests on Postgres) |
  | `api/` | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` |
  | `wui/` | `pnpm run test:unit`, `pnpm run typecheck`, the task's e2e against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and the 155 KB initial-chunk check (`src/node/test/bundle-size.mjs`) |
  | `doc/` | `./run -a do_check_dist_hygiene`, `lint-mdlinks` |

- **Deploy dev and prd, then prove it live.** A hub change ships through wf 20 and is proven by `/version` on dev and prd showing the commit's `v<X.Y.Z>`. A WUI change ships through wf 30 and is proven by `build.json` (and the footer) on dev and prd. Then `./run -a do_check_deploy_lag`, and report `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for both envs. A migration ships through `ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap`; for prd, send the exact command to the orchestrator and wait. It is proven with `do_spl_db_query` on `information_schema`.
- **Budget**: the initial-chunk ceiling is `ci_initial_gzip_kb` = **155 KB** (`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`, owner 2026-10-02). Every calendar module loads on route entry. The reminder timer is the only calendar code allowed in the shell, and it must stay small (T006).
- Plain English, "workspace" in prose; no host literals (read `BASE_DOMAIN` / cnf).

## Order and parallelism

```
T002 rdb ─► T003 store ─► T004 hub API ─┬─► T005 CLI + MCP           (parallel)
                                        ├─► T006 reminder pop-up     (parallel)
                                        └─► T007 /calendar shell ─► T008 main view ─┬─► T009 phone  (parallel)
                                                                                     └─► T010 help   (parallel; after T006 too)
                                                                         T011 region setting (later, after T008)
```

T002 -> T003 -> T004 -> T007 -> T008 is the serial spine. T005, T006 and T007 own disjoint files and may run at once after T004. T009 and T010 may run at once after T008.

---

### Phase 0: Specification
- [x] T001 **spec + tasks** (c-275): `spec.md` v0.4.0 (owner decisions D1..D4, public by default, owner-only private, pop-up reminders) and this file.

### Phase 1: Data (serial)
- [x] T002 **rdb migration** (c-292) `rdb/0125_calendar.sql` (next free number: `ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1` -> `0124_demo_user_role.sql` on 31c04371c; re-read it on the sha you build on, and take the next number if 0125 is gone). `calendar_events` exactly as `spec.md` section 5: `audience text NOT NULL DEFAULT 'public'` with the three-value check, `mentions text[]`, `remind_at`, ENABLE + FORCE ROW LEVEL SECURITY, `tenant_scope` in the `NULLIF` form, `operator_scope`, the three indexes. `official_days` (shared reference, no `tenant_id`, no rows yet). `tenants.calendar_region text NOT NULL DEFAULT ''` (the region is empty by default). **The same commit** seeds `calendar_events` in `seedTenantAll` (`api/internal/store/crosstenant_test.go`), or `TestCrossTenantEveryTable` turns trunk red. Owns: that `.sql` file and that seed. Tests: `TestRLSPoliciesFailClosed`, `TestCrossTenantEveryTable`, the migration catalogue gate, on Postgres. Depends: none. Serial. Deploy: bootstrap dev; prd via the orchestrator. Prove: `information_schema.columns` shows `calendar_events.audience` with default `'public'` on dev and prd.

### Phase 2: Store and hub API (serial)
- [x] T003 **store** (c-304) `api/internal/store/calendar.go` + `calendar_test.go`: create, get, update, delete, range list, year marks, the viewer's reminders in a window. Every read applies the private filter (`audience <> 'private' OR creator_id = viewer OR viewer = ANY(mentions)`), because RLS holds only the workspace (`spec.md` section 5). Reads run `inTenant`. A `to_regclass` probe (the `store/agent_seats.go` pattern) returns empty, not 500, while the table is missing on an env. Tests on Postgres: a create without audience stores `public`; a member who is not mentioned cannot read a private event; the owner and a mentioned agent can; workspace A cannot read workspace B (AC-07). Depends: T002 on master (and on dev). Serial. Deploy + prove: hub `/version` on dev and prd.
  - **Built** (c-304): `store.Calendar`, an optional interface on `*Memory` and `*Postgres` (type-assert `s.store.(store.Calendar)`): `CreateCalendarEvent`, `GetCalendarEvent`, `UpdateCalendarEvent` (a `CalendarPatch` of pointers; nil = unchanged), `DeleteCalendarEvent`, `ListCalendarEvents` / `CalendarMarks` / `CalendarReminders` over a `CalendarRange{Start, End}` (`[Start, End)`), `OfficialDays(region, range)`. `viewer` is the session's human UUID or agent id. Get, update and delete apply the private filter too: a hidden private event is `ErrNotFound`. Errors for T004 to map: `ErrInvalidCalendarEvent` -> 400, `ErrNotFound` -> 404, `ErrCalendarUnavailable` (no rdb 0125 on that env) -> 503, `ErrNoTenant`. T004 still owns the owner-only `private` check (compare `GetCalendarEvent`'s `Audience` with the patch), dropping `internal` for a guest or demo session, and merging `issues.deadline`. Tests: `internal/store/calendar_test.go` (memory + Postgres, AC-07, RLS control, missing-table probe).
- [ ] T004 **hub API** `api/internal/hub/calendar.go` + `calendar_test.go`, and its route lines: the five routes of `spec.md` section 6 plus `GET /v1/calendar/reminders`. **Owner-only private**: a create or `PATCH` that sets `audience` to or from `private` by anyone but the owner returns `403`, an admin included (AC-09, FR-010). `internal` events are dropped for a guest or demo session. `issues.deadline` rows are merged into the range answer (read only here; editing a deadline from the calendar is T008's call to the existing issue `PATCH`). Release events carry `release_version` as a badge field; no row is made per git tag. Tests: `403` for a non-owner setting `private`, `200` for the owner; default `public`; reminders list holds only events the viewer owns or is mentioned on; no spool message and no `internal/notify` call anywhere in the package (a grep test). Depends: T003. Serial. Deploy + prove: `/version` on dev and prd; `GET /v1/calendar/events` answers `200` on both.

### Phase 3: Clients of the API (parallel after T004)
- [ ] T005 **CLI + MCP** `spool calendar list|add|edit|rm` in `api/cmd/spool` and the matching MCP tools (`api/internal/mcp/`, golden `testdata` updated). `--private` is an explicit flag; without it an event is `public`. Agents read their events here; they get no reminder (D4). Owns: the calendar command file, the calendar MCP tool entries and their golden. Tests: `tools_golden_test.go`, a CLI test for the default audience. Depends: T004. Parallel with T006 and T007. Deploy + prove: `/version` on dev and prd (the MCP surface ships with the hub).
- [ ] T006 **reminder timer + pop-up** (D4): `wui/src/utils/calendar-reminders.mjs` (pure: given the reminder list, now and the dismissed keys, return what to show now and the next due time) + `tests/unit/calendar-reminders.test.mjs`; `wui/src/plugins/calendar-reminders.client.ts` (fetches `GET /v1/calendar/reminders` for the next 24 h on start, on focus, on an event change and hourly; sets one browser timer); `wui/src/components/CalendarReminderPopup.vue`, loaded lazily the first time a reminder fires (title, time, Open, Dismiss; dismiss remembered in `localStorage` per event and reminder time; a missed reminder shows once on open if the event has not ended). No agent, no AI, no spool message, no notification-pipeline call. Owns: those three files, their i18n keys, `tests/e2e/calendar-reminder.test.mjs` (AC-06: the pop-up shows; no spool or notify request is made). Depends: T004. Parallel with T005 and T007. Deploy + prove: `build.json` on dev and prd; the 155 KB check still passes with the plugin in the shell.

### Phase 4: The `/calendar` section (serial)
- [ ] T007 **section shell + year strip**: the `calendar` rail entry in `wui/src/utils/rail-order.mjs` (+ `tests/unit/rail-order.test.mjs`), `wui/src/pages/calendar.vue` (single sheet like `issues.vue`: rail stays, channel/topic/thread panes closed), `wui/src/components/CalendarYearStrip.vue` (own Vue, no library: 36 mini-months, previous/current/next year, dots and tints from `GET /v1/calendar/marks`, a click moves the main view to that week), the `calendar.*` i18n keys in every `wui/i18n/locales/*.json`. The main view is a placeholder `defineAsyncComponent` slot. Owns: those files, `tests/e2e/calendar.test.mjs` (AC-01, AC-04, AC-02: calendar code is its own chunk, initial chunk <= 155 KB). Depends: T004. Parallel with T005 and T006. Deploy + prove: `build.json` on dev and prd.
- [ ] T008 **main view + event dialog**: the Schedule-X packages (`@schedule-x/calendar`, `@schedule-x/vue`; fall back to `@fullcalendar/vue3` standard views only if pnpm cannot install a clean MIT set, and say which in this file) in `wui/package.json` + lockfile; `wui/src/components/CalendarMainView.vue` (Week by default, Day / Week / Month switch in WUI controls, the library toolbar hidden, now line, drag to move, theme from the CSS variables), `wui/src/components/CalendarEventDialog.vue` (create and edit in a modal; audience control with `public` preselected, the `private` choice shown only to the owner; `@mentions`; reminder time; release badge; an issue deadline edits the issue). Owns: those files, `tests/e2e/calendar-events.test.mjs` (AC-03, AC-05, AC-09 in the UI: a non-owner sees no `private` choice). Depends: T007. Serial. Deploy + prove: `build.json` on dev and prd; the 155 KB check passes with the library in its own chunk.

### Phase 5: Phone and help (parallel after T008)
- [ ] T009 **phone layout** (<= 820 px): Level 2 with the section strip (`wui/src/composables/useMobileStack.ts`: the calendar entry only), Day view by default, Week as a list grouped by day, the year strip behind a header button. Owns: the <= 820 px CSS in the calendar components, that one entry, `tests/e2e/calendar-phone.test.mjs` (AC-08 at 390x844). Depends: T008. Parallel with T010. Deploy + prove: `build.json` on dev and prd.
- [ ] T010 **help**: `doc/doc/help/calendar.md` (open the section, views, create an event, public by default and private only by its owner, `@mentions`, the reminder pop-up), its link in `doc/doc/help/index.md`, then `node src/node/help/sync-help.mjs` and the public copy under `wui/src/public/help-md/` in its own commit. Owns: those files. Depends: T008 and T006. Parallel with T009. Gate: `do_check_dist_hygiene`, `lint-mdlinks`. Deploy + prove: `build.json` on dev and prd serves the page.

### Later (not needed for the first release)
- [ ] T011 **official-days region**: the region setting in workspace settings (empty by default, `tenants.calendar_region`) and a seed of one region's `official_days`, as a named `./run` action. Depends: T008. Starts only when the owner names a region.

The scheduled hourly or twice-daily deploy item (`spec.md` section 11.1) is future work and has no task here. Deploys stay on every push to master.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T04:50:00Z -->
