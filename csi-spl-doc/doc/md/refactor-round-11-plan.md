# Refactoring round 11 - plan (10 actions)

Owner HUM-10, t1 topic `4f46ce09-15ee-4b9a-b05f-edd9812b51fb`, msg 3d22fcea:
rounds run continuously, **no owner go for the round, its panel or its
lanes**. Refactoring share: owner t1 3209f8b8 (msgs a25bfdd6, 36ee9cec,
8cb6cc7d); spawn-share blocker b7870c0f (2026-10-15 03:1xZ: refactor 16 %,
nothing queued). Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10
items, push caps, bands, R1-R16), by pointer, not copied. Issue: SPL-1920.

**Status: v1.0, SIGNED** (`7dc9ed7e3`; section 9). It folds the mistral
seat (`7342fa401`, 10 of 10 agree; section 8). The rows spawn from the signed v1.0
sha (rulebook 1.4: consensus, then build, no second go).

Editor: **c-156@sat** (claude).

**One sha:** every count is measured on **`eb1d01ae1`** (`origin/master`,
2026-10-15 03:19Z), n=1 per command unless stated. Input:
[refactor-round-10-retro.md](refactor-round-10-retro.md) section 7 (landed
`b3c59ec30`).

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept, or for a gate a **red control**: the
  check fails on the bad input before the change and passes after.
- **Paths:** `api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` =
  `csi-spl-wui/`, `orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`. Lines as
  of `eb1d01ae1`.
- **Box:** the preferred box; the spawner's box pick may move a row (no pin).
- **Vendor:** the owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`
  on `eb1d01ae1`: simple_coding -> grok, backup claude; complex_coding and
  tests -> claude, backup mistral; specs_and_docs -> agy, backup claude),
  then R14. grok has no quota (`402`), agy is out until about
  2026-10-15T09:40Z. R14 after round 10: its one mistral row (05) made the
  round's only trunk red and was taken over by claude after 2 tries (retro
  section 3), so mistral gets one row whose failure cannot reach `./run`: a
  new standalone test file (row 03), backup claude after 2 tries (owner
  10-12).
- **Subject** (R6 reads it): `<type>(r11-NN-<slug>, SPL-<row issue>): ...`.
- **R7.4 line, this round:** the review line carries the run it claims
  (retro 7.1), in the landing commit:
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
  The sha is pasted from `git rev-parse`, never typed; `ran:` names only
  commands that are in the `log:` file (the reviewer's own session journal:
  vibe `.../unified/<session>/journal/*.jsonl`, claude
  `.../projects/<slug>/<sid>.jsonl`, grok `.../chat_history.jsonl`, under
  the reviewer's `$HOME`). Until rows 04 and 06 land, the dispatcher checks
  it by hand; after, the gate and the action do. Trunk-red takeover: rulebook
  2.11.3.

## 2. Where the rows come from (measured on `eb1d01ae1`)

| source | command | n | row |
|---|---|---|---|
| retro 7.5 | `git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' eb1d01ae1 -- csi-spl-iac \| wc -l` | 3 files | 01 |
| retro 7.2 | loop over `git grep -l '^\s*spl_gcp_temp_sdk_config \|\| return 1' -- src/bash/run lib/bash/funcs` (in `iac:`), counting the files part 3 of `gcp-actions-isolated-config.tst.sh` scans (a `run/gcp-*.func.sh`, or the lib helpers `gcp-each-env-sa`/`gcp-project-apis`, with a `gcloud auth activate`/`login` line) | 23 callers, 11 scanned, 12 blind | 02 |
| retro 7.3 | `git grep -nE '^\s*(source\|\.) +"?/opt/' eb1d01ae1 -- 'csi-spl-iac/src/bash/run/' 'csi-spl-orc/src/bash/run/' 'csi-spl-iac/lib/' 'csi-spl-orc/lib/' \| wc -l`; `git grep -l '/opt/csi' -- 'csi-spl-iac/src/bash/tests/*' \| grep -c no-box` | 0 sites, 0 tests (round 10 had 5 sites for 1 h 43 min) | 03 |
| retro 7.1 | `grep -n 'PASS \[0-9a-f\]{7,40}' csi-spl-orc/src/bash/run/spl-push-master.func.sh` -> line 137; `grep -c '\| log:'` on the same file -> 0 | the gate takes any 7-40 hex and asks for no `log:` | 04 |
| retro 7.4 | `git grep -n -i review eb1d01ae1 -- csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push \| wc -l` | 0 | 05 |
| retro 7.1 | `ls csi-spl-orc/src/bash/run \| grep -c review-line` | 0 actions; round 10: 3 of 10 commit lines unbacked, 1 unchecked (retro section 2) | 06 |
| retro 7.6 | `sed -n '/^const LONG/,/^\])/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | 5 entries; `live.ts setup` 304 | 07 |
| retro 7.6 | same | `notification.ts <anon>` 430 | 08 |
| retro 7.7 | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | 13 LONG; `do_tf_init` 93 (ceiling 95); NOTE `do_gcp_002_delete_project_service_account` 132 (ceiling 133) | 09 |
| retro 7.8 | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out \| awk '$3=="0.0%"'` | 74.5 %, 19 at 0.0 %; `repoEdit` (`hub_repo_edit.go:27`), `nonEmpty` (`:81`) | 10 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r11-01-bash-temp-sdk-config-last-three)` | DRY | the last 3 copies of the 4-line block | `iac:src/bash/run/gcp-import-to-cloudsql.func.sh:10`<br>`…/gcp-project-delete.func.sh:12`<br>`…/gcp-sync-src-s3-to-tgt-s3-silent.func.sh:8` | 3 files | the r10-04 pattern (`spl_gcp_temp_sdk_config` + caller RETURN trap; the helper sourced relative to the action behind `declare -F`, as `6535dd26d`, **never** an `/opt/...` path). Tests: `gcp-actions-isolated-config.tst.sh`, `gcp-temp-sdk-config.tst.sh`, `return-not-exit-gcp.tst.sh`, `gcp-key-path-no-eval.tst.sh`, `bash-cleancode.tst.sh` (run, **not edited**: the two LONG functions shrink by 1, a NOTE only). **Control:** the old-literal grep -> 0 on `iac:`; `wc -l` per file +1 (C3); the tests run once from a copy of the tree outside `/opt/csi/csi-spl` (CI shape, retro 6) | sat | claude (grok out) | simple_coding | 1 |
| 02 `test(r11-02-isolated-config-scan-helper-callers)` | test gap | 12 of 23 helper callers unscanned | `iac:src/bash/tests/gcp-actions-isolated-config.tst.sh:97-112` | 12 blind | part 3 also scans every `run/` and `lib/` file that calls `spl_gcp_temp_sdk_config`: each has the call as `\|\| return 1` and the caller RETURN trap `spl_gcp_temp_sdk_config_restore`. **Red control:** a temp copy of one blind file (e.g. `spl-gh-app-key-put.func.sh`) with the call deleted fails; the real tree passes with 26 callers after 01 | sat | claude | tests | 2 (after 01: its count) |
| 03 `test(r11-03-no-box-path-source)` | gate, nothing ad hoc | a fixed box path in a `source` line broke every iac action (r10-05) | new `iac:src/bash/tests/no-box-path-source.tst.sh` | 0 tests | fails on any `source`/`.` line under `csi-spl-{iac,orc}/src/bash/run/` and `csi-spl-{iac,orc}/lib/` whose path starts with `/opt/`, `/home/` or `/mnt/` (comments skipped). **Red control:** a temp fixture holding `source "/opt/csi/x/lib.func.sh" \|\| exit 1` fails, the `6535dd26d` relative form passes; the real tree passes (0 sites). Runs in the iac suite (`run-all-tests.sh` picks up `*.tst.sh`) | sat | mistral (backup claude after 2 tries) | tests (R14) | 1 |
| 04 `ci(r11-04-push-master-review-line-checkable)` | review before merge, gate | a typed sha passed; no pointer to the run | `orc:src/bash/run/spl-push-master.func.sh:130-139`<br>`orc:src/bash/tests/spl-push-master.tst.sh`<br>`csi-spl-doc/doc/md/rounds-rulebook.md` (2.7.4) | 0 checks | `_spl_push_master_unreviewed` also refuses a row whose review line's sha is not 40 hex or does not resolve (`git rev-parse --verify -q <sha>^{commit}`, after fetching `review/<round>-NN`), or has no `\| log: \S+@\S+:\S+`: `REFUSED round row <sha> review line: <reason>`. Rulebook 2.7.4 gets the format of section 1, and its qto doc `e621cc32` the same edit (the `11cd0c0c4` path: desk doctree on prd, export byte-equal). **Red control:** fixtures `refactor(r99-01-x)` with a 39-char sha, an unresolvable 40-char sha, no `log:`: refused; the full line passes; a `docs(...)` commit passes. R9: `PRE_PUSH_TIER=full` | sat | claude | simple_coding (R14) | 1 |
| 05 `ci(r11-05-pre-push-hook-review-line)` | gate | a hand `git push` skips row 04 | `orc:src/bash/features/spawn-agents/hooks/pre-push`<br>new `orc:src/bash/features/spawn-agents/tests/test-pre-push-review-line.sh` | 0 | the hook runs row 04's check (one shared helper, sourced, not copied) on the commits it pushes to master, `SPL_PREPUSH_OVERRIDE` included. **Red control:** a scratch repo pushing a row commit with no line, then with a typed sha: refused by the hook; with the full line: pushed. R9 | sat | claude | simple_coding (R14) | 2 (after 04: the helper) |
| 06 `ci(r11-06-review-line-log-check)` | review evidence, nothing ad hoc | the dispatcher read journals by hand 4 times in round 10 | new `orc:src/bash/run/spl-review-line-check.func.sh`<br>new `orc:src/bash/tests/spl-review-line-check.tst.sh` | 0 actions | `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` reads the `log:` file (on this box) and, for every test file named in `ran:` (`*.tst.sh`, `*.test.mjs`, `*_test.go`, `go test <pkg>`, `pnpm run <script>`), needs a `"command"` in it that names it; prints `MISSING <name>` and exits 3, else `OK <n> of <n>`. Refuses a log on another box (exit 2, names the box). **Red control:** a fixture journal holding only `git diff --stat` (the r10-09 shape) -> `MISSING git-prune-round-branches.tst.sh`, exit 3; one holding the run -> exit 0 | sat | claude | complex_coding | 1 |
| 07 `refactor(r11-07-wui-small-store-live)` | small functions | store setup 304 lines | `wui:src/stores/live.ts:32`<br>`wui:tests/unit/cleancode.test.mjs` (LONG map) | 1 LONG entry | named module step functions under 80 lines; `useLiveStore(key)` (`live.ts:338`) and its reactivity unchanged; delete the LONG entry (5 -> 4). Tests: `cleancode.test.mjs`, the 13 unit tests that import it (`git grep -lE "stores/live(\.ts)?['\"]\|useLiveStore" -- csi-spl-wui/tests`), `pnpm run typecheck`, **`perf-budget.py bundle`** with the CI node version (same-box A/B; `ci_initial_gzip_kb` may not rise) | PC | claude | simple_coding (R14) | 1 |
| 08 `refactor(r11-08-wui-small-store-notification)` | small functions | store body 430 lines | `wui:src/stores/notification.ts:75`<br>`wui:tests/unit/cleancode.test.mjs` | 1 LONG entry | as 07; `useNotificationStore` unchanged; LONG 4 -> 3. Tests: `cleancode.test.mjs`, the 4 unit tests that import it (same grep with `notification`/`useNotificationStore`), typecheck, **`perf-budget.py bundle`** | PC | claude | simple_coding (R14) | 2 (after 07: `cleancode.test.mjs`) |
| 09 `refactor(r11-09-bash-small-tf-init)` | small functions | 93 lines | `iac:src/bash/run/tf-init.func.sh:6`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:22,29` | 1 LONG entry, 1 ceiling | named steps under 80 lines; same exports, wipe, `GOOGLE_APPLICATION_CREDENTIALS` and exits; delete the `do_tf_init` LONG line (13 -> 12) and lower `do_gcp_002_delete_project_service_account` to 132. Tests: `bash-cleancode.tst.sh` and the 9 others naming it (`git grep -lE 'tf-init\|do_tf_init' -- '*.tst.sh'` -> 10). Terraform is never run: the tests stub it | sat | claude | simple_coding (R14) | 1 |
| 10 `test(r11-10-go-coverage-repo-edit)` | tests, coverage | 2 functions at 0.0 % with no Postgres need for their guards | new `api:cmd/spool/hub_repo_edit_test.go` (`repoEdit` `hub_repo_edit.go:27`, `nonEmpty` `:81`)<br>`csi-spl-api/src/bash/tests/go-coverage-floor.txt:11` | 2 functions | `repoEdit` returns nil when editing is off, when the store is not Postgres, and with no docs bucket (log line asserted, no key logged); `nonEmpty` table test. Read `cmd/spool` 3 times, set the floor to the lowest read. **Red control:** without the new file the raised floor fails | PC | claude | tests | 1 |

### 3.1 Disjoint files (R1)

- **Batch 1:** 01, 03, 04, 06, 07, 09, 10. No path is in two of them: 01
  three `iac:` run files; 03 one new `iac:` test; 04 the push action, its
  test and the rulebook; 06 two new `orc:` files; 07 `live.ts` +
  `cleancode.test.mjs`; 09 `tf-init.func.sh` + `bash-cleancode.tst.sh` (01
  runs it, never edits it); 10 a new Go test + the floor file.
- **Batch 2:** 02 after 01 (its caller count), 05 after 04 (the shared
  helper), 08 after 07 (`cleancode.test.mjs`); each placed within 30 min of
  its prerequisite landing (R16).
- Rows 01-03 do not edit `gcp-temp-sdk-config.func.sh`; 01 does not edit
  `gcp-actions-isolated-config.tst.sh` (02 does).
- Rows 04 and 06 parse the same line format (section 1); neither imports the
  other.

### 3.2 Off every live lane (R3)

`lane-map.sh --check <19 row paths> --agent c-156` on `eb1d01ae1` -> rc 4:
no live lane lists any row path. Four live lanes record no files:
c-296@PC (`c-296-cga-editor`, the standing CI-refactor seat), c-522@PC
(`c-522-r10-seat-claude-2`, round 10 seat), c-525@PC (`c-525-s137-t019-gaps`)
and c-530@PC (`c-530-bug-stale-global-gitconfig-lock`). Rows 03 and 05 sit
nearest the CI area (an iac test, the pre-push hook): c-296 is asked on the
spool before batch 1 spawns. The spawner re-runs `--check` per row (R3).

## 4. Per row: what the lane does

- **01:** replace the 4-line block (`local _spl_sdk_saved=...`, `mktemp -d`,
  `export CLOUDSDK_CONFIG`, the RETURN trap) with `local _spl_sdk_saved
  _spl_sdk_dir`, `spl_gcp_temp_sdk_config || return 1` and `trap
  'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN`; source the helper
  as `6535dd26d` does (relative to the action, behind `declare -F`). No other
  line changes. Commit body: `git diff --stat`, `wc -l` before and after, and
  the test run from a tree copy outside `/opt/csi/csi-spl`.
- **02:** extend part 3, keep parts 1-2 as they are; the pass line names the
  caller count it scanned.
- **03:** one new file; no other path changes. The fixture lives in a temp
  dir, never in the tree.
- **04:** the refusal reason is one line per row commit; `_spl_push_master_worker`
  stays under 80 lines. The rulebook edit is the 2.7.4 line format only; the
  qto doc edit goes through the desk as `11cd0c0c4` did (if no desk seat is
  free, the row reports a blocker to the orchestrator, it does not push the
  md alone: the next export would revert it).
- **05:** source row 04's helper from the hook; no second copy of the regex.
- **06:** read-only; never fetches a log from another box. The dispatcher
  runs it on the reviewer's box for every row line from round 11 on.
- **07, 08:** split the store setup into module-level step functions under
  80 lines; the store's exported API and reactivity stay as they are.
  Measure `ci_initial_gzip_kb` before and after with the CI node version.
- **09:** split `do_tf_init` into named steps under 80 lines; keep the
  `bin/` wipe first (repo CLAUDE.md: one run per env + step). Delete its LONG
  line and lower the other ceiling.
- **10:** a fake store type that is not `*store.Postgres` drives the second
  guard; no network, no Postgres.

## 5. Panel and reviewers (R7)

agy is out until about 2026-10-15T09:40Z, grok has none (`402`). The plan
has no multilingual text: no agy language review is needed.

- **Signing panel:** the editor c-156@sat (claude) and the **mistral seat**
  m-159@sat: two vendors. No agy seat signs: waiting for agy's quota (about
  09:40Z) would hold 10 rows for some 2.5 h, and the panel is already
  cross-vendor. agy joins as a row reviewer when it is back.
- Seats write `refactor-round-11/seat-<vendor>.md` (verdict per row: agree,
  agree with changes, disagree, with the command behind any change), commit
  that file only (R7.6), then sign the editor's v1.0 sha. Seats stay up until
  the editor confirms the signed version; reviewer seats stay until R6 shows
  10 of 10 rows on trunk (R7.1).
- **Reviewer per row** (R7.2), every line in the section 1 format:
  - **claude rows 01, 02, 04-10** -> the **agy seat** once it is up; until
    then the **mistral seat**, whose lines the dispatcher checks against the
    `log:` file before the row lands (retro section 2: 4 of 9 mistral lines
    were unbacked or void).
  - **mistral row 03** -> a claude panel seat (the editor does not review).
- If a seat closes, the spawner places a reviewer of an eligible vendor
  (R7.3).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| WUI LONG `channel.ts` 576, `createLiveClient` 499, `createSpoolClient` 545 | larger; 07 and 08 first | LONG map, section 2 |
| bash LONG `check-pre-push 137`, `spawn_main 185`, `run.sh do_log 143` and `execute_step 99` (x2), gcp-001/002, `gcp-import-to-cloudsql 175`, `gcp-project-delete 120`, `provision-firebase-dns 169` | the pre-push gate is c-296's CI area; the two gcp actions are row 01's files this round (R1); the rest next rounds | `bash-cleancode.tst.sh` |
| `cmd/spool` `hub.go` 12, `key.go` 4, `main.go` 1 | need Postgres, a key daemon or the process entry | `go tool cover -func`, section 2 |
| kept unlanded tips: `review/r5-02`, `review/r7-05*` (4), 3 r7 `wip/`, `wip/fix/r10-05-helper-path`, `wip/m-524-r10-mistral-review-seat` | not a code row; listed to the orchestrator | retro section 5 |
| `review/r6-*` (6) and `wip/m-689-r5-panel-mistral` listed by the prune | rounds 5-6 predate the matcher; their retros never pruned; the orchestrator decides | `ROUND="5,6,7,10" DRY_RUN=1 ./run -a do_git_prune_round_branches` |

## 7. Counts

| | n |
|---|---|
| rows | 10 (refactor 4, test 3, ci 3) |
| vendor | claude 9, mistral 1 |
| box (preferred) | sat 7, PC 3 |
| batches | batch 1: 7; batch 2: 3 |

## 8. Changes

- v0.1 (`102f8b5c2`): from the round 10 retro section 7, measured on
  `eb1d01ae1`.
- v1.0: folds `refactor-round-11/seat-mistral.md` (m-159@sat, `7342fa401`:
  10 agree, R1 holds). Re-checked by the editor against the seat's commands:
  row 02's blind count is **12**, not 13 (the seat's count is right: the
  first count left out `gcp-project-apis.func.sh`, which part 3 scans; 23
  callers, 11 scanned). The retro's section 4 and 7.2 carry the same fix.
  The agy seat is dropped from signing (section 5).

## 9. Consensus

| seat | id | signed | file |
|---|---|---|---|
| editor (claude) | c-156@sat | v1.0 `7dc9ed7e3` | this file |
| mistral seat | m-159@sat | verdict `7342fa401` (10 agree, folded in v1.0); **signed v1.0** `4d625434a` (`signed: m-159 on 7dc9ed7e37c26624de9fc71f6b2d119dcf65166d`) | `refactor-round-11/seat-mistral.md` |
| agy | not a signing seat (section 5); row reviewer when its quota is back | - | - |
| grok seat | none: no quota (`402`) | - | - |

Signed plan sha: **`7dc9ed7e3`** (v1.0), signed by both seats. The rows
spawn from it. On record (R7, retro section 2): m-159's spool reply cited
`eb48795ec6333333333333333333333333333333` as its landed sha, which does
not resolve (`git rev-parse --verify -q` -> rc 1). The landed sign-off is
`4d625434a`, and the sha inside it is correct. Whoever reviews round 11 rows
pastes the sha from `git rev-parse` (section 1); row 04 refuses a sha that
does not resolve.
