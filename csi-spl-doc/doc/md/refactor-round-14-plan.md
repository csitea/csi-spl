# Refactoring round 14 - plan (9 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Issue: SPL-2557  

Owner HUM-10 directives:
- t1 topic `dc15ad65-a5c8-495c-b244-030b6f4d768d` msg 686bc1a3: **"keep 2 row lanes in parallel"**.
- msg b8e22a15: **"do not ask me for input - just reach consensus between all of the members of the panel and start implementation"**.
- msg 7f664194: 20-30% allocation of resources for refactoring.
- owner 10-17 (t1 b61851fb): **no mistral coding rows** (docs and review only).

Round 14 focus: **Balanced repo-wide refactoring: WUI component/composable decomposition, bash cleancode ceilings, Go API coverage, and central runner logging**.  
Concurrency: **build 2 row lanes in parallel at all times**.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps 1..1 up to 3 max 5, bands, R1-R16), by pointer.  

**Status: v1.0, Consensus (Editor signed; pending Claude panel seat signature on v1.0)**.

Editor: **a-615@PC** (agy).  
Panel reviewer: **c-666@PC** (claude).  

**One sha:** every count is measured on **`e9fa87f74`** (`origin/master`, 2026-10-19) and re-verified on **`ab685ef25`** / **`b8e6ad94c`**, n=1 per command unless stated. Input: [refactor-round-13-retro.md](refactor-round-13-retro.md) section 7 and Claude panel review [seat-claude.md](refactor-round-14/seat-claude.md) (`b8e6ad94c`).

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else, with a test that shows behaviour kept, or for a gate / test addition a **red control**: the check fails on the bad input before the change and passes after.
- **Paths:** `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`, `api:` = `csi-spl-api/`. Lines as of `ab685ef25`.
- **Box:** the preferred box (`sat` or `PC`); the spawner's box pick may move a row (no pin).
- **Vendor:** owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`), restricted by owner 10-17 (no mistral coding rows; coding assigned to claude).
- **Subject** (R6 reads it): `<type>(r14-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`. The sha is pasted from `git rev-parse`, never typed; `ran:` names only commands in the reviewer's `log:` file.

## 2. Where the rows come from (measured on `e9fa87f74`, verified on `ab685ef25`)

| source | command | n | row |
|---|---|---|---|
| retro 7.1 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue \| wc -l` | 677 script lines (ceiling 677) | 01 |
| retro 7.7 | `sed -n '/^spawn_main() {/,/^}/p' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh \| wc -l` | 184 lines (ceiling 185) | 02 |
| retro 7.2 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/QtoFileTree.vue \| wc -l` | 654 script lines (ceiling 654) | 03 |
| retro 7.8 | `sed -n '/^do_check_pre_push() {/,/^}/p' csi-spl-iac/src/bash/run/check-pre-push.func.sh \| wc -l` | 137 lines (ceiling 137) | 04 |
| retro 7.3 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/CalendarMainView.vue \| wc -l` | 612 script lines (ceiling 612) | 05 |
| retro 7.10 | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/` | 72.4% statement coverage | 06 |
| retro 7.4 | `wc -l csi-spl-wui/src/composables/useMobileStack.ts \| awk '{print $1}'` | 531 lines (largest composable) | 07 |
| retro 7.6 / claude | `node csi-spl-wui/tests/unit/unused-exports.test.mjs` | 75 unused exports (cap 76; ALLOW top: `errorJournal` 7, `monitoring-tokens` 6, `upload-fail` 4, `tenant-costs` 3) | 08 |
| claude prop 7.1 | `diff <(sed -n '/^do_log() {/,/^}/p' csi-spl-iac/src/bash/run/run.sh) <(sed -n '/^do_log() {/,/^}/p' csi-spl-orc/src/bash/run/run.sh)` | 143 lines each (2 LONG entries in `bash-cleancode.tst.sh`) | 09 |

## 3. The 9 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2 bold: source-text tests) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r14-01-wui-decompose-doc-view)` | component decomposition, cleaner code | `WorkspaceDocView.vue` `<script>` tag is 677 lines (ceiling 677 in `sfc-script-size.test.mjs:30`); picture handling and insert operations mixed with view logic | `wui:src/components/workspace-docs/WorkspaceDocView.vue:339-1015` | 677 script lines | Decompose picture handling (`upload`, `onImageFile`, `pastePic`, `dragPic`, `dropPic`, `pickPic`, `insertPic`, `imageOf`) and insert operations (`insertAt`, `insertTable`, `insertQuote`) into composables (`useDocPictures.ts`, `useDocInsert.ts`) to shrink script under 500 lines, deleting its entry in `sfc-script-size.test.mjs` BIG map. Tests: **`tests/unit/doc-outline.test.mjs:143-144`** (`branchOf`), `tests/e2e/docs.test.mjs`, `sfc-script-size.test.mjs`, unit runner, typecheck. **Red control:** delete `WorkspaceDocView.vue` entry in `sfc-script-size.test.mjs` while script > 500 lines fails test; passes after shrink. | sat | claude | complex_coding | 1 (Lane 1 start) |
| 02 `refactor(r14-02-orc-small-spawn-main)` | small functions, cleaner orchestration | `spawn_main` in `spawn-core.inc.sh` is 184 lines, ceiling in `bash-cleancode.tst.sh:28` is 185; mixes guards, env setup, identity, spool dirs, registry row, trust pre-accept, session launch | `orc:src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:439-622` | 184 lines | Split `spawn_main` into named helper steps (`spawn_guards_env`, `spawn_init_dirs`, `spawn_register_agent`, `spawn_launch_session`) each <= 80 lines; leave `NO_FORCE` (`:282`) untouched; delete `spawn_main` from `LONG` in `bash-cleancode.tst.sh` (10 -> 9). Tests: `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-dry-run.sh` (211 passed), `tests/test-seed-no-force-push.sh`, `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`. **Red control:** delete `spawn_main` from `LONG` in `bash-cleancode.tst.sh` while function is still 184 lines -> RED; passes after split. | sat | claude | complex_coding | 1 (Lane 2 start) |
| 03 `refactor(r14-03-wui-decompose-qto-tree)` | component decomposition, cleaner code | `QtoFileTree.vue` `<script>` tag is 654 lines (ceiling 654 in `sfc-script-size.test.mjs:31`); mixes tree traversal, folder toggle/expansion, and drag-and-drop moving | `wui:src/components/workspace-docs/QtoFileTree.vue:139-792` | 654 script lines | Extract folder expansion and tree drag/drop into composables (`useQtoTreeFolders.ts`, `useQtoTreeDrop.ts`) reusing existing `src/utils/tree-drag.mjs`; shrink script under 500 lines and delete `QtoFileTree.vue` from `BIG` in `sfc-script-size.test.mjs`. Tests: `tests/e2e/docs.test.mjs`, `tests/e2e/docs-dock-collapse.test.mjs`, `sfc-script-size.test.mjs`, unit runner, typecheck. **Red control:** delete `QtoFileTree.vue` from `BIG` in `sfc-script-size.test.mjs` while script > 500 lines fails test; passes after shrink. | sat | claude | complex_coding | 2 (Lane 1, after 01) |
| 04 `refactor(r14-04-iac-small-check-pre-push)` | small functions, cleaner tooling | `do_check_pre_push` in `check-pre-push.func.sh` is 137 lines (ceiling 137 in `bash-cleancode.tst.sh:19`); mixes part planning (`:943-978`), tree-pass skip (`:984-990`), and run + summary (`:991-1050`) | `iac:src/bash/run/check-pre-push.func.sh:914-1050` | 137 lines | Extract `_pp_plan_parts` and `_pp_run_parts` helper steps <= 80 lines each (using `_pp_` prefix, not `do_`); delete `do_check_pre_push` from `LONG` in `bash-cleancode.tst.sh` (9 -> 8). R9 applies: run under `PRE_PUSH_TIER=full` once, and once with all `PRE_PUSH_*` unset. Tests: `check-pre-push*.tst.sh` (all 14 test suites), `stop-pre-push.tst.sh`, `bash-cleancode.tst.sh`. **Red control:** delete `do_check_pre_push` from `LONG` while function is 137 lines -> RED; passes after split. | sat | claude | simple_coding | 2 (Lane 2, after 02) |
| 05 `refactor(r14-05-wui-decompose-calendar-main)` | component decomposition, cleaner code | `CalendarMainView.vue` `<script>` tag is 612 lines (ceiling 612 in `sfc-script-size.test.mjs:32`); mixes view modes, date navigation, event selection, and event drag/resize | `wui:src/components/CalendarMainView.vue:206-817` | 612 script lines | Extract event drag and resize logic (`begin`, `onItemDown`, `onResizeDown`, `onGridDown`, `hitAt`, `liftOff`) into `useCalendarDrag.ts` first, shrinking script under 500 lines and deleting `CalendarMainView.vue` from `BIG` in `sfc-script-size.test.mjs` (leaving only `issues.vue` in `BIG`). Keep `load` in SFC to preserve endpoint asserts. Tests: **`tests/unit/calendar-year.test.mjs:125`** (asserts `/v1/calendar/events\?/`), **`tests/unit/hub-headers.test.mjs:22`**, `tests/e2e/calendar-drag.test.mjs`, `tests/e2e/calendar.test.mjs`, `sfc-script-size.test.mjs`, unit runner, typecheck. **Red control:** delete `CalendarMainView.vue` from `BIG` in `sfc-script-size.test.mjs` while script > 500 lines fails test; passes after shrink. | sat | claude | complex_coding | 3 (Lane 1, after 03) |
| 06 `test(r14-06-go-coverage-payments-paypal)` | unit test coverage, testability | `internal/payments` has 72.4% statement coverage (`go-coverage-floor.txt:52`); error and response helpers (`Error`, `AlreadyCaptured`, `CreateIntent`, `Refund`, `CancelIntent`, `payPalIssue`, `truncatePayPalErr`) in `paypal_payments.go` have 0.0% coverage (44 uncovered statements from line 338 on) | `api:src/go/spool-hub-api/internal/payments/paypal_payments.go:338-390`<br>`api:src/bash/tests/go-coverage-floor.txt:52` | 72.4% statement coverage | Create `internal/payments/paypal_payments_test.go` using `httptest` server pattern; add table tests covering error formatting, refund requests, and intent responses (`CancelIntent` is 1-line no-op); raise statement coverage floor in `go-coverage-floor.txt` from 72.4 to >= 74.0 (up to 77.4% ceiling reachable). Tests: `go test -count=1 -cover ./internal/payments/`. **Red control:** pin `truncatePayPalErr` (e.g. 300-byte raw body ends in `…` after 256 bytes) or corrupt error formatting to trip unit test assertion. | sat | claude | tests | 3 (Lane 2, after 04) |
| 07 `refactor(r14-07-wui-small-composable-mobile-stack)` | small composables, testability | `useMobileStack.ts` is 531 lines (largest composable in WUI); 26 top-level functions drive DOM/history/popstate; pure stack decisions (`onPopCapture`, `dropStaleTopic`, `leaveStaleLogin`) can be extracted to pure helpers | `wui:src/composables/useMobileStack.ts:1-531`<br>`wui:src/utils/mobile-stack.mjs`<br>`wui:tests/unit/mobile-stack.test.mjs` | 531 lines | Extract pure decision helpers into existing `src/utils/mobile-stack.mjs` (239 lines) and test via `tests/unit/mobile-stack.test.mjs` (135 lines); shrink `useMobileStack.ts` to <= 420 lines without modifying exported composable API. Tests: **`tests/unit/swallow-reasons.test.mjs:44`**, **`tests/unit/touch-ui.test.mjs:38`**, `tests/unit/mobile-stack.test.mjs`, `tests/e2e/mobile-stack.test.mjs`, `tests/e2e/mobile-back-stuck.test.mjs`, `tests/e2e/mobile-overlay.test.mjs`, unit runner, typecheck. **Red control:** inverting a stack transition decision in `src/utils/mobile-stack.mjs` trips test failure in `tests/unit/mobile-stack.test.mjs`. | sat | claude | simple_coding | 4 (Lane 1, after 05) |
| 08 `refactor(r14-08-wui-ratchet-unused-exports)` | dead code elimination, testability ratchet | `unused-exports.test.mjs` has 75 unused exports in `ALLOW` (cap 76); `flowTopicUnread` is used and can be removed; top remaining unused exports live in `errorJournal.mjs` (7), `monitoring-tokens.mjs` (6), `upload-fail.mjs` (4), `tenant-costs.mjs` (3) | `wui:tests/unit/unused-exports.test.mjs`<br>`wui:src/utils/errorJournal.mjs`<br>`wui:src/utils/monitoring-tokens.mjs`<br>`wui:src/utils/upload-fail.mjs`<br>`wui:src/utils/tenant-costs.mjs` | 75 unused exports in ALLOW | Delete `flowTopicUnread` from ALLOW; unexport ~17 dead declarations across the top 4 files; ratchet `ALLOW_CAP` down from 76 to <= 60 in `unused-exports.test.mjs`. Tests: `node tests/unit/unused-exports.test.mjs`, unit runner. **Red control:** adding an unused `export const` in a test file trips `unused-exports.test.mjs` failure. | sat | claude | simple_coding | 4 (Lane 2, after 06) |
| 09 `refactor(r14-09-bash-small-run-do-log)` | small functions, central runner logging | `do_log` is 143 lines (ceiling 143 in `bash-cleancode.tst.sh:26,29`) in both `csi-spl-iac/src/bash/run/run.sh:320` and `csi-spl-orc/src/bash/run/run.sh:320`. The two bodies are identical (`diff` empty). Mixes output formatting, level filtering, log file writing, and OK summary rewrites | `iac:src/bash/run/run.sh:320-462`<br>`orc:src/bash/run/run.sh:320-462`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:26,29` | 143 lines in 2 files (ceiling 143) | Split `do_log` into named helper steps <= 80 lines each, keeping both `run.sh` implementations byte-identical (`diff` empty); remove BOTH `do_log 143` entries from `LONG` in `bash-cleancode.tst.sh` (2 LONG lines eliminated). Tests: `csi-spl-iac/src/bash/tests/run-log-compact.tst.sh`, `csi-spl-iac/src/bash/tests/run-log-nofork.tst.sh`, `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`, `./run -a do_check_dist_hygiene` from both `iac` and `orc`. **Red control:** delete `do_log` entries from `LONG` in `bash-cleancode.tst.sh` while function is still 143 lines -> RED; passes after split. | sat | claude | complex_coding | 5 (Lane 2, after 08) |

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All 9 rows touch disjoint files across `csi-spl-wui/`, `csi-spl-orc/`, `csi-spl-iac/`, and `csi-spl-api/`:
- **Lane 1 (odd rows, WUI stream):** Row 01 -> Row 03 -> Row 05 -> Row 07
- **Lane 2 (even rows + tail, Bash/API/Gate stream):** Row 02 -> Row 04 -> Row 06 -> Row 08 -> Row 09
- **Starting rows (Batch 1):** Row 01 (`WorkspaceDocView.vue`) and Row 02 (`spawn-core.inc.sh`) spawn in parallel as Batch 1.
- **Asynchronous lane independence:** Every batch pair is completely disjoint:
  - Row 01 (`WorkspaceDocView.vue`) vs Row 02 (`spawn-core.inc.sh`): disjoint.
  - Row 03 (`QtoFileTree.vue`) vs Row 04 (`check-pre-push.func.sh`): disjoint.
  - Row 05 (`CalendarMainView.vue`) vs Row 06 (`paypal_payments.go`): disjoint.
  - Row 07 (`useMobileStack.ts`) vs Row 08 (`unused-exports.test.mjs`, `errorJournal.mjs`, `monitoring-tokens.mjs`, `upload-fail.mjs`, `tenant-costs.mjs`): disjoint (`mobile-stack.mjs` is not in ALLOW).
  - Row 09 (`run.sh` in iac + orc, `bash-cleancode.tst.sh`): runs in Lane 2 after Row 08 lands; no parallel collision.
- **Shared test suites strictly serialised per lane:**
  - `sfc-script-size.test.mjs`: serialized in Lane 1 (01, 03, 05).
  - `bash-cleancode.tst.sh`: serialized in Lane 2 (02, 04, 09).

### 3.2 Off every live lane (R3)

`lane-map.sh --check` verifies that none of these paths are owned by any live lane on any box. Spawners re-run `--check` per row prior to placement.

## 4. Per row: what the lane does

- **01:** decompose `WorkspaceDocView.vue` `<script>` tag (`339-1015`, 677 lines) by extracting picture handling and insert operations into `useDocPictures.ts` and `useDocInsert.ts`; shrink `<script>` under 500 lines and delete `WorkspaceDocView.vue` from `BIG` map in `sfc-script-size.test.mjs`. Keep **`tests/unit/doc-outline.test.mjs`** green.
- **02:** decompose `spawn_main` in `spawn-core.inc.sh` (`439-622`, 184 lines) into helper steps (`spawn_guards_env`, `spawn_init_dirs`, `spawn_register_agent`, `spawn_launch_session`) under 80 lines each; leave `NO_FORCE` untouched; remove `spawn_main` from `LONG` in `bash-cleancode.tst.sh`. Verify `test-spawn-dry-run.sh` and `test-seed-no-force-push.sh`.
- **03:** decompose `QtoFileTree.vue` `<script>` tag (`139-792`, 654 lines) by extracting folder expansion and drag-and-drop moving into `useQtoTreeFolders.ts` and `useQtoTreeDrop.ts`, reusing `src/utils/tree-drag.mjs`; shrink `<script>` under 500 lines and delete `QtoFileTree.vue` from `BIG` map in `sfc-script-size.test.mjs`.
- **04:** decompose `do_check_pre_push` in `check-pre-push.func.sh` (`914-1050`, 137 lines) into `_pp_plan_parts` and `_pp_run_parts` steps <= 80 lines each; remove `do_check_pre_push` from `LONG` in `bash-cleancode.tst.sh`. Run under `PRE_PUSH_TIER=full` and plain per R9.
- **05:** decompose `CalendarMainView.vue` `<script>` tag (`206-817`, 612 lines) by extracting drag and resize into `useCalendarDrag.ts`; keep `load` in SFC; shrink `<script>` under 500 lines and delete `CalendarMainView.vue` from `BIG` map in `sfc-script-size.test.mjs`. Keep **`tests/unit/calendar-year.test.mjs`** and **`tests/unit/hub-headers.test.mjs`** green.
- **06:** create `paypal_payments_test.go` with `httptest` server covering error formatting and refund/intent requests in `paypal_payments.go`; pin `truncatePayPalErr` red control; raise statement coverage floor in `go-coverage-floor.txt` from 72.4 to >= 74.0.
- **07:** extract pure stack transition decisions from `useMobileStack.ts` into existing `src/utils/mobile-stack.mjs` with unit tests in `tests/unit/mobile-stack.test.mjs`; shrink composable <= 420 lines while keeping public API unchanged. Keep **`tests/unit/swallow-reasons.test.mjs`** and **`tests/unit/touch-ui.test.mjs`** green.
- **08:** remove `flowTopicUnread` from `ALLOW` in `unused-exports.test.mjs`; unexport ~17 dead declarations in `errorJournal.mjs`, `monitoring-tokens.mjs`, `upload-fail.mjs`, `tenant-costs.mjs`; ratchet `ALLOW_CAP` down from 76 to <= 60.
- **09:** split `do_log` in `csi-spl-iac/src/bash/run/run.sh` and `csi-spl-orc/src/bash/run/run.sh` (`320-462`, 143 lines each) into named helper steps <= 80 lines each, keeping both byte-identical (`diff` empty); remove both `do_log 143` entries from `LONG` in `bash-cleancode.tst.sh`. Verify `run-log-compact.tst.sh` and `run-log-nofork.tst.sh`.

## 5. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-615@PC` (`seat-agy.md`)
  - Claude seat: `c-666@PC` (`seat-claude.md`)
  - Mistral seat: `m-xxx@sat` (`seat-mistral.md` - docs and review only per owner rule: no mistral coding rows)
  - Grok seat: `g-xxx@<box>` (`seat-grok.md` - conditional subject to vendor quota availability)
- **Reviewers per row (R7.2):**
  - All coding rows are assigned to Claude per owner directive (no mistral coding rows, owner 10-17).
  - Cross-vendor review enforced: editor seat `a-615@PC` (agy) and mistral seat provide 100% cross-vendor review (`grep -c 'same vendor'` -> 0).
  - Review lines verified via `do_spl_review_line_check`.

## 6. Left out, measured (carried to future rounds by pointer)

| what | why | measured by |
|---|---|---|
| `pages/issues.vue` further decomposition | Script was decomposed from 2083 to 876 lines in Round 13 Row 06; well under 1200 ceiling | `sfc-script-size.test.mjs` (876 lines) |
| `usePaneWidths.ts` state persistence | Ratio math already in `utils/pane-widths.mjs` (307 lines); composable is small functions <= 80 lines | `wc -l` (314 lines) |
| `internal/blob` GCS paths | Requires GCS emulator/credentials not available in hermetic unit test runner | `go tool cover -func` |
| Other `bash-cleancode.tst.sh` LONG functions (`gcp-001`, `gcp-002`, `gcp-import-to-cloudsql`, `gcp-project-delete`) | The gcp-* functions require live GCP credentials/state; addressed in dedicated infra rounds | `bash-cleancode.tst.sh` (5 remaining after Round 14) |
| `src/stores/notification.ts` | Setup body is already 72 lines; no toast code; 11 source-reading tests | `sed -n '498,$p' \| wc -l` (72 lines) |
| `provision-firebase-dns.func.sh` | Sha256-pinned to csi-rel (`wui-hosting-019-031.tst.sh:26-30`); requires live DNS GCP mutation | `wui-hosting-019-031.tst.sh` |

## 7. Counts

| | n |
|---|---|
| rows | 9 (refactor 8, test 1; WUI 5, Bash 3, Go 1) |
| vendor | claude 9 (all coding rows per owner 10-17); agy / mistral cross-vendor reviewers |
| box (preferred) | sat / PC |
| batches | 5 batches (2 parallel lanes at all times) |

## 8. Changes

- v0.1: Initial proposed plan for Round 14 (balanced refactoring: WUI components/stores, bash cleancode ceilings, and Go API coverage), measured on `e9fa87f74` (retro section 7 input list).
- v1.0: Consensus refinement folding Claude panel seat verdict (`b8e6ad94c`):
  - Corrected site line ranges for all 6 code refactoring rows (01, 02, 03, 04, 05, 07).
  - Row 01: Refined seams to picture handling and insert operations (`useDocPictures.ts`, `useDocInsert.ts`). Added bold source-text test `tests/unit/doc-outline.test.mjs:143-144`.
  - Row 02: Refined seams to guards+env, identity, spool dirs, registry row, launch. Changed kind to `complex_coding`. Added behaviour test `test-spawn-dry-run.sh` and pinned `NO_FORCE` preservation (`test-seed-no-force-push.sh`).
  - Row 03: Reused existing `src/utils/tree-drag.mjs`. Added e2e tests `docs.test.mjs` and `docs-dock-collapse.test.mjs`.
  - Row 04: Refined seams to part planning, tree-pass skip, run+summary. Named helper steps with `_pp_` prefix. Added all 14 `check-pre-push*.tst.sh` suites. Noted R9 tier requirements.
  - Row 05: Refined seam to drag/resize (`useCalendarDrag.ts`). Kept `load` in SFC to preserve endpoint asserts. Added bold source-text tests `calendar-year.test.mjs:125` and `hub-headers.test.mjs:22`.
  - Row 06: Noted `paypal_payments_test.go` creation via `httptest` server; `CancelIntent` is 1-line no-op; red control pins `truncatePayPalErr`.
  - Row 07: Adjusted shrink target to <= 420 lines for pure decisions (`onPopCapture`, etc.), reusing existing `utils/mobile-stack.mjs`. Added bold source-text tests `swallow-reasons.test.mjs:44`, `touch-ui.test.mjs:38`.
  - Row 08: Corrected sites to real top of ALLOW (`errorJournal.mjs`, `monitoring-tokens.mjs`, `upload-fail.mjs`, `tenant-costs.mjs`), dropping `flowTopicUnread` and unexporting ~17 declarations to lower cap to <= 60.
  - Dropped v0.1 Row 09 (notification store target already met; no toast code) and v0.1 Row 10 (firebase DNS is sha256-pinned to csi-rel and requires live GCP mutation).
  - Adopted Proposal 7.1 as Row 09: `do_log` split across both `csi-spl-iac/src/bash/run/run.sh` and `csi-spl-orc/src/bash/run/run.sh`, eliminating 2 LONG entries from `bash-cleancode.tst.sh`.
  - Adopted Proposal 7.2: Added bold source-text test column (R2) to plan rows.
  - Pinned all coding rows to Claude (`SPAWN_PLACE=claude:...`).

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| Editor | agy | a-615@PC | v1.0 editor consensus | `refactor-round-14/seat-agy.md` |
| Claude seat | claude | c-666@PC | reviewed v0.1 in `b8e6ad94c` (pending signature on v1.0) | `refactor-round-14/seat-claude.md` |
| Mistral seat (docs/review only) | mistral | pending | pending spawn / review | `refactor-round-14/seat-mistral.md` |
| Grok seat | grok | pending | pending review of v0.1 (quota check) | `refactor-round-14/seat-grok.md` |
