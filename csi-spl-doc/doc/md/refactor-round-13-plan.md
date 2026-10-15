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

**Status: v0.3, PROPOSED**. The rows spawn once v1.0 is signed by the expert panel.

Editor: **a-584@<box>** (agy).

**One sha:** every count is measured on **`dc17f840e`** (`origin/master`,
2026-10-15 19:54Z), n=1 per command unless stated. Input:
[refactor-round-12-retro.md](refactor-round-12-retro.md) section 7.

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept, or for a gate / test addition a
  **red control**: the check fails on the bad input before the change and passes after.
- **Paths:** `wui:` = `csi-spl-wui/`. Lines as of `dc17f840e`.
- **Box:** the preferred box (`sat` or other available box); the spawner's box
  pick may move a row (no pin).
- **Vendor:** the owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`
  on `dc17f840e`: simple_coding -> grok, backup claude/mistral; complex_coding
  -> claude, backup mistral; tests -> claude, backup mistral/grok), then R14.
- **Subject** (R6 reads it): `<type>(r13-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
  The sha is pasted from `git rev-parse`, never typed; `ran:` names only
  commands that are in the `log:` file.

## 2. Where the rows come from (measured on `dc17f840e`)

| source | command | n | row |
|---|---|---|---|
| retro 7.1 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/MessageCard.vue \| wc -l` | 1416 lines | 01 |
| retro 7.2 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/ChannelSidebar.vue \| wc -l` | 1007 lines | 02 |
| retro 7.3 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/MessageComposer.vue \| wc -l` | 1135 lines | 03 |
| retro 7.4 | `wc -l csi-spl-wui/src/composables/useMobileStack.ts \| awk '{print $1}'` | 531 lines | 04 |
| retro 7.5 | `wc -l csi-spl-wui/src/composables/useMsgShortcuts.ts \| awk '{print $1}'` | 464 lines | 05 |
| retro 7.6 | `wc -l csi-spl-wui/src/composables/usePaneWidths.ts \| awk '{print $1}'` | 314 lines | 06 |
| retro 7.7 | `wc -l csi-spl-wui/src/composables/useScrollAnchor.ts \| awk '{print $1}'` | 293 lines | 07 |
| retro 7.8 | `git grep -l "useSubmitKey(" csi-spl-wui/tests/unit/ \| wc -l` | 0 direct tests | 08 |
| retro 7.9 | `git grep -l "poll-fence" csi-spl-wui/tests/unit/ \| wc -l` | 0 tests | 09 |
| retro 7.10 | `git grep -l "editMode" csi-spl-wui/tests/unit/ \| wc -l` | 0 tests | 10 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r13-01-wui-decompose-message-card)` | component decomposition, cleaner code | `MessageCard.vue` `<script>` tag is 1416 lines; contains mixed concerns (reactions, menus, attachments) | `wui:src/components/MessageCard.vue:2-1417` | 1416 script lines | Decompose helper logic into sub-composables / subcomponents to shrink script under 500 lines. Smoke tests: `pnpm run typecheck`, `node tests/unit/cleancode.test.mjs`, `node src/node/test/run-unit-tests.mjs`, `python3 /opt/csi/csi-spl/csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub csi-spl-wui/.output/public --budgets /opt/csi/csi-spl/csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`. **Red control:** line count probe before (`1416 > 500`) vs after (`< 500`). | sat | claude | complex_coding | 1 (Lane 1 start) |
| 02 `refactor(r13-02-wui-decompose-channel-sidebar)` | component decomposition, cleaner code | `ChannelSidebar.vue` `<script>` tag is 1007 lines; mixes channel list, section folding, and search | `wui:src/components/ChannelSidebar.vue:2-1008` | 1007 script lines | Extract channel item and section management subcomponents / composable to shrink script under 500 lines. Smoke tests: typecheck, unit tests, perf budget. **Red control:** line count probe before (`1007 > 500`) vs after (`< 500`). | sat | claude | complex_coding | 1 (Lane 2 start) |
| 03 `refactor(r13-03-wui-decompose-message-composer)` | component decomposition, cleaner code | `MessageComposer.vue` `<script>` tag is 1135 lines; combines text entry, emoji/mention triggers, and file uploads | `wui:src/components/MessageComposer.vue:2-1136` | 1135 script lines | Decompose composer input and attachment drag-drop into targeted helpers to shrink script under 500 lines. Smoke tests: typecheck, unit tests, perf budget. **Red control:** line count probe before (`1135 > 500`) vs after (`< 500`). | sat | claude | complex_coding | 2 (Lane 1, after 01) |
| 04 `refactor(r13-04-wui-small-composable-mobile-stack)` | small functions, testability | `useMobileStack.ts` is 531 lines; navigation state transitions are tightly coupled | `wui:src/composables/useMobileStack.ts:1-531` | 531 lines | Extract pure stack transition math and state machine into pure helper under 200 lines. Smoke tests: typecheck, unit tests. **Red control:** line count probe before (`531 > 200`) vs after (`<= 200`). | sat | grok | simple_coding | 2 (Lane 2, after 02) |
| 05 `refactor(r13-05-wui-small-composable-msg-shortcuts)` | small functions, testability | `useMsgShortcuts.ts` is 464 lines; shortcut map and key event dispatcher | `wui:src/composables/useMsgShortcuts.ts:1-464` | 464 lines | Extract shortcut dictionary and matching logic into pure testable helper under 200 lines. Smoke tests: typecheck, unit tests. **Red control:** line count probe before (`464 > 200`) vs after (`<= 200`). | sat | grok | simple_coding | 3 (Lane 1, after 03) |
| 06 `refactor(r13-06-wui-small-composable-pane-widths)` | small functions, testability | `usePaneWidths.ts` is 314 lines; pane resizing math and bounds clamping | `wui:src/composables/usePaneWidths.ts:1-314` | 314 lines | Extract pure width clamping and ratio calculations under 150 lines. Smoke tests: typecheck, unit tests. **Red control:** line count probe before (`314 > 150`) vs after (`<= 150`). | sat | grok | simple_coding | 3 (Lane 2, after 04) |
| 07 `refactor(r13-07-wui-small-composable-scroll-anchor)` | small functions, testability | `useScrollAnchor.ts` is 293 lines; scroll position and threshold calculations | `wui:src/composables/useScrollAnchor.ts:1-293` | 293 lines | Extract scroll offset math and anchor threshold detection into pure function under 150 lines. Smoke tests: typecheck, unit tests. **Red control:** line count probe before (`293 > 150`) vs after (`<= 150`). | sat | grok | simple_coding | 4 (Lane 1, after 05) |
| 08 `test(r13-08-wui-test-composable-submit-key)` | tests, testability | `useSubmitKey.ts` is an untested composable (0 direct invocations in `tests/unit/`) | `wui:src/composables/useSubmitKey.ts:1-43`<br>`wui:tests/unit/use-submit-key.test.mjs` | 0 direct tests | Add unit test `csi-spl-wui/tests/unit/use-submit-key.test.mjs` verifying Enter keydown handling, hint resolution, and mode parsing. Smoke tests: `node tests/unit/use-submit-key.test.mjs`. **Red control:** `git grep -l "useSubmitKey(" csi-spl-wui/tests/unit/ \| wc -l` (0 -> 1); mutation of `hintFor` breaks test. | sat | claude | tests | 4 (Lane 2, after 06) |
| 09 `test(r13-09-wui-test-util-poll-fence)` | tests, testability | `src/utils/poll-fence.mjs` is an untested regex utility (0 tests in `tests/unit/`) | `wui:src/utils/poll-fence.mjs:1-15`<br>`wui:tests/unit/poll-fence.test.mjs` | 0 tests | Add unit test `csi-spl-wui/tests/unit/poll-fence.test.mjs` covering fence extraction, multiline blocks, and edge cases. Smoke tests: `node tests/unit/poll-fence.test.mjs`. **Red control:** `git grep -l "poll-fence" csi-spl-wui/tests/unit/ \| wc -l` (0 -> 1); mutating regex pattern breaks test. | sat | claude | tests | 5 (Lane 1, after 07) |
| 10 `test(r13-10-wui-test-store-edit-mode)` | tests, testability | `src/stores/editMode.ts` is an untested Pinia store (0 tests in `tests/unit/`) | `wui:src/stores/editMode.ts:1-12`<br>`wui:tests/unit/edit-mode-store.test.mjs` | 0 tests | Add unit test `csi-spl-wui/tests/unit/edit-mode-store.test.mjs` verifying state transitions and editing set/clear. Smoke tests: `node tests/unit/edit-mode-store.test.mjs`. **Red control:** `git grep -l "editMode" csi-spl-wui/tests/unit/ \| wc -l` (0 -> 1); mutating store state breaks test. | sat | claude | tests | 5 (Lane 2, after 08) |

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All 10 rows touch completely disjoint files across `csi-spl-wui/`. No file is shared between any two rows.
To satisfy the owner directive ("build 2 row lanes in parallel at all times", owner t1 dc15ad65 msg 686bc1a3):
- **Lane 1 (odd rows):** Row 01 -> Row 03 -> Row 05 -> Row 07 -> Row 09
- **Lane 2 (even rows):** Row 02 -> Row 04 -> Row 06 -> Row 08 -> Row 10
- **Starting rows:** Row 01 and Row 02 spawn in parallel as Batch 1. When Row 01 lands, Row 03 spawns on Lane 1; when Row 02 lands, Row 04 spawns on Lane 2. Exactly 2 lanes remain active at all times.

### 3.2 Off every live lane (R3)

`lane-map.sh --check <paths> --agent a-584` verifies that no live lane owns any row path. The spawner re-runs `--check` per row before spawning (R3).

## 4. Per row: what the lane does

- **01:** decompose `MessageCard.vue` `<script>` tag (1416 lines) by extracting reaction and attachment subcomponents / composables; shrink `<script>` below 500 lines.
- **02:** decompose `ChannelSidebar.vue` `<script>` tag (1007 lines) by extracting channel list and section folding helpers; shrink `<script>` below 500 lines.
- **03:** decompose `MessageComposer.vue` `<script>` tag (1135 lines) by extracting text input, shortcut triggers, and file drag-drop helpers; shrink `<script>` below 500 lines.
- **04:** extract pure stack transition calculations from `useMobileStack.ts` (531 lines) into a pure helper under 200 lines.
- **05:** extract shortcut definitions and matching logic from `useMsgShortcuts.ts` (464 lines) into a pure helper under 200 lines.
- **06:** extract width clamping and pane sizing math from `usePaneWidths.ts` (314 lines) into a pure helper under 150 lines.
- **07:** extract scroll offset calculations from `useScrollAnchor.ts` (293 lines) into a pure helper under 150 lines.
- **08:** write `tests/unit/use-submit-key.test.mjs` directly importing and testing `useSubmitKey.ts`.
- **09:** write `tests/unit/poll-fence.test.mjs` testing regex parsing and fence extraction in `src/utils/poll-fence.mjs`.
- **10:** write `tests/unit/edit-mode-store.test.mjs` testing Pinia store actions and state transitions in `src/stores/editMode.ts`.

## 5. Panel of experts and reviewers (R7)

- **Expert Panel:** one seat of every active agent kind placed via dispatcher (`c-002@sat`):
  - Editor / agy seat: `a-584@<box>` (`seat-agy.md`)
  - Claude seat: `c-xxx@sat` (`seat-claude.md`)
  - Mistral seat: `m-xxx@sat` (`seat-mistral.md`)
  - (No grok seat: no grok quota on any box, per dispatcher `c-002@sat` note `6acfc32a`. No qwen seat: no qwen on fleet boxes).
  Each expert panel seat re-measures the 10 rows on current trunk and proposes up to 3 empirical actions with numbers; the best proposals are folded into v1.0.
- **Reviewers per row (R7):** Cross-vendor review enforced for every row:
  - Claude rows (01, 02, 03, 08, 09, 10) reviewed by agy or mistral seats.
  - Simple coding rows (04, 05, 06, 07) reviewed by claude or agy seats.
  - Zero same-vendor reviews. Every review verified via `do_spl_review_line_check`.

## 6. Left out, measured (carried to Round 14 by pointer)

| what | why | measured by |
|---|---|---|
| Hub repo edit & action coverage | Non-WUI; round 13 is dedicated exclusively to WUI clean code and testability | `csi-spl-api/src/go/spool-hub-api` go coverage |
| Bash LONG functions: `check-pre-push` (137), `spawn_main` (185), `run.sh do_log` (143), `provision-firebase-dns` (169) | Non-WUI; carried to round 14's input list | `bash-cleancode.tst.sh` |
| Remote branch prune round 12 | Executed under R8 step 2 by retro lane after retro landed | `ROUND=12 DRY_RUN=0 ./run -a do_git_prune_round_branches` |

## 7. Counts

| | n |
|---|---|
| rows | 10 (refactor 7, test 3; 100% WUI) |
| vendor | claude 6, grok 4 (backup mistral) |
| box (preferred) | sat 10 |
| batches | 5 batches of 2 rows (2 parallel lanes at all times) |

## 8. Changes

- v0.1: Initial proposed plan for Round 13 (WUI cleaner code and better testability), measured on `dc17f840e` (retro section 7 input list).
- v0.2: Expert panel composition updated per dispatcher `c-002@sat` (msg `f1cdd328`): claude, grok, mistral, agy (no qwen seat: no qwen on fleet boxes). Each seat re-measures the 10 rows and proposes up to 3 actions with numbers to fold into v1.0.
- v0.3: Expert panel composition updated per dispatcher `c-002@sat` (note `6acfc32a`): no grok seat for round 13 (no grok quota on any box). Panel = claude seat + mistral seat + agy editor seat; fold those two into v1.0.

## 9. Consensus

| seat | kind | id | signed | file |
|---|---|---|---|---|
| editor | agy | a-584@<box> | v0.3 proposed | this file |
| claude seat | claude | pending | pending | `refactor-round-13/seat-claude.md` |
| mistral seat | mistral | pending | pending | `refactor-round-13/seat-mistral.md` |
