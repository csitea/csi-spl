# Feature Specification: The WUI on Phones and Small Tablets (one panel at a time)

**Feature ID**: `043-spool-wui-mobile` · **Milestone**: M3 · **Status**: In progress (see `tasks.md`)
**Created**: 2026-09-27 · **Lead + verifier**: CLE-35022 · **Epic**: SPL-988 (lanes SPL-989..993)
**Authority**: this file for the rule; `tasks.md` for the lanes, the file ownership and what is built.

Status vocabulary follows `../README.md` §2.3.

## 1. The owner's request, verbatim

prd t1 `#spool-hub-mobile`, topic `c397d781-5d22-4566-8aad-e1d0dfb7b760`, 2026-09-27 07:55-08:08Z:

> we need a complete revamp on the mobile site

> should start with analysis from all of the agent types ...

> than a small discussion on the subject and taking a new plan

> and by mobile I mean up till small tablettes size ...

> the mobile should behave a bit like the slack app

> basically all of the most used functions available on this desktop web app should be available for mobile as well ..

> now the channels and left most pane gets collapsed ...

> the problem is the 3 vertical lines - the regular smart phones are too narrow for that , so we need some kind of
> accordion / each pannel at the time , type of UI ... which will go slowly from left to write and slide .. .

> so first the user will end up always choosing the sections - channels , issues , flow etc. and see the left most
> panel only , than only after clicking the left most panel should close and the middle pannel shoud open , than on
> click the third panel will open and by closing one will be able to go back to the second and the first view

> ok , this is your job to work now autonomously for the next 100 minutes ... fork new agents all of the time

## 2. Scope

- **S1** "Mobile" is a viewport at most **820 px** wide: phones (360-430 px) and small tablets in portrait
  (600-820 px). The one breakpoint is the literal `@media (max-width: 820px)` with the token
  `--mobile-max: 820px` (`assets/css/base.css`); `--tap: 44px` is the touch target.
- **S2** Above 820 px **nothing changes**: the desktop 3-pane layout stays pixel-identical. Every lane proves it
  with a 1440 px screenshot before and after its change.
- **S3** The WUI only (`csi-spl-wui`). The hub API does not change.

## 3. Today, measured (the analysis)

Run: prd e2e, build v0.9.7 (trunk `f9e87b07`), headless Chrome with touch emulation, n=1 per width, 8 routes plus
the open-topic, message-menu, emoji and search flows. The full tables are in the topic (message `a657ea12`,
08:18Z) and in `analysis.md` in this folder.

| area | 360-430 px | 768 px | 820 px |
|---|---|---|---|
| layout | three columns: a 72 px sidebar (rail 18-22 px + list 51-54 px) and a 288-358 px feed | the same 72 px sidebar | the desktop layout (260 + 554) |
| channel and DM names | hidden (`#` and avatars only) | hidden | shown |
| rail tab tap size | 17-21 px | 37 px | 40 px |
| topic pane | 280 px over the feed, which still shows a 72-150 px strip | 380 px overlay | 380 px overlay |
| Back after opening a topic | leaves the page (no history entry) | same | same |
| composer in a channel | **none**: it is in the top bar behind the search icon | top bar | top bar |
| message menu / emoji buttons | 32 / 32 px (at 360 the picker did not open) | 32 / 32 | 32 / 32 |
| hover-only controls | the 3 card-clip mode buttons (opacity 0) | same | same |
| controls under 44 px (#lobby) | 136-138 of 162 | 159 of 163 | 146 of 163 |
| Issues | an 8-column table with 106-130 controls off-screen; the detail is a 380 px overlay | 31 off-screen | 54 off-screen |
| page x-scroll | none | none | none |

AGY-3501 posted an independent code-read analysis (08:11Z). It agrees on every item above. It adds two: no
`viewport-fit=cover` / safe-area insets (notch, home bar), and inputs under 16 px make iOS zoom on focus. It
disagrees on one: it read the phone topic pane as full-width, but the measured width is 280 px.

## 4. The navigation model (the owner's, fixed)

- **N1** The stack has three levels, and **only one is on screen** at <= 820 px:
  1. **Level 1, sections**: the section chooser (DMs, Channels, Issues, Topics, Flow, Event log, Archive, and Users
     for admins) and the chosen section's list, full width, with every name shown.
  2. **Level 2, the list or feed**: the page of the route (a channel, a DM, #lobby, /issues, /search, /settings,
     /events, /archive), full width.
  3. **Level 3, the item**: an open topic, thread or issue, full width.
- **N2** The app opens on level 1. A tap on a row goes to level 2. A tap on a message's topic, a reply count or an
  issue goes to level 3.
- **N3** Closing goes back **one** level (3 -> 2 -> 1). The header's back arrow, a right swipe from the left edge,
  and browser/OS Back all do the same thing, because each level is a history entry.
- **N4** Moving between levels is a 200 ms horizontal slide (forward from the right, back to the right). There is
  none under `prefers-reduced-motion`.
- **N5** One module owns the stack: `composables/useMobileStack.ts` over the pure `utils/mobile-stack.mjs`
  (M1, `f35dca1c`; `rightPanel(open, close)` for an open issue, `558f3e03`). It provides `isMobile`, `level`,
  `push(2)`, `pop()`, `home()` and `rightPanel()`. Route changes and topic opens need no call. No other file writes
  stack or history logic. The shell sets `data-mobile-level="1|2|3"` on `.spool-shell`.

## 5. Decisions (the discussion round, in the topic after the analysis)

| # | question | decision | why |
|---|---|---|---|
| D1 | a bottom tab bar or the level-1 panel? | **level 1**: the sections as a 44 px icon+label strip across the top of level 1, with the list below. No bottom tab bar. | the owner's model makes level 1 the chooser, so a tab bar would duplicate it and cost 56 px on every screen |
| D2 | tablets 600-820 px | one panel, the same as phones | the owner said "up till small tablets", and one rule is simpler to test |
| D3 | message actions | a **visible 44 px menu button**, and a long-press opens the same actions as a bottom sheet (reactions, reply in topic, edit, delete, kind, copy link) | there is no hover on touch |
| D4 | composer | pinned to the **bottom** of levels 2 and 3, above the keyboard (`visualViewport`, `interactive-widget=resizes-content`); on phones the top bar keeps search only, as a full-screen sheet | it is the thumb zone, and it is Slack's pattern |
| D5 | top bar at <= 820 px | one row: back arrow (levels 2 and 3), tenant name, search, avatar. Language, theme and notifications move into the avatar sheet. | four 44 px targets fit 360 px |
| D6 | dropped on phones | the drag dividers, dragging to reorder the rail (still in Settings -> Behaviour), the keyboard-hint lines, the version hover card | there is no mouse or keyboard to use them |
| D7 | the notch and home bar | `viewport-fit=cover`, plus `env(safe-area-inset-*)` padding on the top bar, the sheets and the composer | AGY-3501 |
| D8 | iOS zoom on focus | text inputs are 16 px at <= 820 px | AGY-3501 |

## 6. Functional requirements

- **FR-001** At <= 820 px exactly one of sidebar, main and topic/issue detail is visible (width = viewport), per N1.
- **FR-002** Level 1 shows every channel, DM, topic and issue-epic name; rows are >= 44 px tall.
- **FR-003** Every level-2 and level-3 screen has a back arrow (>= 44 px) at the start of its header.
- **FR-004** Back (arrow, swipe, browser) goes exactly one level up; a deep link to level 3 goes back to its level 2.
- **FR-005** Every interactive control on a level has a hit area of at least 44 x 44 px (the icon may be smaller).
  Inline links inside message text are exempt.
- **FR-006** No control appears only on hover: anything hover-revealed on desktop is always visible, or reachable
  through the long-press sheet.
- **FR-007** A composer is pinned at the bottom of every chat level (channel, DM, #lobby, topic) with attach, emoji
  and send; it stays above the software keyboard; the @ mention list opens upward.
- **FR-008** Issues at <= 820 px: level 2 is a one-column card list (key, title, status, priority, assignee); the
  sort and filter controls live in one sheet; level 3 is the full-screen issue with its subtasks.
- **FR-009** Settings, dialogs and the other pages fit 360 px: dialogs are full-screen sheets, the settings tabs are
  a level-2 list, and label/value grids stack at <= 480 px.
- **FR-010** No horizontal page scroll at any width from 360 to 820 px, on any route.
- **FR-011** Every most-used desktop function has a mobile path (the table in `analysis.md` §5): choose a section,
  open a channel or DM, read, send, attach, react, the message menu, open a topic, reply, search, the issues
  list/open/edit, a new issue, settings, switch tenant, sign out.
- **FR-012** Above 820 px the layout, the dividers and the keyboard shortcuts are unchanged (S2).

## 7. Acceptance

- **A1** The lead's audit (`csi-spl-wui/tests/e2e/mobile-audit-live.proof.mjs`) on prd e2e and dev t1 at
  360x780, 390x844, 430x932, 768x1024 and 820x1180 reads, on every route: one panel visible, no x-scroll,
  0 hover-only controls, and no control under 44 px except those FR-005 exempts.
- **A2** Walking N2 and back (level 1 -> channel -> topic -> Back -> Back) lands on level 1 with browser Back and
  with the arrow, at 390 and 820.
- **A3** The 1440 px screenshots of `/lobby`, `/issues` and `/settings` before and after are identical (FR-012).
- **A4** Every lane: `pnpm run typecheck`, the unit tests, the mock browser e2e, the 160 KB first-paint budget and
  `do_check_dist_hygiene` green; live on dev AND prd (build.json carries the sha); 390 and 820 px screenshots
  posted in the topic.
