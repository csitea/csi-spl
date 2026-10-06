# 097 Calendar full editing: tasks

Authority for what is built (`spec.md` holds the behaviour and the owner's
decisions, sections 0.1 and 10). Each task is one lane: one agent, one task, the
files it owns, the tests that prove it, its dependencies. Status vocabulary:
`../README.md` §2.3. The owner answered Q1..Q9 "as proposed"
(spec section 10, msg `92b3e0d6`); the spec is fully decided.

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`api/` = `csi-spl-api/src/go/spool-hub-api/`, `wui/` = `csi-spl-wui/`,
`doc/` = `csi-spl-doc/`.

## Rules for every task

- The gates and the deploy proof of 089 `tasks.md` ("Rules for every task")
  apply unchanged: `do_check_pre_push` before every push and after the
  rebase; `PRE_PUSH_TIER=full` for `rdb/` and `api/internal/store/`; hub
  changes proven by `/version` on dev and prd; WUI changes by `build.json` on
  dev and prd; the 155 KB initial-chunk check.
- **Backward compatible, always** (spec FR-001): every hub task keeps a test
  that sends the 089 body (c-394's "Add to calendar" call) and gets 089's
  answer plus the new fields at their defaults.
- **Migration before hub.** T002 is applied on dev and prd (prd through the
  orchestrator) before any hub task that reads its columns reaches prd; until
  then the store probes the column and answers 089's shape.
- New Go functions stay under the clean-code gate (80 lines, depth 4,
  8 params).

## Order and parallelism

```
T002 rdb ─► T003 store base ─► T004 hub base (props, reminders, If-Match, soft delete)
                 │                 ├─► T009 search   (parallel)
                 │                 ├─► T011 export   (parallel, after T006)
                 │                 └─► T012 CLI + MCP (parallel, after 089 T005)
T005 rrule pkg ──┴──────────────► T006 recurrence store + hub ─► T007 guests + rsvp ─► T008 notices
T010 quick-add parser (pure, any time) ─► its route after T006 and T007
WUI, after 089 T008: T013 drag ─► T014 dialog fields ─► T015 repeat + scope ─► T016 guests
                     T017 undo + trash (after T004)   T018 quick add + search + export   T019 help
```

T005 and T010 are pure packages with no dependency and may start at once.

---

### Phase 0: Specification
- [x] T001 **spec + tasks** (c-397): `spec.md` v0.1 and this file; v0.2 folds in
  the owner's decisions E1..E3 (spec section 0.1).

### Phase 1: Data
- [ ] T002 **rdb migration** `rdb/NNNN_calendar_full_edit.sql` (the next free
  number on the sha you build on), exactly spec 3.1: the `calendar_events`
  columns, constraints and indexes, the `calendar_guests` table with its RLS
  and composite foreign key. **The same commit** seeds `calendar_guests` in
  `seedTenantAll` (`api/internal/store/crosstenant_test.go`). Tests:
  `TestRLSPoliciesFailClosed`, `TestCrossTenantEveryTable`, the migration
  catalogue gate, on Postgres. Deploy: bootstrap dev; prd via the
  orchestrator. Prove: `information_schema.columns` shows
  `calendar_events.props` and `calendar_guests.response` on dev and prd.
  (FR-012)

### Phase 2: Hub, base (serial)
- [ ] T003 **store base** `api/internal/store/calendar*.go`: `Props`,
  `TimeZone`, `DeletedAt` on `CalendarEvent`; a patch precondition on
  `updated_at` (`ErrEditConflict`); soft delete, `RestoreCalendarEvent`,
  `CalendarTrash`; `deleted_at IS NULL` on every other read; the
  missing-column probe. Memory and Postgres. Tests on Postgres: restore keeps
  the id, the trash lists only the caller's deletions, a stale precondition
  is refused, workspace A cannot restore B's event (AC-07, AC-08). Depends:
  T002. (FR-002, FR-008)
- [ ] T004 **hub base** `api/internal/hub/calendar.go` (+ a
  `calendar_props.go` registry): the 3.3 registry, the new body fields,
  `reminders` as typed `{amount, unit}` (a whole number 1 or more, minutes /
  hours / days, at most 4 weeks, up to 5; owner E2) with the `remind_at`
  mapping both ways, `/reminders` answering
  one item per fire time, `If-Match` -> `409 edit_conflict`, soft `DELETE`,
  `POST .../restore`, `GET /v1/calendar/trash`, the daily
  `./run -a do_spl_calendar_purge_trash` action in `csi-spl-iac` (+ its
  test). Tests: AC-01 (c-394's body), AC-02, AC-03, an unknown `props` key is
  `400`, `TestCalendarSendsNothing` still green. Depends: T003. (FR-001..003,
  FR-007, FR-008)

### Phase 3: Recurrence (serial)
- [ ] T005 **rrule package** `api/internal/calrecur/` (pure; Q1 decided
  `rrule-go` behind a wrapper): parse and validate the 4.4 subset,
  compute `recur_until`, expand `[start, end)` in a time zone with
  exceptions and cancellations, the 2000-occurrence cap, occurrence ids.
  Tests: table tests incl. AC-04's DST case, `-1FR`, `COUNT` vs `UNTIL`, a
  refused rule. Depends: none.
- [ ] T006 **recurrence in store + hub**: series and exception rows; the
  range and marks reads expand series; `?scope=this|following|all` on PATCH
  and DELETE (spec 4.4 table). Tests on Postgres: AC-04 end to end, a
  cross-workspace `recurring_event_id` is refused. Depends: T004, T005.
  (FR-004)

### Phase 4: Guests (serial)
- [ ] T007 **guests + rsvp**: `calendar_guests` in the store; `guests` on
  create and PATCH (kept in `mentions`); `POST .../rsvp` with `this|all`;
  `guests` and `my_response` on the event object. Tests: AC-05, AC-08 for
  guests. Depends: T006 (an answer on an occurrence). (FR-005)
- [ ] T008 **notices**: one notice per guest on invite, time or place change
  and cancel, `notify_guests: false` sends none; a human gets a Flow item (062)
  with Yes / Maybe / No, an agent a spool `note` from `system` (per Q3).
  `TestCalendarSendsNothing` narrowed to the reminder path. Tests: AC-06.
  Depends: T007. (FR-006)

### Phase 5: Find, add, export (parallel)
- [ ] T009 **search** `GET /v1/calendar/search` (spec 4.7) + tests (private,
  demo, deleted filters; cursor; AC-08). Depends: T004; a series matches once
  after T006. (FR-009)
- [ ] T010 **quick add** `api/internal/calquick/` (pure parser, the 4.6
  grammar, table tests incl. AC-09) and the route
  `POST /v1/calendar/events/quick` with `dry_run`. Parser: no dependency; the
  route after T006 (repeats) and T007 (guests). (FR-010)
- [ ] T011 **export** `GET /v1/calendar/export.ics` (spec 4.9) + a golden
  `.ics` test. Depends: T006, T007. (FR-011)
- [ ] T012 **CLI + MCP** for the new calls (`spool calendar edit --scope`,
  `rsvp`, `restore`, `search`, `quick`), golden `testdata` updated. Depends:
  089 T005 and each call it wraps.

### Phase 6: WUI (on top of 089 T008)
- [ ] T013 **drag move / resize** in `wui/src/components/CalendarMainView.vue`:
  drag, bottom-edge resize, drag on empty time to create, `If-Match` on every
  save, `edit_conflict` reload with a short notice. e2e: two tabs drag the
  same event. Depends: 089 T008, T004. (G1)
- [ ] T014 **dialog fields** in `CalendarEventDialog.vue`: reminders list (up
  to 5, each a whole-number field and a minutes / hours / days choice; a
  fraction or 0 cannot be typed), location, colour swatches (theme variables,
  light and dark), time zone picker (default the member's `time_zone`
  preference); event pop-over with Duplicate. No video link, no busy / free
  (owner E3). Depends: T013.
  (G6..G9, G11)
  - The dialog exists (089 T008 v1, c-378): `wui/src/components/CalendarEventDialog.vue`, its rules in `wui/src/utils/calendar-event-form.mjs` (add a field: one key in `calFormFromEvent`, one entry in `calFormBody`), its slot for these fields marked `097 T014..T016` between all day and the Private switch.
- [ ] T015 **repeat + scope**: the repeat menu and Custom editor, the
  "This / This and following / All" prompt on save and delete. Depends: T014,
  T006.
- [ ] T016 **guests**: the guests picker (members and agents), "notify
  guests", answers in the pop-over, Yes / Maybe / No for the viewer. Depends:
  T015, T007, T008.
- [ ] T017 **Undo + trash**: the 10-second Undo toast after a delete, the
  trash list in the calendar menu. Depends: 089 T008, T004. Parallel with
  T013..T016.
- [ ] T018 **quick add, search, export** in the header: the `+` sentence box
  with live `dry_run` preview, the search field and result list, "Export
  .ics". Depends: T009, T010, T011.
- [ ] T019 **help**: extend `doc/doc/help/calendar.md` (repeat, guests,
  reminders, Undo, quick add, search, export), then the help sync. Depends:
  T018 and T016.

### Later (spec section 6, rank 11; each waits for the owner)
- [ ] L1 `.ics` import (`POST /v1/calendar/import`, `dry_run`).
- [ ] L2 private subscribe link with a revocable token (Q7).
- [ ] L3 `push` reminders (after 095) and `email` reminders (mail relay).
- [ ] L4 e-mail invitations, opt-in per workspace (Q3).

<!-- version: 0.3 · updated: 2026-10-06 -->
