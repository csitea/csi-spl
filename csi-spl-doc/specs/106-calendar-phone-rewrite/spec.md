# 106 Calendar on the phone: a phone-first rewrite

**Feature ID**: `106-calendar-phone-rewrite` · **Milestone**: M3 · **Status**: Draft v0.1 (seat 1 of 4, waiting for review seats 2..4)
**Created**: 2026-10-07 · **Drafter**: c-508 (seat 1) · **Topic**: t1 `197cf92c-785a-4b5a-9ed8-a654a60bbbd6` · lane dispatch `dispatch-197cf92c`
**Authority**: this file for how the calendar behaves at <= 820 px; `tasks.md` for what is built. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [089 the Calendar section](../089-calendar-section/spec.md): the section, the event object (6.1), audience, pop-up reminders. Its phone layout (2.2, T009) is what this spec **replaces**.
- [097 full editing](../097-calendar-full-editing/spec.md): drag, reminders, repeat, Undo, search, the mobile-first rules of 5.1. Every 097 feature stays; this spec gives them a phone shell.
- [043 mobile WUI](../043-spool-wui-mobile/spec.md): the mobile stack (level 1/2/3, Back).
- [023 settings](../023-spool-user-settings-keys/spec.md) 3.4: the five font-size levels (every text size is `rem`).
- [027 performance](../027-spool-performance/spec.md): the 155 KB initial chunk.

**Desktop (> 820 px) does not change.** Nothing in this spec alters a pixel above 820 px.

Prose says **workspace**; `<BASE_DOMAIN>` and `<env>` are placeholders.

---

## 1. Why: the owner's ask

Owner HUM-10, t1 `197cf92c`, msg `109ed484`, verbatim:

> "The whole calendar UI and UX on mobile is pretty clunky. It needs a total rewrite."

### 1.1 Owner hard requirements (msgs `466cd622`, `fe747f55`, verbatim)

> "First, proper discussions between at least four agents include AGI in it. Proper discussion for usability. More or less, it should remind the best in the class, which is Google Calendar. Not copy, but remind the usage of it. Use sliding screens. It should be possible to have: - monthly view - weekly view - daily view. There should be no horizontal scrolling, only vertical scrolling."

> "And it should overall live up to the standards of the current UI and be cool-looking. Have some 3D and nice controls. Not too big or too small buttons. Everything should be harmonic and nice."

Each sentence above is a named, testable requirement in section 6 (H1..H8). The four-agent discussion is section 9.

---

## 2. Walkthrough of today's phone calendar

### 2.1 How it was measured

| field | value |
|---|---|
| tree | trunk `0bb82f55` (2026-10-07), WUI footer `v1.1.3` in the mock build |
| build | `NUXT_PUBLIC_USE_MOCK=1 pnpm run generate`, served by `src/node/test/serve-generated.mjs` (the mock workspace: same components as dev and prd, seeded events, no sign-in) |
| browser | headless Chrome, `isMobile`, `hasTouch`, device scale 2 |
| viewports | 390x844 and 360x780 |
| n | one scripted run per viewport (`/var/tmp/c508-walk/walk.mjs`, measures in `/var/tmp/c508-walk/walk.json`) |

Not measured on a signed-in dev or prd page: no proof credential was at hand for this lane. The phone code paths are the same files (`pages/calendar.vue`, `CalendarMainView.vue`, `CalendarEventDialog.vue`, `CalendarEventPopover.vue`, `CalendarYearStrip.vue`); a deployed page can only add real data, not other controls. T013 repeats the walk live.

Screenshots (not committed, the repo bans images): `/var/tmp/c508-walk/390/NN-*.png` and `/var/tmp/c508-walk/360/NN-*.png`, the same 20 steps at both widths.

| # | step | file (390 px; same name under `360/`) |
|---|---|---|
| 01 | app start (level 1) | [01-home](/var/tmp/c508-walk/390/01-home.png) |
| 02 | calendar opens: Day view, today | [02-open-day](/var/tmp/c508-walk/390/02-open-day.png) |
| 03 | Day view scrolled to the end of the day | [03-day-scrolled-end](/var/tmp/c508-walk/390/03-day-scrolled-end.png) |
| 04 | next day | [04-next-day](/var/tmp/c508-walk/390/04-next-day.png) |
| 05 | Week: seven days as a list | [05-week](/var/tmp/c508-walk/390/05-week.png) |
| 06 | next week | [06-next-week](/var/tmp/c508-walk/390/06-next-week.png) |
| 07 | week list scrolled to Sunday | [07-week-scrolled](/var/tmp/c508-walk/390/07-week-scrolled.png) |
| 08 | year strip sheet (36 mini-months) | [08-strip](/var/tmp/c508-walk/390/08-strip.png) |
| 09 | year strip scrolled three months ahead | [09-strip-target](/var/tmp/c508-walk/390/09-strip-target.png) |
| 10 | Day view on that day | [10-target-day](/var/tmp/c508-walk/390/10-target-day.png) |
| 11 | tap an event: the pop-over | [11-event-peek](/var/tmp/c508-walk/390/11-event-peek.png) |
| 12 | Edit: the full dialog | [12-event-edit-dialog](/var/tmp/c508-walk/390/12-event-edit-dialog.png) |
| 13 | Edit dialog scrolled to its end | [13-event-edit-dialog-end](/var/tmp/c508-walk/390/13-event-edit-dialog-end.png) |
| 14 | after Save | [14-after-edit](/var/tmp/c508-walk/390/14-after-edit.png) |
| 15 | New event dialog | [15-new-dialog](/var/tmp/c508-walk/390/15-new-dialog.png) |
| 16 | after Save of the new event | [16-after-add](/var/tmp/c508-walk/390/16-after-add.png) |
| 17 | tap the new event | [17-del-peek](/var/tmp/c508-walk/390/17-del-peek.png) |
| 18 | Delete asks once | [18-del-confirm](/var/tmp/c508-walk/390/18-del-confirm.png) |
| 19 | deleted: the Undo bar | [19-after-delete](/var/tmp/c508-walk/390/19-after-delete.png) |
| 20 | the `...` menu | [20-menu](/var/tmp/c508-walk/390/20-menu.png) |

### 2.2 Tap counts today

Counted by the script, identical at 390 and 360 px. A "tap" is one press; typing a title is not counted.

| task | taps today | how |
|---|---|---|
| see next week (from opening, Day view) | 2 | Week, `>` |
| find a day 3 months ahead | 2 taps + 1 scroll | year-strip button, scroll the 36-month list, tap the day (a 24 px-tall cell) |
| open an event | 1 | tap it: a full-screen sheet with two lines of content |
| add an event | 3 | New event, title, Save; it lands at 09:00-10:00 whatever hour is on screen; another time costs the native time picker (2+ taps per field) |
| edit an event | 3 | event, Edit, Save, in a full-screen form taller than the screen |
| delete an event | 4 | event, Edit, Delete, "Delete this event?" |
| month view | not possible | the phone has Day and Week only (`PHONE_VIEWS = ['day', 'week']`, `CalendarMainView.vue`) |
| search | not possible | no search on the phone |

### 2.3 What is clunky

Ranked by how often a person meets it. Measures are CSS px from `walk.json`.

| # | clunky | evidence |
|---|---|---|
| C1 | **The calendar gets half the screen.** At 390x844 the time grid is ~440 px tall (~52 %) and shows 8 hours; at 360x780 ~375 px (~48 %), 6.5 hours. Around it: a header row holding only the `2026-10` button, then three rows of controls at the bottom (the date label, New / Today / `<` / `>`, then `...` alone on a row beside Day / Week), then the composer dock and the status line. | 02, 03; 360/02 |
| C2 | **No Month view, no swipe.** The owner's three views are two; a period changes only by `<` / `>`. Nothing slides. | 02, 05; `PHONE_VIEWS` |
| C3 | **Opening an event is a full-screen sheet with two lines on it**, and delete is four taps deep (event, Edit, Delete, confirm), although 097 T017 already gives Undo. | 11, 17, 18, 19 |
| C4 | **The add / edit form is a desktop form on a phone.** Ten fields in one full-screen page, 887 px tall (taller than the 844 px screen); the title box is 27 px tall; the checkboxes are browser-small; date and time are grey native boxes that ignore the theme and print `10/07/2026` while the rest of the app prints `2026-10-07`; with the delete question open, Save drops onto a row of its own. A new event ignores the hour on screen (always 09:00). | 12, 13, 15, 18 |
| C5 | **Going three months ahead means scrolling a 36-month list of 24 px-tall day cells** (52x24 at 390, 48x24 at 360: under the 44 px target), opened from a button that costs a whole header row. | 08, 09 |
| C6 | Week is a list in which every empty day still takes a full row (Mon..Sun, ~48 px each), so a quiet week is seven headings, and the list opens at Monday, not today. | 05, 07 |
| C7 | The `...` menu (trash) sits alone on its own row, and the range label is a row of its own: three rows where one would do. | 02, 20 |

Outside this spec (shell, not calendar): at 390 and 360 px the Calendar tab is off-screen in the section strip at app start (01): reaching it needs a sideways swipe of that strip. The owner's "no horizontal scrolling" may well mean that strip too; it belongs to spec 043's owner and is listed here so the reviewers can decide whether to raise it.

---

## 3. How three well-known phone calendars do it

Patterns only; no layout, icon or asset is copied.

| pattern | Google Calendar (phone) | Apple Calendar (iPhone) | Outlook (phone) | what we take |
|---|---|---|---|---|
| views | Schedule, Day, 3 days, Week, Month, from a side menu | Year -> Month -> Day, a zoom: tap a month, tap a day; a list toggle | Agenda, Day, 3 days, Month | **Month / Week / Day, one tap apart**, on a segmented control that is always on screen (owner H1). No side menu: one tap, not two. |
| changing the period | swipe the view sideways, it slides | swipe the week strip or the day | swipe; drag the month strip down to open it | **swipe the view sideways = next / previous period, a sliding page** (H2), plus `<` / `>` for those who cannot swipe |
| jumping far | tap the month name: a month grid drops down | pinch out to Year, tap a month | drag down the month strip | **tap the title (`October 2026`): a month-and-year picker** replaces the 36-month strip |
| the day | time grid, the now line, all-day row on top | a week strip of seven day chips over the day | same | **Day = a week strip of seven chips over a time grid** |
| create | a round `+` button, bottom corner; a quick sheet with title and time, "More options" for the rest | `+` in a corner, a full form | round `+` button, a quick form | **a round `+` button in the thumb corner opens a half-height bottom sheet**; "More options" grows it to full height with the 097 fields |
| create at a time | tap empty time in Day / Week, the sheet opens with that time | press and hold empty time | tap empty time | **tap empty time in Day: the sheet opens on that hour** |
| open an event | a card with the details and the actions (edit, delete, more) | a full page | a card | **a peek sheet as tall as its content**, Edit / Duplicate / Delete on it; delete is immediate with Undo |
| month cells | events as small coloured bars in the cell | dots | dots | **dots in colour (max 3, then `+n`)**; tapping a day shows its agenda under the grid |

---

## 4. The phone design

### 4.1 One screen, three bands

```
+--------------------------------------+
| <  October 2026 v      [Q]  [...]    |  header: Back, title = picker, search, menu (one row)
+--------------------------------------+
|                                      |
|      the view: Month | Week | Day    |  vertical scroll only; a sideways
|      (slides sideways between        |  swipe turns the period
|       periods, a page at a time)     |
|                                      |
|                               ( + )  |  round add button, thumb corner
+--------------------------------------+
| [Today]  [ Month | Week | Day ]  < > |  bottom bar: one row, thumb zone
+--------------------------------------+
| composer dock (the app's, unchanged) |
```

- **Header (one row)**: Back (the stack's chevron), the **title** (`October 2026` in Month, `5-11 Oct 2026` in Week, `Wed 2026-10-07` in Day; dates keep the app's ISO style, month names come from `calendar.months`), a search button, the menu (trash, export). The `2026-10` year-strip row goes.
- **The view** fills everything between the header and the bottom bar.
- **Bottom bar (one row)**: Today, the segmented **Month | Week | Day**, `<` and `>`. The separate range-label row and the `...` row go.
- **Add button**: a round raised `+`, bottom right, above the bottom bar.

Target: at 390x844 the view gets **>= 65 %** of the viewport height (today ~52 %), at 360x780 >= 60 % (today ~48 %). The composer dock and the status line stay as the app has them.

### 4.2 The three views

| view | what it shows | a tap on ... |
|---|---|---|
| **Month** | a 6x7 grid of days (Monday first, as the year strip), every cell >= 44x44 at 360 px (328 / 7 = 46 px); up to 3 coloured dots per day, then `+n`; today raised; under the grid, the **agenda of the selected day** (today by default), which scrolls vertically | a day: selects it, its agenda shows under the grid; a second tap on the same day opens it in Day |
| **Week** | a week strip of seven day chips on top, then the seven days as an agenda list; **empty days fold** into one thin row ("Thu-Sat: nothing planned"); the list opens scrolled to today | a chip: scrolls the list to that day; an event: its peek |
| **Day** | the week strip on top, then the all-day row, then the time grid (hour rows >= 52 px), the now line, opened scrolled to the now line or the first event | empty time: the add sheet on that hour; an event: its peek; hold: 097's drag to move / resize |

Default on open: **Week**, then whatever view the person last used (remembered in this browser). Week answers "what is coming" at a glance; Day is one tap away. (Owner question Q2.)

### 4.3 Sliding between periods

- A sideways swipe on the view turns the period: left = next month / week / day, right = previous. The new page slides in; the old one slides out.
- It is a **page turn, not a scroll**: the view holds the current page and, during a swipe, its neighbour; the container clips them (`overflow: hidden`), so nothing can be scrolled sideways and `scrollWidth == clientWidth` always.
- The swipe uses the app's thresholds (`MOBILE_SWIPE_MIN_DX` 64, `MOBILE_SWIPE_MAX_DY` 48, `dx > 1.5 dy`, `utils/mobile-stack.mjs`); vertical movement scrolls as today (`touch-action: pan-y` on the view).
- In Day and Week the **week strip** swipes by week; the view below swipes by its own period.
- **Back stays reachable.** Today a swipe right starting in the left half of the screen is Back (`MOBILE_SWIPE_EDGE_RATIO` 0.5). On the calendar's view a swipe right turns to the previous period instead; Back is the header chevron, the browser / system Back, and a swipe that starts within 16 px of the left edge. (Owner question Q3.)
- `<` / `>` do exactly what a swipe does, so the feature never depends on a gesture.

### 4.4 Add and edit: one bottom sheet, one thumb

- `+` (or a tap on empty time) opens a **half-height bottom sheet**: Title (focused, keyboard up), a date chip, start and end chips (preset to the tapped hour, or the next full hour on the shown day, for one hour), the All-day switch, **Save** at the bottom right of the sheet.
- **More options** grows the same sheet to full height with 097's fields in 097's order (time zone, location, reminders, colour, repeat, guests, private, description). Nothing new is invented; only the shell changes.
- The sheet is themed: the date and time chips are WUI controls showing ISO dates and the 24-hour clock, which open the platform's own picker (no grey browser box); switches replace bare checkboxes; every field is >= 44 px tall.
- Edit opens the same sheet, full height, on the event. Save stays bottom right; Delete is bottom left; the confirm question does not move Save.
- The sheet is a mobile-stack overlay (Back closes it), keeps clear of the composer dock and the safe-area inset, and drags down to close.

### 4.5 Open, delete

- A tap on an event opens a **peek sheet as tall as its content**: colour, title, time, location, private badge, guests if any, and Edit / Duplicate / Delete in its bottom row.
- **Delete is one tap from the peek**, no question: the event goes and 097 T017's "Event deleted · Undo" bar shows for 10 s. A repeating event asks 097's This / Following / All first.

### 4.6 Jump and search

- A tap on the title opens the **month picker**: the 12 months of a year as a 3x4 grid, the year changed by `<` / `>` or a sideways swipe, within the 3-year range of 089 (previous, current, next year). A tap on a month opens Month on it. It replaces the 36-mini-month sheet on the phone.
- The search button turns the header into a search field; results are a vertical list grouped by day (097 4.7, `GET /v1/calendar/search`); a tap opens that day in Day with the event's peek.

### 4.7 Look and feel: "3D, harmonic, nice controls"

Only the WUI's own tokens (`src/assets/css/variables.css`), so all palettes and the light theme follow:

| element | treatment |
|---|---|
| raised controls (add button, the selected segment, Today, event cards in Month agenda and Week) | `box-shadow: var(--focus-3d)` plus the top-light / bottom-dark inset bevel the app already uses for raised buttons (`main.css`, SPL-1186); pressed = 1 px down, `var(--color-selected)`, inset shadow |
| sheets | top corners `var(--radius-lg)`, `var(--focus-3d)` above the page, a grab bar |
| today | its cell / chip raised and outlined in `var(--color-accent)`; the now line `var(--color-accent)` with `var(--color-glow)` |
| focus | the one ring: `var(--focus-ring-w) solid var(--focus-ring)`, offset `var(--focus-offset)`, never wider than 3 px |
| radius | `var(--radius)`, `--radius-md`, `--radius-lg`, `--radius-pill` only |
| page turn | a short 3D slide: the pages sit in `perspective: 1200px`; the leaving page moves out with `rotateY` up to 8 degrees and `scale(0.98)`, the arriving one in, 220 ms, ease-out |
| reduced motion | under `prefers-reduced-motion: reduce` there is no transform and no transition: the page swaps at once, the sheet appears without sliding |
| type | `rem` only, from the sizes the calendar already uses (0.75 .. 1 rem); everything follows the five font-size levels |
| sizes | every control >= `var(--tap)` (44 px) and <= 48 px tall; the add button 56 px; no text button wider than half the screen |

---

## 5. Tap-count targets

| task | today | target |
|---|---|---|
| switch Month / Week / Day (any to any) | Day <-> Week 1; Month impossible | **1** |
| see next week (from opening, Week) | 2 | **1 swipe or 1 tap** (`>`) |
| find a day 3 months ahead | 2 taps + 1 scroll | **<= 3 taps** (title, month, day) or Month + 3 swipes + 1 tap |
| open an event | 1 (full-screen sheet) | **1** (peek sheet) |
| add an event on the shown day | 3, at 09:00 | **2** (`+`, Save) after typing; **2** at a tapped hour in Day (empty time, Save) |
| edit an event | 3 | **3** (event, Edit, Save) in a sheet that fits without scrolling for title and time |
| delete an event | 4 | **2** (event, Delete) with Undo |
| search | impossible | **1** to open the field |

---

## 6. Requirements

### 6.1 Owner hard requirements (H)

| id | requirement | test (at 360x780 and 390x844, dark and light theme) |
|---|---|---|
| **H1** | Month, Week and Day views exist, and each is **one tap** from the other two | e2e: from each view, one tap on the segmented control reaches each other view (`data-view`), 6 pairs |
| **H2** | **Sliding screens**: a sideways swipe turns to the next / previous period, with a slide | e2e: a synthetic touch swipe left / right in each view changes the period by one (`data-period`); a transform is applied during the turn |
| **H3** | **No horizontal scrolling, only vertical** | e2e: `documentElement.scrollWidth - clientWidth <= 1`, and no element under the calendar has `scrollWidth > clientWidth + 1` with `overflow-x` auto / scroll, in every view, with a sheet open, at font-size level 1 and level 5 |
| **H4** | Reminds of Google Calendar's usage, not a copy | review: section 3's patterns are present (segmented views, swipe, title picker, `+` button, quick sheet, peek); no asset, icon set or wording copied |
| **H5** | Lives up to the current UI: its tokens | lint test: the new phone files hold no colour literal (`#hex`, `rgb(`, `hsl(`) and no `px` radius / shadow other than through the tokens of 4.7; e2e reads the computed focus outline = `--focus-ring` / `--focus-ring-w` |
| **H6** | **Some 3D**, with a reduced-motion fallback | e2e: the add button and the selected segment have a non-`none` `box-shadow`; during a page turn the page has a `rotateY` transform; with `prefers-reduced-motion: reduce` emulated, no transform and a 0 s transition |
| **H7** | **Not too big or too small buttons** | e2e: every visible button, link and input in the calendar is >= 44x44 and <= 48 px tall (the add button 56); month cells >= 44x44 at 360 px |
| **H8** | **Harmonic**: one header row, one bottom bar, the view gets the room | e2e: the view's height >= 65 % of the viewport at 390x844 and >= 60 % at 360x780; header and bottom bar are one row each (height <= 56 px) |

### 6.2 Functional requirements (FR)

- **FR-001** At <= 820 px `/calendar` renders the phone calendar (`CalendarPhone.vue`, its own lazy chunk); above 820 px it renders today's desktop components, unchanged.
- **FR-002** Default view: Week on first open, then the last view used, stored in this browser (a failure to store falls back to Week).
- **FR-003** Month: 6x7 grid, dots per day (colour from the event's colour, max 3 + `+n`), selected-day agenda under it; a second tap on a day opens Day.
- **FR-004** Week: week strip + agenda, empty days folded, opened at today when today is in the week.
- **FR-005** Day: week strip, all-day row, time grid >= 52 px per hour, now line, opened at the now line or the first event; tap on empty time opens the add sheet at that hour; 097's hold-to-drag and resize keep working.
- **FR-006** Swipe turns the period (4.3) with the app's thresholds; a swipe starting within 16 px of the left edge is Back; `<` / `>` do the same as a swipe.
- **FR-007** Add / edit is one bottom sheet (4.4), a mobile-stack overlay; the quick part holds title, date, start, end, all day; More options holds 097's fields; it calls the existing `calendar-events-api.mjs` and `calendar-event-form.mjs` (no new API).
- **FR-008** Peek sheet (4.5); delete from it with Undo (097 T017); repeating events ask the scope first (097).
- **FR-009** Month picker from the title (4.6), 3-year range of 089.
- **FR-010** Search from the header (4.6) over `GET /v1/calendar/search`.
- **FR-011** Desktop unchanged: the desktop e2e (`calendar`, `calendar-events`, 097's `calendar-drag`, `calendar-undo`, `calendar-event-fields` at 1440 px) pass with no edit to their assertions.
- **FR-012** No calendar code in the initial chunk; `ci_initial_gzip_kb` <= 155.
- **FR-013** Every text in `calendar.*` / `calendar_event.*` i18n keys, in every locale file; dates ISO (`date-iso.test.mjs` rules).

### 6.3 Acceptance

- **AC-01** H1..H8 green at 360x780 and 390x844, dark and light.
- **AC-02** Each tap-count target of section 5 met, counted by an e2e that taps through each task.
- **AC-03** A day 3 months ahead is reached in 3 taps (title, month, day).
- **AC-04** An event added from a tapped 14:00 slot in Day is stored at 14:00-15:00 on that day.
- **AC-05** Delete from the peek, then Undo: the event is back with the same id.
- **AC-06** At 1440x900 the calendar's screenshots and e2e are as before.
- **AC-07** A swipe from the left 16 px edge goes Back to level 1; a swipe right from mid-screen turns to the previous period and stays on `/calendar`.

---

## 7. What moves out of the phone view

| goes | replaced by |
|---|---|
| the header row with only the `2026-10` year-strip button | the title, which opens the month picker |
| the 36-mini-month sheet on the phone | the month picker (desktop keeps its 36-month column) |
| the range-label row, the `...` row, the Day / Week row | one bottom bar; the menu in the header |
| the "New event" text button | the round `+` button |
| the full-screen event pop-over | the content-height peek sheet |
| the full-screen ten-field form as the first thing a new event shows | the half-height quick sheet; the ten fields behind More options |
| the delete question | delete with Undo |

---

## 8. Not in scope

- Desktop (> 820 px): no change.
- The hub, the store and the API: no change; every call exists (089 6, 097 4).
- The section strip's own sideways scroll at app start (2.3, last paragraph): spec 043's owner.
- New event fields: 097 owns them; this spec only lays them out on the phone.

---

## 9. Discussion: four seats (owner H-requirement)

The owner asked for "proper discussions between at least four agents", agy included. Seat 1 drafts; seats 2..4 review, each with a verdict on H1..H8, on section 4 and on the open questions; disputes are recorded, not smoothed.

| seat | agent | vendor | status |
|---|---|---|---|
| 1 | c-508 | claude | drafted v0.1 |
| 2 | (requested by c-002) | agy | waiting |
| 3 | (requested by c-002) | claude | waiting |
| 4 | c-515 | claude | reviewed: **agree with changes**, S4-1..S4-9 and Q1..Q3 in 9.3 |

### 9.1 Agreed

(filled after review)

### 9.2 Disputed

(filled after review)

### 9.3 Seat 4 review: c-515 (claude), accessibility and edge cases

**Verdict: agree with changes.** H1..H8, section 4 and the tap targets stand. My angle: screen readers, reduced motion, all-day and multi-day events, long titles, a full day, time zones and DST, 360 px, dark mode. The changes below are the places where v0.1 either breaks one of its own H-tests at the edges or leaves a behaviour unspecified. Facts checked on trunk `bcc13ef2` (2026-10-07). Each fact names the file it came from.

| # | change | where | concrete rule and its test |
|---|---|---|---|
| S4-1 | **H7 / H8 / H3 at font level 5 do not fit 360 px as drawn.** Level 5 is a 22 px root (`base.css:16`, 023 3.4). At that size the bottom bar (Today + `Month\|Week\|Day` + `<` `>` + gaps + 16 px gutters) needs about 390 px. So at 360 px it either wraps (H8 red) or overflows (H3 red). A 1 rem field with padding is also taller than 48 px (H7 red). | 4.1, 4.7 "sizes", H7 | At **level >= 4, or a viewport < 400 px**: Today becomes an icon button (the day number in a frame, `aria-label` "Today"). The segments show `M` / `W` / `D` from the new keys `calendar.view_short_{month,week,day}`, and each keeps its full word as its accessible name. The title truncates with an ellipsis, never wraps, and its `aria-label` carries the full text. H7 becomes: ">= 44x44 always; <= 48 px tall **at level 3**, growing only by the rem of its text above that". The H3, H7 and H8 tests run at levels 1, 3 and 5. |
| S4-2 | **Screen-reader semantics are not specified.** Today's calendar has 37 `aria-*` / `role` attributes (`grep -c` over `Calendar*.vue`), and the year strip is already a `role="grid"`. The rewrite must not lose them. | new 4.8 | (a) Segmented control = `role="radiogroup"` + `aria-checked`. (b) Month = `role="grid"`; each cell's name is "Wed 2026-10-07, 3 events". The dots are `aria-hidden` and the count is spoken. Arrow keys move between days. (c) A period change, by swipe, by `<` / `>` or by the picker, announces the new title once in one `aria-live="polite"` region. (d) During a page turn the leaving page is `inert`, so nothing reads two pages. (e) Every sheet is `role="dialog" aria-modal="true"`. Focus goes to the Title (add) or to the sheet heading (peek), and returns to the control that opened it on close. (f) The Undo bar is `role="status"`. Its 10 s timer pauses while it has focus or hover (WCAG 2.2.1). (g) 097's hold-to-drag has a non-drag path: Edit, then the time chips (WCAG 2.5.7). Test: an e2e asserts (a)..(f) by attribute, and a keyboard-only run does add, open and delete. |
| S4-3 | **All-day and multi-day placement.** 089 stores all-day as midnight UTC to the next midnight (089 6.1). Converted to a viewer's local time west of UTC, it lands on the previous day. The desktop avoids this by reading the date part (`calendar-drag.mjs:52`, `starts_at.slice(0,10)`). | 4.2, FR-003..005 | The phone places **all-day events by their UTC date, never by the viewer's zone**, through the same helper. A multi-day event gets a dot on **every** day it covers (the event counts toward that day's 3-dot cap). In Week it lists under each day as "Day 2 of 3". In Day, an all-day event sits in the all-day row. A timed event that crosses midnight draws to 24:00 with a "continues" mark, then from 00:00 the next day. The all-day row shows at most 2 lines, then `+n more`, which expands in place, so it never eats the grid (H8). Test: a fixture with an all-day event, a 3-day event and a 22:00-02:00 event, run under `emulateTimezone` `America/New_York` and `Asia/Tokyo`. Each appears on the right day(s). |
| S4-4 | **A full day: 20 events, overlaps, short events.** At 52 px per hour a 15-minute event is 13 px tall. Side-by-side overlaps at 360 px get under 44 px wide. | 4.2 Day, H7 | In Day: at most **3 overlap columns** (about 100 px each at 360). A 4th or later overlapping event becomes a `+n` chip in its slot, which opens that hour's list. Blocks shorter than 30 min draw at the 30-min height (26 px), with the title on one line. H7 exempts grid blocks from the 44 px **height** only: they stay >= 44 px wide, and every agenda row (Month, Week) is >= 44 px tall. Month agenda and Week lists scroll vertically with no cap. Test: a fixture with 20 events on one day, 5 of them overlapping at 14:00. Every event is reachable by a tap or through `+n`, and H3 stays green. |
| S4-5 | **Long titles must never widen anything.** An unbroken title (a URL, a long word) can push `scrollWidth` past `clientWidth` and fail H3 in the peek or the agenda. | 4.2, 4.5, H3 | Grid blocks: one line, ellipsis. Agenda rows: 2 lines (`line-clamp`). Peek: the full title wraps (`overflow-wrap: anywhere`), and so do location and guests. Every truncated text keeps its full value as its accessible name. Test: the H3 fixture adds a 200-character unbroken title and a 120-character location. |
| S4-6 | **Time zones and DST.** v0.1 says nothing about which zone the grid uses, or about 23- and 25-hour days. The next transitions are 2026-10-25 (EU) and 2026-11-01 (US). | 4.2 Day, 4.4 | Times show in the viewer's display zone: the hub `time_zone` preference, else the browser's (as `calendar-event-form.mjs:19` already resolves it). When an event's own zone (097 G9) differs, the peek adds it: `15:00 (Europe/Helsinki 16:00)`. The Day grid draws **the local hours of that date**: 23 rows on spring-forward and 25 on fall-back, with the repeated hour labelled twice. The now line and tap-to-add both resolve through the zone, never by `hour * 52 px` from local midnight. Test: `emulateTimezone('Europe/Helsinki')` on 2026-10-25 shows 25 hour rows. A tap on the second 03:00 stores `2026-10-25T01:00:00Z`. |
| S4-7 | **Reduced motion covers more than the page turn.** | 4.7, H6 | Under `prefers-reduced-motion: reduce`: no `rotateY` or scale, no sheet slide, no smooth scroll to the now line (`scroll-behavior: auto`), and no glow pulse on the now line. The swipe **still works** (it is input, not motion); the page simply swaps. Test: the H6 reduced-motion run also checks the sheet and the scroll-to-now line, and asserts that a swipe still changes `data-period`. |
| S4-8 | **Dark mode and palettes: colour is never the only signal.** `variables.css` defines eight themes, not two: the default, `dark`, `light` and five `light-*` (`grep -c '^:root\[data-theme=' variables.css` -> 7, plus `:root`). The event dots use the event's own colour on the cell's background. | 4.7, H5, AC-01 | Tests run in **every theme**, not "dark and light". Event colours (097) must reach >= 3:1 against the Month cell background in each theme (WCAG 1.4.11). A unit test checks the colour list against each theme's surface token. Today is marked by its raise and outline **and** a bold number, never by colour alone (1.4.1). The focus ring stays visible on raised controls, because `--focus-3d` is a zero-spread drop shadow and the ring sits outside it. |
| S4-9 | **360 px arithmetic depends on the gutter.** The 46 px cell (328 / 7) only holds with 16 px side gutters and no cell gap. | 4.2 Month, 4.1 | State it: the Month grid has a 16 px side gutter, no inter-cell gap, and the day number at 0.875 rem. The round `+` sits `env(safe-area-inset-bottom)` + 16 px above the bottom bar and never covers the last agenda row: the list gets bottom padding equal to the button's height plus 16 px. Test: at 360x780, level 5, the last agenda row is tappable without the `+` on top of it. |

**Owner questions: seat 4 answers.**

| # | seat 4 recommends | why (accessibility / edge) |
|---|---|---|
| Q1 | **the list**, as proposed | Seven columns at 360 px are about 44 px each. At level 5 a title then shows 2..3 letters. A screen reader reads seven columns in grid order, not time order. The list reads naturally, wraps long titles, and passes H3/H7 at every level. |
| Q2 | **Week first, then the last view used**, as proposed | One rule to add: when storage fails (private mode), fall back to Week without an error (FR-002 already). The choice is per browser, like the theme and the font size (023 3.4). |
| Q3 | **yes, with a 24 px edge** instead of 16 | iOS Safari and Android gesture navigation claim about the first 20 px for system Back, so 16 px is mostly never seen by the page. 24 px catches the rest. Screen-reader users (VoiceOver and TalkBack take over swipes) and switch users never need a swipe: the chevron, `<` and `>` cover every gesture (WCAG 2.5.1). |

---

## 10. Questions for the owner

| # | question | proposal |
|---|---|---|
| Q1 | Week on the phone: a list of the seven days (what Week is today, with empty days folded) or Google's seven narrow columns on a time grid (about 44 px per day at 360 px, titles cut to a few letters)? | the list |
| Q2 | Which view opens first: Week, Day, or Month? | Week the first time, then whatever was last used |
| Q3 | On the calendar a swipe right turns to the previous period. Back stays on the chevron, the phone's Back, and a swipe from the very left edge. Acceptable? | yes |

---

## 11. Version log

| version | date | author | change |
|---|---|---|---|
| v0.1 | 2026-10-07 | c-508 | Draft: walkthrough at 390 and 360 px (tree `0bb82f55`, mock build, n=1 per width), clunky list C1..C7, three-app comparison, phone design, H1..H8, tap targets, tasks. |

<!-- version: 0.1 · updated: 2026-10-07 -->
