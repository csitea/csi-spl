# 106 Calendar on the phone: tasks

Authority for what is built (`spec.md` holds the behaviour; its section 6.1 holds the owner's hard requirements H1..H8). Each task is one lane: one agent, one task, the files it owns, the tests that prove it, its dependencies. Status vocabulary: `../README.md` §2.3.

**Building starts only after the four-seat review (`spec.md` section 9) and the owner's answers to Q1..Q3** (or the owner's go on the proposals).

Paths: `wui/` = `csi-spl-wui/`, `doc/` = `csi-spl-doc/`.

## Rules for every task

- **Desktop untouched.** No task changes what renders above 820 px. Every task runs the desktop calendar e2e unchanged (`calendar`, `calendar-events`, and 097's `calendar-drag`, `calendar-undo`, `calendar-event-fields` at 1440 px) and they stay green.
- **No hub, store or API change.** Every call exists (089 section 6, 097 section 4).
- **Gate before every push, and again after the mandatory rebase**: `cd csi-spl-iac && ./run -a do_check_pre_push`, plus for `wui/`: `pnpm run test:unit`, `pnpm run typecheck`, the task's e2e against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), `perf-budget.py` / `src/node/test/bundle-size.mjs` (initial chunk <= 155 KB); for `doc/`: `./run -a do_check_dist_hygiene`, `lint-mdlinks`.
- **Every phone e2e runs at 360x780 and 390x844**, dark and light theme, and asserts H3 (no sideways scroll) and H7 (44..48 px controls) on every screen it opens.
- **Tokens only** (H5): no colour literal, no px radius or shadow outside the tokens of `spec.md` 4.7. T004's lint test enforces it for every file named `CalendarPhone*.vue`.
- **Deploy dev and prd, then prove it live**: wf 30, `build.json` (and the footer) on dev and prd show the commit's `v<X.Y.Z>`; `./run -a do_check_deploy_lag`; `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for both envs.
- **097 overlap.** 097 T015 (repeat + scope), T016 (guests) and T018 (quick add, search, export) are open and edit `CalendarMainView.vue` / `CalendarEventDialog.vue`. Tasks here create **new** `CalendarPhone*` files and only read the shared utils; where a 097 task ships a phone part first, the 106 task reuses it instead of rebuilding it. Before starting, check `lane-map.sh --check <paths>` for a live 097 lane.

## Order and parallelism

```
T002 pure utils ─┐
T003 stack swipe ┴─► T004 phone shell ─┬─► T005 Month      (parallel)
                                       ├─► T006 Week       (parallel)
                                       ├─► T007 Day        (parallel)
                                       ├─► T008 add/edit sheet (parallel)
                                       ├─► T009 peek + delete  (parallel)
                                       └─► T010 month picker + search (parallel)
                         T005..T010 ─► T011 retire the old phone branch ─► T012 help ─► T013 live proof
```

T002 and T003 own disjoint files and run at once. T005..T010 each own their own new component and run at once after T004.

---

### Phase 0: Specification
- [x] T001 **spec + tasks** (c-508): `spec.md` v0.1 (walkthrough at 390 and 360 px, clunky list, three-app comparison, design, H1..H8, tap targets) and this file.

### Phase 1: Foundations (parallel)
- [ ] T002 **pure utils** `wui/src/utils/calendar-phone-nav.mjs` (period step for month / week / day, the 6x7 Monday-first month grid, the week strip's seven days, folding empty days into ranges, the next-full-hour preset, the title text per view) and `wui/src/utils/calendar-swipe.mjs` (classify a touch track into `next` / `prev` / `back` / `none`, reusing `MOBILE_SWIPE_MIN_DX`, `MOBILE_SWIPE_MAX_DY` and a 16 px left-edge zone for Back). Owns: those two files, `tests/unit/calendar-phone-nav.test.mjs`, `tests/unit/calendar-swipe.test.mjs`. Tests: month grid across a year end and a leap February; week fold (`Thu-Sat`); swipe left = `next`, right from mid-screen = `prev`, right from x <= 16 = `back`, a diagonal = `none`. Depends: T001 reviewed. Parallel with T003.
- [ ] T003 **stack swipe opt-out** `wui/src/utils/mobile-stack.mjs`: a gesture that starts inside an element marked `data-swipe-owner` is not Back unless it starts within 16 px of the left edge (spec 4.3, Q3). Owns: that change and its unit test (`tests/unit/mobile-stack.test.mjs`, the new cases only). Tests: the new rule; the existing Back swipe on every other page is unchanged (the existing cases stay green). Depends: Q3 answered. Parallel with T002.

### Phase 2: The phone shell (serial)
- [ ] T004 **phone shell** `wui/src/components/CalendarPhone.vue` (its own lazy chunk): the one-row header (Back, title button, search button, menu), the one-row bottom bar (Today, segmented Month | Week | Day, `<` `>`), the round `+` button, the page-turn container (`overflow: hidden`, two pages during a turn, `perspective`, `rotateY` <= 8 deg, 220 ms; nothing under `prefers-reduced-motion`), `data-swipe-owner` on the view, `data-view` / `data-period` attributes, the last-view memory (Week first). `wui/src/pages/calendar.vue`: at <= 820 px render `CalendarPhone` instead of the strip + main view; the > 820 px branch is byte-for-byte the same markup. Placeholder slots for the three views until T005..T007. i18n keys `calendar_phone.*` in every locale. Owns: `CalendarPhone.vue`, the phone branch of `pages/calendar.vue`, `tests/e2e/calendar-phone-shell.test.mjs` (H1, H2 on the placeholders, H3, H6, H7, H8), `tests/unit/calendar-phone-tokens.test.mjs` (H5 lint over `CalendarPhone*.vue`). Depends: T002, T003. Serial.

### Phase 3: Views and sheets (parallel after T004)
- [ ] T005 **Month** `wui/src/components/CalendarPhoneMonth.vue`: the 6x7 grid (cells >= 44x44 at 360 px), up to 3 colour dots then `+n`, today raised, the selected day's agenda under the grid; a second tap on a day opens Day. Reads `GET /v1/calendar/events` for the shown month. Owns: that file, `tests/e2e/calendar-phone-month.test.mjs` (FR-003, swipe = next / previous month, H3, H7). Depends: T004.
- [ ] T006 **Week** `wui/src/components/CalendarPhoneWeek.vue`: the week strip (swipes by week) and the agenda with empty days folded, opened at today. Owns: that file, `tests/e2e/calendar-phone-week.test.mjs` (FR-004, "see next week" in 1 swipe or 1 tap). Depends: T004.
- [ ] T007 **Day** `wui/src/components/CalendarPhoneDay.vue`: the week strip, the all-day row, the time grid >= 52 px per hour, the now line, opened at the now line or the first event; a tap on empty time emits `create(at)`; 097's hold-to-drag and resize through `utils/calendar-drag.mjs` (read only, not edited). Owns: that file, `tests/e2e/calendar-phone-day.test.mjs` (FR-005, hold-drag still moves an event, AC-04 with T008). Depends: T004.
- [ ] T008 **add / edit sheet** `wui/src/components/CalendarPhoneSheet.vue`: half-height quick part (title, date chip, start / end chips, all-day switch, Save bottom right), More options to full height with 097's fields in 097's order, Delete bottom left on edit without moving Save, drag down to close, a mobile-stack overlay, clear of the composer dock and the safe area. Writes through `utils/calendar-events-api.mjs` and `utils/calendar-event-form.mjs` (read only); fires `CALENDAR_CHANGED_EVENT` after a write. Owns: that file, `tests/e2e/calendar-phone-sheet.test.mjs` (add in 2 taps after typing, AC-04 at a tapped 14:00, edit in 3 taps, every field >= 44 px, ISO date and 24-hour clock shown). Depends: T004.
- [ ] T009 **peek + delete** `wui/src/components/CalendarPhonePeek.vue`: content-height sheet (colour, title, time, location, private badge, guests), Edit / Duplicate / Delete; delete at once with 097 T017's Undo bar (`UndoSnackbar`, read only); a repeating event asks 097's scope first. Owns: that file, `tests/e2e/calendar-phone-peek.test.mjs` (open in 1 tap, delete in 2, AC-05 Undo restores the same id). Depends: T004.
- [ ] T010 **month picker + search** `wui/src/components/CalendarPhoneYear.vue` (12 months as 3x4, year by `<` `>` or swipe, 3-year range) and `wui/src/components/CalendarPhoneSearch.vue` (header search field over `GET /v1/calendar/search`, results grouped by day, a tap opens Day with the peek). If 097 T018 has shipped a search component, reuse it. Owns: those two files, `tests/e2e/calendar-phone-jump.test.mjs` (AC-03: 3 months ahead in 3 taps; search opens in 1 tap). Depends: T004.

### Phase 4: Clean-up, help, proof (serial)
- [ ] T011 **retire the old phone branch**: remove the `phone` prop paths, `PHONE_VIEWS` and the `.cal-main--phone` CSS from `wui/src/components/CalendarMainView.vue`, the phone strip-sheet code from `pages/calendar.vue`, the phone-only CSS of `CalendarEventDialog.vue` / `CalendarEventPopover.vue` that no phone screen reaches any more; replace `tests/e2e/calendar-phone.test.mjs` (089 T009's AC-08) with a pointer to the 106 tests. Owns: those removals only. Tests: every desktop calendar e2e green with unchanged assertions (FR-011, AC-06); all 106 phone e2e green; initial chunk <= 155 KB. Depends: T005..T010.
- [ ] T012 **help**: the phone section of `doc/doc/help/calendar.md` (the three views, swipe, the title picker, `+`, the sheet, delete with Undo), then `node src/node/help/sync-help.mjs` and the public copy under `wui/src/public/help-md/` in its own commit. Owns: those files. Depends: T011. Gate: `do_check_dist_hygiene`, `lint-mdlinks`.
- [ ] T013 **live proof**: `wui/tests/e2e/calendar-phone-live.proof.mjs` repeats `spec.md` section 2's walk on dev and on prd (signed in on the e2e host, not the apex), at 360x780 and 390x844, and records each tap count of `spec.md` section 5 against its target, plus H3 / H7 / H8. Screenshots under `/var/tmp`, never committed. Owns: that file. Depends: T012 deployed on dev and prd.

<!-- version: 0.1 · updated: 2026-10-07 -->
