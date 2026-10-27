> Written by a **claude** seat (c-382) holding the mistral slot of this panel: it was queued as the mistral seat and started as claude (dispatch note 30a3d36d). The file keeps the slot's name.

# Section stripe on a phone: seat proposal (mistral slot)

Issue SPL-3786 · Epic SPL-2403 · Spec [043](../spec.md) · Panel: 2 seats, the editor merges into `section-stripe-behaviour.md`.
Written before reading the other seat's file.

## 0. The ask

The owner (HUM-10, t1 c3e53990): the stripe "is not logically consistent ... when does it appear, and when not?"; "whenever one has entered the first level of it, it should always be shown"; it shows on the channels level "but is not shown on the deeper levels"; on Monitoring it must not "jump on and off based on the tab which has been clicked"; "the top stripe is like the Windows taskbar ... shown and closed automatically, or something like that. I'm open to every suggestion".

## 1. Today, measured

### 1.1 How it was measured

- Dev site, build `b3cb06eea` (v5.6.0, built 2026-10-27T07:44Z), measured 2026-10-27T08:00Z.
- Headless Chrome, 390 x 844 px, `isMobile` + touch, signed in as the dev t1 probe member. Read-only: no post, no setting changed.
- Each route opened as a deep link (a fresh `goto`), then 2.5 s settle; one topic opened by a tap on the first card of `#lobby`. n = 1 per cell.
- Per cell: the shell's `data-mobile-level`, `data-mobile-section`, whether `[data-testid=sidebar-rail]` (the stripe) is painted in the viewport, and the count of painted Back chevrons.
- Not measured: the tap path into every route (only the topic was tapped), a reply (`?in=`), DM threads, the tablet width, a real phone.

### 1.2 The table: section x level -> stripe

The top bar ends at y = 58; when the stripe shows it sits at y = 58..119 (61 px, 7.2 % of an 844 px screen).

| section | route opened | level | stripe | Back |
|---|---|---|---|---|
| Channels (front door) | `/` | 1 | **shown** | 0 |
| Channels | `/lobby` | 2 | not shown | 1 |
| Channels | `/channel/lobby` | 2 | not shown | 1 |
| Channels | `/channel/lobby?topic=…` (tap) | 3 | not shown | 1 |
| Channels | `/t/<uuid>` | 3 | not shown | 1 |
| DMs | `/dm` | 1 | **shown** | 0 |
| Issues | `/issues` | 2 | **shown** | 0 |
| Archive | `/archive` | 2 | **shown** | 0 |
| People | `/people` | 2 | **shown** | 0 |
| People | `/people/HUM-11` | 2 | not shown | 1 |
| Calendar | `/calendar` | 2 | **shown** | 1 |
| Monitoring | `/monitoring` -> `/monitoring/agents` | 2 | **shown** | 0 |
| Monitoring | `/monitoring/boxes`, `/monitoring/events` | 2 | **shown** | 0 |
| Monitoring | `/monitoring/costs`, `/lanes`, `/tokens` | 2 | not shown | 1 |
| Monitoring | `/monitoring/agents/<agent>@<box>` | 2 | not shown | 1 |
| Monitoring | `/monitoring/boxes/<box>` | 2 | not shown | 1 |
| Reporting | `/reporting` -> `/reporting/releases` | 2 | **shown** | 0 |
| Reporting | `/reporting/issues`, `/lanes`, `/posts`, `/sql`, `/tokens` | 2 | not shown | 1 |
| Help | `/help` | 2 | **shown** | 0 |
| Help | `/help/getting-started` | 2 | not shown | 1 |
| Docs | `/docs` -> `/workspace/docs` | 2 | not shown | 1 |
| Workspace settings | `/tenant-settings` | 2 | **shown** | 0 |
| Workspace settings | `/tenant-settings/general`, `/members`, `/channels`, `/agents` | 3 | not shown | 1 |
| Workspace settings | `/users` -> `/tenant-settings/members` | 3 | not shown | 1 |
| Search | `/search` | 2 | not shown | 1 |
| Settings | `/settings` -> `/lobby?settings=` | 2 | not shown | 1 |

### 1.3 Why it behaves so

- `csi-spl-wui/src/layouts/default.vue:404`: `sectionStrip = isMobile && level === 2 && isSectionPage(path)`. Level 1 always shows the stripe, because level 1 IS the sidebar.
- `isSectionPage` is the hand-kept `SECTION_PAGES` set in `csi-spl-wui/src/utils/section-strip.mjs` (18 paths). Every tab added after it (Monitoring costs/lanes/tokens, Reporting issues/lanes/posts/sql/tokens, the Workspace settings sections, `/workspace/docs`) is missing. That is the "jump on and off by tab": a list nobody updates.
- The rule itself is "a drill-down keeps its own header and Back" (CLE-77886). So a channel, a person, an agent, a box, a help page and every topic hide the stripe by design. That is the owner's "not shown on the deeper levels".
- `tabForPath` in `csi-spl-wui/src/utils/sidebar-tabs.mjs:60` already maps a path to its section from the path itself (prefix rules, no per-tab list), but it returns `null` for `/lobby`, the Channels feed most readers land on.

So there are two defects: a hand-kept list that drifts, and a rule that removes the stripe exactly when the reader goes one level deeper.

## 2. Candidates

Common to all: the stripe is 61 px today; the 44 px target and the "whole controls only" rule (SPL-2062, `stripFit`) stay; it stays one row that rolls (`loopPosition`). Budget: the `ci_initial_gzip_kb` ceiling is 155 KB, with 149.7 KB in the measured metrics of `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`. CSP forbids new inline `:style`, so every state is a `data-*` attribute on `.spool-shell` plus CSS. The apps named below are from common knowledge of their phone apps, not measured in this lane.

### 2.1 A: always shown inside a section (pinned)

- **Every level and tab**: once the reader is in any section (level 1 onward), the stripe is on top at levels 1, 2 and 3, on every tab and every drill-down. The section is its selected control. The drill-down's own header (title + Back) sits *under* the stripe, not instead of it.
- **Back**: unchanged (spec 087: one level per Back). The stripe is navigation across sections; Back is depth within one. A tap on another section goes to that section's level 1 or 2, as today.
- **Keyboard**: when the on-screen keyboard is up (`visualViewport.height` well below `innerHeight` while a composer has focus), the stripe folds away and comes back when the keyboard goes. One rule, independent of the tab, and it gives the composer and the messages 61 px when they matter most.
- **Accessibility**: the stripe's tabs are a `role=tablist` today; it keeps its place in the tab order (after the top bar, before the content), so focus order does not change between levels. No motion except the keyboard fold, which is instant under `prefers-reduced-motion`.
- **Space**: 61 px on every level-2/3 screen (7.2 % at 844 px; about 9 % at 667 px). Level 3 loses that much reading height.
- **Budget**: about zero JS: a different computed in the layout, the list removed. The keyboard rule is a few lines on `visualViewport` (a browser API, no import).
- **Who uses it**: iOS tab bars stay on pushed screens by default (Apple Music, App Store, Instagram, X); Material navigation bars persist down a destination's hierarchy in Google Photos and YouTube. Those bars are at the bottom; the principle (navigation never disappears with depth) is the same.

### 2.2 B: hide on scroll down, show on scroll up

- **Every level and tab**: present at every level, as in A, but it slides up out of view while the reader scrolls the content down and comes back on any scroll up, at the top of the list, and on any level or tab change.
- **Back**: a Back always shows it again.
- **Keyboard**: hidden while typing, as A.
- **Accessibility**: focus moving into the stripe (keyboard, switch access, screen reader) must force it visible; it animates `transform` only, and does not move under `prefers-reduced-motion` (it then behaves as A). It stays in the accessibility tree while hidden.
- **Space**: 0 px while reading, 61 px otherwise.
- **Budget**: a scroll listener per scroller. The feed, the topic pane, every page list and the Docs reader each scroll their own container, so it is a composable wired to each of them (~1 KB gz estimated, unmeasured; client-only and loaded after first paint, so `ci_initial_gzip_kb` need not move).
- **Who uses it**: the Chrome for Android and Safari address bars, the X and Facebook top bars, Medium.
- **Risk**: it moves on its own, which is what the owner asked to stop ("not jump on and off"); the rule is consistent, but the screen still jumps, now with the thumb.

### 2.3 C: collapsed to a handle

- **Every level and tab**: at level 1 the full stripe; at levels 2 and 3 it collapses to a 44 px handle row (the current section's icon and a chevron). A tap or a swipe down on it opens the full stripe over the content; picking a section or tapping outside closes it.
- **Back**: Back first closes an open stripe (an overlay, spec 043 T055), then walks levels.
- **Keyboard**: the handle stays; opening it dismisses the keyboard.
- **Accessibility**: the handle is a button with `aria-expanded`; the open stripe is not modal and Escape closes it.
- **Space**: 44 px instead of 61 px at levels 2/3; the handle could share the top bar's row to cost 0.
- **Budget**: a small component; CSS for the open state.
- **Who uses it**: Google Maps and Apple Maps bottom sheets; Android's notification shade (swipe down).
- **Risk**: one more tap to change section from a deep level; a handle is easy to miss.

### 2.4 D: bottom tab bar

- **Every level and tab**: the sections move to a bottom bar, shown at every level.
- **Back**: unchanged.
- **Keyboard**: hidden while typing (OS convention).
- **Accessibility**: best thumb reach; 44 px targets fit five or six sections, not the full rail, so a "More" control is needed.
- **Space**: ~56 px plus the safe-area inset, at the bottom, where the docked composer and the status strip (`MobileStatusStrip`) already live.
- **Budget**: a new component and the rail's order logic again.
- **Who uses it**: WhatsApp, Instagram, Slack, most native apps.
- **Risk**: spec 043 D1 decided against it ("a tab bar would duplicate it and cost 56 px on every screen"); it re-designs the phone shell, not the stripe.

### 2.5 E: today's rule, made exact (baseline)

- Section pages at level 2 derive from the route (no list), so every Monitoring, Reporting and Workspace settings tab shows the stripe; drill-downs (a channel, a person, a topic) still swap it for their own header and Back.
- Fixes the "on and off by tab" defect; does not do "always shown on deeper levels". Listed so the owner sees the smallest change.

## 3. Recommendation: A, pinned, with the keyboard rule

- It is the owner's own rule ("whenever one has entered the first level of it, it should always be shown"), and it ends the jumping: the stripe only changes when the keyboard comes or goes, which every phone user already expects.
- It is the cheapest in JS and in tests, and it removes code (the list, the level-2 special case).
- B answers "shown and closed automatically", but it still moves, with a scroll listener per container; it can come later as an opt-in over A (the same `data-*` state, a Behaviour setting), not as the default.
- The price is 61 px at levels 2/3. If that is too much, the stripe can be compacted at levels 2 and 3 (icons only, 48 px) as a follow-up slice; I would not start there, as a height change between levels is a small jump of its own.

### 3.1 Wireframes (390 px, A)

Level 1, Channels:

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |  top bar
+--------------------------------------+
| [Chan*] [DMs] [Issues] [Flow] [Mon]  |  stripe, Channels selected
+--------------------------------------+
| # lobby                              |
| # feedback                           |
| # dev                                |
+--------------------------------------+
| . bell  note            v5.6.0       |  status strip
+--------------------------------------+
```

Level 2, a channel:

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |
+--------------------------------------+
| [Chan*] [DMs] [Issues] [Flow] [Mon]  |  same stripe, same place
+--------------------------------------+
| <  # lobby                           |  the drill-down's own header
| card: topic A                        |
| card: topic B                        |
+--------------------------------------+
| [ composer ......................  ] |
+--------------------------------------+
```

Level 3, a topic (a reply view is the same):

```text
+--------------------------------------+
| [=] spool        (search)   (o) (me) |
+--------------------------------------+
| [Chan*] [DMs] [Issues] [Flow] [Mon]  |
+--------------------------------------+
| <  Topic A title                     |
| message 1                            |
|   reply 1.1                          |
+--------------------------------------+
| [ composer ......................  ] |
+--------------------------------------+
```

Level 2, Monitoring, any tab (Agents, Boxes, Events, Costs, Lanes, Tokens):

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

Any level, keyboard up (composer focused):

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

## 4. Build slices (after the owner's pick, A assumed)

Each slice is one small lane; every e2e enumerates the routes from `csi-spl-wui/src/pages/**` at run time (the file tree is the route table), never a hand-kept list.

| # | slice | change | its test |
|---|---|---|---|
| S1 | the section of a route, derived | `sectionOf(path)` built on `tabForPath(path)` and `railLinkSection(path)`, with `/lobby`, `/workspace/docs` and `/tenant-settings/*` mapped; `SECTION_PAGES` and `isSectionPage` removed | unit: walk `src/pages/**`, turn each file into a path (a `[param]` gets a sample value), assert every page on the default layout has a section; pages with their own layout (`definePageMeta({ layout })`: login, checkout, blog, ...) are excluded by reading the file, not by a list. Red control: a new page with no section fails |
| S2 | stripe at every level | `default.vue`: `sectionStrip = isMobile && sectionOf(path) !== ''` at levels 1-3; the drill-down header + Back render under the stripe; the level-3 pane starts under it; `ChannelSidebar`'s strip-only mode covers levels 2 and 3; `TabletStrip` stays hidden while the stripe is up | e2e at 360 and 390 px, dark + light: every route from S1's walk plus one drill-down per dynamic route (a channel, a topic `?topic=`, a reply `?in=`, a person, an agent, a box, a help page): stripe painted right under the top bar, its section selected, exactly one Back from level 2 on, no horizontal scroll. Red control: restore the level-2 check and the drill-down rows fail |
| S3 | keyboard fold | `visualViewport` resize -> `data-mobile-kbd="1"` on `.spool-shell`, CSS hides the stripe; instant under reduced motion | e2e: focus the composer at levels 2 and 3, shrink the visual viewport, stripe not painted; blur, stripe back at the same y |
| S4 | Back is unchanged | none expected | run `tests/e2e/phone-back-matrix.test.mjs` (spec 087) on the S2 build: one level per Back in every cell |
| S5 | docs | spec 043 (D1 and the level rows) and the CLE-77886 comment in `section-strip.mjs` state the new rule | reviewer reads the diff |

Budget check for S2/S3: `perf-budget.py` on the mock bundle, same-box A/B against master.

## 5. Owner poll (for the editor's merge)

```poll
On a phone, when should the section stripe show?
(A) Always, at every level and tab of a section; it folds away only while you type (recommended)
(B) Always, but it hides while you scroll down and comes back when you scroll up
(C) Collapsed to a small handle below level 1; tap or swipe it to open the full stripe
(D) Move the sections to a bottom tab bar, shown at every level
(E) Keep today's rule, but every tab of a section shows it (drill-downs keep their own header)
```
