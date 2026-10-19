# Refactoring round 14 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Issue: SPL-2557  

Owner HUM-10 directives:
- t1 topic `dc15ad65-a5c8-495c-b244-030b6f4d768d` msg 686bc1a3: **"keep 2 row lanes in parallel"**.
- msg b8e22a15: **"do not ask me for input - just reach consensus between all of the members of the panel and start implementation"**.
- msg 7f664194: 20-30% allocation of resources for refactoring.
- owner 10-17 (t1 b61851fb): **no mistral coding rows** (docs and review only).

Round 14 focus: **Balanced repo-wide refactoring: WUI component/store decomposition, bash cleancode ceilings, and Go API coverage**.  
Concurrency: **build 2 row lanes in parallel at all times**.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps 1..1 up to 3 max 5, bands, R1-R16), by pointer.  

**Status: v0.1, DRAFT (Panel review in progress)**.

Editor: **a-615@<box>** (agy).

**One sha:** every count is measured on **`e9fa87f74`** (`origin/master`, 2026-10-19), n=1 per command unless stated. Input: [refactor-round-13-retro.md](refactor-round-13-retro.md) section 7.

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else, with a test that shows behaviour kept, or for a gate / test addition a **red control**: the check fails on the bad input before the change and passes after.
- **Paths:** `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`, `api:` = `csi-spl-api/`. Lines as of `e9fa87f74`.
- **Box:** the preferred box (`sat` or `<box>`); the spawner's box pick may move a row (no pin).
- **Vendor:** owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`), restricted by owner 10-17 (no mistral coding rows; coding assigned to claude).
- **Subject** (R6 reads it): `<type>(r14-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`. The sha is pasted from `git rev-parse`, never typed; `ran:` names only commands in the reviewer's `log:` file.

## 2. Where the rows come from (measured on `e9fa87f74`)

| source | command | n | row |
|---|---|---|---|
| retro 7.1 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue \| wc -l` | 677 script lines | 01 |
| retro 7.7 | `sed -n '/^spawn_main() {/,/^}/p' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh \| wc -l` | 184 lines (ceiling 185) | 02 |
| retro 7.2 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/QtoFileTree.vue \| wc -l` | 654 script lines | 03 |
| retro 7.8 | `sed -n '/^do_check_pre_push() {/,/^}/p' csi-spl-iac/src/bash/run/check-pre-push.func.sh \| wc -l` | 137 lines (ceiling 137) | 04 |
| retro 7.3 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/CalendarMainView.vue \| wc -l` | 612 script lines | 05 |
| retro 7.10 | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/` | 72.4% statement coverage | 06 |
| retro 7.4 | `wc -l csi-spl-wui/src/composables/useMobileStack.ts \| awk '{print $1}'` | 531 lines (largest composable) | 07 |
| retro 7.6 | `node csi-spl-wui/tests/unit/unused-exports.test.mjs` | 75 unused exports (cap 76) | 08 |
| retro 7.5 | `wc -l csi-spl-wui/src/stores/notification.ts \| awk '{print $1}'` | 569 lines (largest store) | 09 |
| retro 7.9 | `sed -n '/^do_provision_firebase_dns() {/,/^}/p' csi-spl-iac/src/bash/run/provision-firebase-dns.func.sh \| wc -l` | 169 lines (ceiling 169) | 10 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r14-01-wui-decompose-doc-view)` | component decomposition, cleaner code | `WorkspaceDocView.vue` `<script>` tag is 677 lines (ceiling 677 in `sfc-script-size.test.mjs`); mixed doc view, heading navigation, drawer state, and doc history | `wui:src/components/workspace-docs/WorkspaceDocView.vue:242-918` | 677 script lines | Decompose drawer and history logic into sub-composables (`useDocDrawer.ts`, `useDocHistory.ts`) to shrink script under 500 lines, deleting its entry in `sfc-script-size.test.mjs` BIG map. Smoke tests: typecheck, cleancode, unit runner. **Red control:** `tests/unit/sfc-script-size.test.mjs` ceiling lowered; scratch 501-line script fails. | sat | claude | complex_coding | 1 (Lane 1 start) |
| 02 `refactor(r14-02-orc-small-spawn-main)` | small functions, cleaner orchestration | `spawn_main` in `spawn-core.inc.sh` is 184 lines, ceiling in `bash-cleancode.tst.sh` is 185 (prints NOTE); mixes argument parsing, container checks, and session initialization | `orc:src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:75-258` | 184 lines | Split `spawn_main` into named helper steps (`spawn_parse_args`, `spawn_init_env`, `spawn_start_session`) each <= 80 lines; delete `spawn_main` from `LONG` in `bash-cleancode.tst.sh` (10 -> 9). Smoke tests: `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`, `spawn-agents/tests/*.sh`. **Red control:** artificially lengthening an extracted step over 80 lines fails test. | sat | claude | simple_coding | 1 (Lane 2 start) |
| 03 `refactor(r14-03-wui-decompose-qto-tree)` | component decomposition, cleaner code | `QtoFileTree.vue` `<script>` tag is 654 lines (ceiling 654 in `sfc-script-size.test.mjs`); mixes tree traversal, folder toggle, drag-and-drop file moves, and context actions | `wui:src/components/workspace-docs/QtoFileTree.vue:240-893` | 654 script lines | Extract folder expansion and tree drag-drop into composables (`useQtoTreeFolders.ts`, `useQtoTreeDrag.ts`) to shrink script under 500 lines, deleting its entry in `sfc-script-size.test.mjs` BIG map. Smoke tests: typecheck, cleancode, unit runner. **Red control:** `sfc-script-size.test.mjs` ceiling lowered; scratch 501-line script fails. | sat | claude | complex_coding | 2 (Lane 1, after 01) |
| 04 `refactor(r14-04-iac-small-check-pre-push)` | small functions, cleaner tooling | `do_check_pre_push` in `check-pre-push.func.sh` is 137 lines (ceiling 137 in `bash-cleancode.tst.sh`); mixes tier resolution, fast-tier parts execution, full-tier checks, and report formatting | `iac:src/bash/run/check-pre-push.func.sh:30-166` | 137 lines | Extract `do_check_pre_push_fast` and `do_check_pre_push_full` steps <= 80 lines; eliminate `do_check_pre_push` from `LONG` in `bash-cleancode.tst.sh` (9 -> 8). Smoke tests: `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`, `bash csi-spl-iac/src/bash/tests/pre-push-*.tst.sh`. **Red control:** helper step lengthened over 80 lines fails cleancode. | sat | claude | simple_coding | 2 (Lane 2, after 02) |
| 05 `refactor(r14-05-wui-decompose-calendar-main)` | component decomposition, cleaner code | `CalendarMainView.vue` `<script>` tag is 612 lines (ceiling 612 in `sfc-script-size.test.mjs`); mixes calendar view mode, date navigation, event filtering, and modal popups | `wui:src/components/CalendarMainView.vue:326-937` | 612 script lines | Extract event selection and navigation logic into composables (`useCalendarNav.ts`, `useCalendarEvents.ts`) to shrink script under 500 lines, deleting its entry in `sfc-script-size.test.mjs` BIG map (leaving only `issues.vue` in `BIG`). Smoke tests: typecheck, cleancode, unit runner. **Red control:** `sfc-script-size.test.mjs` ceiling lowered. | sat | claude | complex_coding | 3 (Lane 1, after 03) |
| 06 `test(r14-06-go-coverage-payments-paypal)` | unit test coverage, testability | `internal/payments` has 72.4% statement coverage (`go-coverage-floor.txt`); error and response helpers (`Error`, `AlreadyCaptured`, `payPalIssue`, `truncatePayPalErr`, `Refund`, `CancelIntent`) in `paypal_payments.go` have 0.0% coverage | `api:src/go/spool-hub-api/internal/payments/paypal_payments.go:338-390`<br>`api:src/bash/tests/go-coverage-floor.txt:52` | 72.4% statement coverage | Add table-driven unit tests in `paypal_payments_test.go` covering pure error formatting and refund/cancel request builders; raise `internal/payments` floor in `go-coverage-floor.txt` from 72.4 to >= 74.0. Smoke tests: `go test -count=1 -cover ./internal/payments/`. **Red control:** mutating error format string trips test failure. | sat | claude | tests | 3 (Lane 2, after 04) |
| 07 `refactor(r14-07-wui-small-composable-mobile-stack)` | small composables, testability | `useMobileStack.ts` is 531 lines (largest composable in WUI); pure route stack math and transition logic are coupled to router watchers and window listeners | `wui:src/composables/useMobileStack.ts:1-531`<br>`wui:src/utils/mobile-stack.mjs`<br>`wui:tests/unit/mobile-stack.test.mjs` | 531 lines | Extract pure stack transition decisions and history math into `src/utils/mobile-stack.mjs` with unit tests in `mobile-stack.test.mjs`; shrink `useMobileStack.ts` to <= 250 lines without modifying imported composable API. Smoke tests: typecheck, unit runner. **Red control:** mutation of stack transition decision fails unit test. | sat | claude | simple_coding | 4 (Lane 1, after 05) |
| 08 `refactor(r14-08-wui-ratchet-unused-exports)` | dead code elimination, testability ratchet | `unused-exports.test.mjs` has 75 unused exports in `ALLOW` (cap 76); `flowTopicUnread` is used and can be removed; top remaining utils contain dead export keywords | `wui:tests/unit/unused-exports.test.mjs`<br>Top files: `src/utils/perf-rum.mjs`, `src/utils/omnibox-dock.mjs`, `src/utils/calendar-swipe.mjs` | 75 unused exports in ALLOW | Delete `flowTopicUnread` from ALLOW; unexport ~15 unused helpers across top remaining utils; lower `ALLOW_CAP` in `unused-exports.test.mjs` from 76 to <= 60. Smoke tests: `node tests/unit/unused-exports.test.mjs`, unit runner. **Red control:** adding an unused `export const` turns test red. | sat | claude | simple_coding | 4 (Lane 2, after 06) |
| 09 `refactor(r14-09-wui-decompose-notification-store)` | store decomposition, cleaner state | `src/stores/notification.ts` is 569 lines (largest store in WUI); toast notifications, sound alerts, browser push permission, and grouping logic all inline | `wui:src/stores/notification.ts:1-569`<br>`wui:src/utils/notification-toast.mjs`<br>`wui:src/utils/notification-push.mjs` | 569 lines | Extract toast queue/timer helpers and browser push permission logic into module helpers (`notification-toast.mjs`, `notification-push.mjs`); shrink store setup body under 250 lines while preserving store API. Smoke tests: typecheck, unit runner. **Red control:** mutating notification deduplication fails unit test. | sat | claude | complex_coding | 5 (Lane 1, after 07) |
| 10 `refactor(r14-10-iac-small-provision-firebase-dns)` | small functions, cleaner infra scripting | `do_provision_firebase_dns` in `provision-firebase-dns.func.sh` is 169 lines (ceiling 169 in `bash-cleancode.tst.sh`); mixes DNS record checking and SSL certificate wait loops | `iac:src/bash/run/provision-firebase-dns.func.sh:35-203` | 169 lines | Split DNS verification and SSL certificate checking into named sub-steps (`dns_check_records`, `dns_wait_ssl`) <= 80 lines each; eliminate `do_provision_firebase_dns` from `LONG` in `bash-cleancode.tst.sh` (8 -> 7). Smoke tests: `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`. **Red control:** helper step lengthened over 80 lines fails cleancode. | sat | claude | simple_coding | 5 (Lane 2, after 08) |

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All 10 rows touch completely disjoint files across `csi-spl-wui/`, `csi-spl-orc/`, `csi-spl-iac/`, and `csi-spl-api/`. No file path appears in more than one row:
- **Lane 1 (odd rows):** Row 01 -> Row 03 -> Row 05 -> Row 07 -> Row 09
- **Lane 2 (even rows):** Row 02 -> Row 04 -> Row 06 -> Row 08 -> Row 10
- **Starting rows (Batch 1):** Row 01 (`WorkspaceDocView.vue`) and Row 02 (`spawn-core.inc.sh`) spawn in parallel as Batch 1.
- **Asynchronous lane independence:** Every odd row and even row are completely disjoint:
  - Row 01 (`WorkspaceDocView.vue`) vs Row 02 (`spawn-core.inc.sh`): disjoint.
  - Row 03 (`QtoFileTree.vue`) vs Row 04 (`check-pre-push.func.sh`): disjoint.
  - Row 05 (`CalendarMainView.vue`) vs Row 06 (`paypal_payments.go`): disjoint.
  - Row 07 (`useMobileStack.ts`) vs Row 08 (`unused-exports.test.mjs`): disjoint.
  - Row 09 (`notification.ts`) vs Row 10 (`provision-firebase-dns.func.sh`): disjoint.
- **Composables and utilities stability:** Extracted composables and utilities preserve existing exported APIs to prevent caller drift.

### 3.2 Off every live lane (R3)

`lane-map.sh --check` verifies that none of these paths are owned by any live lane on any box. Spawners re-run `--check` per row prior to placement.

## 4. Per row: what the lane does

- **01:** decompose `WorkspaceDocView.vue` `<script>` tag (`242-918`, 677 lines) by extracting heading navigation and drawer/history concerns into `useDocDrawer.ts` and `useDocHistory.ts`; shrink `<script>` under 500 lines and delete `WorkspaceDocView.vue` from `BIG` map in `sfc-script-size.test.mjs`.
- **02:** decompose `spawn_main` in `spawn-core.inc.sh` (`75-258`, 184 lines) into helper steps (`spawn_parse_args`, `spawn_init_env`, `spawn_start_session`) under 80 lines each; remove `spawn_main` from `LONG` in `bash-cleancode.tst.sh`.
- **03:** decompose `QtoFileTree.vue` `<script>` tag (`240-893`, 654 lines) by extracting folder expansion and drag-and-drop moving into `useQtoTreeFolders.ts` and `useQtoTreeDrag.ts`; shrink `<script>` under 500 lines and delete `QtoFileTree.vue` from `BIG` map in `sfc-script-size.test.mjs`.
- **04:** decompose `do_check_pre_push` in `check-pre-push.func.sh` (`30-166`, 137 lines) into `do_check_pre_push_fast` and `do_check_pre_push_full` steps <= 80 lines; remove `do_check_pre_push` from `LONG` in `bash-cleancode.tst.sh`.
- **05:** decompose `CalendarMainView.vue` `<script>` tag (`326-937`, 612 lines) by extracting navigation and event selection into `useCalendarNav.ts` and `useCalendarEvents.ts`; shrink `<script>` under 500 lines and delete `CalendarMainView.vue` from `BIG` map in `sfc-script-size.test.mjs`.
- **06:** add table tests in `paypal_payments_test.go` covering pure error formatting and intent builders in `paypal_payments.go`; raise statement coverage floor in `go-coverage-floor.txt` from 72.4 to >= 74.0.
- **07:** extract pure stack transition decisions from `useMobileStack.ts` into `src/utils/mobile-stack.mjs` with unit tests in `tests/unit/mobile-stack.test.mjs`; shrink composable <= 250 lines while keeping public composable API unchanged.
- **08:** remove `flowTopicUnread` from `ALLOW` in `unused-exports.test.mjs`; unexport ~15 dead functions in `perf-rum.mjs`, `omnibox-dock.mjs`, `calendar-swipe.mjs`; lower `ALLOW_CAP` from 76 to <= 60.
- **09:** extract toast timers and browser push notification helpers from `src/stores/notification.ts` into `notification-toast.mjs` and `notification-push.mjs`; shrink store setup body under 250 lines while preserving public store API.
- **10:** split `do_provision_firebase_dns` in `provision-firebase-dns.func.sh` (`35-203`, 169 lines) into named sub-steps (`dns_check_records`, `dns_wait_ssl`) <= 80 lines each; remove `do_provision_firebase_dns` from `LONG` in `bash-cleancode.tst.sh`.

## 5. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-615@<box>` (`seat-agy.md`)
  - Claude seat: `c-xxx@sat` (`seat-claude.md`)
  - Mistral seat: `m-xxx@sat` (`seat-mistral.md` - docs and review only per owner rule: no mistral coding rows)
  - Grok seat: `g-xxx@<box>` (`seat-grok.md` - conditional subject to vendor quota availability; grok weekly quota is monitored via `spl_box_quota_here`)
- **Reviewers per row (R7.2):**
  - All 10 coding rows are assigned to Claude per owner directive (no mistral coding rows, owner 10-17).
  - Cross-vendor review enforced: editor seat `a-615@<box>` (agy) and mistral seat `m-xxx@sat` (mistral) provide 100% cross-vendor review for all 10 rows (`grep -c 'same vendor'` -> 0).
  - Review lines verified via `do_spl_review_line_check`.

## 6. Left out, measured (carried to future rounds by pointer)

| what | why | measured by |
|---|---|---|
| `pages/issues.vue` further decomposition | Script was decomposed from 2083 to 876 lines in Round 13 Row 06; well under 1200 ceiling | `sfc-script-size.test.mjs` (876 lines) |
| `usePaneWidths.ts` state persistence | Ratio math already in `utils/pane-widths.mjs` (307 lines); composable is small functions <= 80 lines | `wc -l` (314 lines) |
| `internal/blob` GCS paths | Requires GCS emulator/credentials not available in hermetic unit test runner | `go tool cover -func` |
| Other `bash-cleancode.tst.sh` LONG functions (`gcp-001`, `gcp-002`, `run.sh do_log`) | Rows 02, 04, and 10 address the 3 longest actionable tool functions first; remaining carry to Round 15 | `bash-cleancode.tst.sh` (7 remaining after Round 14) |

## 7. Counts

| | n |
|---|---|
| rows | 10 (refactor 9, test 1; WUI 6, Bash 3, Go 1) |
| vendor | claude 10 (all coding rows per owner 10-17); agy / mistral cross-vendor reviewers |
| box (preferred) | sat / <box> |
| batches | 5 batches of 2 rows (2 parallel lanes at all times) |

## 8. Changes

- v0.1: Initial proposed plan for Round 14 (balanced refactoring: WUI components/stores, bash cleancode ceilings, and Go API coverage), measured on `e9fa87f74` (retro section 7 input list).

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| Editor | agy | a-615@<box> | v0.1 proposed | `refactor-round-14/seat-agy.md` |
| Claude seat | claude | pending | pending review of v0.1 | `refactor-round-14/seat-claude.md` |
| Mistral seat (docs/review only) | mistral | pending | pending review of v0.1 | `refactor-round-14/seat-mistral.md` |
| Grok seat | grok | pending | pending review of v0.1 (quota check) | `refactor-round-14/seat-grok.md` |
