# Refactoring round 13 - plan (10 actions)

Owner HUM-10, t1 topic `dc15ad65-a5c8-495c-b244-030b6f4d768d`, msgs b6696969
("UI clean code and testability refactoring round") and f822986b ("panel of
experts for 10 empirical actions to perform to get cleaner code and better
testability than the current one").
Round 13 focus: **the WUI (`csi-spl-wui/`) only: cleaner code and better testability**.
Concurrency: **build 2 row lanes in parallel at all times** (owner t1 dc15ad65
msg 686bc1a3 and eafc9b15 msg 2c1b49ee: "use 2 lanes in parallel for this one").
Consensus: **no owner go, no question to the owner** (rulebook 1.4; owner t1
dc15ad65 msg b8e22a15: "do not ask me for input - just reach consensus between
all of the members of the panel and start implementation").
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps,
bands, R1-R16), by pointer, not copied. Issue: SPL-2045.

**Status: v1.1, SIGNED**. The rows spawn from the signed v1.1
sha (rulebook 1.4: consensus, then build, no second go).

Editor: **a-584@<box>** (agy).

**One sha:** every count is measured on **`e95587ea2`** (`origin/master`,
2026-10-16), n=1 per command unless stated. Input:
[refactor-round-12-retro.md](refactor-round-12-retro.md) section 7 and expert
panel proposals ([seat-claude.md](refactor-round-13/seat-claude.md) `68ceccb3f`,
[seat-mistral.md](refactor-round-13/seat-mistral.md) `7919bd66e`).

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept, or for a gate / test addition a
  **red control**: the check fails on the bad input before the change and passes after.
- **Paths:** `wui:` = `csi-spl-wui/`. Lines as of `e95587ea2`.
- **Box:** the preferred box (`sat` or other available box); the spawner's box
  pick may move a row (no pin).
- **Vendor:** the owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`
  on `e95587ea2`: simple_coding -> mistral, backup claude; complex_coding
  -> claude, backup mistral; tests -> claude, backup mistral), then R14.
  (Grok dropped per dispatcher `c-002@sat` note `6acfc32a`: no grok quota on any box).
- **Subject** (R6 reads it): `<type>(r13-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
  The sha is pasted from `git rev-parse`, never typed; `ran:` names only
  commands that are in the `log:` file.

## 2. Where the rows come from (measured on `e95587ea2`)

| source | command | n | row |
|---|---|---|---|
| retro 7.1 / panel | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/MessageCard.vue \| wc -l` | 1416 lines | 01 |
| panel P1 | `for f in $(git ls-files 'csi-spl-wui/src/**/*.vue' 'csi-spl-wui/src/*.vue'); do echo "$(sed -n '/<script/,/<\/script>/p' $f \| wc -l) $f"; done \| sort -rn \| awk '$1>500' \| wc -l` | 7 SFCs > 500 lines | 02 |
| retro 7.3 / panel | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/MessageComposer.vue \| wc -l` | 1135 lines | 03 |
| retro 7.2 / panel | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/ChannelSidebar.vue \| wc -l` | 1007 lines | 04 |
| retro 7.5 / panel | `wc -l csi-spl-wui/src/composables/useMsgShortcuts.ts \| awk '{print $1}'` | 464 lines (0 dispatch tests) | 05 |
| panel P2 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/pages/issues.vue \| wc -l` | 2084 lines (largest in WUI) | 06 |
| retro 7.7 / panel | `wc -l csi-spl-wui/src/composables/useScrollAnchor.ts \| awk '{print $1}'` | 293 lines (3 untested `after*`) | 07 |
| panel P3 | `for each export in utils and composables: git grep -lw <name> -- src tests nuxt.config.ts (excl. defining file)` | 87 unused exports in 49 files | 08 |
| retro 7.9 / panel | `git grep -l "poll-fence" csi-spl-wui/tests/unit/ \| wc -l` | 0 direct test files | 09 |
| retro 7.8 / panel | `wc -l csi-spl-wui/src/composables/useSubmitKey.ts \| awk '{print $1}'` | 42 lines (hintFor untested) | 10 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r13-01-wui-decompose-message-card)` | component decomposition, cleaner code | `MessageCard.vue` `<script>` tag is 1416 lines; contains mixed concerns (reactions, menus, attachments) | `wui:src/components/MessageCard.vue:466-1881` | 1416 script lines | Decompose helper logic into sub-composables / subcomponents to shrink script under 500 lines. Smoke tests: `pnpm run typecheck`, `node tests/unit/cleancode.test.mjs`, `node src/node/test/run-unit-tests.mjs`, perf budget. 39 unit tests reading source re-pointed without assert count dropping. **Red control:** `tests/unit/sfc-script-size.test.mjs` ratchet ceiling. | sat | claude | complex_coding | 1 (Lane 1 start) |
| 02 `test(r13-02-wui-test-sfc-script-ratchet)` | tests, clean code ratchet | No limit currently exists on SFC `<script>` block sizes (MAX_LINES=80 only gates functions) | `wui:tests/unit/sfc-script-size.test.mjs` | 7 SFCs > 500 lines | New unit test `sfc-script-size.test.mjs` with `MAX_SCRIPT = 500` and ceiling map of today's 7 SFCs (`issues.vue` 2084, `MessageCard.vue` 1416, `MessageComposer.vue` 1135, `ChannelSidebar.vue` 1007, `WorkspaceDocView.vue` 678, `QtoFileTree.vue` 654, `CalendarMainView.vue` 612). Smoke tests: `node tests/unit/sfc-script-size.test.mjs`. **Red control:** scratch SFC with 501 script lines fails test; restored passes. | sat | claude | tests | 1 (Lane 2 start) |
| 03 `refactor(r13-03-wui-decompose-message-composer)` | component decomposition, cleaner code | `MessageComposer.vue` `<script>` tag is 1135 lines; text entry, emoji/mention triggers, file uploads | `wui:src/components/MessageComposer.vue:328-1462` | 1135 script lines | Decompose composer input and attachment drag-drop into targeted helpers to shrink script under 500 lines. Smoke tests: typecheck, cleancode, unit runner, perf budget. 26 unit tests reading source re-pointed without assert count dropping. **Red control:** `tests/unit/sfc-script-size.test.mjs` ratchet ceiling. | sat | claude | complex_coding | 2 (Lane 1, after 01) |
| 04 `refactor(r13-04-wui-decompose-channel-sidebar)` | component decomposition, cleaner code | `ChannelSidebar.vue` `<script>` tag is 1007 lines; channel list, section folding, search | `wui:src/components/ChannelSidebar.vue:711-1717` | 1007 script lines | Extract channel item and section management subcomponents / composables to shrink script under 500 lines. Smoke tests: typecheck, cleancode, unit runner, perf budget. 48 unit tests reading source re-pointed without assert count dropping. **Red control:** `tests/unit/sfc-script-size.test.mjs` ratchet ceiling. | sat | claude | complex_coding | 2 (Lane 2, after 02) |
| 05 `refactor(r13-05-wui-small-composable-msg-shortcuts)` | small functions, testability | `useMsgShortcuts.ts` is 464 lines; shortcut matching in `msg-shortcuts.mjs` (458 lines), but keydown dispatch decisions (key+state->action) have 0 tests | `wui:src/composables/useMsgShortcuts.ts:1-464`<br>`wui:src/utils/msg-shortcuts-dispatch.mjs`<br>`wui:tests/unit/msg-shortcuts-dispatch.test.mjs` | 464 lines | Extract keydown dispatch decisions into new `.mjs` helper with unit tests; shrink `useMsgShortcuts.ts` to <= 250 lines without changing composable API. Smoke tests: typecheck, unit runner. **Red control:** mutation of one moved branch fails new unit test. | sat | mistral | simple_coding | 3 (Lane 1, after 03) |
| 06 `refactor(r13-06-wui-decompose-issues-page)` | component decomposition, cleaner code | `pages/issues.vue` `<script>` tag is 2084 lines (largest in WUI; file 4108 lines); board, column, and drag concerns tightly coupled | `wui:src/pages/issues.vue:1161-3244`<br>*(see 3.3 for Perf 6 coordination)* | 2084 script lines | Extract board, column and drag logic into composables/subcomponents; shrink script to <= 1200 lines without modifying imported composable APIs. Smoke tests: typecheck, cleancode, unit runner, perf budget. 19 unit tests reading source re-pointed. **Red control:** `tests/unit/sfc-script-size.test.mjs` ratchet ceiling. | sat | claude | complex_coding | 3 (Lane 2, after 04) |
| 07 `refactor(r13-07-wui-small-composable-scroll-anchor)` | small functions, testability | `useScrollAnchor.ts` is 293 lines; scroll offset math is in `scroll-anchor.mjs`, but key-list decisions in `afterPatch`, `afterPrepend`, `afterAppend` are untested | `wui:src/composables/useScrollAnchor.ts:179-225`<br>`wui:src/utils/scroll-anchor.mjs`<br>`wui:tests/unit/scroll-anchor.test.mjs` | 3 `after*` functions | Extract row-key selection decisions (row to hold, stick to bottom) into pure functions in `scroll-anchor.mjs` with unit tests covering prepend, append, patch. Smoke tests: typecheck, unit runner. **Red control:** mutation of row-selection decision fails unit test. | sat | mistral | simple_coding | 4 (Lane 1, after 05) |
| 08 `refactor(r13-08-wui-gate-unused-exports)` | dead code elimination, testability gate | 87 exported functions/constants in 49 files have no importer outside their own file (see 3.2 for discrepancy analysis) | `wui:tests/unit/unused-exports.test.mjs`<br>Top 5 files: `utils/perf-rum.mjs`, `utils/omnibox-dock.mjs`, `utils/act-as-mock.mjs`, `utils/mock-data.mjs`, `utils/calendar-swipe.mjs` | 87 unused exports | Add `unused-exports.test.mjs` with allowlist of 87 that may only shrink; unexport/delete dead exports in top 5 files (31 entries). Smoke tests: `node tests/unit/unused-exports.test.mjs`, unit runner. **Red control:** adding an unused `export const` turns test red. | sat | mistral | simple_coding | 4 (Lane 2, after 06) |
| 09 `test(r13-09-wui-test-util-poll-fence)` | tests, testability | `poll-fence.mjs` (15 lines) is re-exported by `poll.mjs` with 2 basic asserts in `poll-control.test.mjs`, but fence edge cases are untested | `wui:src/utils/poll-fence.mjs:1-15`<br>`wui:tests/unit/poll-fence.test.mjs` | 0 direct test files | Add unit test `poll-fence.test.mjs` covering edge cases: 4-backtick fence, trailing tab/space, CRLF, fence at EOF, null/empty input. Smoke tests: `node tests/unit/poll-fence.test.mjs`. **Red control:** regex mutation in `poll-fence.mjs` fails test. | sat | claude | tests | 5 (Lane 1, after 07) |
| 10 `test(r13-10-wui-test-composable-submit-key)` | tests, testability | `useSubmitKey.ts` contains `hintFor` logic (3 lines) which cannot be imported directly in node unit tests due to Nuxt/Vue imports | `wui:src/composables/useSubmitKey.ts:37-39`<br>`wui:src/utils/submit-key.mjs`<br>`wui:tests/unit/submit-key.test.mjs` | 0 direct tests of `hintFor` | Move `hintFor` into `utils/submit-key.mjs` as pure `submitHintFor(mode, base)`; keep `hintFor` wrapper in composable; add unit tests in `submit-key.test.mjs`. Smoke tests: `node tests/unit/submit-key.test.mjs`. **Red control:** mutate `submitHintFor` fails test. | sat | claude | tests | 5 (Lane 2, after 08) |

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All 10 rows touch completely disjoint files across `csi-spl-wui/`. No file is shared between any two rows.
To satisfy the owner directive ("build 2 row lanes in parallel at all times", owner t1 dc15ad65 msg 686bc1a3):
- **Lane 1 (odd rows):** Row 01 -> Row 03 -> Row 05 -> Row 07 -> Row 09
- **Lane 2 (even rows):** Row 02 -> Row 04 -> Row 06 -> Row 08 -> Row 10
- **Starting rows:** Row 01 (`MessageCard.vue`) and Row 02 (`sfc-script-size.test.mjs`) spawn in parallel as Batch 1.
- **Asynchronous lane independence:** Because lanes run asynchronously, disjointness holds across every pair of an odd row and an even row:
  - Row 01 (`MessageCard.vue`) vs Row 02 (`sfc-script-size.test.mjs`): disjoint.
  - Row 03 (`MessageComposer.vue`) vs Row 04 (`ChannelSidebar.vue`): disjoint.
  - Row 05 (`useMsgShortcuts.ts`) vs Row 06 (`pages/issues.vue`): disjoint (Row 05 preserves composable API).
  - Row 07 (`useScrollAnchor.ts`) vs Row 08 (`unused-exports.test.mjs` + top 5 utils): disjoint.
  - Row 09 (`poll-fence.mjs`) vs Row 10 (`submit-key.mjs`): disjoint.
- **No caller overlap:** Dropping obsolete row 04 (`useMobileStack.ts`) removed the cross-lane caller overlap with rows 01, 03, and 06. Row 05 and Row 10 strictly maintain existing composable signatures.

### 3.2 Row 08 count discrepancy analysis: symbol scan vs keyword tokens

The expert panel examined the count discrepancy between Mistral seat (`seat-mistral.md` Proposal 1: 2390) and Claude seat (`seat-claude.md` Section 3.3 / Proposal P3: 87):
- **Mistral measuring command:**
  ```bash
  for file in $(git ls-files 'csi-spl-wui/src/utils/'*.mjs 'csi-spl-wui/src/composables/'*.ts); do 
    exports=$(grep -E '^export (const|function|class|let|var|type|interface)' $file | awk '{print $2}' | sed 's/[({].*//'); 
    for export in $exports; do 
      if [ $(git grep -lw $export -- src tests nuxt.config.ts | grep -v $file | wc -l) -eq 0 ]; then 
        echo $export; 
      fi; 
    done; 
  done | wc -l
  ```
  *Analysis:* Mistral's pipeline used `awk '{print $2}'`, which extracted the syntax keywords (`const`, `function`, `class`, `let`, `var`, `type`, `interface`) instead of the exported identifier name (which sits at `$3` or after `export async function`). Furthermore, running `git grep -- src tests nuxt.config.ts` from repo root (where those folders reside under `csi-spl-wui/`) found 0 hits outside the defining file, falsely flagging all 2390 export keywords in the codebase as "unused".
- **Canonical symbol-level command (Claude seat / adopted):**
  Extracts the actual symbol identifier with regex `export\s+(?:async\s+)?(?:function|const|class|let|var)\s+([A-Za-z0-9_$]+)` across `src/composables/*.ts` and `src/utils/*.{mjs,ts}`, and searches for references across `csi-spl-wui/src`, `csi-spl-wui/tests`, and `csi-spl-wui/nuxt.config.ts` (excluding defining file).
  *Result on `e95587ea2`:* Exactly **87** unreferenced exports across 49 files (out of 2455 total scanned exports).
  Top 5 files with unreferenced exports:
  - `src/utils/perf-rum.mjs`: 12
  - `src/utils/omnibox-dock.mjs`: 6
  - `src/utils/act-as-mock.mjs`: 5
  - `src/utils/mock-data.mjs`: 4
  - `src/utils/calendar-swipe.mjs`: 4
  *(31 total unreferenced exports to unexport/clean up in Row 08).*
- **Consensus:** Both seats agreed on the practice (dead code elimination and unused exports gate) and the gate design (allowlist of 87 that only shrinks, unexporting dead exports in top 5 files). The verified baseline count is 87.

### 3.3 Cross-round coordination: `src/pages/issues.vue` (Round 13 Row 06 and Perf Round 6 Row 08)

`csi-spl-wui/src/pages/issues.vue` is touched by two planned rows across concurrent rounds:
- **Round 13 Row 06** (`refactor(r13-06-wui-decompose-issues-page)`): Decomposes board, column, and drag concerns inside `<script setup>` (`1161-3244`) to shrink script size from 2084 to <= 1200 lines.
- **Perf Round 6 Row 08** (`perf(p6-08-wui-issues-windowed-rows)`, plan `90599126f`, lane `a-591@<box>`): Implements progressive windowed rendering for issue table rows (`375,520`) to cut DOM nodes on initial paint.

**Execution Order:**
1. **Round 13 Row 06 lands first on master.** It extracts column/board composables and decomposes script logic to <= 1200 lines, preserving template structures and component contracts.
2. **Perf Round 6 Row 08 rebases onto landed Row 06.** Once Row 06 lands on `origin/master`, lane `a-591@<box>` rebases its branch onto master and implements progressive windowed row rendering against the decomposed component.
3. **Coordination notification:** `a-584@<box>` notified `a-591@<box>` via spool message on task `dispatch-eb4bd4b3` (`d59983ed`).

### 3.4 Off every live lane (R3)

`lane-map.sh --check <paths> --agent a-584` verifies that no live lane owns any row path. The spawner re-runs `--check` per row before spawning (R3).

## 4. Per row: what the lane does

- **01:** decompose `MessageCard.vue` `<script>` tag (`466-1881`, 1416 lines) by extracting reaction and attachment subcomponents / composables; shrink `<script>` below 500 lines. Re-point 39 source-reading unit tests without dropping assert count.
- **02:** add `tests/unit/sfc-script-size.test.mjs` establishing `MAX_SCRIPT = 500` and today's 7 SFC ceilings (`issues.vue` 2084, `MessageCard.vue` 1416, `MessageComposer.vue` 1135, `ChannelSidebar.vue` 1007, `WorkspaceDocView.vue` 678, `QtoFileTree.vue` 654, `CalendarMainView.vue` 612).
- **03:** decompose `MessageComposer.vue` `<script>` tag (`328-1462`, 1135 lines) by extracting text input, shortcut triggers, and file drag-drop helpers; shrink `<script>` below 500 lines. Re-point 26 source-reading unit tests without dropping assert count.
- **04:** decompose `ChannelSidebar.vue` `<script>` tag (`711-1717`, 1007 lines) by extracting channel list and section folding helpers; shrink `<script>` below 500 lines. Re-point 48 source-reading unit tests without dropping assert count.
- **05:** extract shortcut keydown dispatch decisions (key+state->action) from `useMsgShortcuts.ts` into a new `.mjs` helper with unit tests; shrink composable to <= 250 lines while preserving public composable API.
- **06:** decompose `pages/issues.vue` `<script>` tag (`1161-3244`, 2084 lines) by extracting board, column, and drag concerns into composables/subcomponents; shrink script to <= 1200 lines without changing imported composable APIs. Re-point 19 source-reading unit tests.
- **07:** extract scroll key-list decisions (row to hold, stick to bottom) from `afterPatch`, `afterPrepend`, `afterAppend` in `useScrollAnchor.ts` into pure functions in `utils/scroll-anchor.mjs` with unit tests covering prepend, append, patch.
- **08:** add `tests/unit/unused-exports.test.mjs` failing on unused exports outside defining file (allowlist of 87); unexport/delete dead exports in top 5 files (31 entries).
- **09:** write `tests/unit/poll-fence.test.mjs` covering edge cases for `src/utils/poll-fence.mjs` (4-backtick fence, trailing tab/space, CRLF, fence at EOF, null/empty).
- **10:** move `hintFor` from `src/composables/useSubmitKey.ts` into `src/utils/submit-key.mjs` as pure `submitHintFor(mode, base)`; keep `hintFor` wrapper in composable; add unit tests in `submit-key.test.mjs`.

## 5. Panel of experts and reviewers (R7)

- **Expert Panel:** one seat of every active agent kind placed via dispatcher (`c-002@sat`):
  - Editor / agy seat: `a-584@<box>` (`seat-agy.md`)
  - Claude seat: `c-243@sat` (`seat-claude.md`) — measured on `e95587ea2`, 7 agree with changes, 3 disagree, 3 proposals (P1-P3) folded into plan.
  - Mistral seat: `m-244@sat` (`seat-mistral.md`) — measured on `e95587ea2`, agreed on 9 rows, confirmed practice/gate design for Row 08.
  - (No grok seat: no grok quota on any box, per dispatcher `c-002@sat` note `6acfc32a`. No qwen seat: no qwen on fleet boxes).
- **Reviewers per row (R7):** Cross-vendor review enforced for every row:
  - Claude rows (01, 02, 03, 04, 06, 09, 10) reviewed by agy or mistral seats.
  - Mistral rows (05, 07, 08) reviewed by claude or agy seats.
  - Zero same-vendor reviews. Every review verified via `do_spl_review_line_check`.

## 6. Left out, measured (carried to Round 14 by pointer)

| what | why | measured by |
|---|---|---|
| `useMobileStack.ts` Vue/router wiring | Pure stack math already extracted in `utils/mobile-stack.mjs` (239 lines, 5 tests); remaining lines are Vue/router wiring | `seat-claude.md` section 2.2 |
| `usePaneWidths.ts` state persistence | Clamping and ratio math already in `utils/pane-widths.mjs` (307 lines, tested); composable is 23 small functions <= 80 lines | `seat-claude.md` section 2.4 |
| `src/stores/editMode.ts` | 12-line store with one setter; test protects nothing | `seat-claude.md` section 2.8 |
| `composables/useMove.ts` (253 lines) | Logic already in `utils/move-apply.mjs` (388 lines, 4 test files); ranks below P1-P3 | `seat-claude.md` section 3.3 |
| Hub repo edit & action coverage | Non-WUI; round 13 is dedicated exclusively to WUI clean code and testability | `csi-spl-api/src/go/spool-hub-api` go coverage |
| Bash LONG functions: `check-pre-push` (137), `spawn_main` (185), `run.sh do_log` (143), `provision-firebase-dns` (169) | Non-WUI; carried to round 14's input list | `bash-cleancode.tst.sh` |
| Remote branch prune round 12 | Executed under R8 step 2 by retro lane after retro landed | `ROUND=12 DRY_RUN=0 ./run -a do_git_prune_round_branches` |

## 7. Counts

| | n |
|---|---|
| rows | 10 (refactor 7, test 3; 100% WUI) |
| vendor | claude 7 (01, 02, 03, 04, 06, 09, 10), mistral 3 (05, 07, 08) |
| box (preferred) | sat 10 |
| batches | 5 batches of 2 rows (2 parallel lanes at all times) |

## 8. Changes

- v0.1: Initial proposed plan for Round 13 (WUI cleaner code and better testability), measured on `dc17f840e` (retro section 7 input list).
- v0.2: Expert panel composition updated per dispatcher `c-002@sat` (msg `f1cdd328`): claude, grok, mistral, agy (no qwen seat: no qwen on fleet boxes). Each seat re-measures the 10 rows and proposes up to 3 actions with numbers to fold into v1.0.
- v0.3: Expert panel composition updated per dispatcher `c-002@sat` (note `6acfc32a`): no grok seat for round 13 (no grok quota on any box). Panel = claude seat + mistral seat + agy editor seat; fold those two into v1.0.
- v0.4: Folded expert panel findings from claude seat `c-243@sat` (`seat-claude.md`, commit `68ceccb3f`, measured on `e95587ea2`):
  - Fixed site ranges for rows 01, 03, 04 to target `<script>` blocks (`466-1881`, `328-1462`, `711-1717`) instead of templates.
  - Added source-reading test preservation requirements to test columns for rows 01, 03, 04, 06.
  - Replaced low-value row 10 (`editMode.ts`) with proposal P1 (`sfc-script-size.test.mjs` ratchet ceiling for 7 SFCs > 500 lines), placed at row 02 (Lane 2 start).
  - Replaced duplicate helper row 04 (`useMobileStack.ts`) with proposal P2 (decomposing `pages/issues.vue` `1161-3244` from 2084 to <= 1200 script lines), placed at row 06.
  - Replaced duplicate helper row 06 (`usePaneWidths.ts`) with proposal P3 (no-unused-exports gate `unused-exports.test.mjs`, allowlist 87, unexporting top 5 files), placed at row 08.
  - Clarified row 05 target: extract dispatch decisions to `.mjs` helper with unit tests; target composable <= 250 lines.
  - Clarified row 07 target: extract key-list decisions from `after*` functions into pure functions in `scroll-anchor.mjs`.
  - Clarified row 10 target: move `hintFor` into `submit-key.mjs` as pure function with unit tests.
  - Ordered batches to guarantee 2 parallel lanes (Lane 1: 01, 03, 05, 07, 09; Lane 2: 02, 04, 06, 08, 10) with complete cross-lane file disjointness and API stability.
- v1.0: Consensus signed by panel:
  - Mistral seat `m-244@sat` reviewed v0.4 (`seat-mistral.md`, commit `7919bd66e`, measured on `e95587ea2`): agreed with 9 rows (01, 02, 03, 04, 05, 06, 07, 09, 10).
  - Row 08 consensus: Mistral seat confirmed the practice and gate design (unused-exports gate); its 2390 count scanned raw keyword tokens; Claude seat's symbol-level scan identified 87 unreferenced exports across 49 files (2465 total scanned). Allowlist gate and unexporting top 5 files adopted.
  - Full consensus reached across all 3 active panel seats (agy editor `a-584@<box>`, claude seat `c-243@sat`, mistral seat `m-244@sat`). Plan is SIGNED v1.0.
- v1.1: Resolved dispatcher send-back items (`e2bcf0cb`):
  - Signed seat files verified on `origin/master`: Claude seat signed in `393642ce4` on `1a1e01c84`; Mistral seat signed in `7a041f105` on `1a1e01c84`. Agy editor seat signed in `seat-agy.md` on `1a1e01c84` and `v1.1`.
  - Row 08 discrepancy resolved: detailed token vs symbol parsing in Section 3.2, citing exact commands and explaining the 2390 keyword-token probe vs the 87 symbol-level scan, confirming canonical 87 unused exports in 49 files and top 5 file breakdown.
  - Cross-round coordination established in Section 3.3 for `src/pages/issues.vue`: Round 13 Row 06 lands first, Perf Round 6 Row 08 rebases onto it; notified `a-591@<box>` on `dispatch-eb4bd4b3` (`d59983ed`).

## 9. Consensus

| seat | id | signed | file |
|---|---|---|---|
| editor (agy) | a-584@<box> | **signed v1.0** on `1a1e01c84`; **signed v1.1** (this commit) | this file, `refactor-round-13/seat-agy.md` |
| claude seat | c-243@sat | **signed v1.0** in `393642ce4` on `1a1e01c84` | `refactor-round-13/seat-claude.md` |
| mistral seat | m-244@sat | **signed v1.0** in `7a041f105` on `1a1e01c84` | `refactor-round-13/seat-mistral.md` |
