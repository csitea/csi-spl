# 106 Calendar on the phone: a phone-first rewrite

**Feature ID**: `106-calendar-phone-rewrite` · **Milestone**: M3 · **Status**: v1.0 (consensus: seats 1..4 agree with changes; owner answered 1A, 2A, 3A)
**Created**: 2026-10-07 · **Drafter**: c-508 (seat 1 draft), folded by a-528 (seat 1 fold) · **Topic**: t1 `197cf92c-785a-4b5a-9ed8-a654a60bbbd6` · lane dispatch `dispatch-197cf92c`
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
| the day | time grid, the now line, all-day row on top | a week strip of seven day chips over the day | same | **Day = time grid, now line, all-day row on top** (drops week strip to maximize grid height and eliminate gesture conflict) |
| create | a round `+` button, bottom corner; a quick sheet with title and time, "More options" for the rest | `+` in a corner, a full form | round `+` button, a quick form | **a round `+` button in the thumb corner opens a half-height bottom sheet** with sticky header Cancel/Save; "More options" grows it to full height with the 097 fields |
| create at a time | tap empty time in Day / Week, the sheet opens with that time | press and hold empty time | tap empty time | **tap empty time in Day: the sheet opens on that hour** |
| open an event | a card with the details and the actions (edit, delete, more) | a full page | a card | **a peek sheet as tall as its content**, Edit / Duplicate / Delete on it; delete is immediate with Undo |
| month cells | events as small coloured bars in the cell | dots | dots | **dots in colour (max 3, then `+n`)**; tapping a day shows its agenda under the grid with 1-tap event peek |

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

- **Header (one row)**: Back (the stack's chevron), the **title** (`October 2026` in Month, `5-11 Oct 2026` in Week, `Wed 2026-10-07` in Day; dates keep the app's ISO style, month names come from `calendar.months`), a search button, the menu (trash, export). An `aria-live="polite"` region on the header outside the turning wrapper announces period changes once (S4-2). Header height <= 48 px. The `2026-10` year-strip row goes.
- **The view** fills everything between the header and the bottom bar.
- **Bottom bar (one row)**: Today (at font level >= 4 or viewport < 400 px, collapses to an icon button showing day number in a frame, `aria-label` "Today", per S4-1), the segmented **Month | Week | Day** (shows short `M` / `W` / `D` from keys `calendar.view_short_{month,week,day}` at font level >= 4 or viewport < 400 px), `<` and `>`. Bottom bar height <= 48 px at level 3. The separate range-label row and the `...` row go.
- **Add button**: a round raised `+` (56x56 px, S2-6), bottom right, positioned `env(safe-area-inset-bottom)` + 16 px above the bottom bar, 16 px from the right edge. All view scrollers leave 72 px bottom padding so the button never occludes the last agenda row or 23:00 (S4-9, 9.4 #12).

Target: at 360x780 and 390x844 the view gets **>= 82 %** of the space the app gives the page (section strip bottom to composer dock top) at font level 3 (restated per seat 3 #11). Header and bottom bar are <= 48 px each (fits H7 control bound). At font level 5, the bars grow only by their text's rem and H8 verifies no wrap and no overflow. The composer dock and the status line stay as the app has them.

### 4.2 The three views

| view | what it shows | a tap on ... |
|---|---|---|
| **Month** | a 6x7 grid of days (Monday first, as the year strip, 16 px side gutters, no cell gap, day number at 0.875 rem); every cell >= 44x44 at 360 px (328 / 7 = 46 px), no upper bound on cell size; up to 3 coloured dots per day, then `+n` (contrast >= 3:1 in all 8 themes); today raised, outlined in `var(--color-accent)` and bold number (WCAG 1.4.1); all-day events placed by UTC date, never viewer zone (S4-3); multi-day events have a dot on each day covered; under the grid, the **agenda of the selected day** (today by default), which scrolls vertically | a day: selects it, its agenda shows under the grid; a second tap on the same day opens it in Day; tapping any event card in the agenda opens its Peek sheet directly (1 tap, S2-3); empty day shows `No events planned · [ + Add event ]` which opens Add sheet preset to that date (2 taps, S2-3) |
| **Week** | a week strip of seven day chips on top, then the seven days as an agenda list; **empty days fold** into one thin row ("Thu-Sat: nothing planned"); multi-day events list under each day as "Day X of Y" (S4-3); the list opens scrolled to today | a chip: scrolls the list to that day; a folded range row: unfolds in place into individual empty day rows with a `+` affordance, or tapping a day chip scrolls and unfolds that day (S2-7); an event: its peek |
| **Day** | **no week strip** (title names the day; swipe, `< >`, or Week tab switches days; dropped per seat 3 #11 and consensus to eliminate gesture conflicts and provide >= 520 px grid height for H8); the all-day row (at most 2 lines, then `+n more`, UTC date); the time grid (hour rows at **48 px**, visible grid >= 520 px, >= 10.5 hours on screen); now line; local hours for date (23 on spring-forward, 25 on fall-back DST, repeated hour labelled twice, S4-6); overlaps cap at 3 columns (>= 44 px wide each), 4th+ becomes `+n` chip opening hour list (S4-4); short events (< 30 min) draw at 24 px minimum height; opened scrolled to now line or first event | empty time: the add sheet on that hour (directional lock & tap slop: < 8 px displacement, < 300 ms dwell; dwell > 400 ms triggers 097 hold-drag, S2-2); an event: its peek; hold: 097's drag to move time only on phone |

Default on open: **Week**, then whatever view the person last used (remembered in `localStorage`, falling back to Week if storage fails, per owner decision Q2).

### 4.3 Sliding between periods

- A sideways swipe on the view turns the period: left = next month / week / day, right = previous. The new page slides in; the old one slides out.
- It is a **page turn, not a scroll**: the view holds the current page and, during a swipe, its neighbour; the container clips them with `overflow-x: clip` (not `overflow: hidden`, 9.4 #5), so nothing can be scrolled sideways and `scrollWidth == clientWidth` always. The leaving page is marked `inert` during the turn. Tab through the view and Today leave `scrollLeft == 0`.
- **Pointer Events with `touch-action: pan-y`** on the view: the browser owns vertical scrolling and sends `pointercancel` on vertical drift.
- **Directional lock & tap slop** (S2-2): if initial touch displacement reaches `dy >= 10 px` before `dx >= 16 px`, lock exclusively to vertical scrolling until touch end. If `dx >= 16 px` and `dx > 1.5 dy`, lock to horizontal page turn. Tap-to-add on empty time triggers on `pointerup` only if total displacement is `< 8 px` and dwell `< 300 ms`; dwell `> 400 ms` without movement triggers 097 hold-to-drag.
- **Interactive 1:1 flat tracking vs 3D release snap** (S2-5, 9.4 #2, #7): during touch tracking (finger down), the view follows the touch 1:1 strictly along the X-axis (`translateX` batched in rAF) with 0 deg rotation for crisp subpixel text rendering. The 3D rotation (`rotateY <= 8deg`) and scale (0.98) engage **only** during the release momentum/snap animation (220 ms ease-out). On animation end (`transitionend`), `transform: none` is restored.
- **Compositor performance** (9.4 #7): animate only `transform` and `opacity` on one wrapper per page; set `will-change: transform` only during the turn; add `backface-visibility: hidden`; keep header, bottom bar and `+` FAB **outside** the turning wrapper; render at most two pages during a turn and only one at rest.
- **Data prefetch** (9.4 #9): when a period settles, prefetch previous and next ranges (`GET /v1/calendar/events`); rapid swipes abort in-flight fetches via `AbortController`.
- **Gesture precedence** (innermost to outermost, 9.4 #3):
  1. A held event (097 drag, `CAL_HOLD_MS` 250 ms, `CAL_TOUCH_SLOP_PX` 8, moves time only on phone).
  2. The week strip (in Week view), which turns by week and stops propagation.
  3. The view, which turns by its own period.
  4. The left-edge Back.
  (A track moving > 8 px before 250 ms is a swipe or scroll, never a drag.)
- **Back stays reachable** (S4 Q3, 9.4.2 Q3, agreed by all): Back is the header chevron, the browser / system Back (`popstate`), and a swipe starting within **24 px** of the left edge (rtl: >= width - 24 px). The view claims swipes via existing `stack.swipe.claim()` at `touchend` unless the touch started in that 24 px edge zone. `utils/mobile-stack.mjs` is not modified (T003 dropped per 9.4 #1).
- `<` / `>` do exactly what a swipe does, so the feature never depends on a gesture.

### 4.4 Add and edit: one bottom sheet, one thumb

- `+` (or a tap on empty time) opens a **half-height bottom sheet** with a **sticky top header containing Cancel (left) and Save (right)** (S2-1). Because Cancel and Save sit in the sticky header, a 300-350 px mobile virtual keyboard never occludes Save, enabling event creation in exactly 2 taps after typing a title with zero scrolling or keyboard dismissal.
- The quick part of the sheet holds: Title (focused, keyboard up), date chip, start and end chips (preset to tapped hour or next full hour), All-day switch.
- **More options** grows the same sheet to full height with 097's fields in 097's order (time zone, location, reminders, colour, repeat, guests, private, description).
- The sheet is themed: date and time chips are WUI controls showing ISO dates and the 24-hour clock; switches replace bare checkboxes; every field is >= 44 px tall.
- Edit opens the same sheet, full height, on the event. Cancel and Save stay in the sticky top header; Delete is bottom left; the confirm question does not move Save.
- The sheet is a mobile-stack overlay (Back closes it), keeps clear of the composer dock and safe-area insets. Dismissal drag-down engages only from the grab bar or header, or when sheet content is at `scrollTop == 0` (9.4 #4). `overscroll-behavior-y: contain` on view and sheet prevents browser reload collisions.

### 4.5 Open, delete

- A tap on an event opens a **peek sheet as tall as its content**: colour, title, time (with source time zone if different, e.g. `15:00 (Europe/Helsinki 16:00)`, S4-6), location, private badge, guests if any, and Edit / Duplicate / Delete in its bottom row. Long titles, locations, and guests wrap cleanly with `overflow-wrap: anywhere` (S4-5).
- **Delete is one tap from the peek**, no question: the event goes and 097 T017's "Event deleted · Undo" bar shows for 10 s. The Undo bar is `role="status"`, and its 10 s timer pauses while focused or hovered (WCAG 2.2.1, S4-2). A repeating event asks 097's This / Following / All first.

### 4.6 Jump and search

- A tap on the title opens the **month picker**: the 12 months of a year as a 3x4 grid, the year changed by `<` / `>` or a sideways swipe, within the 3-year range of 089 (previous, current, next year). A tap on a month opens Month on it. It replaces the 36-mini-month sheet on the phone.
- The search button turns the header into a search field; results are a vertical list grouped by day (097 4.7, `GET /v1/calendar/search`); a tap opens that day in Day with the event's peek.

### 4.7 Look and feel: "3D, harmonic, nice controls"

Only the WUI's own tokens (`src/assets/css/variables.css`), so all palettes and the light theme follow:

| element | treatment |
|---|---|
| raised controls (add button, the selected segment, Today, event cards in Month agenda and Week) | `box-shadow: var(--focus-3d)` plus top-light / bottom-dark inset bevel tokenised as `var(--bevel-shine)` / `var(--bevel-shade)` in `variables.css` in dark and light themes (9.4 #6); pressed = 1 px down, `var(--color-selected)`, inset shadow |
| sheets | top corners `var(--radius-lg)`, `var(--focus-3d)` above the page, grab bar, `overscroll-behavior-y: contain` |
| today | its cell / chip raised and outlined in `var(--color-accent)` and a bold number (never colour alone, WCAG 1.4.1); the now line `var(--color-accent)` with `var(--color-glow)` |
| focus | the one ring: `var(--focus-ring-w) solid var(--focus-ring)`, offset `var(--focus-offset)`, never wider than 3 px; visible outside `--focus-3d` drop shadow |
| radius | `var(--radius)`, `--radius-md`, `--radius-lg`, `--radius-pill` only |
| page turn | 1:1 flat interactive translation (`translateX`) during finger drag; 3D slide on release snap (`perspective: 1200px`, `rotateY <= 8deg`, `scale(0.98)`, 220 ms, ease-out); restored to `transform: none` at rest (S2-5, 9.4 #7) |
| reduced motion | under `prefers-reduced-motion: reduce`: no `rotateY` or scale, no sheet slide, no smooth scroll to now line (`scroll-behavior: auto`), no glow pulse; 1:1 translation swipe still works as direct manipulation input (S4-7, 9.4 #2/#7) |
| type | `rem` only, from the sizes the calendar already uses (0.75 .. 1 rem); everything follows the five font-size levels |
| sizes (H7 split, 9.4 #10, S4-1, S4-4) | **Controls** (header, bottom bar, sheets, peek, picker): >= `var(--tap)` (44 px) and <= 48 px tall at font level 3; the add button 56x56 px; no text button wider than half screen. At font level >= 4, controls grow only by the rem of their text. **Content targets** (month cells, week chips, agenda rows): >= 44x44, no upper bound. **Timed event blocks < 44 px**: exempt from 44 px height bound (minimum 26 px height for <30m at 48 px/hr), stay >= 44 px wide, capped at 3 overlap columns. Scrollers have 72 px bottom padding so the `+` FAB never covers content. |
| contrast (S4-8) | event dots and colours maintain >= 3:1 contrast against surface background across all 8 themes (WCAG 1.4.11) |

### 4.8 Accessibility and semantics (S4-2)

The phone rewrite implements full accessible semantics:
- **Segmented control**: `role="radiogroup"`; each button has `role="radio"` with `aria-checked` and accessible name.
- **Month grid**: `role="grid"`; each cell's accessible name is "Day YYYY-MM-DD, N events" (dots `aria-hidden`, event count spoken). Arrow keys navigate between days.
- **Period change**: announces the new period title once via a single persistent `aria-live="polite"` region located in the header outside turning wrappers.
- **Page transitions**: during a page turn, the leaving page is marked `inert` so screen readers never encounter two simultaneous pages.
- **Bottom sheets**: every sheet is `role="dialog" aria-modal="true"`. Focus moves to Title input (Add) or heading (Peek), and returns to the opening trigger on close.
- **Undo snackbar**: `role="status"`. The 10 s countdown pauses while the bar has focus or hover (WCAG 2.2.1).
- **Non-drag event modification**: in addition to 097 hold-to-drag, full time adjustment is available via Edit sheet time chips (WCAG 2.5.7).

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

| id | requirement | test (at 360x780, 390x844 and 820x1180, dark and light theme) |
|---|---|---|
| **H1** | Month, Week and Day views exist, and each is **one tap** from the other two | e2e: from each view, one tap on the segmented control reaches each other view (`data-view`), 6 pairs |
| **H2** | **Sliding screens**: a sideways swipe turns to the next / previous period, with a slide | e2e: a synthetic touch swipe left / right in each view changes the period by one (`data-period`); 1:1 flat interactive translation during finger drag, 3D transform applied during release snap (220 ms) |
| **H3** | **No horizontal scrolling, only vertical** | e2e: `documentElement.scrollWidth - clientWidth <= 1`, and no element under the calendar has `scrollWidth > clientWidth + 1` with `overflow-x` auto / scroll, in every view, with a sheet open, at font-size levels 1, 3 and 5. `scrollLeft == 0` after Tab through the view and after Today. Tested with 200-character unbroken title and 120-character location (S4-5, 9.4 #5). |
| **H4** | Reminds of Google Calendar's usage, not a copy | review: section 3's patterns are present (segmented views, swipe, title picker, `+` button, quick sheet with sticky header Save, peek); no asset, icon set or wording copied |
| **H5** | Lives up to the current UI: its tokens | lint test: the new phone files hold no colour literal (`#hex`, `rgb(`, `hsl(`) and no `px` radius / shadow other than through the tokens of 4.7; `--bevel-shine` and `--bevel-shade` tokenised in `variables.css` (9.4 #6); e2e reads computed focus outline = `--focus-ring` / `--focus-ring-w`; event dot contrast >= 3:1 against surface tokens verified across all 8 themes (S4-8) |
| **H6** | **Some 3D**, with a reduced-motion fallback | e2e: the add button and the selected segment have a non-`none` `box-shadow`; during a page turn release snap the page has a `rotateY <= 8deg` transform; with `prefers-reduced-motion: reduce` emulated, no 3D transform, no sheet slide, no smooth scroll to now line, but 1:1 translation swipe remains enabled as touch input (S4-7, 9.4 #2/#7) |
| **H7** | **Not too big or too small buttons (split bounds, 9.4 #10, S4-1, S4-4)** | e2e: **Controls** (header, bottom bar, sheets, peek, picker) >= 44x44 always and <= 48 px tall at font level 3 (growing only by text rem above that); add button 56x56 px. **Content targets** (month cells, week chips, agenda rows) >= 44x44 with no upper bound. **Timed event blocks < 44 px** exempt from 44 px height bound (min 26 px height for <30m at 48 px/hr), stay >= 44 px wide, capped at 3 overlap columns. At level >= 4 or viewport < 400 px, Today is icon button and segments show short `M`/`W`/`D`. |
| **H8** | **Harmonic (restated per seat 3 #11)**: one header row, one bottom bar, the view gets the room | e2e: the view's height gets **>= 82 %** of the space the app gives the page (section strip bottom to composer dock top) at 360x780 and 390x844 (measured at font level 3); header and bottom bar are <= 48 px each; Day view shows **no week strip** and has 48 px hour rows, providing visible Day grid >= 520 px (>= 10.5 visible hours at 390x844). At level 5, checked for no wrap and no overflow. |

### 6.2 Functional requirements (FR)

- **FR-001** At <= 820 px `/calendar` renders the phone calendar (`CalendarPhone.vue`, its own lazy chunk); above 820 px it renders today's desktop components, unchanged.
- **FR-002** Default view: Week on first open, then the last view used, stored in `localStorage` in this browser (falling back to Week if storage fails, per Q2).
- **FR-003** Month: 6x7 grid (cells >= 44x44, 16 px gutters, no cell gap), dots per day (colour from event colour, max 3 + `+n`, contrast >= 3:1 in all 8 themes), UTC date for all-day events (S4-3), selected-day agenda with 1-tap peek (S2-3), clear empty state `No events planned · [ + Add event ]` (2 taps to add, S2-3); a second tap on selected day opens Day.
- **FR-004** Week: week strip + agenda, empty days folded into one row, tap on folded range unfolds into individual empty day rows in place with `+` affordance or tapping day chip in strip scrolls and unfolds (S2-7), multi-day events as "Day X of Y" (S4-3), opened at today.
- **FR-005** Day: **no week strip**, all-day row (UTC date, max 2 lines + `+n more`), time grid with hour rows at 48 px (visible grid >= 520 px, >= 10.5 hours), now line, local hours for date (23 on spring-forward, 25 on fall-back DST, S4-6), max 3 overlap columns (>= 44 px wide), short events min 26 px height, directional lock (`dy >= 10 px` before `dx >= 16 px`) and tap slop (< 8 px / < 300 ms; > 400 ms triggers 097 hold-drag, S2-2).
- **FR-006** Swipe turns the period with 1:1 finger follow and 3D release snap; Back is chevron, system Back, and left **24 px** edge swipe (rtl: >= width - 24 px); claims swipe via existing `stack.swipe.claim()` at `touchend` (9.4 #1, S4 Q3); `<` / `>` do the same as a swipe.
- **FR-007** Add / edit is one bottom sheet with Cancel (left) and **Save** (right) in a **sticky top header** (S2-1, keyboard safe); quick part holds title, date, start, end, all-day; More options grows to full height with 097 fields in 097 order; sheet drag-down engages only from header/grab bar or when `scrollTop == 0` (9.4 #4); `overscroll-behavior-y: contain`.
- **FR-008** Peek sheet (4.5); long titles wrap with `overflow-wrap: anywhere` (S4-5); delete from it with 10 s Undo bar (timer pauses on focus/hover, WCAG 2.2.1); repeating events ask the scope first (097).
- **FR-009** Month picker from the title (4.6), 3-year range of 089.
- **FR-010** Search from the header (4.6) over `GET /v1/calendar/search`.
- **FR-011** Desktop unchanged: the desktop e2e (`calendar`, `calendar-events`, 097's `calendar-drag`, `calendar-undo`, `calendar-event-fields` at 1440 px) pass with no edit to their assertions.
- **FR-012** Lazy loading (3 levels: `CalendarPhone` in `pages/calendar.vue`, views async on first show, dialogs async on first open, 9.4 #8); no new packages; initial chunk <= 155 KB; core i18n catalogue untouched.
- **FR-013** Every text in `calendar.*` / `calendar_event.*` / `calendar_phone.*` i18n keys, in every locale file; dates ISO (`date-iso.test.mjs` rules).
- **FR-014** Accessible semantics (S4-2): segmented control `role="radiogroup"` + `aria-checked`, Month `role="grid"`, period change announced via `aria-live="polite"` region on header, leaving page `inert`, sheets `role="dialog" aria-modal="true"`, Undo bar `role="status"`, non-drag editing path.

### 6.3 Acceptance

- **AC-01** H1..H8 green at 360x780, 390x844 and 820x1180, dark and light, font levels 1, 3 and 5.
- **AC-02** Each tap-count target of section 5 met, counted by an e2e that taps through each task.
- **AC-03** A day 3 months ahead is reached in <= 3 taps (title, month, day) when it lies in the shown year; when it lies in the next year (from October to December) it takes 4 taps (title, year, month, day), because the month picker opens on the shown year. Owner choice option A (leave it), 2026-10-08, t1 197cf92c.
- **AC-04** An event added from a tapped 14:00 slot in Day is stored at 14:00-15:00 on that day; Save button clickable without scrolling when virtual keyboard is active (S2-1).
- **AC-05** Delete from the peek, then Undo: the event is back with the same id.
- **AC-06** At 1440x900 the calendar's screenshots and e2e are as before.
- **AC-07** A swipe from the left 24 px edge goes Back to level 1; a swipe right from mid-screen turns to the previous period and stays on `/calendar`.

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
| 1 | c-508 / a-528 | claude / agy | drafted v0.1 (c-508); folded into v1.0 consensus (a-528) |
| 2 | a-526 | agy | reviewed: **agree with changes**, S2-1..S2-7 and Q1..Q3 in 9.5; consensus update in 9.5.2 |
| 3 | c-514 | claude | reviewed: **agree with changes**, 12 changes and Q1..Q3 in 9.4; angle: WUI fit (gestures, mid-phone performance, 155 KB, lazy loading, tokens, H1..H8 test feasibility) |
| 4 | c-515 | claude | reviewed: **agree with changes**, S4-1..S4-9 and Q1..Q3 in 9.3 |

### 9.1 Agreed

All four seats reached unanimous consensus to adopt the rewrite design and H1..H8 with the following agreed refinements:
- **Gestures & swipe**: Drop T003; use existing `stack.swipe.claim()` from `useMobileStack.ts` called at `touchend` with a 24 px left-edge zone for Back (mirrored in RTL). `mobile-stack.mjs` is untouched. 1:1 flat interactive translation during finger touch tracking; 3D `rotateY <= 8deg` tilt and `scale(0.98)` engage only during the 220 ms release snap transition; container clips with `overflow-x: clip`; leaving page is `inert`. Explicit gesture precedence: held event (097) > week strip (Week view) > view period swipe > 24 px left-edge Back. Directional lock: `dy >= 10 px` before `dx >= 16 px` locks vertical scroll; tap slop < 8 px and dwell < 300 ms. Prefetch neighbour periods with `AbortController` cancellation on rapid swipes.
- **Sizing bounds (H7)**: Split bounds into controls and content targets: controls (header, bottom bar, sheets, peek, picker) >= 44x44 always and <= 48 px tall at font level 3 (growing only by text rem above that; FAB `+` is 56x56 px); content targets (month cells, week chips, agenda rows) >= 44x44 with no upper bound; timed event blocks shorter than 44 px exempt from 44 px height bound (min 26 px height for < 30 min at 48 px/hr), stay >= 44 px wide, capped at 3 overlap columns. At font level >= 4 or viewport < 400 px, Today becomes an icon button and segments show short `M`/`W`/`D` (keys `calendar.view_short_{month,week,day}`).
- **Harmonic layout & H8**: Restated to view gets >= 82 % of the page area (section strip bottom to composer dock top) at 360x780 and 390x844 (measured at font level 3). Header and bottom bar are <= 48 px each. Day view drops the week strip to eliminate gesture conflict and recover vertical space (providing >= 520 px visible Day grid, >= 10.5 visible hours at 48 px/hr).
- **Add / edit bottom sheet**: Cancel (left) and Save (right) placed in sticky top header (S2-1) so virtual keyboard (300-350 px) never occludes Save; More options expands to full height with 097 fields; sheet drag-down engages only from header/grab bar or when at `scrollTop == 0`; `overscroll-behavior-y: contain`.
- **Peek & direct interactions**: 1-tap direct Peek from Month view agenda cards (S2-3); clear empty state `No events planned · [ + Add event ]` (2 taps to add); folded empty days in Week view unfold in place on tap with `+` affordance (S2-7).
- **Accessibility & semantics (S4-2)**: Segmented control `role="radiogroup"` + `aria-checked`; Month grid `role="grid"` with spoken event counts and keyboard arrow navigation; period change announced once via `aria-live="polite"` region on header; leaving page `inert`; sheets `role="dialog" aria-modal="true"`; Undo bar `role="status"` (timer pauses on focus/hover); non-drag editing path via time chips. Under reduced motion, 3D transforms, scale, sheet slide, smooth scroll, and glow pulse are removed while 1:1 translation swipe remains enabled as touch input.
- **Tokens & themes (H5)**: Inset bevel tokenised as `--bevel-shine` / `--bevel-shade` in `variables.css` (both light and dark). Today marked by raise, outline, and bold number (never colour alone). Event colours maintain >= 3:1 contrast against surface background across all 8 themes.
- **Data & edge cases**: All-day events placed by UTC date, never viewer zone (S4-3); all-day row capped at 2 lines + `+n more`; local hours for date (23/24/25 on DST transitions, S4-6); multi-day events get a dot on every day covered and list as "Day X of Y"; long titles wrap or clamp with full accessible name preserved (S4-5).
- **Lazy loading (FR-012)**: 3 levels (`CalendarPhone` in `pages/calendar.vue`, views async on first show, dialogs async on first open); no new npm packages; core i18n catalogue untouched; initial chunk <= 155 KB.
- **Owner questions Q1..Q3**: Decided 1A, 2A, 3A by owner HUM-10 (msg fc7ecb8d).

### 9.2 Disputed

None. All four seats reached unanimous consensus. Where initial reviews differed, the version accepted by the other seats was adopted in full:
- **Week strip in Day view**: Seat 2 initially proposed day chips (S2-4), but agreed with Seat 3 (#11) and Seat 4 to drop the week strip in Day view to eliminate swipe boundary conflicts and recover vertical budget (>= 82 % page area, >= 520 px grid height for H8).
- **Left-edge swipe zone**: 24 px adopted over draft's 16 px (proposed by Seat 4 Q3, accepted by Seat 3 9.4.2 Q3 and Seat 2 9.5.2) to clear mobile OS back gestures.
- **3D transition during touch tracking**: 1:1 flat translation during interactive finger tracking adopted over continuous 3D rotation (proposed by Seat 2 S2-5, accepted by Seat 3 #2/#7 and Seat 4) to prevent motion sickness and text distortion, engaging 3D `rotateY <= 8deg` only on release snap.
- **Gesture implementation**: Dropped T003 modifying `mobile-stack.mjs` in favor of existing `stack.swipe.claim()` at touchend (proposed by Seat 3 #1, accepted by Seat 2 and Seat 4).
- **Sizing bounds (H7)**: Split bounds into controls (44..48 px at level 3) and content targets (>= 44x44, no upper bound), exempting short events (proposed by Seat 3 #10 and Seat 4 S4-1/S4-4, accepted by Seat 2).

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

### 9.4 Seat 3 review (c-514, claude): WUI fit

**Verdict: agree with changes.** Section 4's design is right and buildable on today's WUI. The changes below are mostly about the plumbing: how gestures, chunks, tokens and tests work underneath it. Read on trunk `b4b6cf98` (spec at `7fa2858c`); every code claim cites its file.

Verdict per H: H1 agree · H2 agree with 9.4.1 #1, #2, #9 · H3 agree with #5 · H4 agree · H5 agree with #6 · H6 agree with #7, #9 · H7 **change** (#10) · H8 **change** (#11).

#### 9.4.1 Changes (numbered, each concrete)

1. **Drop T003; use the existing swipe claim.** `useMobileStack.ts` already has `stack.swipe.claim()` (CLE-77906, used by `MessageCard.vue` and `useTopicRowSwipe.ts`). The shell's Back handler is a *bubbling* `touchend` on the layout (`layouts/default.vue`, `@touchend.passive`), so a `touchend` listener on the calendar view runs first. It calls `claim()` unless the touch started at x <= 16 (rtl: >= width - 16). `utils/mobile-stack.mjs` stays as it is, so there's no shared-file edit and no `data-swipe-owner` attribute. The 16 px rule moves into T002's `calendar-swipe.mjs` (classify returns `back`, and the view doesn't claim). Claim in `touchend`, never in `pointerdown`/`touchstart`: the shell's `onTouchStart` runs after a descendant's and resets the claim.
2. **Pointer Events with `touch-action: pan-y` for the page turn, and the page follows the finger.** With `pan-y`, the browser owns vertical scrolling and sends a `pointercancel` as soon as it does. The calendar only ever sees horizontal tracks, so it needs no `preventDefault` and no non-passive listener (no scroll jank). Move the page with `translateX` on each `pointermove` (batched in rAF). On release past `MOBILE_SWIPE_MIN_DX`, or a flick faster than 0.5 px/ms, it completes; otherwise it springs back. A turn that fires only on release doesn't feel like Google's "sliding screens".
3. **Gesture precedence, written down in 4.3**, from innermost to outermost:
   1. A held event (097 drag, `CAL_HOLD_MS` 250 ms, `CAL_TOUCH_SLOP_PX` 8, `utils/calendar-drag.mjs`). Once lifted it owns every axis and claims the swipe. On the phone, Day drag moves the time only; another day goes through the sheet's date chip.
   2. The week strip, which turns by week and stops propagation.
   3. The view, which turns by its own period.
   4. The left-edge Back.

   A track that moves more than 8 px before 250 ms is a swipe or a scroll, never a drag.
4. **Sheet drag-down only from the grab bar or header, or when the sheet's content is at `scrollTop` 0.** Otherwise scrolling up inside More options closes the sheet. Add `overscroll-behavior-y: contain` on the view and the sheet, so Chrome Android's pull-to-refresh can't reload the app in the middle of a gesture (the app already uses `contain` on its own scrollers, `main.css` 201, 323, 992).
5. **Clip with `overflow-x: clip`, not `overflow: hidden`.** A `hidden` box can still be scrolled by script: `scrollIntoView`, a focus moving onto the off-screen neighbour page, or scroll-to-today. That slides the page halfway and leaves it there with `scrollWidth == clientWidth` still true. Add to H3: after a keyboard Tab through the view and after Today, every calendar element has `scrollLeft == 0`. Hide the neighbour page with `inert` while it isn't turning.
6. **Tokenise the 3D bevel before H5 can pass.** The raised-button bevel 4.7 points to is written as rgba literals (`main.css` 1211-1212, 1327-1328: `inset 0 1px 0 rgba(255,255,255,.28)`, `inset 0 -1px 0 rgba(0,0,0,.18)`), so a `CalendarPhone*.vue` that reuses it fails H5's own lint. T004 adds `--bevel-shine` / `--bevel-shade` to `variables.css` in both themes (dark and light) and owns that edit. `--focus-3d` stays the drop shadow (zero spread, owner ceiling, `variables.css` 55-57). The lint allows `0`, `transparent`, `currentColor` and `inherit`.
7. **Keep the 3D page turn on the compositor, so a mid phone holds 60 fps:**
   - animate only `transform` and `opacity` on one wrapper per page, never `box-shadow`, `height` or `top`;
   - set `will-change: transform` only during the turn (a permanent layer costs GPU memory on every page);
   - add `backface-visibility: hidden`;
   - keep the `+` button, the header and the bottom bar **outside** the turning wrapper: a transform makes it the containing block of any `position: fixed` child, so a FAB inside it would turn with the page;
   - render at most two pages during a turn and only one at rest; never keep three mounted.
8. **Lazy loading, three levels, and no new package.** `pages/calendar.vue` already loads `CalendarMainView` with `defineAsyncComponent` (line 58). Do the same for `CalendarPhone` (desktop never downloads it, the phone never downloads `CalendarMainView`). Inside it, Month, Week and Day are async on first show, and the sheet, peek, year picker and search are async on first open (the sheet carries 097's ten fields). No gesture or carousel library: Hammer / Swiper / Embla are each several KB gzipped, and the turn is about 60 lines over Pointer Events. FR-012 adds: `calendar_phone.*` i18n keys stay out of the core catalogue. Calendar isn't in `FIRST_SCREEN_PAGES` (`utils/i18n-first-screen.mjs`), so the en core key count from `split-catalogue.mjs` must be unchanged. The headroom is real but small: `ci_initial_gzip_kb` 149.0 of 155 (perf plan E29, n=1). T004's gate records the before and after numbers.
9. **Data on a turn: prefetch the neighbours, abort stale fetches.** When a period settles, fetch its previous and next ranges (`GET /v1/calendar/events`), cached by range, so the arriving page is already filled. Three fast swipes abort the two in-flight fetches (`AbortController`), so the last swipe wins and no stale month paints. A page still loading shows its grid with no dots, not a spinner. Add a mid-phone check to T004: Chrome CPU throttle 4x (`Emulation.setCPUThrottlingRate`, the profile the perf work uses), 5 turns per view, no `longtask` over 50 ms and every turn settled within 300 ms.
10. **H7: split the bounds.** As written ("every visible button, link and input >= 44x44 and <= 48 px tall"), H7 fails on correct content. Month cells at 390 px are 51 px wide and sized by the grid. Agenda rows grow with a two-line title at font level 5. A 15-minute event at 52 px/hour is 13 px tall. Proposal:
    - **Controls** (header, bottom bar, sheets, peek, picker): >= 44 and <= 48 px tall; the `+` is 56.
    - **Content targets** (month cells, week chips, agenda rows): >= 44x44, no upper bound.
    - **Timed event blocks shorter than 44 px** are exempt (097's layout sets their height). The test lists them by `data-event-id` and skips them. Same rule as S4-4, which also keeps them >= 44 px wide and caps overlaps at 3 columns: seat 3 agrees with S4-4, and with S4-1 for font level 5.
11. **H8: restate the number. 65 % at 390x844 is only just reachable as specced.** Measured on screenshot `390/02` (CSS px):
    - The app's own chrome takes 118 px above (top bar and section strip, spec 043's) and about 81 px below (composer dock and status line), which leaves the calendar 645 px.
    - With header and bottom bar at 56 px each, the view gets 533 px = **63 %**: fails H8. At 48 px each it gets 549 px = 65.0 %, exactly on the line. At 360x780 it's 581 - 96 = 485 = 62 % (passes 60 %).
    - Also, today's 52 % was the **time grid**. In Day, the week strip (>= 44) and the all-day row come off the view, so the grid would grow from about 440 to about 470 px. With hour rows growing from 48 to 52 px, that's still about 9 hours on screen against 8 today.

    Proposal:
    - Header and bottom bar <= 48 px each (fits H7's control bound).
    - H8 measured as the view's share of the space the app gives the page (strip bottom to dock top): >= 82 % at both widths.
    - Day shows **no week strip** (the title already names the day; swipe or Week changes it), and its hour rows stay at **48 px**. Then the Day grid is >= 520 px at 390x844 (>= 10.5 hours, against 8 today), and H8 also asserts that number.
12. **Test plan feasibility, and 820 px.** Each H is testable headless, with one caveat each:
    - H2 and AC-07 drive touches with CDP `Input.dispatchTouchEvent`, as `tests/e2e/calendar-drag.test.mjs` 170-183 already does.
    - H6's "transform during the turn" freezes the turn with CDP `Animation.setPlaybackRate` 0 before reading the computed transform. Sampling a 220 ms transition by timing is flaky.
    - Reduced motion comes from `Emulation.setEmulatedMedia`.
    - Add **820x1180** to every phone e2e. It's the widest width that still gets the phone shell (`MOBILE_STACK_MAX_PX` 820), and `calendar-phone.test.mjs` already tests it. Month cells there are about 110 px, so H7's no-upper-bound rule for content (#10) matters.
    - Add **rtl** (one locale) to the swipe tests: the swipe directions and the 16 px edge mirror, as `isMobileBackSwipe` already does.
    - Landscape phones (844x390) are > 820 px, so they get the desktop calendar. Out of scope; listed so nobody files it as a 106 bug.
    - Leave a 72 px bottom padding inside every scroller, so the `+` button never covers the last agenda row or 23:00 (= S4-9).

#### 9.4.2 Owner questions: decided, and how seat 3 builds them

The owner decided **1A, 2A, 3A** (HUM-10, t1 `197cf92c`, msg `fc7ecb8d`, relayed by c-002): the proposals of section 10. Seat 3 had recommended the same three answers. The notes below are build rules, not reopened questions.

| # | decided | seat 3 build note (WUI) |
|---|---|---|
| Q1 | Week = a 7-day list | Each row leads with its start time. The list needs no horizontal layout, so H3 holds at every font level. |
| Q2 | Week first, then the last-used view | Kept in `localStorage` under try/catch, falling back to Week (FR-002), per browser like the theme. |
| Q3 | Swipe right = previous period; Back = chevron, the phone's Back, the left-edge swipe | Built per change #1: the existing `stack.swipe.claim()`, no change to `mobile-stack.mjs`, mirrored in rtl. Seat 3 agrees with seat 4's **24 px** edge over 16: the OS claims about the first 20 px (Android gesture navigation; iOS Safari's edge swipe), and it already reaches the shell as a `popstate`. |

#### 9.4.3 Seat 3 on seat 4 (S4-1..S4-9)

| S4 | seat 3 | why / how it meets 9.4.1 |
|---|---|---|
| S4-1 | **agree** | It fits #10: controls are 44..48 px at level 3 and grow only by their text's rem above that. **One addition:** H8 (#11) is asserted at level 3 only. At level 5 the bars grow by design, and the view's share is checked only for "no wrap, no overflow" (H3). |
| S4-2 | **agree** | (d) `inert` on the leaving page is #5's rule too. The `aria-live` title goes on the header, outside the turning wrapper (#7), so it isn't re-created on each turn and read twice. |
| S4-3 | **agree** | The pure part (UTC-date placement, multi-day spans, midnight split) belongs in T002's `calendar-phone-nav.mjs` with unit tests, not in each view. |
| S4-4 | **agree** | It is #10's exemption for short blocks, plus the 3-column cap and the 30-minute minimum height. With #11's 48 px hour rows, a 30-minute block is 24 px. |
| S4-5 | **agree** | Add the unbroken title to the #5 test fixture too, so H3 and the `scrollLeft == 0` check run on it. |
| S4-6 | **agree** | The Day grid's row count comes from the zone (23/24/25). Day's `>= 520 px` target in #11 is the visible grid height, independent of the row count. |
| S4-7 | **agree** | Same as #2 and #7: under reduce, the finger-follow `translateX` still runs (input), and only the `rotateY`, scale and transitions go. |
| S4-8 | **agree, with a cheaper matrix** | Every theme is right for the colour checks: the dot contrast unit test covers all 8 at no e2e cost, and H5 is a lint. Running the full e2e matrix (8 themes x 3 widths x 3 levels) is about 72 runs per test file and would slow the phone e2e several-fold. Proposal: H3, H7 and H8 run in `dark` and `light` at 360/390/820 and at levels 1/3/5. H5's computed-ring e2e and a today-marker check run once per theme at 390, level 3. |
| S4-9 | **agree** | The same as #12's 72 px bottom padding (56 + 16). The 16 px gutter is also what #11's 360 px arithmetic assumes. |

#### 9.4.4 Top 3, for the fold into v1.0

1. **#11 H8**: as specced, the 65 % target fails at 390 px with 56 px bars. Use bars of 48 px or less, measure the view against the page area, and drop the week strip from Day.
2. **#1 and #3 gestures**: drop T003 for the existing `stack.swipe.claim()`, and write down the hold > strip > view > edge order.
3. **#6 and #10 tokens and sizes**: tokenise the bevel so H5 can pass, and split H7 into controls (44..48) and content (>= 44).

### 9.5 Seat 2 review: a-526 (agy), usability

**Verdict: agree with changes.** H1..H8, section 4 and the tap targets are sound and directly address owner requirements C1..C7. My angle: usability, taps per task, one-thumb reach, swipe vs scroll conflicts, the 3D page turn vs readability, and comparison with Google Calendar's usage. The changes below resolve practical touch interaction conflicts, keyboard occlusions, and readability preservation during gestures.

| # | change | where | concrete rule and its test |
|---|---|---|---|
| S2-1 | **Virtual Keyboard / IME occludes Save button in half-height Add Sheet.** When `+` opens the half-height sheet with Title focused and keyboard up, mobile OS keyboards cover 40-50% (300-350 px) of the screen. If Save is pinned to the sheet's bottom-right, it is hidden beneath the keyboard, forcing an extra tap to dismiss the keyboard or scroll before saving. | 4.4, FR-007, AC-04 | Place the primary action bar with Cancel (left) and **Save** (right) in the sticky top header of the bottom sheet (matching Google Calendar mobile). Tapping `+`, typing a title with the keyboard up, and tapping Save in the sheet header takes exactly 2 taps with zero scrolling or keyboard dismissal. e2e test at 360x780 with simulated virtual keyboard height (300 px) verifies the Save button remains visible, clickable, and within comfortable upper-thumb reach without scrolling. |
| S2-2 | **Day view vertical scroll vs period swipe and tap-vs-scroll slop.** In Day view (1248 px tall grid), natural thumb flicking drifts diagonally. Without a directional lock, diagonal movement can exceed `dx > 1.5 dy` or `MOBILE_SWIPE_MIN_DX = 64` and trigger an accidental day turn. Similarly, fast vertical scrolling can accidentally trigger tap-to-add on empty time slots. | 4.2 Day, 4.3, FR-005, FR-006 | **Directional lock:** if initial touch displacement reaches `dy >= 10 px` before `dx >= 16 px`, lock exclusively to vertical scrolling (`touch-action: pan-y`) until touch end. If `dx >= 16 px` and `dx > 1.5 dy`, lock to horizontal page turn. **Tap slop:** tap-to-add on empty time triggers on `pointerup` only if total displacement is `< 8 px` and dwell `< 300 ms`; pointer held `> 400 ms` without movement triggers 097 hold-to-drag. Test: synthetic touch dragging diagonally (30 px X, 80 px Y) scrolls vertically without changing `data-period`. |
| S2-3 | **Direct 1-tap Peek from Month view agenda and clear empty state.** Tapping a day in Month view shows its agenda below the grid. The spec allows a second tap on the day to open Day view, but does not specify tapping events in this sub-grid agenda or handling empty days. | 4.2 Month, 4.5, FR-003 | Tapping any event card in the Month view agenda under the grid opens that event's Peek sheet directly (1 tap), enabling immediate view/edit/delete from Month view without requiring navigation to Day view first. When a selected day has zero events, the agenda pane displays a clear empty state: `No events planned · [ + Add event ]` which opens the Add sheet preset to that date in 1 tap. Test: in Month view, tap an event in the agenda below the grid -> Peek sheet opens (1 tap). Tap empty day -> tap "+ Add event" -> Add sheet opens with that date selected (2 taps). |
| S2-4 | **Week Strip day chip interaction in Day view.** In Day view, the top week strip displays seven day chips. Tapping another day chip should switch Day view to that day in 1 tap with a directional transition. | 4.2 Day, 4.3, FR-005 | Tapping any of the 7 day chips in the top week strip of Day view navigates Day view directly to that date (1 tap). The active chip shows the raised, accent-highlighted state (`box-shadow: var(--focus-3d)`, `var(--color-accent)`). The page slides in the direction corresponding to the date change. Swiping the week strip horizontally changes the strip by 7 days without changing the currently displayed day until a chip is selected. Test: in Day view, tap the next day's chip in the week strip -> Day view updates `data-period` to that day in 1 tap. |
| S2-5 | **3D transition ergonomics: 1:1 flat interactive drag vs 3D release snap.** Applying `perspective: 1200px` and `rotateY(8deg)` continuously during interactive finger tracking skews text under the moving finger, causing visual disorientation and motion sickness. Google Calendar uses flat 1:1 translation during touch tracking. | 4.7, H6, FR-006 | During interactive touch tracking (finger down), the view follows the touch 1:1 strictly along the X-axis (`translateX(deltaX)` with zero rotation). The 3D rotation (`rotateY <= 8deg`) and scale (0.98) engage **only** during the release momentum/snap animation (220 ms ease-out). On animation end (`transitionend`), `transform: none` is restored so static text retains crisp subpixel antialiasing. Under `prefers-reduced-motion: reduce`, transition is instantaneous with 0 deg rotation. Test: during simulated active drag, computed style shows `rotateY(0deg)` / pure translation; after release, transition applies `rotateY` before reverting to `none`. |
| S2-6 | **FAB `+` button thumb-zone placement and left-handed reachability.** The round `+` button is at the bottom right. On large screens, reaching bottom right with the left hand requires reach across the screen. | 4.1, 4.4, H7, H8 | The `+` button is 56x56 px, positioned `env(safe-area-inset-bottom)` + 16 px above the bottom bar and 16 px from the right edge. In addition, tapping empty slots in Day view or the empty-state button in Month/Week view provides an alternative 1-tap entry point across the screen width. Bottom bar buttons (Today, Month/Week/Day, `< >`) maintain equal thumb-zone distribution across the bar with >= 44 px tap targets. Test: e2e verifies `+` bounding box is 56x56 px, >= 16 px from viewport edges and above bottom bar. |
| S2-7 | **Week View Folded Days tap-to-expand behavior.** Section 4.2 folds empty days into one row ("Thu-Sat: nothing planned"). Users need a simple way to schedule into a folded day without switching to Day view. | 4.2 Week, FR-004 | Tapping a folded range row (e.g. "Thu-Sat: nothing planned") unfolds it in place into individual empty day rows (each with a subtle `+` affordance to add an event on that date), or tapping a folded day's chip in the top week strip scrolls the list and unfolds that day. Test: tapping folded row expands the days; tapping "+" on an unfolded empty day opens Add sheet with that date. |

**Owner questions: seat 2 answers.**

| # | seat 2 recommends | why (usability) |
|---|---|---|
| Q1 | **the list**, as proposed | Seven columns at 360 px width leave < 45 px per day column. Titles are truncated to 2-3 characters ("barcode" view), requiring constant tapping to identify events and skyrocketing tap counts. The list view with folded empty days preserves full-width event titles, effortless vertical thumb scanning, and >= 44 px tap targets (H7). |
| Q2 | **Week first, then the last view used**, as proposed | Week provides the best balance of situational awareness ("what is coming up") without Month's compressed dot representation or Day's single-day tunnel vision. Remembering last-used view in `localStorage` respects individual workflow habits. |
| Q3 | **yes, with primary reliance on chevron and system Back** | In calendar apps (Google, Apple, Outlook), horizontal swipe is the universal mental model for period navigation. Hijacking horizontal swipe for Back breaks this model. Swipe right should navigate to the previous period, while Back is handled by the prominent header chevron, system gesture/hardware Back (`popstate`), and best-effort left-edge detection. |

#### 9.5.1 Top 3, for the fold into v1.0

1. **S2-1 Keyboard-safe Add Sheet:** Place Cancel/Save in the sticky top header of the bottom sheet (Google Calendar pattern) so virtual keyboard popup does not occlude Save or force scrolling/dismissal taps.
2. **S2-2 Gesture locking and tap slop:** 10 px directional lock prevents diagonal scrolling in the 24h Day grid from accidentally triggering period turns, and 8 px tap slop prevents accidental event creation while scrolling.
3. **S2-5 3D transition ergonomics:** Keep interactive swiping 1:1 and flat along X (zero rotation under finger), engaging the 3D `rotateY(8deg)` tilt only during the 220 ms release snap transition, restoring `transform: none` at rest for crisp subpixel text rendering.

#### 9.5.2 Seat 2 on Seat 3 and Seat 4 (consensus)

Seat 2 has reviewed Seat 4's review (9.3, S4-1..S4-9) and Seat 3's review (9.4, 12 changes), as well as Seat 4's concurrence on Seat 3. Seat 2 **agrees in full**:
- **Day view week strip**: Seat 2 endorses Seat 3's recommendation (#11, accepted by Seat 4) to drop the week strip from Day view. This directly eliminates the swipe-boundary conflict between the week strip and the 24-hour time grid, while recovering crucial vertical screen budget (>= 520 px grid height for H8) and keeping Day view uncluttered. Day navigation remains 1 swipe away (day sliding) or 1 tap via the bottom bar `< >` or Week tab.
- **Gesture precedence & implementation**: Seat 2 endorses Seat 3's #1 and #3 (using existing `stack.swipe.claim()` and explicit precedence: held event > week strip > view > 24 px edge).
- **Control vs content sizing (H7)**: Seat 2 agrees with Seat 3's #10 split and Seat 4's S4-1/S4-4 (controls 44..48 px at level 3; content >= 44 px; short blocks exempt).
- **Reduced motion & 3D ergonomics**: Seat 2 agrees with S4-7 and Seat 3's #2/#7: under reduced motion, finger-following 1:1 translation remains available as direct manipulation input while 3D rotation, scaling, and transitions are completely omitted.
- **Unanimous consensus**: With these agreements, all 4 seats are in full alignment for Seat 1 to fold the changes into v1.0.

---

## 10. Questions for the owner

The owner answered **1A, 2A, 3A** (HUM-10, t1 `197cf92c-785a-4b5a-9ed8-a654a60bbbd6`, msg `fc7ecb8d`, 2026-10-07 19:14:23Z, relayed by c-002). All questions are decided and unanimous across all four seats.

| # | question | proposal | decision (HUM-10) |
|---|---|---|---|
| Q1 | Week on the phone: a list of the seven days (what Week is today, with empty days folded) or Google's seven narrow columns on a time grid (about 44 px per day at 360 px, titles cut to a few letters)? | the list | **1A: The list**, with folded empty days (tap-to-unfold in place). |
| Q2 | Which view opens first: Week, Day, or Month? | Week the first time, then whatever was last used | **2A: Week first, then last-used view** (stored in `localStorage`, falling back to Week if storage fails). |
| Q3 | On the calendar a swipe right turns to the previous period. Back stays on the chevron, the phone's Back, and a swipe from the very left edge. Acceptable? | yes | **3A: Yes, with a 24 px left-edge zone** for Back (system Back, chevron, and 24 px left-edge swipe). |

---

## 11. Version log

| version | date | author | change |
|---|---|---|---|
| v0.1 | 2026-10-07 | c-508 | Draft: walkthrough at 390 and 360 px (tree `0bb82f55`, mock build, n=1 per width), clunky list C1..C7, three-app comparison, phone design, H1..H8, tap targets, tasks. |
| v1.0 | 2026-10-07 | a-528 | Consensus v1.0: fold of unanimous reviews from seats 2, 3, 4 and owner decisions (1A, 2A, 3A). Restated H7 (controls 44..48 px at level 3, content >= 44x44, short events exempt) and H8 (view >= 82% of page area, Day drops week strip, bars <= 48 px); dropped T003 in favor of existing `stack.swipe.claim()` with 24 px edge; added sticky header Cancel/Save (S2-1), gesture precedence, directional locking, 1:1 flat tracking with 3D release snap, accessibility semantics (S4-2), tokens `--bevel-shine`/`--bevel-shade`, UTC all-day handling, DST hours. |

<!-- version: 1.0 · updated: 2026-10-07 -->
