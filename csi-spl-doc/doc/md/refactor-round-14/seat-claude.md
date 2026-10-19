# Round 14 - claude seat verdict (c-666@PC)

Reviews [plan v0.1](../refactor-round-14-plan.md) (`b7fad2def`).

**Where and when:** PC, 2026-10-19 14:49Z..15:20Z, worktree on `origin/master`
**`ab685ef25`**, n=1 per command. None of the 10 rows' files changed between
the plan's sha `e9fa87f74` and `ab685ef25`: `git diff --stat e9fa87f74
ab685ef25 -- csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-api` lists 7 files,
none of them a row site. `git log origin/master --grep='r14-' --oneline` -> 0
lines, so no row has landed yet.

**Tally: 1 agree / 6 agree with changes / 3 disagree / 2 proposals.**

## 1. Verdict per row

| # | baseline re-measured on `ab685ef25` | verdict | why (verified) |
|---|---|---|---|
| 01 | `sed -n '/<script/,/<\/script>/p' .../WorkspaceDocView.vue \| wc -l` -> 677; BIG ceiling 677 (`sfc-script-size.test.mjs:30`) | agree with changes | (a) Site `:242-918` is wrong: `grep -n '<script\|</script>'` -> 339 and 1015, so the range is `:339-1015`. It was wrong on `e9fa87f74` too (`git show e9fa87f74:<file> \| grep -n '<script setup'` -> 339). (b) The named seams hardly exist: in the script, `grep -ci drawer` -> 1, `grep -ci history` -> 1. The large concern is picture handling (`upload`, `onImageFile`, `pastePic`, `dragPic`, `dropPic`, `pickPic`, `insertPic`, `imageOf`) plus the insert ops (`insertAt`, `insertTable`, `insertQuote`). Name `useDocPictures.ts` / `useDocInsert.ts`, not drawer/history. (c) Behaviour test: **`tests/unit/doc-outline.test.mjs:143-144`** reads this file's source (`branchOf`), so it goes in the test column, plus e2e `tests/e2e/docs.test.mjs`. |
| 02 | `sed -n '/^spawn_main() {/,/^}/p' .../spawn-core.inc.sh \| wc -l` -> 184; LONG ceiling 185 (`bash-cleancode.tst.sh:28`) | agree with changes | (a) Site `:75-258` is wrong: `grep -n '^spawn_main() {'` -> 439, so `:439-622`. (b) The body parses no arguments and checks no container: `grep -nE 'case \|getopts\|docker'` over it -> 0. Its seams are guards + env, identity, spool dirs, registry row, trust pre-accept, launch: name the steps after those. (c) Behaviour test: `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-dry-run.sh` -> `211 passed, 0 failed` (3.9 s); name it in the row. (d) The same file holds `NO_FORCE` (`:282`), the one home of the no-force rule (developer guide section 4): the row leaves it untouched and also runs `tests/test-seed-no-force-push.sh`. Every agent's seed comes from this file, so the kind is `complex_coding`, not `simple_coding`. |
| 03 | `sed ... QtoFileTree.vue \| wc -l` -> 654; ceiling 654 (`:31`) | agree with changes | (a) Site `:240-893` is wrong: `<script` at 139, `</script>` at 792, so `:139-792`. (b) The seams are real: in the script `grep -ci fold` -> 109, `grep -ci drop` -> 12 (`canDrop`, `moveRow`, `canDropSection`, `moveSection`). (c) Behaviour test: no unit test names the file except the size ratchet (`grep -rl QtoFileTree tests` -> 1 file). Name e2e `tests/e2e/docs.test.mjs` and `docs-dock-collapse.test.mjs`, else C2 has nothing to show. (d) `src/utils/tree-drag.mjs` already exists (its `TREE_DROP_EDGE` is in the unused-exports ALLOW): reuse it, do not add a second drag module. |
| 04 | `sed -n '/^do_check_pre_push() {/,/^}/p' ... \| wc -l` -> 137; ceiling 137 (`:19`) | agree with changes | (a) Site `:30-166` is wrong: `grep -n '^do_check_pre_push() {'` -> 914, so `:914-1050`. (b) Fast and full are not two code paths: `PRE_PUSH_TIER` is one variable read through the whole body (`:918`, `:969`, `:984`, `:992`, `:1030`). The seams are part planning (`:943-978`), the tree-pass skip (`:984-990`) and the run + summary (`:991-1050`). (c) Helper names must not start with `do_`: under csi-rel naming a `do_*` function is a `./run -a` action. Use the file's own `_pp_` prefix (`_pp_plan_parts`, `_pp_run_parts`). (d) The test glob `pre-push-*.tst.sh` matches nothing (`ls csi-spl-iac/src/bash/tests/pre-push-*.tst.sh` -> "No such file"); the suite is `check-pre-push*.tst.sh` (14 files) + `stop-pre-push.tst.sh`. (e) It changes the gate itself, so R9 applies: `PRE_PUSH_TIER=full` once, and once with every `PRE_PUSH_*` unset. |
| 05 | `sed ... CalendarMainView.vue \| wc -l` -> 612; ceiling 612 (`:32`) | agree with changes | (a) Site `:326-937` is wrong: `<script` at 206, `</script>` at 817, so `:206-817`. (b) The largest seam is drag and resize (`grep -ci drag` -> 22: `begin`, `onItemDown`, `onResizeDown`, `onGridDown`, `hitAt`, `liftOff`), not navigation (`step`, `prevLabel`, `nextLabel`: a few lines). Extract `useCalendarDrag.ts` first. (c) Source-text tests the row must keep green: **`tests/unit/calendar-year.test.mjs:125`** asserts `/\/v1\/calendar\/events\?/` in this file, and **`tests/unit/hub-headers.test.mjs:22`** lists it; moving `load` into a composable reds the first. Behaviour: e2e `calendar-drag.test.mjs`, `calendar.test.mjs`. |
| 06 | `go test -count=1 -cover ./internal/payments/` -> `72.4%`; floor `internal/payments 72.4` (`csi-spl-api/src/bash/tests/go-coverage-floor.txt:52`) | agree | The 0.0% functions the plan names are real (`go tool cover -func` lists `Error`, `AlreadyCaptured`, `CreateIntent`, `Refund`, `CancelIntent`, `payPalIssue`, `truncatePayPalErr` at 0.0%). The target is reachable: the profile holds 880 statements, 637 covered; 74.0% needs 652, i.e. +15. The uncovered statements of `paypal_payments.go` from line 338 on are 44, so this file alone allows up to 77.4%. `Refund` needs an `httptest` server; 4 test files of the package already use one. Notes for the brief: `paypal_payments_test.go` does not exist yet (`ls internal/payments/*_test.go`), the row creates it; `CancelIntent` is a one-line no-op, not a request builder. |
| 07 | `wc -l useMobileStack.ts` -> 531 | agree with changes | (a) The extraction target already exists: `src/utils/mobile-stack.mjs` (239 lines) with `tests/unit/mobile-stack.test.mjs` (135 lines), imported once by the composable. (b) The composable is already 26 top-level functions (`grep -cE '^function'`); most drive `history`, `popstate` and touch events, which are not pure. <= 250 means moving 281 lines out of DOM code: not realistic as a behaviour-kept move. Set the target to what is pure (the `onPopCapture` / `dropStaleTopic` / `leaveStaleLogin` decisions), measured by the lane, e.g. <= 420. (c) Behaviour: e2e `mobile-stack.test.mjs`, `mobile-back-stuck.test.mjs`, `mobile-overlay.test.mjs`; source-text: **`swallow-reasons.test.mjs:44`**, **`touch-ui.test.mjs:38`**. |
| 08 | `node tests/unit/unused-exports.test.mjs` -> `75 unused, all listed in ALLOW (76 <= cap 76)` + `NOTE ALLOW: ... 'flowTopicUnread' is no longer an unused export` | disagree (as written) | The 3 named target files are not in ALLOW at all: `grep -cE 'perf-rum\|omnibox-dock\|calendar-swipe' tests/unit/unused-exports.test.mjs` -> 0 (round 13 row 08, `16efe287e`, already cleaned the top 5). Unexporting there changes nothing the gate counts. The real top of ALLOW: `errorJournal.mjs` 7, `monitoring-tokens.mjs` 6, `upload-fail.mjs` 4, `tenant-costs.mjs` 3. Those first 17 + `flowTopicUnread` -> ALLOW 58, so cap <= 60 is reachable. Agree once the sites are those files. |
| 09 | `wc -l src/stores/notification.ts` -> 569 | disagree | The target is already met: the store is split into step factories (`permissionSteps`, `alertSteps`, `topicSteps`, `readSteps`, `countSteps`, `ingestStep`), and the `defineStore` setup body is `sed -n '498,$p' \| wc -l` -> 72 lines, not over 250. The file has no toast code (`grep -ci toast` -> 0), so `notification-toast.mjs` would be empty. Also **`tests/unit/notify.test.mjs`** reads the store's source 11 times (`grep -c 'stores/notification.ts'` -> 11): a move reds it. Drop the row; use the slot for proposal 7.1. |
| 10 | `sed -n '/^do_provision_firebase_dns() {/,/^}/p' ... \| wc -l` -> 169; ceiling 169 (`:25`) | disagree | The file is pinned byte-identical to csi-rel's by owner order 2026-09-19: `csi-spl-iac/src/bash/tests/wui-hosting-019-031.tst.sh:26-30` fails on any sha256 other than `73ffb71f...`. Any split reds it, and editing `want_sha` breaks "exactly as csi-rel". Its only behaviour proof is a live DNS run, i.e. a GCP mutation, which the round allows none of. The site `:35-203` is also wrong (`^do_provision_firebase_dns() {` is at line 20). Replace with proposal 7.1. |

## 2. The checks the brief asked for

| check | result | how |
|---|---|---|
| R1 disjoint files between the 2 lanes | holds, with one condition | Shared test files sit in one lane each: `sfc-script-size.test.mjs` (01, 03, 05: lane 1, serial), `bash-cleancode.tst.sh` (02, 04, 10: lane 2, serial). Condition: row 08's sites, once corrected to `errorJournal.mjs`, `monitoring-tokens.mjs`, `upload-fail.mjs`, stay off row 07's files (batch 4, parallel); they do (`mobile-stack.mjs` is not in ALLOW). |
| each decomposition row names a behaviour test | no | 01, 03, 05, 07 name only typecheck, cleancode, the unit runner and the size ratchet. The ratchet proves the size, not the behaviour. Tests per row in section 1. |
| row 08 cap vs today's count | cap 76, ALLOW 76, unused 75 | the gate's own summary line on `ab685ef25`. <= 60 is reachable only on the files named in row 08 above. |
| row 06 coverage target | realistic | +15 of 880 statements; this file's ceiling 77.4%. |
| no prd or GCP mutation | holds for 01-09; fails for 10 | Row 10's only behaviour proof is a live DNS run. |
| every coding row is claude, no mistral | no mistral in cnf; the spawner must still pin claude | `csi-spl-cnf/csi-spl/all.env.yaml:1079-1081`: `tests {claude 85, grok 15}`, `simple_coding {claude 59, grok 41}`, `complex_coding {claude 90, grok 10}`. A lane-mix pick may still give grok, so "vendor claude" needs `SPAWN_PLACE=claude:<slug>` on each row. |
| rows already done on master | none landed; row 09's target already met | `git log origin/master --grep='r14-'` -> 0; row 09 above. |

## 3. Red controls

- 01, 03, 05: the ratchet's own control (`fresh(MAX_SCRIPT + 1)`, `sfc-script-size.test.mjs:108`) already fails a new 501-line script, so "scratch 501-line script fails" adds nothing. The row's real control: delete the BIG line while the file is still over 500 -> RED; after the shrink -> GREEN. Record both runs.
- 02, 04: "lengthen an extracted step over 80" is already `bash-cleancode.tst.sh:118` (`PASS: CONTROL: a listed function grown 1 line past its ceiling fails`, this run). The row's control: delete the LONG line while the function is still long -> RED.
- 06: "mutate an error format string" fails only if a test asserts the text. Pin it, e.g. `truncatePayPalErr` on a 300-byte raw body ends in `…` after 256 bytes.
- 08: holds (an unused `export const` fails the gate, `unused-exports.test.mjs:5-7`).

## 4. Not run, said plainly

- `check-pre-push*.tst.sh` (row 04's suite), typecheck and the WUI e2e files named above were not run in this review: they are listed by name only.
- `do_spl_lane_mix` printed only its header line here (`instance: kinds off qwen, paused none (hub)`), so the vendor split above is read from cnf, not from a lane-mix pick.

## 7. Proposals the plan missed

### 7.1 Replace row 10 (and fill row 09's slot): `do_log`, twice

`do_log` is 143 lines in both `csi-spl-iac/src/bash/run/run.sh:320` and
`csi-spl-orc/src/bash/run/run.sh:320` (2 LONG lines in `bash-cleancode.tst.sh`),
and the two bodies are identical (`diff <(sed -n '/^do_log() {/,/^}/p' <iac
run.sh>) <(... <orc run.sh>)` -> no output). One split removes two LONG
entries. Behaviour tests exist and are green on `ab685ef25`:
`run-log-compact.tst.sh` and `run-log-nofork.tst.sh` -> `PASS: all ...
assertions`. No GCP touch. Risk: every `./run` action calls it, and it
rewrites `OK x` lines, so the compact test is the behaviour proof. Kind
`complex_coding`, lane 2, batch 5.

The plan's section 6 says rows 02, 04 and 10 are "the 3 longest actionable"
LONG functions; they are not. LONG on `ab685ef25` (`sed -n 18,30p
bash-cleancode.tst.sh`): `spawn_main` 185, `do_gcp_import_to_cloudsql` 174,
`do_provision_firebase_dns` 169, `do_gcp_002_create_project_service_account`
149, `do_log` 143 x2, `do_check_pre_push` 137. The gcp-* ones can only be
proven against GCP, so `do_log` is the next one a test can prove.

### 7.2 A source-text test column per row (R2, bold)

R2 puts every test that reads a site's source in the row's test column. The
plan names none, yet 5 rows have them: `doc-outline.test.mjs` (01);
`calendar-year.test.mjs`, `hub-headers.test.mjs` (05);
`swallow-reasons.test.mjs`, `touch-ui.test.mjs` (07); `notify.test.mjs` x11,
`verbosity-notify-wire.test.mjs`, `ai-message.test.mjs` (09). Measured with
`grep -rlE '<basename>' tests` per site. A move reds them unless the brief
lists them, which costs a push (rulebook 1.2). Add them to each row.

## 8. Signature on v1.0

signed: c-666@PC on c9b3225b0ce16bed7cf31d37aef5b0d5879428a7

Checked against section 1 above on `c9b3225b0` (n=1, PC, 2026-10-19 15:1xZ):
the 6 corrected file:line ranges, the seams of 01-05, the bold source-text
tests, the 08 ALLOW files, the drops of old 09 and 10, and new row 09
(`do_log`, `bash-cleancode.tst.sh:26,29`, `run.sh:320-462`) all match my
measurements.

Two corrections row 08's brief must carry. The spawner pastes them into
the brief; they change no other row and no file set:

1. **Path:** `errorJournal.mjs` is `wui:src/composables/errorJournal.mjs`,
   not `src/utils/` (`ls csi-spl-wui/src/utils/errorJournal.mjs` -> "No
   such file"; `unused-exports.test.mjs:35` lists it under
   `src/composables/`).
2. **Red control:** "an unused `export const` in a test file" cannot turn
   the gate red. The gate reads exports only under
   `src/composables` and `src/utils` (`DEF_DIRS`,
   `unused-exports.test.mjs:29`). Use an unused `export const` in a
   `src/utils/*.mjs` file instead -> RED.
