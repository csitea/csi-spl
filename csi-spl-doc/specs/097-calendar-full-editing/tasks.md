# 097 Calendar full editing: tasks

Authority for what is built (`spec.md` holds the behaviour and the owner's
decisions, sections 0.1 and 10). Each task is one lane: one agent, one task, the
files it owns, the tests that prove it, its dependencies. Status vocabulary:
`../README.md` §2.3. The owner answered Q1..Q9 "as proposed"
(spec section 10, msg `92b3e0d6`) and approved the mobile-first feature list and rule
in t1 52aee116 (msg `adf16567`); the spec is fully decided; v0.4 adds
mobile-first phone acceptance to WUI tasks.

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
- [x] T002 **rdb migration** `rdb/0139_calendar_full_edit.sql` (c-421, `351d63e8a`; applied on dev and prd 2026-10-06; the next free
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
- [x] T003 **store base** `api/internal/store/calendar*.go` (c-383): `Props`,
  `TimeZone`, `DeletedAt` on `CalendarEvent`; a patch precondition on
  `updated_at` (`ErrEditConflict`); soft delete, `RestoreCalendarEvent`,
  `CalendarTrash`; `deleted_at IS NULL` on every other read; the
  missing-column probe. Memory and Postgres. Tests on Postgres: restore keeps
  the id, the trash lists only the caller's deletions, a stale precondition
  is refused, workspace A cannot restore B's event (AC-07, AC-08). Depends:
  T002. (FR-002, FR-008)
- [x] T004 **hub base** (c-399, `d0d750bb` + `09ac94da`; the purge action is in csi-spl-orc, beside its DB proxy) `api/internal/hub/calendar.go` (+ a
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
- [x] T005 **rrule package** `api/internal/calrecur/` (c-422; pure; Q1 decided
  `rrule-go` behind a wrapper): parse and validate the 4.4 subset,
  compute `recur_until`, expand `[start, end)` in a time zone with
  exceptions and cancellations, the 2000-occurrence cap, occurrence ids.
  Tests: table tests incl. AC-04's DST case, `-1FR`, `COUNT` vs `UNTIL`, a
  refused rule. Depends: none.
- [x] T006 **recurrence in store + hub** (c-441, `7b4265210`; hub v2.3.7 live on dev and prd): series and exception rows; the
  range and marks reads expand series; `?scope=this|following|all` on PATCH
  and DELETE (spec 4.4 table). Tests on Postgres: AC-04 end to end, a
  cross-workspace `recurring_event_id` is refused. Depends: T004, T005.
  (FR-004)

### Phase 4: Guests (serial)
- [x] T007 **guests + rsvp** (c-425, `7d75c7ae`; hub v2.5.6-c2 on dev and prd; `store/calendar_guests.go`; an answer keeps `updated_at`; the route is the session caller's, agents answer once T012 wraps it): `calendar_guests` in the store; `guests` on
  create and PATCH (kept in `mentions`); `POST .../rsvp` with `this|all`;
  `guests` and `my_response` on the event object. Tests: AC-05, AC-08 for
  guests. Depends: T006 (an answer on an occurrence). (FR-005)
- [ ] T008 **notices**: one notice per guest on invite, time or place change
  and cancel, `notify_guests: false` sends none; a human gets a Flow item (062)
  with Yes / Maybe / No, an agent a spool `note` from `system` (per Q3).
  `TestCalendarSendsNothing` narrowed to the reminder path. Tests: AC-06.
  Depends: T007. (FR-006)

### Phase 5: Find, add, export (parallel)
- [x] T009 **search** `GET /v1/calendar/search` (spec 4.7) + tests (private,
  demo, deleted filters; cursor; AC-08) (c-442, `a905f380e`; hub v2.3.9 on dev
  and prd). Depends: T004; a series matches once after T006: T006's follow-up
  in `store/calendar_search.go`. (FR-009)
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

No new backend tasks for mobile: all backend routes (T002..T012) are platform-neutral
REST / JSON / ICS endpoints; touch gestures, full-screen sheets, virtual keyboard adaptation,
and responsive pickers are handled entirely within the WUI surface (T013..T019).

- [x] T013 **drag move / resize** (c-443, `d1693452` + i18n `f944aca3` + e2e/drag fix `3370905e`; WUI v2.4.4 on dev and prd) in `wui/src/components/CalendarMainView.vue`:
  drag, bottom-edge resize, drag on empty time to create, `If-Match` on every
  save, `edit_conflict` reload with a short notice. e2e: two tabs drag the
  same event. Phone acceptance (360 and 390 px): touch hold-to-drag (>= 250 ms)
  moves event without page scroll; bottom resize handle has >= 44x44 px touch
  hit area; drag on empty slot creates event; zero sideways scroll.
  Depends: 089 T008, T004. (G1, spec 5.1.1)
  - **Built** (c-443): the desktop week and the Day view are a 24-hour time grid
    (all-day items on top); the phone Week list moves between days. Pure rules in
    `wui/src/utils/calendar-drag.mjs` (+ `tests/unit/calendar-drag.test.mjs`);
    `calendarUpdate(api, id, patch, today, ifMatch)` sends `If-Match` (the mock
    checks it too); `CalendarEventDialog` takes an optional `span` (HH:MM start /
    end) for a drag-created event; i18n `calendar_event.drag_conflict`. The
    dragged node stays mounted and a ghost shows the drop (a touch must keep its
    target node); the non-passive touchmove guard lives on the scroller for good.
    The hub's event has no `updated_by`, so the notice says "someone else", not
    who. e2e `tests/e2e/calendar-drag.test.mjs` 54/54 (wf 10 green for it on `3370905e`).
- [x] T014 **dialog fields** (c-427, `00135d19`; WUI v2.5.4 on dev and prd) in `CalendarEventDialog.vue`: reminders list (up
  to 5, each a whole-number field and a minutes / hours / days choice; a
  fraction or 0 cannot be typed), location, colour swatches (theme variables,
  light and dark), time zone picker (default the member's `time_zone`
  preference); event pop-over with Duplicate. No video link, no busy / free
  (owner E3). Phone acceptance (360 and 390 px): dialog opens full-screen
  (100vw x 100dvh); fields stack in 1 column without horizontal scroll; reminder
  amount inputs use `inputmode="numeric"`; colour swatches and time zone select
  meet >= 44 px touch targets; Duplicate opens full-screen create form; Save, Cancel,
  and Delete are anchored in a sticky bottom bar reachable by thumb.
  Depends: T013. (G6..G9, G11, spec 5.1.2, 5.1.6, 5.1.9)
  - The dialog exists (089 T008 v1, c-378): `wui/src/components/CalendarEventDialog.vue`, its rules in `wui/src/utils/calendar-event-form.mjs` (add a field: one key in `calFormFromEvent`, one entry in `calFormBody`), its slot for these fields marked `097 T014..T016` between all day and the Private switch.
  - **Built** (c-427): time zone (default the member's `time_zone`; the form's
    clock is wall time in the event's zone; an 089 `UTC` event opens in the
    viewer's zone and keeps `UTC` until the picker moves), location, reminder
    rows (`calReminderAmount` keeps digits only), 11 swatches on
    `--cal-color-*` (`variables.css`, dark + light); actions in UiDialog's
    footer. A click shows `CalendarEventPopover.vue` (Edit, Duplicate); the
    dialog's `copy` prop is Duplicate. e2e `calendar-event-fields` 40/40
    (1440 / 360 / 390). First screen +57 B (`isoDateTime(value, zone)`).
- [ ] T015 **repeat + scope**: the repeat menu and Custom editor, the
  "This / This and following / All" prompt on save and delete. Phone acceptance
  (360 and 390 px): repeat dropdown and Custom cadence editor fit small screen
  without clipping; "This / This and following / All" scope prompt displays as
  a stacked bottom action sheet with >= 44 px buttons reachable by thumb.
  Depends: T014, T006. (spec 5.1.3)
- [ ] T016 **guests**: the guests picker (members and agents), "notify
  guests", answers in the pop-over, Yes / Maybe / No for the viewer. Phone
  acceptance (360 and 390 px): Yes / Maybe / No RSVP buttons sit in the bottom
  thumb-reach zone (>= 44 px height); guest picker input and suggestions dropdown
  scroll smoothly on touch with >= 44 px tap targets; "Notify guests" switch is
  >= 44 px. Depends: T015, T007, T008. (spec 5.1.5)
- [x] T017 **Undo + trash** (c-428, `fd504c40`; WUI v2.5.8 on dev and prd): the 10-second Undo toast after a delete, the
  trash list in the calendar menu. Phone acceptance (360 and 390 px): Undo
  toast floats above bottom navigation bar and composer dock (`--composer-dock-h`),
  never obscuring bottom controls or system gestures; Undo button is >= 44 px;
  trash list renders as full-width mobile view. Depends: 089 T008, T004. Parallel with
  T013..T016. (spec 5.1.4)
  - **Built** (c-428): `CalendarMainView.vue` shows the shared UndoSnackbar
    ("Event deleted · Undo", 10 s, `data-testid=calendar-undo`) on the
    dialog's `deleted`; Undo is `calendarRestore` (POST .../restore, same id).
    On a phone its bottom is the measured bar height + `--composer-dock-h` +
    8 px, 8 px side margins. The bar's ... button (`calendar-menu`, a
    UiPointMenu; T018 adds Export .ics as a second item in `MENU_ITEMS`)
    opens `CalendarTrash.vue` (lazy; GET /v1/calendar/trash, Restore per
    row). `calendar-events-api.mjs` gains `calendarRestore` / `calendarTrash`,
    the mock a soft delete with a 30-day trash; i18n `calendar_trash.*`.
    Tests: `tests/unit/calendar-trash.test.mjs`, `tests/e2e/calendar-undo.test.mjs`
    (AC-07 in the UI at 1440, 360 and 390 px). AC-02: 158532 of 158771 B.
- [ ] T018 **quick add, search, export** in the header: the `+` sentence box
  with live `dry_run` preview, the search field and result list, "Export
  .ics". Phone acceptance (360 and 390 px): Quick add docks above software
  keyboard with live `dry_run` preview without layout jump; search opens full-screen
  with touch filter chips and >= 48 px result rows; "Export .ics" triggers native
  mobile browser calendar import/download. Depends: T009, T010, T011.
  (spec 5.1.7, 5.1.8, 5.1.10)
- [ ] T019 **help**: extend `doc/doc/help/calendar.md` (repeat, guests,
  reminders, Undo, quick add, search, export), then the help sync. Phone
  acceptance: includes mobile gestures (touch-and-hold drag, resize handle,
  thumb reach, mobile Quick add and RSVP). Depends: T018 and T016.

### Later (spec section 6, rank 11; each waits for the owner)
- [ ] L1 `.ics` import (`POST /v1/calendar/import`, `dry_run`).
- [ ] L2 private subscribe link with a revocable token (Q7).
- [ ] L3 `push` reminders (after 095) and `email` reminders (mail relay).
- [ ] L4 e-mail invitations, opt-in per workspace (Q3).

<!-- version: 0.4 · updated: 2026-10-06 -->
