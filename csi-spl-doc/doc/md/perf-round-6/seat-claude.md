# Perf round 6: claude seat verdict

Seat: **c-250@sat** (claude), task `dispatch-eb4bd4b3`, issue SPL-2069 (round SPL-2051).
Reviews: [perf-round-6-plan.md](../perf-round-6-plan.md) v0.1 (`90599126f`).

**One sha:** every number below was measured in this session on
**`4a3781047`** (`4a3781047db5977cb5d9e26796fadb5cc48e0693`, `origin/master`,
2026-10-16). Master moved while I wrote this, but only docs changed:
`git diff 4a3781047 origin/master -- csi-spl-wui | wc -l` -> `0`, so the
numbers also hold for the WUI on the newer master.

**Verdict: 0 agree / 5 agree with changes / 7 disagree / 2 proposals.**

| row | verdict | one line why |
|---|---|---|
| 01 user menu `v-if` | agree with changes | 45 hidden nodes on desktop and 56 on a phone, not "~15". The red control names a class that does not exist |
| 02 async topic panes | agree with changes | Neither pane is in the initial (`200.html`) set. Both ride `index.html`'s modulepreload set, so the gain lands in `ci_home_gzip_kb`, which has 0.8 KB headroom |
| 03 memoize date parts | disagree | `formatToParts` runs only when the viewer picked a time zone: 8.2 ms per 1000 dates, 0 by default. A minute-keyed cache also breaks `isoDateTimeSec` |
| 04 DeadlinePicker CSS sizing | disagree | It only mounts on `/issues` (1 instance), never on login. CSS sizing would drop the owner's SPL-1147 "text + 2 mm" width (e2e C1) |
| 05 lazy CodeViewer | agree with changes | Saves at most 1.47 KB gzip. Prism does not exist in the WUI. The chunk sits in the home set |
| 06 TransitionGroup gate | agree with changes | Real, but `:css="isMounted"` cannot work: the rows arrive *after* mount (2 enter-active mutations per row) |
| 07 login wallpaper `v-if` | disagree | Already `display:none` on the front page, so no filter or animation runs. That leaves 10 DOM nodes |
| 08 windowed issue rows | agree with changes | The mock has 0 issues (1 empty `tbody` row), so the plan's 620 nodes are not rows. Needs a seeded fixture and must run after r13-06 |
| 09 markdown fast path | disagree | Already on master: `looksLikeMarkdown` (`MessageBody.vue:57`). Plain bodies never mount MarkdownBlock (0 md-blocks for 3 bodies) |
| 10 debounce seedTopics | disagree | Vue already coalesces same-tick updates (10 -> 1 call). The watcher is off during a channel switch, so switch latency is not its cost |
| 11 channel store cache | disagree | `computed` already memoises, so the red control is green today. 0.7 ms per recompute at 200 msgs. The slug names a different thing |
| 12 docs tree folding | disagree | Already folded (`open = {'csi-spl-doc'}`, `docs.vue:207`). `/docs` redirects to `/workspace/docs`, which is a different component |

## 1. How I measured

### 1.1 The bundle

The mock-tenant bundle, built the way CI's `wui-generate` job builds it
(`.github/workflows/10_ci-quality.yml:415-426`, same `NUXT_PUBLIC_*` env):

```bash
cd csi-spl-wui && pnpm install --frozen-lockfile && NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate
```

```bash
python3 ../csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub .output/public --budgets ../csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json
```

Output (n=1):

```
PASS ci_initial_gzip_kb 154.6 <= 155
PASS ci_home_gzip_kb 351.3 <= 352.1
DOC 200.html 3 chunk(s) gzip 154.6 KB
DOC index.html 86 chunk(s) gzip 351.3 KB
```

Headroom is **0.4 KB** initial and **0.8 KB** home. The plan has 0.1 / 0.9.
On this box, node reads a little below CI, so judge by a same-box A/B delta.

### 1.2 Page metrics

I served the bundle with `node src/node/test/serve-generated.mjs --port <free>`
and drove it with puppeteer-core plus CDP: `Performance.getMetrics`, paint
entries, a `largest-contentful-paint` observer, and a long-task observer for
TBT. Each sample is a fresh browser context, `networkidle0` plus 500 ms; n=3,
median shown. The script is in section 6.1.

- **desktop** = 1440x900, no throttle.
- **mobile** = 390x844, 4x CPU, iPhone UA.

The box was loaded (`uptime` load 9.28), so absolute ms are about 1.5-2x the
plan's. Compare rows to each other, not to the plan.

| profile | route (landed) | FP | FCP | LCP | TBT | DOM | Layout ms | Script ms | raw FCP/LCP/TBT/DOM |
|---|---|---|---|---|---|---|---|---|---|
| desktop | `/` (`/lobby`) | 160 | 180 | 564 | 175 | 610 | 62 | 91 | 180/572/175/610 216/564/196/610 160/520/171/610 |
| desktop | `/login` | 252 | 252 | 252 | 11 | 493 | 73 | 125 | 284/284/19/493 252/252/7/493 240/240/11/493 |
| desktop | `/channel/alerts` | 96 | 772 | 772 | 242 | 524 | 47 | 85 | 772/772/242/524 1144/1144/311/524 704/704/177/524 |
| desktop | `/issues` | 120 | 788 | 788 | 195 | 581 | 40 | 85 | 756/756/164/581 812/812/203/581 788/788/195/581 |
| desktop | `/docs` (`/workspace/docs`) | 124 | 752 | 932 | 189 | 811 | 44 | 77 | 752/932/189/811 720/916/186/811 860/1036/190/811 |
| mobile | `/` | 292 | 400 | 1788 | 941 | 661 | 129 | 268 | 400/1788/1095/661 788/2100/941/661 348/1536/861/661 |
| mobile | `/login` | 128 | 320 | 320 | 236 | 482 | 124 | 239 | 320/320/209/482 312/312/246/482 324/324/236/482 |
| mobile | `/channel/alerts` | 160 | 1648 | 1648 | 905 | 545 | 52 | 177 | 1740/1740/984/545 1648/1648/905/545 1572/1572/855/545 |
| mobile | `/issues` | 168 | 1784 | 1784 | 855 | 656 | 60 | 221 | 1784/1784/855/656 1752/1752/853/656 2028/2028/996/656 |
| mobile | `/docs` (`/workspace/docs`) | 160 | 1824 | 1824 | 1050 | 818 | 74 | 194 | 1824/1824/1050/818 1816/1816/971/818 1884/1884/1089/818 |

Facts this table settles:

- **`/docs` is not `pages/docs.vue`.** `/docs` redirects to `/workspace/docs`
  (SPL-1882, `docs.vue:143-152`), so the plan's 807/782 "Docs" DOM counts
  belong to `WorkspaceDocsLayout`.
- **Layout is not the cost.** Layout duration is 40-129 ms on every route.
  The plan's "243 ms layout on desktop sign-in" does not reproduce: I get
  73 ms. The cost is script. A mobile CPU profile of `/channel/alerts`
  (section 6.2) puts 726 ms of self time in `Cc4Azcwx.js` (Vue runtime) and
  411 ms in `B-pcqvXw.js` (entry).
- **The plan's harness cannot be re-run.** It cites
  `node scratch/measure-wui-perf.mjs`, but
  `git ls-files | grep -c measure-wui-perf` -> `0` and the file is not in the
  main checkout either. R12: a number another seat cannot reproduce from the
  plan is not evidence. v1.0 should cite a committed script, or the one in
  section 6.1.

### 1.3 Where each component ships

`grep -lF -- '<data-test>' .output/public/_nuxt/*.js`, then
`grep -oE "<link[^>]*<chunk>[^>]*>" 200.html index.html`:

| component | chunk | gzip -6 | `200.html` (initial) | `index.html` (home) |
|---|---|---|---|---|
| TopicPane (`"topic-pane-close"`) | `BFMRHlHc.js` | 4955 B | prefetch | **modulepreload** |
| LiveTopicPane (`"live-topic-close"`), default layout, UserMenu | `B4WS_APv.js` | 46722 B | prefetch | **modulepreload** |
| CodeBlock + CodeLines + CodeViewer (`code-viewer__bar`) | `Bxzn4V-n.js` | 7493 B | prefetch | **modulepreload** |
| login wallpaper (`"login-front-field"`) | `u3xDw7F8.js` | 2101 B | - | - |
| initial set | `B-pcqvXw` 98263, `Cc4Azcwx` 48706, `gsbslMDU` 11296 | | modulepreload | |

## 2. Row by row

Every cited file:line was opened at `4a3781047`. Lines that differ from the
plan are flagged.

### 2.1 Row 01: `UserMenu.vue` `v-show` -> `v-if`: AGREE WITH CHANGES

- Site: `grep -n 'v-show="open"' src/components/UserMenu.vue` -> `60:        v-show="open"`. The line exists.
- **Measured.** Signed in the way `tests/e2e/own-picture.test.mjs:114`
  does it (`session.adopt`), on `/channel/alerts`:
  - desktop: `{"panelNodes":45,"display":"none","dom":571}`
  - mobile: `{"panelNodes":56,"display":"none","dom":603}`

  That is 45 and 56 nodes, not "~15", and about 8-9% of the shell DOM on
  every signed-in route.
- **Changes.**
  - (a) The red control `initial HTML has no .user-menu-dropdown` names a
    class that does not exist (`grep -rn user-menu-dropdown src` -> 0 hits).
    The panel is `[data-test=user-menu-panel]`. Make the control: panel node
    count when closed goes 45 -> 0.
  - (b) The trigger's `aria-controls` points at `menuId`. Bind it only while
    open, or keep the id on an always-mounted wrapper.
  - (c) 10 test files name `user-menu-panel`
    (`grep -rln user-menu-panel tests | wc -l` -> 10). Their test column must run.
    `last-data-clock.test.mjs:98` and `mobile-overlay.test.mjs:54` read the
    panel while it is closed and have to handle `null`.

### 2.2 Row 02: async `LiveTopicPane` / `TopicPane`: AGREE WITH CHANGES

- Site: `grep -n TopicPane src/layouts/default.vue` -> `94`, `95` (and a
  comment at `311`). **Lines 203-205 are `OperatorPane`, which is already
  async.** The panes are Nuxt auto-imports with no `import` line, so the
  sites are `94-95` only.
- **Measured.** Neither pane is in `200.html`'s initial set (section 1.3).
  "Cuts entry JS chunk by ~8 KB gzip" cannot happen: `ci_initial_gzip_kb`
  will not move.

  What does move: both panes sit in `index.html`'s **modulepreload** set.
  TopicPane alone is `BFMRHlHc.js`, 4955 B gzip. As an async component it
  drops to prefetch, so `ci_home_gzip_kb` (0.8 KB headroom) falls by about
  5 KB plus LiveTopicPane's share of `B4WS_APv.js`.
- **Changes.**
  - (a) Target and red control: `ci_home_gzip_kb` drops by >= 4 KB, A/B on
    the same box. `ci_initial_gzip_kb` stays unchanged.
  - (b) The `v-if`/`v-else-if` chain at 94-96 is the 1..1 invariant
    ("Do NOT mount either of them a second time"). Keep the chain and only
    swap in the component definitions. The 1..1 topic-pane e2e gate (CI
    `wui-e2e`) belongs in the test column.
  - (c) Deep link `/t/<id>` on a cold load must still open the pane:
    measure its time-to-pane before and after.

### 2.3 Row 03: memoize `fields()` in `date-iso.mjs`: DISAGREE

- Site: `formatToParts` is at `90` and `fields()` at `83-93`. The lines exist.
- **Measured** with 1000 ISO strings 37 s apart, `isoDate`, 5 runs, node,
  this box:
  - `zone="" (browser default): n=5 median_ms= 2.14`
  - `zone=Europe/Helsinki (picked): n=5 median_ms= 8.23` (the 27.92 ms max
    is the cold first run)

  `formatToParts` runs **only for a viewer who picked a time zone**
  (`fields()` returns `getFullYear()`... when `zone` is `""`). The formatter
  is already cached per zone (`fmtCache`). The plan's ">25 ms for 1000
  dates" is the cold first run, not steady state. A feed renders a window
  of 30 rows (`WINDOW = 30`, `utils/feed-window.mjs:4`), so the saving is
  about 0.25 ms per render, for some viewers.
- **Breaks a function.** The proposed key, `${zone}:${Math.floor(ms / 60000)}`,
  drops seconds. `isoDateTimeSec` (`date-iso.mjs:119-124`, used by
  `IssueHistory`, `PersonActivityDialog`, `ReleaseNotesDialog`,
  `DebugPanel`) would print the wrong seconds. A second-keyed key fixes that
  but leaves a sub-millisecond gain. The row is out.

### 2.4 Row 04: `DeadlinePicker` without forced reflow: DISAGREE

- Site: `getBoundingClientRect` at `166` (plus `204`, the popover). `sizeField` is at `153-167`. The lines exist.
- **Measured.**
  - The component mounts only in `pages/issues.vue` (lines 253, 311, 490,
    670, 845; `grep -rln DeadlinePicker src` -> `issues.vue` and
    `popover-clamp.mjs`).
  - On `/issues`: desktop `{"dlp":1,"dlpVisible":1}`, mobile `{"dlp":0}`.
  - It is **not** on login or any form, so "282 ms layout on mobile
    login/forms" does not belong to it. `/login` mobile layout is 124 ms
    *total* for the page, with no DeadlinePicker in it.
  - Cost: one measuring layout on mount, one per font-ready, one per
    keystroke.
- **Breaks a function.** `sizeField` is the owner's SPL-1147 rule (topic
  f9b6c844): the field is exactly its text plus ~2 mm. e2e
  `deadline-picker.test.mjs` C1 asserts `trailing == 8 +- 1 px` at 1440.
  - `calc(n * 1ch)` is wrong for `-`, `:` and the space, which are not
    `1ch` even with tabular nums.
  - `field-sizing: content` is not available in every engine the WUI
    serves.

  Either way C1 goes red, or the width drifts on Safari and Firefox.

### 2.5 Row 05: lazy `CodeViewer`: AGREE WITH CHANGES

- Site: `grep -n CodeViewer src/components/CodeBlock.vue` -> `57`. **There
  is no import line:** it is a Nuxt auto-import, and `65` imports
  `previewOf`. There is **no Prism** in the WUI
  (`grep -rli prism src package.json` -> 0).
- **Measured.** CodeBlock, CodeLines and CodeViewer share one chunk,
  `Bxzn4V-n.js` (20568 B raw, 7493 B gzip), and it is modulepreloaded by
  `index.html`. CodeViewer's whole SFC source is 3725 B, and
  `gzip -6c src/components/CodeViewer.vue | wc -c` -> `1469`.

  So the upper bound is 1.47 KB gzip off the home set, not "~18 KB raw".
  The dialog already renders its body only when opened.
- **Changes.**
  - (a) Target: `ci_home_gzip_kb` -1.0..-1.5 KB, same-box A/B. Fold it into
    row 02's lane: same practice, same metric, both small.
  - (b) Red control: count of `code-viewer` in the chunk CodeBlock loads,
    9 -> 0.

### 2.6 Row 06: `LiveFeed` TransitionGroup gate: AGREE WITH CHANGES

- Site: `37` and `112`. The lines exist.
- **Measured.** A MutationObserver counted `*-enter-active` class
  mutations during load:
  - `/lobby`: `{"rows":[3],"enterActiveMutations":8}`
  - `/channel/alerts`: `{"rows":[1],"enterActiveMutations":2}`

  So the first batch of rows *does* animate. This is not Vue's `appear`
  (that is off): the rows arrive after the group mounted.
- **Changes.**
  - (a) `:css="isMounted"` set in `onMounted` would not stop it, because
    `onMounted` fires before the rows arrive. Gate on "first non-empty
    batch rendered" instead (flip it after the first `nextTick` that sees
    rows).
  - (b) The mock feed has 1-3 rows, so the plan's ">80 ms TBT" cannot be
    shown on it. The lane must seed 30 rows (the window) in a fixture and
    measure enter-active mutations (2/row -> 0) and TBT there.
  - (c) `LiveFeed.vue` is 474 `<script>` lines. r13-02's
    `sfc-script-size` gate caps new SFCs at 500, so the row may add at most
    25 lines.
  - (d) It calls `useScrollAnchor` (`LiveFeed.vue:158,280`), which r13-07
    reworks (section 3).

### 2.7 Row 07: login wallpaper `v-if`: DISAGREE

- Site: `9-23` exists. The CSS is at `262-263`, not `260-275`.
- **Measured** on `/login`:
  `{"front":true,"wallpaperNodes":10,"wallpaperDisplay":"none","dom":498}`.

  On the front page the wallpaper is already `display:none`
  (`.login:has(.login-front)`). A `display:none` subtree evaluates no filter
  and runs no animation. All the row can save is 10 DOM nodes. The template
  comment (`login.vue:5-8`) records why it is CSS and not a flag: "no flag
  reaches the route table in the entry chunk". `ci_initial_gzip_kb` has
  0.4 KB headroom.

### 2.8 Row 08: windowed rows in `pages/issues.vue`: AGREE WITH CHANGES

- Site: `375` and `520`. The lines exist.
- **Measured** on `/issues`:
  - desktop: `{"tableRows":1,"cards":0,"tbodyNodes":3,"dom":582}`
  - mobile: `{"tableRows":0,"dom":657}`

  The mock tenant has **no issues**, so the plan's "620 DOM nodes ... 100+
  issues" is shell and filter-bar DOM, not rows. Windowing pays off only on
  a tenant with hundreds of issues, and the round has no measurement of
  one.
- **Changes.**
  - (a) Measure on a seeded fixture of 300 issues: DOM count and mobile TBT
    before and after.
  - (b) Rows must keep select-all (`selSet`), the folded groups at `375`,
    keyboard row navigation, and Ctrl+F, so the rAF fill must complete.
  - (c) Run it after r13-06 (section 3).
  - (d) The script is 2082 lines now. r13-02 sets a ceiling and r13-06 cuts
    it to <= 1200, so this row must fit under the ceiling in force when it
    lands.

### 2.9 Row 09: markdown fast path: DISAGREE (already on master)

- Site: `MarkdownBlock.vue:78-101`. The dynamic import is at line 89
  (`await import('~/utils/markdown.mjs')`). The lines exist.
- **Measured.** The fast path exists one level up:
  `MessageBody.vue:57`
  `mdSource = ... (props.markdown || looksLikeMarkdown(props.body)) ? markdownSource(...) : null`.
  MarkdownBlock mounts only when that is non-null. On `/lobby`,
  `{"mdBlocks":0,"msgBodies":3}`: 3 plain bodies, 0 markdown blocks, no
  markdown chunk.

  The regex the row proposes would also send every body containing `\n`
  or `<` to the parser, so it is *worse* than `looksLikeMarkdown`. "3x
  throughput" has no measurement behind it.

### 2.10 Row 10: debounce `seedTopics`: DISAGREE

- Site: `grep -n seedTopics 'src/pages/channel/[name].vue'` -> `82`, `90`,
  `91`, `99`. The watcher is `98-100`. The lines exist.
- **Measured.** Vue's pre-flush scheduler already coalesces. The script
  (section 6.3) gives:
  - `10 same-tick replacements -> watcher calls: 1`
  - `10 replacements in 10 separate ticks -> watcher calls: 10`

  The channel store replaces `messages.value` on every change (15 sites,
  `grep -c "messages.value = " src/stores/channel.ts` -> 15). Two more points:
  - The watcher is gated by `topicFeedReady`, which the selection watcher
    sets `false` for the whole switch (`75-87`). On a channel switch
    `seedTopics` runs **once**, from the selection watcher. The plan's
    "118 ms switch latency" therefore cannot come from this watcher.
  - A 16 ms trailing debounce delays the owner's fix (t1 7ef63cfc, the
    comment at `94-97`) for a gain the row does not measure.

### 2.11 Row 11: cache `channelView` / `feed`: DISAGREE

- Sites: `channel.ts:105` (`feed`) and `115` (`view`) exist. `103` is
  `ordered` (the sidebar), not a message projection.
- **Measured.** Both are Vue `computed`, so they recompute only when
  `messages`, `search` or `visible` change. The red control "mutating
  unrelated store state does not re-compute" is **already green**.

  Cost per recompute (`channelView` + `rootsByTask(topLevel())`, node, n=7):

  | messages | median | min | max |
  |---|---|---|---|
  | 200 | 0.73 ms | 0.48 | 9.67 |
  | 1000 | 4.11 ms | 3.71 | 5.18 |
  | 5000 | 8.41 ms | 7.42 | 9.24 |

  An incremental cache that must stay correct under `applyEdit`,
  `patchReactions`, `withoutMsg` and `mergeCatchUp` is a large correctness
  risk for under a millisecond at realistic sizes. The slug
  `cache-starter-card-stats` does not match the content.

### 2.12 Row 12: fold the docs tree: DISAGREE (already on master)

- Site: `docs.vue:62` and `157` exist.
- **Measured.**
  - The tree already starts folded: `open = ref(new Set(['csi-spl-doc']))`
    (`docs.vue:207`), plus the active doc's ancestors (`318`).
    `DocsWorkspaceTree` starts with `open = new Set()`
    (`DocsWorkspaceTree.vue:101`).
  - On `/docs/csi-spl-doc/doc/md/developer-guide.md`:
    `{"treeRows":9,"dom":637}`.
  - `/docs` itself redirects to `/workspace/docs`, giving
    `{"treeRows":0,"dom":812}`. Those 812 nodes are `WorkspaceDocsLayout`.
    On that page 137 of them are a hidden channel sidebar body
    (proposal P1).

## 3. Cross-round collisions with round 13 (v1.1, SIGNED)

`grep -oE 'wui:[^`<]+'` on both plans: the plan's "0 files shared with Round
13" is wrong. There is one shared file, plus three coupling points:

| perf row | round 13 row | shared | who goes first |
|---|---|---|---|
| 08 `pages/issues.vue` | 06 (decompose `issues.vue`, script 2084 -> <= 1200) | **same file** | **round 13 first.** r13-06 lands, then p6-08 rebases onto it (round 13 plan section 3.3 already says so). p6-08 waits for r13-06 even if its batch comes up first |
| 08 `pages/issues.vue` | 02 (`sfc-script-size` ratchet, ceiling `issues.vue` 2084) | ceiling map | round 13 first. p6-08 may not raise the script past the ceiling in force when it lands |
| 06 `LiveFeed.vue` | 07 (`useScrollAnchor.ts` decisions -> `scroll-anchor.mjs`) | caller (`LiveFeed.vue:158,280`); the transition/anchor timing (`LiveFeed.vue:638-641`) | round 13 first (API-stable refactor). p6-06 then runs the scroll-anchor e2e in its test column |
| 06 `LiveFeed.vue` (474 script lines) | 02 (new SFCs capped at 500) | gate | round 13 first. p6-06 adds <= 25 script lines |
| 03 `date-iso.mjs` (if kept) | 08 (`unused-exports` gate) | gate | either order. A new export needs an importer outside its file |
| P1 `ChannelSidebar.vue` (section 4) | 04 (decompose `ChannelSidebar.vue`) | **same file** | **round 13 first** |

## 4. Proposals the plan missed (2)

The hidden-but-mounted DOM scan (section 6.4) walks the signed-in page and
counts every `display:none` subtree of >= 8 nodes:

```
/channel/alerts 1440 {"dom":571,"hiddenNodes":45,"top":["45 div[data-test=user-menu-panel]"]}
/channel/alerts 390 {"dom":603,"hiddenNodes":217,"top":["153 nav.sidebar","56 div[data-test=user-menu-panel]","8 div[data-test=theme-picker-root]"]}
/issues 1440 {"dom":628,"hiddenNodes":71,"top":["45 div[data-test=user-menu-panel]","26 div.issues-status-dd__list"]}
/workspace/docs 1440 {"dom":857,"hiddenNodes":182,"top":["137 div.sidebar-body","45 div[data-test=user-menu-panel]"]}
```

### 4.1 P1: do not mount the channel list while the sidebar is rail-only (replaces row 12)

- **Where.**
  - `ChannelSidebar.vue:146` `<div class="sidebar-body">`
  - `ChannelSidebar.vue:1731` `.sidebar.sidebar--rail .sidebar-body { display: none; }`
- **Why.** In the rail-only sections (docs, issues rail, calendar,
  monitoring, help) the whole channel list is mounted and hidden: **137 of
  857 nodes (16%)** on `/workspace/docs` with the mock's few channels. It
  grows with the tenant's channel count.
- **Do.** `v-if="!railOnly"` on `.sidebar-body`, with the same predicate
  the class uses. Its store state (folds, unread) lives in Pinia, so a
  remount loses nothing.
- **Measure.**
  - Hidden-node count on `/workspace/docs`, 137 -> 0.
  - Mobile `/workspace/docs` TBT before and after (now 1050 ms median,
    n=3).
- **Order.** After r13-04 (same file).
- **Test column.** The 7 test files that name `sidebar-body` (`grep -rln sidebar-body tests | wc -l` -> 7), plus the rail-section e2e.

### 4.2 P2: mount the phone's hidden channel list on idle, not at boot (replaces row 09)

- **Where.**
  - `layouts/default.vue:44` `<ChannelSidebar v-if="shellIn" />`
  - `assets/css/main.css:889` `.spool-shell:not([data-mobile-level="1"]) > .sidebar { display: none; }`
- **Why.** On a phone with a feed in front, the hidden `nav.sidebar` is
  **153 of 603 nodes (25%)**. It is the largest hidden subtree in the app,
  and on mobile `/channel/alerts` TBT is 905 ms and FCP 1648 ms.
- **Do.** On a phone below `MOBILE_STACK_QUERY` only, when the boot route is
  not level 1, mount it on `requestIdleCallback` (with a timeout fallback)
  instead of in the first render. Back to the list still finds it mounted.
  Desktop is unchanged.
- **Measure.**
  - Mobile `/channel/alerts` DOM at FCP, 603 -> about 450.
  - TBT, n=5 same-box A/B.
  - Red control: the phone back-matrix e2e (`phone-back-matrix.test.mjs`,
    `mobile-back-stuck.test.mjs`) stays green.
- **Order.** Same file as row 02 (`default.vue`), so it goes in row 02's
  lane after row 02 lands, never in the same batch as row 02 (R1).

I found no third proposal worth a row. The mobile CPU profile (section 6.2)
puts the boot cost in the Vue runtime and the entry chunk, not in one
component. A real third row would come from a seeded large-tenant fixture
(issues, channels, messages), which the round does not have. That fixture
is the one tool rows 06, 08 and P1 all need. Building it first would be a
better use of a slot than any row I disagreed with.

## 5. R1 and lanes

- **R1 within each batch: holds.** The 12 plan rows name 12 distinct files
  (`grep -oE 'wui:[^`<]+' perf-round-6-plan.md | sort | uniq -c` -> every
  count is 1). No path appears twice in any batch, and with two
  asynchronous lanes no odd-even pair shares one either.
- **With my proposals.**
  - P2 shares `layouts/default.vue` with row 02, so it follows row 02 in the
    same lane.
  - P1 shares nothing with the perf rows.
  - Rows 02 and 05 measure the same budget, so fold 05 into 02's lane.
- **2 lanes in parallel: holds as written.** It drops to 1 lane whenever
  p6-08 waits for r13-06 (section 3). The spawner should then pull the
  next independent row forward instead of idling lane 2.
- **R7 mapping.** Fine. Under the plan's vendor column I review grok rows
  01, 03, 06, 09 and mistral rows 04, 07, 10 for whichever survive v1.0.

## 6. The measuring scripts (session scratch, reproducible)

### 6.1 Page metrics

```js
// node measure.mjs <base> 3 ; puppeteer-core from csi-spl-wui/node_modules/.pnpm
const profiles = { desktop: { vp: { width: 1440, height: 900 }, cpu: 1 },
  mobile: { vp: { width: 390, height: 844, isMobile: true, hasTouch: true }, cpu: 4, ua: '<iPhone UA>' } }
// per route x profile x n: fresh context, CDP Performance.enable,
// Emulation.setCPUThrottlingRate, observers for largest-contentful-paint and
// longtask (TBT = sum(max(0, d - 50))), goto networkidle0, +500 ms, then
// Performance.getMetrics (LayoutDuration, ScriptDuration), paint entries,
// document.getElementsByTagName('*').length; median of n.
```

### 6.2 CPU profile

Mobile 4x, `/channel/alerts`: CDP `Profiler.start` at a 200 us sampling
interval, `goto networkidle0`, then self time summed per script URL.

```
  845 ms  (program)
  726 ms  Cc4Azcwx.js
  411 ms  B-pcqvXw.js
  170 ms  B4WS_APv.js
  100 ms  gsbslMDU.js
```

### 6.3 Watcher coalescing (row 10)

`ref([])` plus `watch(() => messages.value, ...)` from the WUI's own `vue`.
Ten replacements in one tick, then ten across ten `nextTick`s, counting the
watcher calls.

### 6.4 Hidden subtrees

Recursive walk from `document.body`. A child with computed
`display:none` and >= 8 descendants is recorded and not descended into.
The page is signed in through `session.adopt(...)`, as the e2e tests do.
