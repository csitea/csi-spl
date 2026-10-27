# Section stripe on a phone: the claude seat's proposal

Panel: SPL-3785 (epic SPL-2403), spec 043. Written before reading the other
seat's file. The merged result: `csi-spl-doc/specs/043-spool-wui-mobile/section-stripe-behaviour.md`.

## 1. Today, measured

### 1.1 How it was measured

- The rule, `csi-spl-wui/src/layouts/default.vue:404` on origin/master
  `f013a4711`:
  `sectionStrip = isMobile && stack.level === 2 && isSectionPage(route.path)`.
  `ChannelSidebar.vue` (`stripOnly`) uses the same three terms.
- `isSectionPage` is a hand-kept set of 18 paths,
  `csi-spl-wui/src/utils/section-strip.mjs` (`SECTION_PAGES`).
- The table below is the output of `isSectionPage()` imported from that file
  and called with one path per page under `csi-spl-wui/src/pages` (n = 45
  paths, node, 2026-10-27). Levels come from `utils/mobile-stack.mjs`:
  level 1 is the left panel (the section strip plus that section's list),
  level 3 is any open topic or right panel, and the rule gives no strip there.
- Not measured live: this seat did not sign in to the dev site on a phone
  viewport. The sat box has no dev test login this seat may use.
  `curl https://dev.spool-hub.ai/` returned 200. The screen behaviour below
  is the code's, and the owner's screenshot (msg 3f0287cd) agrees with it.

### 1.2 The table (strip shown = yes)

| section | level 1 (list) | level 2 (page or feed) | level 3 (topic, detail) |
|---|---|---|---|
| Channels | yes | no: `/lobby`, `/channel/<name>` | no: `?topic=` |
| Direct messages | yes | no: `/dm`, `/dm/<peer>` | no |
| Flow | yes | `/` yes | no |
| Issues | yes | `/issues` yes | no: the issue detail |
| Archive | yes | `/archive` yes | no |
| People | yes | `/people` yes, `/people/<id>` no | no |
| Users | yes | `/users` yes | no |
| Calendar | yes | `/calendar` yes | no |
| Docs | yes | `/docs` yes, `/workspace/docs` no | no |
| Help | yes | `/help` yes, `/help/<page>` no | no |
| Monitoring: Agents, Boxes, Events | yes | yes | no: `/monitoring/agents/<id>`, `/monitoring/boxes/<id>` |
| Monitoring: Costs, Tokens, Lanes | yes | **no** | no |
| Reporting: Releases | yes | yes | no: `/releases/<ref>` |
| Reporting: Issues, Lanes, Posts, SQL, Tokens | yes | **no** | no |
| Workspace settings | yes | `/tenant-settings` yes, each settings page no | no |
| Search, `/t/<id>`, `/goals/<id>`, `/roadmap` | n/a | no | no |

Two separate faults, both from the owner's words:

1. **Tabs missing from the list** (msg c3c2ff9b, "jump on and off based on
   the tab"): 3 of 6 Monitoring tabs and 5 of 6 Reporting tabs are absent from
   `SECTION_PAGES`. Each tab added since the list was written made the same
   mistake, because nothing fails when a new tab is missing from it.
2. **No strip below level 2** (msg 09d53b49, "shown on the channels level but
   is not shown on the deeper levels"): the CLE-77886 rule is "a drill-down
   keeps its own header and Back", so a channel feed, a topic, a person's card
   and a settings page all drop the strip.

## 2. Candidate behaviours

The strip control row is `min-height: 52px` (`ChannelSidebar.vue`, phone
`.sidebar-tab`). The tap target is `--tap: 44px` (`assets/css/variables.css:106`).
The initial JS ceiling is `ci_initial_gzip_kb` 155 KB, last measured at
149.7 KB (`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`).

### 2.1 A: always shown on every level inside the app

- **Every level and tab**: the strip is on top at levels 1, 2 and 3, on every
  path under the default layout. The selected control names the section.
  Pages with `layout: 'login'` or `false` (login, checkout, blog, public
  calendar) have no app shell and no strip.
- **Back**: a drill-down (channel, topic, card, settings page) keeps its own
  header row under the strip, with its Back chevron and title, so spec 087
  (Back is one level) is unchanged. A section's own top page still shows no
  title, because the selected control already names it.
- **Keyboard**: while the on-screen keyboard is up (`--kb-inset > 0`,
  `useKeyboardInset`), the strip folds so the composer and the last message
  stay visible. It returns when the keyboard closes. iOS Messages and
  WhatsApp handle their top bars the same way.
- **Accessibility**: the controls already exist, with their focus ring,
  `role=tab` keys (spec 103) and 44 px targets. Nothing moves on its own, so
  it is safe with reduced motion.
- **Space**: about 56 px of every screen, all the time (about 8 % of a
  390 x 844 phone's height after the top bar).
- **CSP and JS**: CSS and one computed property. No new component, no
  `:style`, about 0 KB of initial JS.
- **Used by**: Instagram, YouTube, Gmail and Spotify, whose tab bars stay on
  every level of a section. Telegram and WhatsApp are the opposite: their bar
  is gone once a chat is open.

### 2.2 B: A, plus hide on scroll down and show on scroll up

- **Every level and tab**: as in A, but scrolling the content down by 24 px
  or more slides the strip away. Any scroll up brings it back, and so does
  reaching the top, a Back, focus moving into the strip (Tab), or a tap on
  the top bar. This is the "shown and closed automatically" of msg 88e2c419.
- **Back**: Back always shows the strip again, so after Back the reader can
  see where they are.
- **Keyboard**: as in A.
- **Accessibility**: with `prefers-reduced-motion: reduce` the strip
  appears and disappears without the slide. A hidden strip is `inert`, so
  focus never lands on an invisible control. Moving focus into it shows it.
- **Space**: as A while reading the top of a page. Close to 0 while reading
  down a long feed.
- **CSP and JS**: one passive scroll listener in the existing layout, about
  0.3 KB, CSS transform only. No new client plugin: a statically imported
  plugin is what broke the 155 KB budget before.
- **Used by**: X, Facebook, Reddit, and the address bars of Chrome and Safari
  on phones.

### 2.3 C: collapsed to a handle below level 1

- **Every level and tab**: the full strip at level 1. At levels 2 and 3 it is
  a 12 px handle showing the section's icon, and a tap or a swipe down on it
  opens the strip over the content.
- **Back**: unchanged. The handle never takes a Back.
- **Keyboard**: the handle stays.
- **Accessibility**: the handle needs a 44 px hit area even though it draws
  12 px, so it eats the space it was meant to save. The swipe has to have a
  button alternative. It is hard to discover.
- **Space**: about 12 px drawn, 44 px of touch area.
- **CSP and JS**: a small gesture handler, about 0.5 KB.
- **Used by**: few. It resembles the iOS Safari compact tab bar and the pull
  down notification shade. Users have to learn it.

### 2.4 D: a bottom tab bar on every level

- **Every level and tab**: the strip moves to the bottom of the screen and
  stays on every level.
- **Back**: as in A.
- **Keyboard**: it has to hide while the keyboard is up, because it sits
  exactly where the keyboard rises.
- **Accessibility**: easiest to reach with a thumb. Five or more controls
  stop fitting, and the rail has 9 to 12 (`STRIP_ITEM_MIN` 64 px gives 6
  controls at 390 px), so it would keep the endless roll that works badly at
  the bottom edge.
- **Space**: about 56 px, as A, stacked on top of the bottom composer dock and
  the status strip (CLE-77888), all three fighting over the same edge.
- **CSP and JS**: CSS, but every page's bottom padding and the dock (spec
  133, OmniboxGrip) have to be re-laid out. Large.
- **Used by**: Instagram, YouTube, X, Gmail. iOS and Material both
  recommend bottom bars for 3 to 5 destinations.

### 2.5 E: keep today's rule, derive the list

- **Every level and tab**: every tab of every section shows the strip at
  level 2 (the list comes from the route and from `MONITORING_TABS` /
  `REPORTING_TABS`). Drill-downs still drop it.
- This fixes fault 1 only. The owner rejected fault 2 by name (msg
  09d53b49), so this is the floor, not an option.

## 3. Recommendation

**A first, then B on top of it.** A is the consistency the owner asked for
(msg 1f55e7e1: once inside, "it should always be shown"). It is one rule with
no exceptions, it costs no JS, and it removes the hand-kept list, which is the
cause of fault 1. B answers msg 88e2c419 ("shown and closed automatically") on
top of A, and it can be dropped if A alone reads well. C is hard to discover.
D fights the bottom dock and does not fit a rail of 9 or more. E is
superseded by the owner's own words.

### 3.1 Wireframes (390 px)

Level 2, a channel feed (A):

```
+--------------------------------------+
| [=] spool          (search)  (bell)  |  top bar
+--------------------------------------+
| DMs |[Channels]| Issues | Flow | ... |  section strip, Channels selected
+--------------------------------------+
| <  # dev-ops                    ...  |  the drill-down's own header + Back
|--------------------------------------|
|  message card                        |
|  message card                        |
+--------------------------------------+
| (composer dock)                      |
| . bell  note             v6.x.y      |  status strip
+--------------------------------------+
```

Level 3, a topic (A):

```
+--------------------------------------+
| [=] spool          (search)  (bell)  |
| DMs |[Channels]| Issues | Flow | ... |  strip stays
| <  Topic title                  ...  |  topic header + Back (to the feed)
|  root message                        |
|    reply                             |
+--------------------------------------+
```

Monitoring, any tab (A):

```
+--------------------------------------+
| [=] spool          (search)  (bell)  |
| ... | Calendar |[Monitoring]| Help ..|  strip
|  Agents  Boxes  Events  [Costs] ...  |  the section's own tab bar
|  costs table                         |
+--------------------------------------+
```

Scrolled down a feed (B):

```
+--------------------------------------+
| [=] spool          (search)  (bell)  |  strip slid away
| <  # dev-ops                    ...  |
|  message card                        |
```

Composer focused, keyboard up (A, B):

```
+--------------------------------------+
| [=] spool          (search)  (bell)  |  strip folded
| <  # dev-ops                    ...  |
|  last message                        |
| (composer)                           |
| [ keyboard ]                         |
+--------------------------------------+
```

## 4. Build slices

Each slice is one small lane. The e2e of each one builds its route list from
`csi-spl-wui/src/pages/**/*.vue` (param pages filled from `utils/mock-data.mjs`,
pages with `layout: 'login'` or `false` dropped) plus `MONITORING_TABS` and
`REPORTING_TABS`. It never uses a hand-written list, and a new page or tab
joins the test the day it lands. Each route is checked at 390 px for every
level it can reach.

1. **One rule, no list** (A, levels 1 and 2). Replace `SECTION_PAGES` with
   `sectionStripOn(path, level)` (true on every default-layout path at level 2
   or above) in `section-strip.mjs`, and use it in `default.vue` and
   `ChannelSidebar.vue`. A drill-down keeps its header row and Back under the
   strip, and only a section's own top page hides its title. e2e: every
   derived route at level 2 has `[data-mobile-section="1"]` and the strip
   visible, every drill-down still has its `.mobile-back`, and a red control
   (a route the rule excludes) must fail. Unit: `sectionStripOn` over the
   derived list.
2. **Level 3** (A). The strip stays above the topic pane and above a page's
   own right panel (the issue detail). e2e: open a topic in a channel, a DM
   and Flow, and an issue. The strip shows and Back goes to level 2 (spec 087
   gate unchanged).
3. **Keyboard fold** (A). The strip folds while `--kb-inset > 0` and comes
   back when the keyboard closes. e2e: focus the composer under a simulated
   inset, then blur.
4. **Hide on scroll, show on scroll up** (B, only if the owner picks B). One
   passive listener in the layout. The strip is `inert` while hidden, has no
   slide under reduced motion, and shows again on Back, on focus and at the
   top. e2e: scroll each derived route that scrolls, with
   `prefers-reduced-motion` both ways. The `ci_initial_gzip_kb` check
   (`perf-budget.py`) runs in the lane before the push.
