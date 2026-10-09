# Refactoring round 5 - plan: clean code round 20261010 (10 actions)

Owner HUM-10, prd t1, topic `4f46ce09-15ee-4b9a-b05f-edd9812b51fb`: msg 2f3e0993 "clean code round 20261010", msg e30c2bf1 (the list of 12 practices), msg 6adfde6d "pick 10 concrete actions from this list - build a consensus between claude , agy and mistral agents and start implementation after reaching consensus", msg 1a80758a "use at least 2 agents on sat and 2 on [the primary box] to implment". Relayed by the dispatch holder c-002 (msgs 202d468a, cc80dda9, 17049475, 94c87514).

**Status: DRAFT for signature.** Section 10 (consensus) is empty until all three seats sign one sha.

Panel: the claude seat c-687 (editor, `sat`), the agy seat a-732 (`PC`), the mistral seat m-689 (`sat`). Proposals: `refactor-round-5/seat-claude.md` (ebc8b7056), `refactor-round-5/seat-agy.md` (e61ec161d, fixed by de6f05387), `refactor-round-5/seat-mistral.md` (fb933b786). Inputs: the row format and rules R1-R6 of `refactor-round-4-plan.md`, and `refactor-round-3-retro.md` section 6.

Every site was measured on ONE trunk sha: **`d5d136053`** (`origin/master`, 2026-10-09T21:42Z), n=1 per count unless stated otherwise. Re-checked on `fb933b786` (the trunk when this plan was written): `git diff --stat d5d136053 fb933b786 -- <every site file of section 3, every baseline, both cleancode gates>` names one file, `.shellcheck-warning-baseline.txt` (+2 lines). Only action 05 owns that file and it re-measures at its own start, so every line number below holds.

## 1. How to read this

- One action = one practice = one lane. The lane applies the practice at the sites named and nowhere else, with a test that proves behaviour did not change, or, for a gate, a **red control** that proves the gate now fails on the bad input.
- **Paths:** `api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` = `csi-spl-wui/`, everything else is from the repo root. Line numbers are as of `d5d136053`.
- **Boxes:** `sat` and `PC`, as in round 4 (the primary box's short name is banned in shipped files by the hygiene gate; the lane map prints it). Round 4 line 13 said `sat` has neither Postgres nor Chrome. That is out of date. Measured on `sat` (n=1): `which google-chrome` prints `/usr/bin/google-chrome`, and `docker ps` lists `postgres:16-alpine` containers. So no action is placed by that rule. Each box gets at least 2 (owner msg 1a80758a): `sat` 6, `PC` 4.
- **Agent kind** (owner vendor mix, spec 115: grok by default, claude for the hardest coding, gates and anything on a credential path, mistral for low-level code): grok 4, claude 5, mistral 1.
- **No new dependency.** Actions 01-04 are behaviour-preserving. Actions 05-10 change a gate: what it lets through, never what the product does.
- **Commit subject** (R6 reads it): `refactor(r5-NN-<slug>): ...` for a code action, `ci(r5-NN-<slug>): ...` for a gate action.
- **Off every live lane:** `lane-map.sh --check <all 48 site paths> --agent c-687` -> `free`, rc 0 (two runs on 2026-10-09, after the seats landed). Live and kept off: c-683 (store timing tests), c-686 (workspace-docs hub), c-712 (doc view), c-680 / m-673 (spec 115), c-682, c-688, c-730, c-668 (`sync-roadmap.mjs`). Re-run the check per action before its spawn (section 5).

## 2. Where the actions come from (measured)

| owner practice | command on `d5d136053` | n | action |
|---|---|---|---|
| small functions | `api:internal/cleancode/cleancode_test.go:18-26` (80 lines, depth 4, 8 params); `longFuncs` | 0 allowed: nothing to do in Go | none |
| | `cd csi-spl-wui && CLEANCODE_PRINT=1 node tests/unit/cleancode.test.mjs` | 20 listed, all still over 80; the list is a pass, not a ceiling (`stores/flow.ts` 128 -> 321 lines, `usePaneWidths` 167 -> 201 since listed) | 06 |
| | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | 40 listed, 10 print `NOTE LONG ... no longer over` | 06 |
| dead code | `deadcode -test ./...` (golang.org/x/tools/cmd/deadcode, run from a scratch install) in `api:` | 3 unreachable even from tests; `deadcode ./...` 125, most of them test seams or staged packages (`calquick`, `marketing/seal*`), read by hand | 02 |
| | each export of `wui:src/{utils,composables,stores}`: `grep -rlw <name> src` outside its own file, hits read by hand | 1 module + 2 symbols referenced nowhere | 01 |
| | every function in the 655 production `.sh`: `grep -lw <name> $(git ls-files)` | 33 defined and named nowhere else; 30 are called by a built name (`_pp_part_lint_$x`); 3 real | 03 |
| | SC2034 (assigned, never used) in `.shellcheck-warning-baseline.txt` at the agy sites | 8 (`gcp-sync-local-to-s3` 4, `gcp-sync-s3-to-local` 2, `resolve-oap-worktree.tst.sh` 2) | 03 |
| comments that lie | WUI comments naming a `.mjs/.vue/.ts` that does not exist, read by hand | 22 hits, 4 real | 01 |
| | bash comments naming a `do_*` defined nowhere | 57 mentions, most from the csi-rel donor; real: 8 commented AWS lines + 2 `do_load_pat` guards | 03 |
| | Go: read by hand | `notify.go:66-68` says Queue can stop work in flight; `queue.go:95,143` call `Run` (no ctx) | 02 |
| DRY | a hash of every 6-line window (comments and blanks dropped) over production bash | about 30 groups of 3+ copies; the largest that holds a credential is the DB-connect preamble, 5 copies | 04 |
| | the same over the three `sec-*` baseline compares | 3 hand copies of one Python heredoc | 05 |
| lint / static analysis enforced | the 4 scanner baselines: fail when a count goes UP; when one goes down they print INFO only | `.shellcheck-warning-baseline.txt` 120 entries / 234 findings, `.gosec-` 8 / 10, `.semgrep-` 1 / 1, `.eslint-security-` 1 / 7; nothing forces a fixed entry out | 05 |
| formatting enforced | `gofmt -l . \| wc -l` in `api:` -> 0 (enforced by `csi-spl-api/src/bash/tests/run-all-tests.sh:38-41`); `terraform fmt -check -recursive` -> 0 | already in place | none |
| | `git ls-files '*.py' \| xargs ruff format --no-cache --check` | **47 of 54** would be reformatted; `lint-py` runs `ruff check E9,F` only | 09 |
| CI blocks broken builds / failing tests | `check-pre-push.func.sh:771` `local all="hygiene blog iac wui-vendor wui api"` | no `orc` part; orc jobs were the real failure in 7 of the 19 red wf 10 runs among the last 100 on master | 07 |
| | `gh run list --workflow 10_ci-quality.yml -L 100` on master + the job logs of every red run, read for `gate fail-fast: stopped` | 78 cancelled, 19 failure, 1 success; e2e killed by fail-fast 55 times, failed on its own once; no e2e verdict on trunk since 2026-10-09T15:02:47Z (585ab0d3d) | 08 |
| test coverage | `grep -rlnE 'coverprofile\|go test.*-cover\|experimental-test-coverage\|\bc8\b\|\bnyc\b\|kcov' .github csi-spl-iac/src csi-spl-orc/src csi-spl-api/src/bash csi-spl-wui/package.json` | 2 hits, both false (a variable named `c8`): coverage is measured nowhere | 10 |
| | `nice go test -count=1 -cover ./...` in `api:` (no `SPOOL_TEST_PG_DSN`) | 62.0% of statements, 42 packages; production lows `cmd/spool` 26.8%, `internal/action` 30.3%, `internal/files` 32.9%, `internal/edge` 38.2%; `internal/store` 45.1% with 53 of 174 test files skipped | 10 |

The process practices (review, pairing, training, standards, capacity) are in section 6: rules, not lanes.

## 3. The 10 actions

| # | practice | why (one line) | sites file:line-line (max 5) | n + command | test or red control | box | agent kind | batch |
|---|---|---|---|---|---|---|---|---|
| 01 `r5-01-wui-dead-code` | eliminate dead code and comments that lie (WUI) | A module nothing imports, two exports nothing calls, and comments that send the reader to a file that does not exist | `wui:src/utils/verbosity.mjs:1-72` (whole module)<br>`wui:src/stores/live.ts:341-342` `useLiveStore`<br>`wui:src/utils/perf-rum.mjs:74-77` `perfCollector`<br>`wui:nuxt.config.ts:273`<br>`wui:src/node/i18n/split-catalogue.mjs:181` | `grep -rln "verbosity.mjs\|/verbosity'" csi-spl-wui/src \| wc -l` -> 0; `grep -rlw useLiveStore csi-spl-wui` and `grep -rlw perfCollector csi-spl-wui` -> the defining file only; both comments name `i18n/i18n.config.ts`, which `git ls-files` does not hold (the code is `src/plugins/0.i18n-plain-messages.ts` + `src/utils/i18n-plain-messages.mjs`) | `verbosity.test.mjs` goes with the module; **util-docs.test.mjs** (reads util doc comments), channel-feed.test.mjs, msg-kind.test.mjs, i18n-plain-messages.test.mjs, i18n-split.test.mjs, cleancode.test.mjs, typecheck, `nuxt generate` | PC | grok | 1 |
| 02 `r5-02-go-dead-code` | eliminate dead code and comments that lie (Go) | Exported functions with no production caller read as API; one comment promises a cancel that the caller never uses | `api:internal/hubclient/hubclient.go:590-592` `Session.Lost`<br>`api:internal/cicdlogs/cicdlogs.go:529-533` `DumpJSON`<br>`api:internal/action/action.go:116-121` `Send`<br>`api:internal/notify/notify.go:66-68` | `deadcode -test ./...` -> 3 (`Session.Lost` is one: no caller, tests included); `DumpJSON`'s own comment says "a test helper"; `Send`'s says "no non-test caller"; `grep -n 'Run(' api:internal/notify/queue.go` -> `:95`, `:143` call `Run`, not `RunCtx` | `go test ./internal/hubclient/ ./internal/cicdlogs/ ./internal/action/ ./internal/notify/` (submit_test.go, retired_bounce_test.go, cicdlogs_test.go, fleet_send_test.go, notify_test.go). Test-only helpers move into a `_test.go` of the same package. Notify: write the test first (does `Queue.Stop` end a running notifier?). If it does not, fix the comment and report the gap to the orchestrator as a bug; do not change Queue in this action | sat | mistral | 1 |
| 03 `r5-03-bash-dead-code` | eliminate dead code and comments that lie (bash) | An AWS action nobody calls, commented-out AWS lines, a branch on a function that exists nowhere, and variables assigned and never read | `csi-spl-iac/src/bash/run/tf-apply-local-step-bucket.func.sh:1-66` (whole file)<br>the `# do_backup_region_dynamo_db_tables` line in the 8 `csi-spl-iac/src/bash/run/tf-*.func.sh` that hold it<br>`csi-spl-iac/lib/bash/funcs/validate-params.func.sh:31-37` + `csi-spl-orc/lib/bash/funcs/validate-params.func.sh:30-36`<br>`csi-spl-iac/src/bash/run/gcp-sync-local-to-s3.func.sh`, `gcp-sync-s3-to-local.func.sh` (SC2034)<br>`csi-spl-iac/src/bash/tests/resolve-oap-worktree.tst.sh` (SC2034) | `grep -rn 'do_tf_apply_local_step_bucket\|tf-apply-local-step-bucket' --include=*.sh --include=*.yml .` -> the file itself only; `grep -ln '^ *# *do_backup_region_dynamo_db_tables' csi-spl-iac/src/bash/run/*.sh \| wc -l` -> 8; `grep -rlw do_load_pat --include=*.sh .` -> 2 (the two guards); `grep -E 'SC2034.*(gcp-sync-s3-to-local\|gcp-sync-local-to-s3\|resolve-oap)' .shellcheck-warning-baseline.txt` -> 3 lines, 8 findings | tf-apply-destroy-quoted-paths, tf-import-existing, tf-actions-tf-proj-after-init, resolve-oap-worktree, tf-init-project-key, gcp-actions-isolated-config, **comment-refs-exist** (reads bash comments), bash-cleancode (.tst.sh); `cd csi-spl-iac && ./run -a do_sec_shellcheck` prints the SC2034 lines as `FIXED`. A SC2034 variable that a sourcing caller reads is an out-param, not dead: keep it with a `# shellcheck disable=SC2034` and say who reads it. Do not edit the baseline (05 does) | sat | grok | 1 |
| 04 `r5-04-bash-db-connect-helper` | DRY | Five hand copies of the block that turns the provider and key into a DSN and a throwaway gcloud config; the next change to it needs all five | `csi-spl-orc/src/bash/run/spl-db-rls-check.func.sh:33-63`<br>`csi-spl-orc/src/bash/run/spl-db-period-count-check.func.sh:20-50`<br>`csi-spl-orc/src/bash/run/spl-consumer-lag.func.sh:29-68`<br>`csi-spl-orc/src/bash/run/spl-db-message-show.func.sh:28-60`<br>`csi-spl-orc/src/bash/run/spl-hub-member-list.func.sh:26-58` | the 6-line-window hash: 5 copies of provider -> `none` rc -> key check -> DSN -> `cfg=$(mktemp -d)` + trap, each read by hand | spl-db-rls-check, period-count-check, consumer-lag, msg-to-db, hub-member-list, hub-member-access-until, db-actions-none, cred-tmp-trap (.tst.sh), plus a new unit test for the helper: the `none` provider returns the same rc, a missing key fails with the same message, an interrupted run leaves no temp dir (round 4 rows 08-09 pattern) | sat | claude (credential path) | 1 |
| 05 `ci(r5-05-baseline-down)` | lint and static analysis enforced | A fixed finding stays in its baseline and silently allows a regression up to the old count; three copies of the compare | `csi-spl-iac/src/bash/run/sec-eslint.func.sh:85-105`<br>`csi-spl-iac/src/bash/run/sec-gosec.func.sh:141-158`<br>`csi-spl-iac/src/bash/run/sec-semgrep.func.sh:97-114`<br>`csi-spl-iac/src/bash/run/sec-shellcheck.func.sh` (its compare)<br>the 4 baseline files + the agy sites `csi-spl-iac/src/bash/tests/check-pre-push-baseline.tst.sh` (SC2064, SC2164) and `csi-spl-orc/src/bash/features/spool-install/tests/test-install.sh` (SC2054) | each compare: `n > base` fails, `n < base` prints INFO (`sec-gosec.func.sh:156`, `sec-semgrep.func.sh:112`, `sec-eslint.func.sh:103`); 4 baselines, 130 entries, 252 findings | one compare helper; a count BELOW its baseline now fails with "lower this line"; the same commit fixes the two agy test-file warnings and lowers every baseline to today's findings. **Red control:** a fixture baseline of today's count + 1 must FAIL, today's count must PASS, a count + 1 in the tree must FAIL (as today). sec-eslint, sec-gosec, sec-semgrep, sec-shellcheck, check-pre-push-baseline, check-pre-push-lint (.tst.sh), test-install.sh | sat | claude | 2 (after 03) |
| 06 `ci(r5-06-long-ceiling)` | small functions | A function on the LONG list can grow without limit: two have more than doubled since they were listed | `wui:tests/unit/cleancode.test.mjs` (the LONG set)<br>`csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` (its LONG list) | WUI: 20 listed, `stores/flow.ts <anon>` 128 -> 321, `usePaneWidths` 167 -> 201; bash: 40 listed, 10 `NOTE LONG ... no longer over` | each LONG entry carries its length today as a ceiling; over the ceiling fails; the 10 bash NOTE lines are deleted. **Red control:** a fixture where a listed function grows by 1 line must FAIL in each gate; a shrink prints the NOTE (as today) | PC | grok | 1 |
| 07 `ci(r5-07-prepush-orc)` | CI blocks broken builds (locally, before the push) | An orc-only push runs no orc test locally, and orc was the real red in 7 of 19 red trunk runs | `csi-spl-iac/src/bash/run/check-pre-push.func.sh:771` (the part list) and the part selector beside it | `local all="hygiene blog iac wui-vendor wui api"` -> no `orc`; the iac part's paths leave out `csi-spl-orc` | an `orc` part (fast tier: the orc hermetic suite for touched files + `bash-cleancode` on orc). **Red control:** `PRE_PUSH_PLAN=1` on an orc-only diff must list `orc`; a planted failing `*.tst.sh` in a temp repo must be REFUSED. check-pre-push, check-pre-push-tree-pass (.tst.sh); time the fast tier before and after (an orc part that adds minutes is a finding, report it) | sat | claude | 1 |
| 08 `ci(r5-08-e2e-verdict)` | CI blocks failing tests, and says which | A red in an unrelated job kills the e2e shards, so e2e has had no verdict on trunk for hours | `csi-spl-orc/src/bash/scripts/gate-fail-fast.sh` (the job filter)<br>`csi-spl-iac/src/bash/tests/gate10-fail-fast.tst.sh` | 55 of 56 e2e ends in the 19 red runs were fail-fast kills; 0 e2e verdicts on trunk since 15:02:47Z | e2e stops early only on a red in a job it needs (`wui-generate`, wui unit); hub and orc keep today's rule. **Red control** on a THROWAWAY branch (`gh workflow run 10_ci-quality.yml --ref <branch>`, never trunk): a planted orc failure; e2e must end with its own verdict. Poll with a bounded loop, no foreground `gh run watch` | PC | claude | 1 |
| 09 `ci(r5-09-format-python)` | formatting enforced locally and in CI | 47 of 54 Python files are not in the formatter's shape, and nothing checks it | the 54 tracked `.py` files (one mechanical commit)<br>`csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh:21,73` (`lint-py`) | `git ls-files '*.py' \| xargs ruff format --no-cache --check` -> 47 of 54 | `ruff format` once, then `lint-py` adds `ruff format --check` on touched `.py`. **Red control:** an unformatted `.py` fixture must be REFUSED by lint-py. Every test that runs or reads a touched `.py` passes (`grep -rl <basename> --include=*.tst.sh --include=*.test.mjs .`); the format commit carries no other change (`git diff --stat` then `ruff format --check` -> 0) | sat | grok | 1 |
| 10 `ci(r5-10-go-coverage-floor)` | comprehensive tests, high coverage | Coverage is measured nowhere, so a deleted test is invisible | `csi-spl-api/src/bash/tests/run-all-tests.sh` (add `-coverprofile`)<br>a new per-package floor file beside it | 62.0% total without Postgres; `cmd/spool` 26.8%, `internal/action` 30.3%, `internal/files` 32.9%, `internal/edge` 38.2% | the run prints per-package coverage and fails when a package drops more than 1 point under its floor (a ratchet like the gosec baseline). Measure the floor WITH `SPOOL_TEST_PG_DSN` (docker Postgres), or the store floor is 45.1% and wrong. **Red control:** a fixture package whose only test is removed must FAIL the floor. Raising the low packages is round 6 | PC | claude | 1 |

Sites: 41 (01: 5, 02: 4, 03: 5 groups / 14 files, 04: 5, 05: 6, 06: 2, 07: 1, 08: 2, 09: 2 groups / 55 files, 10: 2). Action 03 lists five site groups; each group is one finding of the same kind.

### 3.1 Disjoint files (R1)

- No path is in two actions. `lane-map --check` over every path: free.
- **Generated or shared files:** the four scanner baselines belong to 05 only. 03 removes findings (the shellcheck gate then prints `FIXED` as INFO, as it does today) and never edits the baseline, so 05 runs after 03 (batch 2) and lowers it once. The WUI `LONG` set and the bash `LONG` list belong to 06 only. `check-pre-push.func.sh` is 07's, `check-pre-push-lint.func.sh` is 09's (two files, no overlap). `gate-fail-fast.sh` is 08's.
- 09 touches all 54 `.py`: `git ls-files '*.py' \| grep -f <every other action's paths>` -> 0. No `.py` is a site of another action.
- A test file named in the test column of two actions is READ by both, never edited by both: the editing action is the one whose sites include it.

## 4. Per action: what the lane does

- **01.** Delete `verbosity.mjs` and its own test. If `channel-feed.test.mjs`, `msg-kind.test.mjs` or `util-docs.test.mjs` import it, drop that import only and keep every other assertion. `useLiveStore` and `perfCollector` go with their comment lines. The two comments name the real files. No `.vue` change; the initial JS chunk can only shrink.
- **02.** `Session.Lost` goes. `DumpJSON` and `action.Send` move to a `_test.go` in the same package (the tests keep calling them). Notify: one test that starts a slow notifier through `Queue` and calls `Stop`; the comment then says what is true. If `Stop` cannot end it, that is a bug report, not a fix in this action. Guard (m- lanes): the commit's `git diff --stat` names only the 4 site files plus `_test.go` files, and `wc -l` of each site file drops by at most the lines removed.
- **03.** Delete the AWS action file and the 8 commented lines. In `validate-params`, remove the `do_load_pat` branch and its comment in BOTH copies (iac and orc). SC2034: delete a variable no one reads; keep an out-param (round 3 row 29 rule) with a disable comment that names its reader.
- **04.** One `_spl_db_connect` (name it after what it returns) in `csi-spl-orc/lib/bash/funcs/`, sourced the way those five files already source their helpers. It keeps each caller's messages and rc. The RETURN trap stays in the CALLER: a helper that sets the trap would fire it when the helper returns (round 4 section 6, the `_spl_sdk_saved=` reason).
- **05.** One helper the four `do_sec_*` call. Then lower each baseline to `./run -a do_sec_<x>` output on the commit's own tree, and only lower. The shellcheck baseline may have moved since `d5d136053` (it gained 2 lines by `fb933b786`): take the numbers on the rebased tree.
- **06.** WUI: the LONG set becomes `name -> ceiling`. bash: the same, and delete the 10 NOTE lines. Ceilings = today's lengths, measured on the rebased tree.
- **07.** Model the part on `api`: changed paths under `csi-spl-orc/` select it. Fast tier = the orc `*.tst.sh` that name a touched file (the R2 map), plus `bash-cleancode`. Run `PRE_PUSH_TIER=full ./run -a do_check_pre_push` once before the push.
- **08.** Keep every other kill rule. The planted failure lives on a throwaway branch only; delete the branch after.
- **09.** Commit 1: `ruff format` only (no other change). Commit 2: the `lint-py` check + its fixture test. Two commits, pushed together.
- **10.** Use a `-coverprofile` in a temp dir, then `go tool cover -func`. The floor file is keyed by package, one line each, `%.1f`. The gate never raises a floor by itself; a lane raises it by hand when it adds tests.

## 5. Spawn, done, status (R1-R8)

- **R1** disjoint files: section 3.1.
- **R2** test column: every test file that names the site's basename, a function it defines, or (WUI) its import path, plus every test that holds a 30-character string from a comment within the site (+/- 3 lines). Bold = a test that reads source text, which a comment-only change can break.
- **R3, before the wave.** The orchestrator re-runs `lane-map.sh --check <action paths> --agent <its id>` per action. An owned path: wait for that lane, never spawn on top.
- **R4, one spawn per slug across all boxes.** `sat` spawns 02, 03, 04, 05, 07, 09; `PC` spawns 01, 06, 08, 10. Before a spawn: `git log origin/master --grep='r5-NN-' --oneline` is empty and no live lane carries the slug.
- **Batch order.** Batch 1 = 01-04 and 06-10, all at once (5 on `sat`, 4 on `PC`). Batch 2 = 05, as soon as 03 is on trunk.
- **R5, done = served.** Hub and WUI changes (01, 02): `cd csi-spl-orc && SHA=<sha> ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd`. Bash and CI changes (03-10): done = on `origin/master` and in each box's checkout (`git -C <box checkout> merge-base --is-ancestor <sha> HEAD` on `sat` and `PC`), plus the red control's proof in the commit body. A lane exit-cleans once its commit is on trunk; one deploy lane proves served.
- **R6, no hand-kept status.** `git fetch origin master && git log origin/master --grep='r5-' --format='%h %cI %s'`, then the R5 commands per sha.
- **R7 (new, peer review, section 6).** Before the push, a lane sends its diff (a pushed `review/r5-NN` branch, never master) to a reviewer of ANOTHER vendor from this round's lanes, who answers `PASS` or `FIX: <item>` against the checklist C1-C6 below. The commit body then carries one line `review: <reviewer id> PASS`. R6 counts it: `git log origin/master --grep='r5-' --format=%B | grep -c '^review: '` must reach 10. The branch is deleted after the push.
  - C1 the diff touches only the action's sites and its tests (`git diff --stat`).
  - C2 behaviour preserved (code) or the red control was seen RED then GREEN (gate), with the command and its output in the body.
  - C3 no file shrank by more than the lines the action removes (`wc -l` before and after; the m- whole-file clobber guard).
  - C4 every test in the action's test column ran and passed, named in the body.
  - C5 no comment states something the code does not do.
  - C6 hygiene and pre-push passed with no override.
- **R8 (new, retro).** After the 10 actions are served, one lane writes `refactor-round-5-retro.md` in round 3's retro shape; its section 6 feeds round 6. Round 4 had no retro.

## 6. Process practices, measured (no lane)

| owner practice | measured state on `d5d136053` | verdict |
|---|---|---|
| peer code review with a checklist before merge | 1971 commits on master since 2026-10-03, 1 merge commit, **0** with a review line (`git log origin/master --since=2026-10-03 --format=%B \| grep -ciE '^(reviewed-by\|review:\|reviewer:)'` -> 0). Specs get panel reviews; code gets none | **adopt as rule:** R7, for this round's 10 actions. Wider adoption waits for the R8 retro to measure its cost (time from commit to push) |
| pair and mob programming | 48 of 116 `spec.md` mention a panel or consensus (`grep -rliE 'consensus\|panel' csi-spl-doc/specs/*/spec.md \| wc -l`); this round is itself a 3-seat panel | **already in place** (spec panels) |
| regular training, workshops, book clubs | 2 `lesson-*.md` in `csi-spl-doc/doc/md`; a retro for round 3, none for round 4 (`ls csi-spl-doc/doc/md \| grep retro` -> round 3 only) | **adopt as rule:** R8, a retro per round. It is the fleet's training material: the next planner must read it |
| shared standards, style guides, ADRs | `csi-spl-doc/doc/md/fleet-rules-index.md` (27 table rows, one home per rule, drift-gated by `do_check_fleet_rules_drift`); 116 spec dirs with plan and research; `ls csi-spl-doc/doc/adr` -> no such dir | **already in place** (fleet-rules-index + specs carry the decisions); an ADR dir with no measured gap would be a second home for the same decisions |
| regular refactoring alongside features | 88 of 1971 commit subjects since 10-03 start `refactor`; rounds 1-4 landed 10-03, 10-04, 10-05, 10-06 | **already in place** (the owner calls a round) |
| dedicated capacity for technical debt | the rounds above; this round runs 10 lanes beside the feature lanes | **already in place** |
| CI that blocks broken builds | master has no protection (`gh api repos/csitea/csi-spl/branches/master/protection` -> 404, rulesets `[]`); the fleet pushes to trunk by standing order, so the block is the pre-push hook. wf 20 deployed 12 times and wf 30 deployed 34 times while wf 10 was red (since 15:02Z) | actions 07 and 08. Making deploys wait for wf 10 is **left to the owner** (section 7, D4) |

## 7. Disagreements

Each seat item that is not one of the 10, and why. "Folded" means it is inside an action.

| # | seat item | resolution |
|---|---|---|
| D1 | agy 1, 2 (SC2034 in `gcp-sync-*` and `resolve-oap-worktree.tst.sh`) | **folded** into 03 (an unused variable is dead code) |
| D2 | agy 4, 5 (SC2064/SC2164 in `check-pre-push-baseline.tst.sh`, SC2054 in `test-install.sh`) | **folded** into 05 (fix, then lower the baseline in the same lane, R1) |
| D3 | agy 6, 7, 8 (12 WUI `fetch` with no `signal`: `grep -rnE "await fetch\(" csi-spl-wui/src/utils/ \| grep -v signal \| wc -l` -> 12, confirmed) | **kept out, reason:** a timeout is a failure-path fix (round 3 rows 6-7, round 4 row 03), not one of the owner's 12 practices; agy 8's `-doctree-api.ts` is in c-686 / c-712's workspace-docs area. First candidate for round 6 |
| D4 | agy 3 (`exit 1` at function level in `gcp-import-to-cloudsql.func.sh:168`, `gcp-export-dns-settings.func.sh:39`, confirmed) | **kept out, reason:** round 4 row 11's practice (failure path), not on the owner's list. Round 6, with D3 |
| D5 | agy 9 (Go `_ =` in `workspace_docs_ops.go`, `message_claim.go`) | **kept out:** `workspace_docs_ops.go` is c-686's area; the other is round 4 row 02's practice |
| D6 | agy 10 (SC2155 in `spawn-agents/tests`) | **kept out:** rotation / spawn scripts stay off, as in rounds 3 and 4 |
| D7 | mistral 01 (`api:internal/store/memberships.go:120-180`, "1 function, 60 lines") | **refuted by measurement:** the file is 197 lines; the functions starting in 120-180 are `isUndefinedColumn` (1 line), `membershipsSQL`, `membershipRow`, `TouchMembership`, none near 60; the Go gate allows nothing over 80 (`longFuncs` empty) |
| D8 | mistral 02 (`CalendarMainView.vue:80-150`, "3 functions, 70+ lines each") | **refuted:** the `<script setup>` starts at `:181`; its functions (`dayHead`, `step`, `boxStyle`, `openCreate`, ...) are short. The file is 822 lines, mostly template and style; an SRP split there has no failing measure |
| D9 | mistral 03 (`gcp-003-enable-apis.func.sh:40-60`, unused functions) | **refuted:** no such file (`ls csi-spl-iac/src/bash/run/gcp-003*` -> `gcp-003-configure-proj-sa-permissions.func.sh`); `grep -rn "function unused_" csi-spl-iac/src/bash/run/ \| wc -l` -> 0. The practice is served by 03 on measured sites |
| D10 | mistral 04 (shellcheck on `csi-spl-orc/src/bash/run/spl-db-*.func.sh`) | **already in place:** wf 67 and the pre-push `lint-shellcheck` scan orc; `shellcheck -x -S warning` on those 14 files -> 0 findings. The real scope gap (api and wui `.sh` are never scanned; 1 error, SC2144 at `csi-spl-api/src/bash/tests/spool-smoke.tst.sh:57`) is section 8 |
| D11 | mistral 05 (a pre-commit hook running `go vet` + `gofmt`) | **already in place:** the pre-push api part runs `gofmt -l` and `go vet ./...` (`csi-spl-api/src/bash/tests/run-all-tests.sh:38-44`), both 0 today. The practice it names (peer review) is R7 |
| D12 | mistral 06 (`avatar.mjs`, "coverage < 80%") | **refuted:** `node --test --experimental-test-coverage` lcov for `src/utils/avatar.mjs`: 348 of 350 lines (99.4%). Coverage is served by 10 |
| D13 | mistral 07 (custom error types in `hubclient.go:200-300`) | **kept out:** `grep -c 'errors.New(' hubclient.go` -> 4, and changing error types changes what callers match: not behaviour-preserving, no measured defect |
| D14 | mistral 08 (an ADR template and `csi-spl-doc/doc/adr/`) | **kept out:** no measured gap; the decisions live in specs and fleet-rules-index (section 6) |
| D15 | mistral 09 (CI gate for unformatted Go) | **already in place:** `gofmt -l . \| wc -l` -> 0, enforced in the api part and wf 10's hub job. The practice is served by 09 for Python, where the gap is (47 of 54) |
| D16 | mistral 10 (`refactoring-guide.md`) | **folded** into R8: the round retro is the guide, written from what the round measured |
| D17 | mistral's sha | its proposal names `352866e1d` (round 4's sha); every count here is on `d5d136053` |
| D18 | claude seat: deploys wait for wf 10 | **left to the owner:** it would have stopped every deploy for the 6 h 49 m trunk was red today; 08 first makes the wf 10 verdict trustworthy |

## 8. Measured and left out

| what | why it is out | measured by |
|---|---|---|
| shellcheck skips the 22 `.sh` under `csi-spl-api` and `csi-spl-wui` (`sec-shellcheck.func.sh:75-77`) | round 6: 1 error (SC2144 at `spool-smoke.tst.sh:57`) + 6 warning lines to fix first | `shellcheck -S error` on those files |
| eslint-security scans `.mjs/.js` only (242 files), not the 370 `.ts/.vue` | semgrep covers them; adding a TS/Vue parser is a dependency | `sec-eslint.func.sh:71` |
| shfmt (1206 `.sh`) and prettier (612 WUI src files) | no config and no tool; one format wave over every live lane's files | `git ls-files` counts |
| a WUI coverage floor | node 20 loads 214 of 612 src files (no `.ts/.vue`), so the number would measure the wrong thing; 28 of 75 composables have no test naming them | `node --test --experimental-test-coverage tests/unit/*.test.mjs` |
| more DRY: the cron "drop tagged line" block (6), the probe scaffold (5), the Go member-write guard (3 in `internal/hub`), the Go calendar series-write skeleton (3 in `internal/store`) | 10 actions; the store one sits beside c-683's live store lane | the 6-line-window hash |
| `wui:src/node/roadmap/sync-roadmap.mjs:33` names a test that does not exist | owned by c-668 | `lane-map.sh --check` |
| the WUI fetch timeouts and the `exit` in sourced functions | D3, D4: round 6 | section 7 |
| 15 production `.func.sh` with no test naming them (largest `spl-agent-identity-restore.func.sh`, 191 lines) | identity / rotation scripts stay off | the R2 map over `*.tst.sh` |

## 9. Counts

| | Go | TS/Vue | bash | CI / gate | total |
|---|---|---|---|---|---|
| code actions | 1 (02) | 1 (01) | 2 (03, 04) | 0 | 4 |
| gate actions | 1 (10) | 0 | 0 | 5 (05, 06, 07, 08, 09) | 6 |
| per box | `sat`: 02, 03, 04, 05, 07, 09 | | | `PC`: 01, 06, 08, 10 | 10 |
| agent kind | claude: 04, 05, 07, 08, 10 | grok: 01, 03, 06, 09 | mistral: 02 | | 10 |

Seat items: agy 10 (4 folded, 6 kept out), mistral 10 (1 folded, 3 already in place, 4 refuted, 2 kept out), claude 10 (all 10 in, one owner question D18).

## 10. Consensus

All three seats signed ONE sha, **`49e21c570`**, with no objection. Sections 1-9 above are that sha's text, unchanged; this commit adds only this section.

| seat | agent | box | reply | spool msg |
|---|---|---|---|---|
| claude (editor) | c-687 | `sat` | SIGN 49e21c570 (author) | - |
| agy | a-732 | `PC` | SIGN 49e21c570 | 5d7a86bf |
| mistral | m-689 | `sat` | SIGN 49e21c570 | b4fa4a3d |

Disagreements kept: D3-D6, D13, D14 (kept out, reasons in section 7), D18 (left to the owner). Every other seat item is folded, already in place or refuted by the command named in section 7.
