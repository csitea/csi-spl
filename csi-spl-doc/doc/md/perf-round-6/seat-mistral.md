# Perf round 6: claude takeover of the mistral seat

Seat: **c-252@sat** (claude), the claude takeover of the mistral seat
(m-594 failed it; dispatch holder c-003, msg ddbd68ed). Task
`dispatch-eb4bd4b3`, issue SPL-2072 (round SPL-2051). Nothing from m-594 is
reused.

Reviews: [perf-round-6-plan.md](../perf-round-6-plan.md) **v1.0 draft**
(`0af615b8c`), the newest plan on origin/master (c-002 msg ea6dc23d).

**One sha:** every number below was measured in this session on
**`b6153d006`** (`b6153d0061b90d950d0e0b4940fbbe47576d8952`, `origin/master`,
2026-10-16). `git diff --stat 4a3781047 b6153d006 -- csi-spl-wui` is empty,
so this is the same WUI tree the claude seat measured. I read the claude
seat's verdict (`a4b20dec6`) and signature (`8cc3e62e2`). I copied no number
from it or from the plan.

**Verdict: 2 agree / 9 agree with changes / 1 disagree / 1 proposal.**

| row | verdict | one line why |
|---|---|---|
| 01 user menu `v-if` | agree with changes | 45 / 56 hidden nodes reproduce, but signed-in only. A unit test is titled "v-show owns display" and must be rewritten, not deleted |
| 02 async topic panes | agree with changes | The gain is **10x the target**: home set −43,687 B (351.3 -> 308.6 KB). Initial +108 B (headroom 0.4 -> 0.3 KB). The cold `/channel/*` load must not get slower |
| 03 rail sidebar body `v-if` | agree | 137 hidden nodes on `/workspace/docs` reproduce. The r13-04 overlap is real |
| 04 issues status list `v-if` | agree with changes | 26 nodes on desktop, **0 on a phone** (the list is not rendered there). 2 test files, not "unit tests" |
| 05 lazy CodeViewer | **disagree** | A/B build: home set −3 B, not −1.47 KB. Replace it with P1 (−501 B) |
| 06 LiveFeed TransitionGroup gate | agree with changes | Every row of a cold load animates in (3 of 3 on `/lobby`). LiveFeed's script is 474 lines, so "<= 25 lines" leaves 1 line of headroom under 500. No file overlap with r13-07 |
| 07 phone sidebar idle mount | agree with changes | 153 hidden nodes reproduce, and 231 on a phone's `/lobby` and `/workspace/docs`. It must spawn only after row 02 has landed (`default.vue`) |
| 08 windowed issue rows | agree with changes | Not measurable today: the mock renders 1 `tbody` row and 0 cards. It needs row 12's fixture **first**, but row 12 is batch 6 and row 08 is batch 4 |
| 09 tenant list `v-if` | agree with changes | 2 nodes on desktop (one membership), 0 on a phone. Measure a multi-tenant session; drop the row under 10 nodes |
| 10 docs TOC `v-if` | agree with changes | The TOC is **open by default** at 1440 px (31 visible nodes), so the red control "closed TOC" does not hold there. The gain is 31 nodes only when the doc pane is narrower than 760 px (closed at 1024 px) |
| 11 KindKeyHost phone gate | agree | Phones fetch its 2430 B chunk today. `usePhone()` *is* `stack.isMobile`, so the gate keeps the handler's own predicate |
| 12 harness + seeded fixture | agree with changes | `git ls-files \| grep -c measure-wui-perf` -> 0, confirmed. Move it to batch 1: rows 06, 08, 09 and 10 need it for their red controls. Keep it off `utils/mock-data.mjs` (r13-08) |

## 1. How I measured

### 1.1 The bundle

The mock-tenant bundle, built the way CI's `wui-generate` job builds it.
The worktree belongs to the push user, so the build runs as that user (`<DEV_USER>`):

```bash
sudo -u <DEV_USER> bash -lc 'cd csi-spl-wui && pnpm install --frozen-lockfile && NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate'
```

```bash
python3 ../csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub .output/public --budgets ../csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json
```

Output (n=1):

```
DOC 200.html 3 chunk(s) gzip 154.6 KB
DOC index.html 86 chunk(s) gzip 351.3 KB
PASS ci_initial_gzip_kb 154.6 <= 155
PASS ci_home_gzip_kb 351.3 <= 352.1
```

Plan section 2.4 reproduces: 0.4 KB headroom initial, 0.8 KB home.

For the A/B rows (02, 05, P1) I made the one-line change in this worktree,
regenerated, measured, then ran `git checkout -- <file>`. `git status --short`
was empty after each one, and nothing from those builds is committed. I
counted bytes exactly (gzip -6 sum of each page's `modulepreload` + `script`
chunks, `homebytes.py` in section 6.3), because `perf-budget.py` rounds to
0.1 KB. Build-to-build noise: a change that touches no home chunk reads
within 3 B.

### 1.2 Page metrics

The bundle was served with `node src/node/test/serve-generated.mjs --root
<copy> --port <free>` and driven by puppeteer-core 25.13.0 with
`/usr/bin/google-chrome` headless (section 6.1). desktop = 1440x900, no
throttle; mobile = 390x844, 4x CPU, iPhone UA. Each sample uses a fresh
browser context, `networkidle0`, then 500 ms. I report the median of n=3.
The box load average was 6-8 (`uptime`), so compare the rows with each
other, not with the plan.

| profile | route (landed) | FP | FCP | LCP | TBT | DOM | Layout | Script | raw FCP/LCP/TBT/DOM |
|---|---|---|---|---|---|---|---|---|---|
| desktop | `/` (`/lobby`) | 104 | 104 | 328 | 54 | 610 | 35 | 58 | 260/572/164/610 104/328/54/610 104/308/44/610 |
| desktop | `/login` | 172 | 172 | 172 | 0 | 493 | 59 | 69 | 176/176/0/493 172/172/0/493 156/156/0/493 |
| desktop | `/channel/alerts` | 64 | 504 | 504 | 92 | 524 | 25 | 53 | 664/664/143/524 504/504/92/524 444/444/81/524 |
| desktop | `/issues` | 64 | 452 | 452 | 77 | 581 | 25 | 52 | 452/452/77/581 512/512/85/581 444/444/76/581 |
| desktop | `/workspace/docs` | 56 | 432 | 524 | 80 | 810 | 26 | 48 | 444/568/81/810 432/524/80/810 420/524/73/810 |
| mobile | `/` | 240 | 360 | 1464 | 762 | 661 | 82 | 231 | 336/1380/693/661 360/1464/762/661 396/1520/834/661 |
| mobile | `/login` | 152 | 324 | 324 | 299 | 482 | 108 | 246 | 436/436/335/482 324/324/234/482 320/320/299/482 |
| mobile | `/channel/alerts` | 184 | 1800 | 1800 | 1059 | 545 | 58 | 197 | 1560/1560/876/545 1804/1804/1059/545 1800/1800/1065/545 |
| mobile | `/issues` | 164 | 1756 | 1756 | 870 | 656 | 56 | 226 | 1744/1744/826/656 1756/1756/870/656 2036/2036/1062/656 |
| mobile | `/workspace/docs` | 176 | 1612 | 1612 | 863 | 634 | 46 | 211 | 1768/1768/968/634 1612/1612/839/634 1572/1572/863/634 |

What this settles:

- The DOM counts of plan section 2.2 reproduce exactly on 8 of 10 cells
  (610, 493, 524, 581, 661, 482, 545, 656). Desktop `/workspace/docs` reads
  810 (plan 811). **Mobile `/workspace/docs` reads 634, not 818**: all 3
  samples read 634. The plan's mobile Docs DOM, and its "Docs" TBT row, need
  re-measuring before v1.0 cites them.
- Layout stays at 25-108 ms on every route. As the plan says, script and
  main-thread blocking are the cost. Mobile TBT is 762-1059 ms on the
  signed-in routes.

### 1.3 Hidden subtrees, signed in

The mock boots signed out, so `UserMenu` (`v-if="signedIn"`,
`UserMenu.vue:21`) renders 0 nodes on a cold load. I signed in the way the
e2e tests do (`session.adopt({hum:'HUM-1', ..., t:'t1'})`,
`tests/e2e/deadline-picker.test.mjs:135`), then `router.push(<route>)` and
waited 1500 ms. The script walks the body; a `display:none` child counts with
its whole subtree (section 6.2). n=1 per cell; the counts are deterministic.

| profile | route | DOM | hidden | biggest hidden subtrees | per-site nodes (h = hidden) |
|---|---|---|---|---|---|
| desktop | `/lobby` | 799 | 68 | 45 `user-menu__panel` | userMenu 45h, tenantList 2h, kindKey 1 |
| desktop | `/channel/alerts` | 643 | 68 | 45 `user-menu__panel` | userMenu 45h, tenantList 2h |
| desktop | `/issues` | 700 | 94 | 45 `user-menu__panel`, 26 `issues-status-dd__list` | statusDd 26h |
| desktop | `/workspace/docs` | 929 | 207 | 137 `sidebar-body`, 45 `user-menu__panel` | sidebarBody 137h, toc 31 (visible) |
| mobile | `/lobby` | 824 | 319 | 231 `nav.sidebar`, 56 `user-menu__panel` | navSidebar 231h, tenantList 0 |
| mobile | `/channel/alerts` | 671 | 232 | 153 `nav.sidebar`, 56 `user-menu__panel` | navSidebar 153h |
| mobile | `/issues` | 782 | 108 | 56 `user-menu__panel`, 29 `sidebar-body` | statusDd 0 |
| mobile | `/workspace/docs` | 760 | 359 | 231 `nav.sidebar`, 56 `user-menu__panel`, 53 `wsdocs-layout__tree` | toc 0 |

### 1.4 Where each site ships

`grep -lF -- '<marker>' .output/public/_nuxt/*.js`, then the chunk's `rel` in
`index.html` and `200.html`. Gzip is `gzip -6c | wc -c`:

| site (marker) | chunk | gzip B | `index.html` | `200.html` |
|---|---|---|---|---|
| default layout + LiveTopicPane + UserMenu + sidebar (`"live-topic-close"`, `user-menu-panel`, `sidebar-body`) | `CVuwGkCh.js` | 46713 | modulepreload | prefetch |
| TopicPane (`"topic-pane-close"`) | `DlbCPcmI.js` | 4957 | modulepreload | prefetch |
| CodeBlock + CodeViewer (`code-viewer__bar`) | `BLpAvhb2.js` | 7491 | modulepreload | prefetch |
| TenantDropBox (`tenant-switcher__list`) | `DK6b0wkA.js` | 2298 | modulepreload | prefetch |
| KindKeyHost (`"kind-key`) | `BqdqHZmu.js` | 2430 | - (lazy) | - |
| issues page (`issues-status-dd__list`) | `L6QRGXF6.js` | 36495 | - | - |
| workspace doc view (`wsdoc__toc`) | `Cp73KbGc.js` | 26282 | - | - |

The plan's "`LiveTopicPane` is part of `B4WS_APv.js`, 46.7 KB" is the whole
**default-layout chunk**, which also holds UserMenu and the channel sidebar.
LiveTopicPane alone is not 46.7 KB. So row 02's gain had to be measured with
an A/B build (2.2), and it turns out to be larger, not smaller.

## 2. Row by row

### 2.1 Row 01: `UserMenu.vue` `v-show` -> `v-if`: AGREE WITH CHANGES

- Sites: `grep -n 'v-show="open"' csi-spl-wui/src/components/UserMenu.vue` ->
  `60:        v-show="open"`; `63: data-test="user-menu-panel"`;
  `29: :aria-controls="menuId"`. All resolve.
- Number: 45 hidden nodes on desktop, 56 on a phone (1.3). These are
  **signed-in only**: signed out, the whole menu is 0 nodes (1.2, `userMenu: 0`).
- Placement still works under `v-if`. `openAt()` sets `open`, then
  `focusItem()` runs `await nextTick()` before `placePanel()`
  (`UserMenu.vue:397-404`), so the panel exists when it is placed.
- Changes:
  - `tests/unit/user-menu.test.mjs:149` is titled "a rotation never shows the
    CLOSED menu (v-show owns display)". Its two asserts read `clearPopover`
    source text, so they stay green. The lane rewrites that title and keeps
    the rotation guard (`watch(narrow, ...)`, `UserMenu.vue:520-523`): with
    `v-if`, a closed menu cannot be shown at all. Do not delete the test.
  - The red control is "signed in, menu closed: 0 nodes under
    `[data-test=user-menu-panel]` (was 45 at 1440 / 56 at 390)".
    `git grep -l user-menu-panel -- csi-spl-wui/tests | wc -l` -> 10 files
    must pass.

### 2.2 Row 02: async `LiveTopicPane` / `TopicPane`: AGREE WITH CHANGES

- Sites: `grep -n "TopicPane" csi-spl-wui/src/layouts/default.vue` ->
  `94: <LiveTopicPane v-if="section === LIVE" />`,
  `95: <TopicPane v-else-if="section === CHANNEL" />`. The 1..1 chain is intact.
- A/B build: I added the two `defineAsyncComponent` lines after the imports
  in `default.vue`, regenerated, then reverted.

  | | `200.html` (initial) | `index.html` (home) |
  |---|---|---|
  | base | 3 chunks, 158355 B (154.6 KB) | 86 chunks, 359726 B (351.3 KB) |
  | row 02 | 3 chunks, 158463 B (154.7 KB) | 78 chunks, 316039 B (308.6 KB) |
  | delta | **+108 B** | **−43,687 B** |

- Mobile page metrics on the same two bundles, alternated on the same box,
  n=5, median:

  | route | base FCP / LCP / TBT | row 02 FCP / LCP / TBT |
  |---|---|---|
  | `/` | 356 / 1472 / 785 | 324 / 1340 / 691 |
  | `/channel/alerts` | 1596 / 1596 / 872 | 1676 / 1676 / 938 |

  Raw base `/`: `340/1416/740 356/1532/845 356/1612/983 392/1472/785 336/1396/732`.
  Raw row 02 `/channel/alerts`: `1668/1668/912 1620/1620/867 1796/1796/1079 1768/1768/992 1676/1676/938`.
- Changes:
  - **Target:** home set drops by >= 40 KB, measured with the exact-bytes
    sum, not ">= 4.0 KB".
  - **Initial set grows by 108 B**, which leaves 0.3 KB of headroom on
    `ci_initial_gzip_kb`. The lane runs `perf-budget.py` with CI's node
    (memory: the box reads low) and stops if initial fails.
  - **Channel cold load:** on `/channel/alerts` the async `TopicPane` is now
    fetched after the layout instead of preloaded. FCP +80 ms and TBT +66 ms
    at n=5, inside the spread but in the wrong direction. Red control: the
    lane measures cold `/channel/<name>` and `/t/<id>` before and after at
    n>=5, same box, alternated. If the medians regress, it adds a prefetch for
    the CHANNEL pane on channel routes.

### 2.3 Row 03: rail-only sidebar body `v-if`: AGREE

- Sites: `grep -n 'sidebar-body' csi-spl-wui/src/components/ChannelSidebar.vue`
  -> `146: <div class="sidebar-body">`,
  `1731: .sidebar.sidebar--rail .sidebar-body { display: none; }`. Both resolve.
- Number: 137 hidden nodes under `div.sidebar-body` on desktop
  `/workspace/docs`, signed in or not (1.2 base `sidebarBody: "137h"`, 1.3).
  It is the biggest hidden subtree on any desktop route.
- `git grep -l sidebar-body -- csi-spl-wui/tests | wc -l` -> 7, as the plan says.
- Order: r13-04 changes `ChannelSidebar.vue:711-1717`, the same file, so
  row 03 runs after it. Agreed.

### 2.4 Row 04: issues status list `v-if`: AGREE WITH CHANGES

- Sites: `grep -n 'statusOpen' csi-spl-wui/src/pages/issues.vue` ->
  `204: <div v-show="statusOpen" class="issues-status-dd__list" role="listbox">`,
  closed by Escape (`:3004`, `:3008`) and an outside click (`:3195`).
- Number: 26 hidden nodes at 1440 (1.3). **At 390 the list is not rendered
  at all** (`statusDd: 0`), so this is a desktop-only gain.
- Changes:
  - The test column is the 2 files that name the list, not "unit tests,
    e2e": `git grep -l issues-status-dd -- csi-spl-wui/tests` ->
    `tests/e2e/issues.test.mjs`, `tests/e2e/issues-dropdowns-live.proof.mjs`.
  - The red control is measured at 1440.
  - After r13-06 (same file, `issues.vue:1161-3244`). Agreed.

### 2.5 Row 05: lazy `CodeViewer`: DISAGREE

- Site: `grep -n "CodeViewer" csi-spl-wui/src/components/CodeBlock.vue` ->
  `57: <CodeViewer :text="text" :lang="lang" />`, inside `UiDialog` (`:56`).
- A/B build with `defineAsyncComponent` for CodeViewer:

  | | `index.html` (home) | CodeBlock chunk |
  |---|---|---|
  | base | 359726 B | `BLpAvhb2.js` 7491 B |
  | row 05 | 359723 B | `CxWHz5aB.js` 7463 B, plus a new non-preloaded `DNMA6M3W.js` 914 B |
  | delta | **−3 B** | −28 B |

- `CodeViewer` shares nearly all of its code with `CodeLines`, which stays
  in the CodeBlock chunk. So moving it out saves noise-level bytes, and every
  dialog open pays a new round trip. The plan's "~1.47 KB" is CodeViewer's
  own size, not what the home set loses.
- Replace it with **P1** (section 4), which saves 501 B with the same kind of
  one-line change.

### 2.6 Row 06: LiveFeed TransitionGroup gate: AGREE WITH CHANGES

- Sites: `grep -n "TransitionGroup" csi-spl-wui/src/components/LiveFeed.vue`
  -> `37` and `112`. Both resolve.
- Number, cold load, MutationObserver from `evaluateOnNewDocument`
  (section 6.2). Vue puts the enter classes on a row *before* inserting it,
  so a class-added filter reads 0. I counted rows inserted with
  `*-enter-active` and the class edits that drop it:

  | profile | route | rows | inserted with enter-active | enter-active removals |
  |---|---|---|---|---|
  | desktop | `/lobby` | 3 | 3 | 6 |
  | mobile | `/lobby` | 3 | 3 | 6 |
  | desktop | `/channel/alerts` | 1 | 1 | 2 |
  | mobile | `/channel/alerts` | 1 | 1 | 2 |

  Every row of the first batch animates in. The plan's "8 on `/lobby`" is
  6 removals plus 3 inserts in my count; either way it is one animation per
  row.
- After a client-side `router.push` with rows already in the store, 0 rows
  animate (1.3, `enterActive: 0`): the cost is the cold first batch only.
- Changes:
  - LiveFeed's `<script>` is 474 lines (`awk` count between the tags), so
    "<= 25 lines" leaves **1 line** under r13-02's 500-line ceiling. Make it
    <= 20.
  - r13-07 edits `useScrollAnchor.ts:179-225` and `scroll-anchor.mjs`, **not**
    `LiveFeed.vue`. R1 has no file collision. Keep "after r13-07" for the
    behaviour reason only (the gate must not fight `afterAppend`), and say so.
  - Its 30-row red control needs row 12's fixture (the mock has 3 rows).

### 2.7 Row 07: phone sidebar on idle: AGREE WITH CHANGES

- Site: `grep -n "ChannelSidebar" csi-spl-wui/src/layouts/default.vue` ->
  `44: <ChannelSidebar v-if="shellIn" />`. `mountMain` already gates the main
  pane for the phone's level 1 (`:336`).
- Number: `nav.sidebar` hidden, 153 nodes on a phone's `/channel/alerts`
  (cold and signed in), **231** on a phone's `/lobby` and `/workspace/docs`
  (1.3). The gain is larger than the plan says on two more routes.
- Changes:
  - `default.vue` is also row 02 (lane 2, batch 1) and row 11 (lane 1,
    batch 6). Under the lane-paced model in plan 3.1, lane 1 reaches row 07
    after 3 landings. If row 02 stalls, row 07 would run beside it on the
    same file. The spawner holds row 07 until row 02 has landed.
  - Red control on all three phone routes; `phone-back-matrix` and
    `mobile-back-stuck` stay green, as the plan says.

### 2.8 Row 08: windowed issue rows: AGREE WITH CHANGES

- Sites: `grep -n 'v-for="issue in' csi-spl-wui/src/pages/issues.vue` ->
  `375` (table) and `520` (cards). Both resolve.
- Number now: **not measurable**. The mock `/issues` renders 1 `tbody tr`
  (the empty state) at 1440 and 0 `.issues-card-li` at 390 (section 6.4).
- Changes:
  - The fixture it needs is row 12, which is in **batch 6**, two batches
    after row 08. Move row 12 to batch 1 (see 2.12) or row 08 cannot show a
    red control.
  - `issues.vue`'s `<script>` is 2082 lines today. r13-06 brings it to
    <= 1200; row 08 runs after r13-06 and fits the ceiling in force then.

### 2.9 Row 09: tenant list `v-if`: AGREE WITH CHANGES

- Site: `grep -n 'listOpen' csi-spl-wui/src/components/TenantDropBox.vue` ->
  `63: v-show="listOpen && shownRows.length > 0"`. The combobox reads
  `aria-controls` (`:38`) and `aria-activedescendant` (`:40`, which is
  undefined while closed, `:197`).
- Number: **2 nodes** at 1440 (one membership), 0 at 390 (not rendered on a
  phone). Not "5-15".
- Changes:
  - Keep `aria-controls` valid: bind it only while open, or keep the `ul`
    and put the `v-if` on its `li` rows.
  - Measure a multi-tenant session first. Drop the row if the closed list is
    under 10 nodes for a 5-tenant member.
  - Test column: `tests/e2e/tenant-list-inset.test.mjs`,
    `tests/unit/tenant-switcher.test.mjs`.

### 2.10 Row 10: docs TOC `v-if`: AGREE WITH CHANGES

- Site: `grep -n 'tocOpen' csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue`
  -> `261: v-show="tocOpen"`, but also `381: const tocOpen = ref(true)` and
  `982: tocOpen.value = !narrow()` on mount, with `NARROW = 760` (`:351`)
  on the doc pane's own width.
- Number (section 6.4, `/workspace/docs`, signed out, the mock's first doc):

  | window | doc pane px | TOC | nodes |
  |---|---|---|---|
  | 1440 | 1079 | open, `display:block` | 31 (8 items) |
  | 1024 | 663 | closed, `display:none` | 31 |
  | 800, 700 | - | no doc view | 0 |

- So "closed TOC on every doc page" is false. At a full desktop width the
  TOC is open and `v-if` changes nothing. The gain is 31 nodes when the doc
  pane is under 760 px (about 820-1180 px windows), or after the reader
  closes it.
- Changes:
  - Red control at 1024 px, not 1440.
  - `goTo()` closes the TOC on a narrow pane (`:967`). The lane checks that
    a link click still scrolls before the `v-if` unmounts it.
  - `tests/e2e/workspace-doctree.test.mjs:1105` reads `[data-test=ws-doc-toc]`
    directly, so it may need a `null` branch.
  - "mounts and animates smoothly": there is no TOC transition today, so the
    lane adds none.

### 2.11 Row 11: KindKeyHost phone gate: AGREE

- Site: `grep -n "KindKeyHost" csi-spl-wui/src/layouts/default.vue` ->
  `144: <LazyKindKeyHost />`. Handler: `KindKeyHost.vue:152`
  `if (!isShiftK(ev) || !shortcutsOn.value || phone.value) return`.
- `usePhone()` is `return useMobileStack().isMobile`
  (`composables/useTouchUi.ts:18-19`). So `v-if="!stack.isMobile.value"` is
  the handler's own predicate, and no device that has Shift+K today loses it.
- Number: DOM is 1 node (`data-testid=kind-key-host`) on both widths. The
  gain is the lazy chunk `BqdqHZmu.js` (2430 B gzip), which phones fetch
  today (cold `/channel/alerts` at 390: `BqdqHZmu fetched: true`), plus its
  four composables' setup.
- Test column: `tests/e2e/shift-k-middle.test.mjs`.

### 2.12 Row 12: committed harness and seeded fixture: AGREE WITH CHANGES

- Number now: `git ls-files | grep -c measure-wui-perf` -> `0`. The mock has
  0 issues (2.8), 1-3 feed rows (2.6) and one membership (2.9).
- Changes:
  - **Run it first.** Rows 06, 08, 09 and 10 all need a fixture for their red
    controls, and row 12 is batch 6. Put row 12 in batch 1 and shift the rest
    (see section 5).
  - The fixture must not edit `utils/mock-data.mjs`: r13-08 names it in its
    top 5 files. Put the fixture in its own module, imported only by the
    harness and the e2e tests.
  - r13-08 adds an unused-exports gate. The harness is a CLI under
    `src/node/test/`, so it exports nothing.
  - My scripts in section 6 are a working start for it.

## 3. Cross-round collisions with round 13

Round 13 is **v1.1, SIGNED** (`fd7e80e2b`), not v0.4 as my brief says.
I compared its sites column with every perf row:

| perf row | file | round 13 row | same file? | who goes first |
|---|---|---|---|---|
| 03 | `ChannelSidebar.vue` | r13-04 (`:711-1717`) | yes | r13-04 first |
| 04 | `pages/issues.vue` | r13-06 (`:1161-3244`) | yes | r13-06 first |
| 08 | `pages/issues.vue` | r13-06 | yes | r13-06 first; row 08 also within r13-02's ceiling |
| 06 | `LiveFeed.vue` | r13-07 (`useScrollAnchor.ts`, `scroll-anchor.mjs`) | **no** | r13-07 first, for behaviour only |
| 06, 08 | script size | r13-02 (`sfc-script-size.test.mjs`) | gate, not file | row 06 <= 20 lines (474 now) |
| 12 | fixture | r13-08 (`utils/mock-data.mjs` among its top 5) | yes, if the fixture goes there | fixture in its own file; then no order |
| 11 | `KindKeyHost.vue` uses `holdPanel` from `useMsgShortcuts.ts` | r13-05 (`useMsgShortcuts.ts`) | no | none; row 11 edits only `default.vue` |
| P1 | `KindBadge.vue` | none | no | none |

Rows 01, 02, 05, 07, 09 and 10 touch no round 13 file.

## 4. Proposals (1)

### 4.1 P1: mount `KindPicker` async in `KindBadge` (replaces row 05)

- Site: `KindBadge.vue:39-47` already mounts the picker only while open
  (`v-if="settable && open"`, comment "mounted only while open
  (CLE-35075)"). But `KindPicker` is a static auto-import, so its code
  ships in the 28.7 KB message-card chunk (`CZBtcMWA.js`, marker
  `kind-picker`), which `index.html` preloads.
- Change: `const KindPicker = defineAsyncComponent(() => import('@/components/KindPicker.vue'))`
  in `KindBadge.vue`. Mounting, props and events stay as they are.
- A/B build, measured like 2.2:
  - `index.html`: 359726 -> 359225 B, **−501 B**.
  - `200.html`: 158355 -> 158356 B.
  - `perf-budget.py`: `ci_home_gzip_kb 350.8`, headroom 0.8 -> 1.3 KB.
- It is 167x row 05's gain, for the same kind of one-line change, on a file
  no other row or round 13 row touches.
- Red control: `ci_home_gzip_kb` falls >= 0.4 KB on the same box. The first
  open of a kind picker still opens it on the first click
  (`KindBadge` e2e, Shift+K via `shift-k-middle.test.mjs`). `KindKeyHost`
  keeps its static `KindPicker`, so it stays one chunk.

## 5. R1 and lanes

- Within each batch of plan 3.1, no path appears twice. I checked each pair:
  01/02, 03/04, 05/06, 07/08, 09/10, 11/12. **R1 holds.**
- Two problems remain, both about order, not R1:
  1. **The fixture comes too late.** Row 12 (batch 6) is needed by rows 06
     (batch 3), 08 (batch 4), 09 and 10 (batch 5).
  2. **Lanes are paced, batches are not.** The rulebook's R1 says batch N+1
     starts after batch N lands. Plan 3.1 instead spawns the next row of a
     lane as soon as that lane's row lands. Then `default.vue` (rows 02, 07,
     11) can run in two lanes at once if lane 2 stalls on row 02 while lane 1
     reaches row 07.
- Proposed order, still 2 lanes and 6 batches:

  | batch | lane 1 | lane 2 |
  |---|---|---|
  | 1 | 01 `UserMenu.vue` | **12** harness + fixture (new files) |
  | 2 | 03 `ChannelSidebar.vue` (after r13-04) | 02 `default.vue` |
  | 3 | P1 `KindBadge.vue` | 06 `LiveFeed.vue` (after r13-07) |
  | 4 | 07 `default.vue` (02 landed in batch 2) | 04 `issues.vue` (after r13-06) |
  | 5 | 09 `TenantDropBox.vue` | 08 `issues.vue` |
  | 6 | 11 `default.vue` | 10 `WorkspaceDocView.vue` |

  - Each batch is disjoint.
  - `default.vue` is in batches 2, 4 and 6 only.
  - `issues.vue` is in batches 4 and 5, both after r13-06.
  - The rule that holds it: a row on a file that another lane's open row
    holds waits for that row to land.

## 6. The measuring scripts (session scratch, reproducible)

All of them run with `node <script> http://127.0.0.1:<port>` against
`serve-generated.mjs`. They import puppeteer-core from
`csi-spl-wui/node_modules/.pnpm/puppeteer-core@25.13.0/node_modules/puppeteer-core/lib/puppeteer/puppeteer-core.js`.

### 6.1 Page metrics (`measure.mjs <base> <n> [routes] [profiles]`)

For each route, profile and n: a fresh context, CDP `Performance.enable` and
`Emulation.setCPUThrottlingRate`, observers for `largest-contentful-paint`
and `longtask` (TBT = sum(max(0, d − 50))), `goto networkidle0` + 500 ms,
then `Performance.getMetrics` (LayoutDuration, ScriptDuration), paint
entries and `getElementsByTagName('*').length`. It prints the median of n.

### 6.2 Signed in, hidden subtrees, enter animations (`signed.mjs`, `misc6.mjs`)

- `goto /login`, then `session.adopt(...)` through `$pinia._s.get('session')`,
  `$router.push(route)`, then 1500 ms.
- The walk from `document.body` records a `display:none` child with its whole
  subtree and does not descend into it.
- A MutationObserver (childList + class attribute, oldValue) is installed
  with `evaluateOnNewDocument`. It counts rows inserted with a
  `*-enter-active` class, and class edits whose old value had it and whose
  new value does not.

### 6.3 Home and initial bytes (`homebytes.py <pub>...`)

For `200.html` and `index.html`: the set of `_nuxt/*.js` named by a
`modulepreload` link or a `script src`, then the sum of
`len(gzip.compress(chunk, 6))`.

### 6.4 Rows 08, 10, 11 (`issues.mjs`, `misc.mjs`)

- Row 08: `/issues` at 1440 and 390, counting `tbody tr` and
  `.issues-card-li`.
- Row 10: `/workspace/docs` at 1440, 1024, 800 and 700, reading the
  `.wsdoc__toc` subtree size, its computed `display` and the `.wsdoc` width.
- Row 11: the response listener records which `.js` files a cold
  `/channel/alerts` load fetches.
