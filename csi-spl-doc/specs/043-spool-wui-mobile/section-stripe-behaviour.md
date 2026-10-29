# Section stripe on a phone: when it shows (panel consensus)

Issue SPL-3785 · Epic SPL-2403 · Spec [043](spec.md) · Panel of 2 seats.

**Signatures** (both on one sha):

- claude seat, editor (c-381): SIGN 5034f89d9
- mistral slot, held by a claude seat (c-382): SIGN 5034f89d9 (spool msg 21ac9bf6, task dispatch-c3e53990)

The seat files, each written before its author read the other one:
[seat-claude.md](section-stripe/seat-claude.md) and
[seat-mistral.md](section-stripe/seat-mistral.md). This file merges them.
Nothing is built until the owner picks an option in section 6.

## 1. The ask

The owner (HUM-10, t1 topic c3e53990), in five messages:

- "On mobile, the stripe with the sections is not logically consistent. Its
  behavior: when does it appear, and when not?" (msg 3f0287cd)
- "whenever one has entered the first "level" of it, it should always be
  shown" (msg 1f55e7e1)
- it "is shown on the channels level but is not shown on the deeper levels"
  (msg 09d53b49)
- on Monitoring it must not "jump on and off based on the tab which has
  been clicked" (msg c3c2ff9b)
- "the top stripe is like the Windows taskbar ... shown and closed
  automatically, or something like that. I'm open to every suggestion"
  (msg 88e2c419)

## 2. Today, measured

### 2.1 How it was measured

- **Live** (seat-mistral 1.1): dev build `b3cb06eea`, measured at
  2026-10-27T08:00Z in headless Chrome at 390 x 844 with touch, signed in as
  the dev t1 probe member, read-only. Each cell was opened once by a deep link
  (n = 1 per cell). One topic was opened by a tap.
- **Code** (seat-claude 1.1): `isSectionPage()` imported from
  `csi-spl-wui/src/utils/section-strip.mjs` on origin/master `f013a4711` and
  called on 45 page paths (n = 45). For every path the live run also covered,
  its shown or not-shown verdict matches the live one.
- The rule, at `csi-spl-wui/src/layouts/default.vue:404`:
  `sectionStrip = isMobile && level === 2 && isSectionPage(path)`. Level 1
  always has the stripe, because level 1 is the sidebar itself.
- Not measured: the tap path into every route, a reply (`?in=`), a DM
  thread, tablet widths (600 to 820 px), a real phone.

### 2.2 Section x level -> stripe (live)

When the stripe shows, it sits at y = 58 to 119: 61 px, which is 7.2 % of an
844 px screen.

| section | route opened | level | stripe | Back |
|---|---|---|---|---|
| Channels (front door) | `/` | 1 | **shown** | 0 |
| Channels | `/lobby`, `/channel/lobby` | 2 | not shown | 1 |
| Channels | `/channel/lobby?topic=…` (tap), `/t/<uuid>` | 3 | not shown | 1 |
| DMs | `/dm` | 1 | **shown** | 0 |
| Issues | `/issues` | 2 | **shown** | 0 |
| Archive | `/archive` | 2 | **shown** | 0 |
| People | `/people` | 2 | **shown** | 0 |
| People | `/people/<id>` | 2 | not shown | 1 |
| Calendar | `/calendar` | 2 | **shown** | 1 |
| Monitoring | `/monitoring/agents`, `/boxes`, `/events` | 2 | **shown** | 0 |
| Monitoring | `/monitoring/costs`, `/lanes`, `/tokens` | 2 | not shown | 1 |
| Monitoring | `/monitoring/agents/<id>`, `/monitoring/boxes/<id>` | 2 | not shown | 1 |
| Reporting | `/reporting/releases` | 2 | **shown** | 0 |
| Reporting | `/reporting/issues`, `/lanes`, `/posts`, `/sql`, `/tokens` | 2 | not shown | 1 |
| Help | `/help` | 2 | **shown** | 0 |
| Help | `/help/<page>` | 2 | not shown | 1 |
| Docs | `/docs` -> `/workspace/docs` | 2 | not shown | 1 |
| Workspace settings | `/tenant-settings` | 2 | **shown** | 0 |
| Workspace settings | `/tenant-settings/<section>`, `/users` -> `/tenant-settings/members` | 3 | not shown | 1 |
| Search | `/search` | 2 | not shown | 1 |
| Settings | `/settings` -> `/lobby?settings=` | 2 | not shown | 1 |

### 2.3 The two defects

1. **A hand-kept list that drifts.** `SECTION_PAGES` names 18 paths. It is
   missing 3 of the 6 Monitoring tabs, 5 of the 6 Reporting tabs, every
   Workspace settings section and `/workspace/docs`. A tab added later does
   not fail any check when it is left out of the list, which is why the
   stripe "jumps on and off by tab".
2. **A rule that drops the stripe one level down.** CLE-77886 says "a
   drill-down keeps its own header and Back". So a channel, a topic, a
   person, an agent, a box, a help page and every settings section replace
   the stripe with that header. This is the owner's "not shown on the deeper
   levels".

## 3. Candidates

These hold for every candidate:

- The 44 px targets (`--tap`) stay, and so do the whole-controls-only rule
  (SPL-2062 `stripFit`) and the endless roll (`loopPosition`).
- CSP forbids a new inline `:style`, so each state is a `data-*` attribute
  on `.spool-shell` plus CSS.
- The initial JS ceiling `ci_initial_gzip_kb` is 155 KB, with 149.7 KB the
  last recorded value
  (`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`).
- The apps named come from general knowledge of their phone apps. This panel
  did not measure them.

| | behaviour, every level and tab | Back | keyboard | accessibility | space at levels 2 and 3 | JS / CSP | used by |
|---|---|---|---|---|---|---|---|
| **A** pinned | shown at levels 1 to 3 on every default-layout route; a drill-down's own header and Back sit **under** it | unchanged (spec 087, one level) | folds while the on-screen keyboard is up, returns when it closes | existing tablist and focus ring; nothing moves on its own; the fold is instant under reduced motion | 61 px | about 0 KB; one computed, the list removed | iOS tab bars on pushed screens (Apple Music, App Store, Instagram, X); Google Photos, YouTube, Gmail |
| **B** A + hide on scroll | as A, but slides away on scroll down; returns on scroll up, at the top, on Back, on a level or tab change, and when focus enters it | Back always shows it | as A | `transform` only, no slide under reduced motion; `inert` while hidden; focus inside forces it visible | 0 to 61 px | a listener for each scroller (feed, topic, page lists, Docs reader); about 1 KB gz, unmeasured, client-only after first paint | Chrome and Safari address bars, X, Facebook, Reddit |
| **C** handle | full at level 1; at levels 2 and 3 a 44 px handle (section icon and chevron), and a tap or swipe opens the stripe over the content | Back closes an open stripe first (spec 043 T055) | handle stays | button with `aria-expanded`, Escape closes, the swipe has a tap alternative; easy to miss | 44 px | a small component | Maps bottom sheets, Android notification shade |
| **D** bottom bar | the sections move to a bottom bar at every level | unchanged | hidden while typing | best thumb reach, but only 5 or 6 targets fit, so it needs a "More" | about 56 px plus the safe area, on the same edge as the composer dock and the status strip | a new component and the rail order logic again; spec 043 D1 rejected it | WhatsApp, Instagram, Slack |
| **E** today's rule, exact | every tab of a section derives from the route; drill-downs still swap the stripe for their header | unchanged | unchanged | unchanged | 0 on drill-downs | about 0 KB | none: this is the baseline |

E fixes defect 1 and leaves defect 2, which the owner named in msg 09d53b49.
It is listed so the owner can see the smallest possible change.

## 4. Recommendation: A, pinned, with the keyboard fold

Both seats recommend A.

- It is the owner's own rule (msg 1f55e7e1): once inside a section, the
  stripe is always there.
- It ends the jumping. The stripe changes only when the keyboard opens or
  closes, and phone users already expect that.
- It costs no JS and removes code: the list and the level-2 special case go.
- B answers "shown and closed automatically" (msg 88e2c419), but it still
  moves on its own, now under the thumb, and it needs a listener on every
  scroller. The seats differ only on when B comes. The claude seat had it
  right after A, the other seat as a later opt-in. The merge: B is its own
  option in the poll, built as slice 6 on top of A only if the owner picks it.
- The price is 61 px at levels 2 and 3. If that is too much, a later slice
  can make the stripe compact (icons only, about 48 px). It should not start
  that way, because a height change between levels is a small jump of its own.

### 4.1 Wireframes (390 px, A)

Level 1, Channels:

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |  top bar
+--------------------------------------+
| [Chan*] [DMs] [Issues] [Flow] [Mon]  |  stripe, Channels selected
+--------------------------------------+
| # lobby                              |
| # dev                                |
+--------------------------------------+
| . bell  note            v6.x.y       |  status strip
+--------------------------------------+
```

Level 2, a channel:

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |
+--------------------------------------+
| [Chan*] [DMs] [Issues] [Flow] [Mon]  |  same stripe, same place
+--------------------------------------+
| <  # lobby                           |  the drill-down's own header + Back
| card: topic A                        |
| card: topic B                        |
+--------------------------------------+
| [ composer ......................  ] |
+--------------------------------------+
```

Level 3, a topic (a reply view looks the same):

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |
+--------------------------------------+
| [Chan*] [DMs] [Issues] [Flow] [Mon]  |
+--------------------------------------+
| <  Topic A title                     |  Back goes to the channel
| message 1                            |
|   reply 1.1                          |
+--------------------------------------+
| [ composer ......................  ] |
+--------------------------------------+
```

Monitoring, any tab:

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |
+--------------------------------------+
| [Issues] [Flow] [Mon*] [Rep] [Help]  |  stripe, Monitoring selected
+--------------------------------------+
| Agents | Boxes | Events | Costs ...  |  the section's own tabs
| ...                                  |
+--------------------------------------+
```

Any level, keyboard up:

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |
+--------------------------------------+
| <  Topic A title                     |  stripe folded away
| message 1                            |
| [ composer, typing ..............  ] |
+--------------------------------------+
|          on-screen keyboard          |
+--------------------------------------+
```

B, scrolled down a feed (only if B is picked):

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |  stripe slid away
| <  # lobby                           |
| card: topic C                        |
```

## 5. Build slices (A; slice 6 only for B)

Each slice is one small lane. Each e2e builds its route list at run time
from `csi-spl-wui/src/pages/**/*.vue`, because the file tree is the route
table:

- a `[param]` gets a sample value from `utils/mock-data.mjs`;
- a page whose own `definePageMeta({ layout })` is `'login'` or `false`
  (login, checkout, blog, public calendar) is dropped, found by reading the
  file and not from a list;
- the tabs of Monitoring and Reporting are also read from `MONITORING_TABS`
  and `REPORTING_TABS`.

No hand-kept list is used, so a new page or tab is in the test the day it
lands. Every check runs at 360 and 390 px, in the dark and the light scheme.

| # | slice | change | its test |
|---|---|---|---|
| 1 | the section of a route, derived | `sectionOf(path)` in `section-strip.mjs`, built on `tabForPath` (`utils/sidebar-tabs.mjs`) and `railLinkSection`, mapping `/lobby`, `/workspace/docs` and `/tenant-settings/*`; `SECTION_PAGES` and `isSectionPage` removed | unit: walk `src/pages/**`; every default-layout page has a section. Red control: a planted page with no section fails |
| 2 | stripe at every level | `default.vue` and `ChannelSidebar.vue` (`stripOnly`): `sectionStrip = isMobile && sectionOf(path) !== ''` at levels 1 to 3; the drill-down header and Back render under the stripe; the level-3 pane and a page's right panel (issue detail) start under it; a section's own top page still shows no title; `TabletStrip` stays hidden while the stripe is up | e2e: every route from the walk, plus one drill-down per dynamic route (a channel, a `?topic=`, a `?in=`, a person, an agent, a box, a help page, an issue): the stripe is painted right under the top bar with its section selected, there is exactly one Back from level 2 on, and there is no horizontal scroll. Red control: restore the `level === 2` check and the drill-down rows fail |
| 3 | keyboard fold | `visualViewport` resize, or `--kb-inset > 0` from `useKeyboardInset`, sets `data-mobile-kbd="1"` on `.spool-shell`; CSS folds the stripe; instant under reduced motion | e2e: focus the composer at levels 2 and 3 and shrink the visual viewport: the stripe is not painted; blur: it is back at the same y |
| 4 | Back unchanged | none expected | `tests/e2e/phone-back-matrix.test.mjs` (spec 087) on the slice 2 build: one level per Back in every cell |
| 5 | docs | spec 043 (D1 and the level rows) and the CLE-77886 comment in `section-strip.mjs` state the new rule | the reviewer reads the diff |
| 6 | (B only) hide on scroll | a composable on each scroller sets `data-mobile-strip-hidden`; the stripe is `inert` while hidden; it shows again on scroll up, at the top, on Back, on a level or tab change and on focus | e2e: scroll every derived route that scrolls, with `prefers-reduced-motion` both on and off |
| 7 | (SPL-4264, owner HUM-10, t1 9b62ee09 msg d9d12c8c) the logo bar goes with the stripe | `default.vue` sets `data-mobile-bars-hidden` on `.app-frame` from the same state as slice 6 (`stripAway`); `main.css` slides the top bar (`header.top-bar`) up by its own height (`--top-bar-full-h`), not sticky while away, sets `--top-bar-h: 0` for what sits under it, and fades its controls; the phone's docked composer inside it stays; no slide under reduced motion | e2e `section-strip-scroll-hide.test.mjs`: on the wheel down the logo bar is off screen and its logo not painted, the pane takes the room of both bars and a docked composer stays painted; on the wheel up and on Back the logo is painted again at the same y. Red control: today's master fails the 44 logo-bar checks (170/214) |

Slice 3 on Android (owner, t1 c3e53990 msg d4459f4c: on his Android phone
the stripe did not fold). The viewport meta asks for
`interactive-widget=resizes-content`, so Android Chrome makes the whole
window shorter for the keyboard: `innerHeight` and `visualViewport.height`
drop together and `--kb-inset` stays 0. `layoutKeyboardStep` in
`utils/touch-ui.ts` reads that shape: the keyboard is up while a text field
has the focus and `innerHeight` is at least 60 px below its height before
the focus, at the same width (a turned phone is a new base, not a keyboard).
`useKeyboardOpen` (`composables/useTouchUi.ts`) is true for either shape, and
`default.vue` folds the stripe on it. `--kb-inset` is unchanged: on Android
the page already ends at the keyboard, so nothing docked needs lifting. Test:
the same e2e also makes the window 300 px shorter after the focus (the
stripe is not painted), then restores it with the field still focused (the
stripe is back at the same y).

The bottom status strip (`components/MobileStatusStrip.vue`) steps away on
the same signal (SPL-4022): it read `--kb-inset` only, so on Android it
stayed up over the keyboard. It now reads `useKeyboardOpen` too; iOS and the
desktop are unchanged. Test: the same e2e checks `[data-test=status-strip]`
is gone while the keyboard is up, in both shapes, and back after it.

Budget for slices 2, 3 and 6: run `csi-spl-orc/src/bash/scripts/perf-budget.py`
on the mock bundle as a same-box A/B against master before the push.

## 6. The owner's choice

```poll
On a phone, when should the section stripe show?
(A) Always, at every level and tab of a section; it folds away only while you type (recommended)
(B) As A, but it also hides while you scroll down and comes back when you scroll up
(C) Collapsed to a small handle below level 1; tap or swipe it to open the full stripe
(D) Move the sections to a bottom tab bar, shown at every level
(E) Keep today's rule, but every tab of a section shows it (drill-downs keep their own header)
```
