# Refactoring round 10 - retrospective

> Generated from qto doc `a8dee37d-cd7d-47a0-a337-b3752cdab807`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Measured 2026-10-15 on trunk **`eb1d01ae1`** (`origin/master`, 03:19Z) only.
Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 7 is
the input list for round 11. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted). Issue: SPL-1920.

Plan: [refactor-round-10-plan.md](refactor-round-10-plan.md), v1.0
`40057b1a5`, signed by the two claude seats (`ad5364424`, `574ab7f22`);
accepted by the dispatch holder 2026-10-14 18:25Z. Review history: spool
topic `dispatch-3209f8b8` (`spool tail --task dispatch-3209f8b8`), from
20:54Z to 03:09Z.

<a id="ws-doc-7465c857-3fd8-4230-860c-dab90b263ad7"></a>
## 1. What landed

`git log origin/master -E --grep='r10-[0-9]{2}' --format='%h %cI %s'` -> **11**
commits: 10 row commits and 1 trunk-red takeover (`6535dd26d`, subject
`fix(iac, SPL-1899, SPL-1908)`, `r10-05` only in its body).
`... --format=%s | grep -oE 'r10-[0-9]{2}' | sort -u | wc -l` -> 10.

| row | landed sha (lane) | landed (UTC) | what it reduced, measured on `eb1d01ae1` |
|---|---|---|---|
| 01 `test(r10-01-go-coverage-spool-cli-verbs)` | `385d906a4` (c-131) | 10-14 21:51Z | `cmd/spool` 69.1 % -> **74.5 %**; functions at 0.0 % 26 -> **19** (`go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out \| awk '$3=="0.0%"'`); floor `cmd/spool 74.3` (`go-coverage-floor.txt:11`) |
| 02 `refactor(r10-02-wui-small-store-flow)` | `2d7a75b54` (c-133) | 21:18Z | WUI LONG `flow.ts <anon> 317` removed |
| 03 `refactor(r10-03-wui-small-auth-client)` | `1a10119c7` (c-151) | 10-15 01:43Z | WUI LONG `createAuthClient 326` removed; with 02: **7 -> 5** entries (`sed -n '/^const LONG/,/^\])/p' csi-spl-wui/tests/unit/cleancode.test.mjs`) |
| 04 `refactor(r10-04-bash-temp-sdk-config-compute-dns)` | `b402b6bbf` (c-529@PC) | 10-14 20:45Z | 5 files call `spl_gcp_temp_sdk_config` |
| 05 `refactor(r10-05-bash-temp-sdk-config-storage-sync)` | `d416a09f8` (m-135), fixed by `6535dd26d` (c-145) | 21:08Z, fix 22:51Z | 5 files; the first commit sourced the helper from a fixed box path (section 3) |
| 06 `refactor(r10-06-bash-temp-sdk-config-secrets-keys)` | `8a662e3cd` (c-139) | 21:54Z | 5 files |
| 07 `refactor(r10-07-bash-temp-sdk-config-projects-iam)` | `cf3c01093` (c-142) | 22:08Z | 5 files; rows 04-07: CLOUDSDK block in **23 -> 3** files (`git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' origin/master -- csi-spl-iac \| wc -l`) |
| 08 `refactor(r10-08-bash-small-spl-cloud-cnf)` | `6a72ccb0b` (c-154) | 10-15 02:46Z | bash LONG `do_spl_cloud_cnf 96` removed: **14 -> 13** (`bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`: 0 failures, 2 NOTEs, section 4) |
| 09 `ci(r10-09-round-branch-prune-lane-prefixed)` | `a3a54c0a5` (c-143) | 10-14 23:49Z | rounds 7-9 pruned (c-143's result, 00:06Z): 0 `r8-`/`r9-` branches on origin; r7 tips with unlanded commits kept (section 5) |
| 10 `ci(r10-10-push-master-review-line)` | `0e918d4b9` (c-144) | 23:07Z | `do_spl_push_master` refuses a row commit with no R7 line (`git grep -c 'has no R7 review line' origin/master -- csi-spl-orc/src/bash/run/spl-push-master.func.sh` -> 2) |

All 10 rows held: none reverted (`git log origin/master --grep='Revert' --format=%s | grep -c r10-` -> 0).
WUI rows 02 and 03 were served on dev and prd (c-002 verdicts: 02 in v9.1.7,
03 in v9.2.3); the other rows have no deploy input (R5: landed is done).

<a id="ws-doc-40c14d58-ab58-4a8d-9070-15f485a62e1d"></a>
## 2. Cross-vendor review (R7): was each line backed by output?

`git log origin/master -E --grep='r10-[0-9]{2}' --format=%B | grep -c '^review: '`
-> **9** (row 05 has none); `... | grep -c 'same vendor'` -> 0. Every line
is mistral reviewing claude (cross-vendor). C7 holds on all 10 rows: the
landed commit's own files equal the reviewed sha's
(`git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l`
-> 0, n=10).

"Backed" means the reviewer's own session shows the commands its `ran:`
field names. Source: the reviewer's vibe session logs on sat
(`$HOME/.vibe/logs/session/unified/<session>/{journal,chunks}/`, the
commands extracted with
`grep -oh '"command\\*":\s*\\*"[^\\"]*' <session>/chunks/*.json <session>/journal/*.jsonl`);
m-138: 5 sessions (`305e3fac`, `50867bd1`, `0e537a84`, `45de339a`,
`da1bd0a0`), m-155: 1 (`04b6f866`). m-524 ran on PC, whose logs are not
readable from sat.

| row | review line in the landed commit | its `ran:` claim | backed by output? |
|---|---|---|---|
| 01 | m-138@sat PASS `60e5a1ef7` | `go test ./cmd/spool/` | **yes**: `go test -count=1 -coverprofile ... ./cmd/spool/` on `f007a54d6`, on `60e5a1ef7`, and with the new test removed (`305e3fac`) |
| 02 | m-138@sat PASS `60d931f6b` | `flow-badge.test.mjs (21/21)` | **yes** for that file (`pnpm run test:unit flow-badge`, `305e3fac`); the row's other tests (`cleancode.test.mjs`, typecheck, `perf-budget.py bundle`) are not in `ran:` (C4: 1 of 4) |
| 03 | m-138@sat PASS `9055095f0` | 13 unit tests, typecheck, pre-push, bundle A/B | **no, VOID**: the `ran:` text is the author's request word for word; m-138 ran only `git diff --stat` and `git show \| wc -l` (c-001, 01:58Z). The commit landed (01:43Z) before the void, so its body carries the void line. Accepted on a later line from m-155 (try 2, 02:21Z): its 40-char sha resolves and its journal (`04b6f866`) holds `test:unit` TAP summaries that sum to 152 tests, fail 0, but not the "12 files" it claims (c-151 ran the 12 files: 156 tests). Try 1 cited `1a10119c78533333333333333333333333333333`, which does not resolve; a 3rd line after the ACCEPT (7 files, 33 tests, `wc` 595/595) contradicts the counted one, and `git show 9055095f0^:csi-spl-wui/src/utils/auth-client.mjs \| wc -l` -> 547 contradicts its `wc` |
| 04 | m-524@PC PASS `f02fd8345` | the 3 gcp `.tst.sh` (`read: PASS`) | **not checked**: PC logs not readable here, and the dispatcher did not check them either (c-001, 03:03Z). m-138 ran the same 3 tests on `f02fd8345` (`305e3fac`), but that line is not in the commit |
| 05 | **none** (landed 21:08Z, before row 10's gate) | - | c-120@sat (claude) sent a FAIL on `d416a09f8` at 21:14Z, backed by CI job 116107034159. After-the-fact line, m-138 PASS `6535dd26d`: it ran the 3 tests, but from the main checkout (`bash /opt/csi/csi-spl/csi-spl-iac/src/bash/tests/...`, `0e537a84`), not on the reviewed tree: **partly** |
| 06 | m-138@sat PASS `91d7a641b` | 8 `.tst.sh` (8/8) | **yes**: `git checkout 91d7a641b -- <5 files> && bash <8 tests>` (`305e3fac`) |
| 07 | m-138@sat PASS `d15ce2048` | 4 `.tst.sh` | **yes** (`50867bd1`); its first line diffed against `43688a782` and was resent with the merge-base |
| 08 | m-155@sat PASS `8ea9df71d16e…` | `bash-cleancode`, `cloud-actions`, `host-spool-no-rebuild`, lint | **partly**: the 3 commands are in `04b6f866`, but no result of `host-spool-no-rebuild.tst.sh`; c-002 ran it itself on `6a72ccb0b` (0 failures). The `wc` (652 -> 677) and diff-stat were re-run by c-001 and match |
| 09 | m-138@sat PASS `7a2151f14` | `git-prune-round-branches.tst.sh (27/27)` | **no**: no run of that test in the 5 m-138 sessions; they hold `git fetch`, `merge-base` and `diff --stat` for row 09 only |
| 10 | m-138@sat PASS `2228f77e3` | `spl-push-master.tst.sh (16/16)` | **no**: same; only `merge-base` and `diff --stat` |

**Count:** of the 10 rows, the review line in the commit is backed by output
on **3** (01, 06, 07); partly on **3** (02, 08, and 03 through the separate
m-155 line); **not** on **3** (03's own body line, 09, 10); not checked on
**1** (04); and row 05 has none. The rows were still accepted on evidence
the dispatcher or the journal showed: 03 and 08 on the m-155 journal plus
c-002's own `host-spool-no-rebuild` run, 04 on byte-identical files, 09 and
10 on "landed = reviewed" (empty `git diff`) and their first green workflow
10 run, whose hermetic job ran both test files (runs 38656455019 and
38652321901: `grep -cE '=== (git-prune-round-branches|spl-push-master)\.tst\.sh'`
on the job log -> 2 each). CI did the work that two review lines claimed.

Reviewer seats: m-524@PC (the placed mistral seat) reviewed 04 and went
silent at 21:08Z; a-137@sat (agy backup) hit agy's quota at start; m-138@sat
(mistral backup, placed 21:13Z) took 01, 02, 04 (late), 05 (after), 06, 07,
09, 10 and 03 (voided twice, then withdrawn); c-120@sat (claude) was
withdrawn from 03 (claude on a claude row breaks R7.5, c-002 msg 115c37dc);
m-155@sat (second mistral seat) took 03 and 08. The dispatcher records m-155
as unreliable (c-002, 03:06Z).

<a id="ws-doc-7e30b146-834b-4348-9ec5-13beda291f13"></a>
## 3. CI verdict per row (R11)

The first workflow 10 run, completed and not cancelled, whose head contains
the row sha (`gh run list --workflow 10_ci-quality.yml --branch master
--status completed -L 120`, then `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 |
|---|---|---|---|
| 01 | 38644583637 (`049bc0840`) | failure: iac only | **pass**: hub job (its tests) success |
| 02 | 38640562856 (`2d7a75b54`) | failure: iac only | **pass**: wui unit + typecheck success |
| 03 | 38667227951 (`1a10119c7`) | success | pass |
| 04 | 38635003388 (`b402b6bbf`) | failure: wui e2e 4/5 only | **pass**: iac job success |
| 05 | 38638301087 (`d416a09f8`) | failure: iac + orc hermetic 1/2 and 2/2 | **RED, its own**: `gcp-s3-download-all.func.sh: line 2: /opt/csi/csi-spl/...: No such file or directory` |
| 06 | 38644583637 (`049bc0840`) | failure: iac | **not reached**: the iac job died in `do_setup_tf_mirror` on row 05's line before any test; first run that ran them: 38650784059 (`6535dd26d`) success |
| 07 | 38646594107 (`90046e28c`) | failure: iac | not reached, as 06; 38650784059 success |
| 08 | 38673156507 (`6a72ccb0b`) | success | pass |
| 09 | 38656455019 (`a3a54c0a5`) | success | pass |
| 10 | 38652321901 (`0e918d4b9`) | success | pass |

**Row 05 red:** `d416a09f8` (landed 21:08Z with no review line) put
`source "/opt/csi/csi-spl/csi-spl-iac/lib/bash/funcs/gcp-temp-sdk-config.func.sh" || exit 1`
in 5 `run/*.func.sh` files. `./run` sources every `func.sh`, so every iac
action exited 1 on a host without that clone: the iac suite and the
shellcheck/deps/trufflehog scanners went red. The pre-push gate passed on sat
because the path exists there. m-135 asked twice for `SPL_PREPUSH_OVERRIDE`
(refused), its 2nd fix copied the same box path into the test, and after 2
tries a claude takeover (c-145) landed `6535dd26d` at 22:51Z: **1 h 43 min**
of trunk red, during which rows 06 and 07 landed with their iac tests never
run in CI.

<a id="ws-doc-de9b49f0-e8e2-451f-a48b-14186fe6fb1a"></a>
## 4. What it did not reduce, and new findings

- **3 CLOUDSDK files left:** `gcp-import-to-cloudsql`, `gcp-project-delete`,
  `gcp-sync-src-s3-to-tgt-s3-silent` (the grep in section 1). Left in round
  10 by the 10-row cap.
- **The isolated-config scan is blind to the helper form** (found by c-139,
  22:04Z): of the 23 files that call `spl_gcp_temp_sdk_config || return 1`,
  **11** are scanned by part 3 of `gcp-actions-isolated-config.tst.sh` (it
  only looks at `run/gcp-*.func.sh` and 2 lib helpers that run `gcloud auth
  activate`/`login` themselves); in the other 12, deleting the call keeps the
  test green (12 corrected from 13 by the round 11 mistral seat, `7342fa401`:
  the first count left out the scanned lib helper `gcp-project-apis`).
  Measured with a loop over `git grep -l '^\s*spl_gcp_temp_sdk_config || return 1' -- src/bash/run lib/bash/funcs`
  in `csi-spl-iac`, counting files whose activation count is non-zero.
- **No test refuses a box-absolute `source`:** the row 05 red was caught by
  CI, not before the push.
  `git grep -nE '^\s*(source|\.) +"?/opt/' origin/master -- 'csi-spl-iac/src/bash/run/' 'csi-spl-orc/src/bash/run/' 'csi-spl-iac/lib/' 'csi-spl-orc/lib/' | wc -l` -> 0 today.
- **Review lines are not checkable:** a `ran:` field is free text. Nothing
  ties it to a run; rows 03 (twice), 09 and 10 carried claims no session
  showed, and a typed 40-char sha (`1a10119c785333…3`) passed the eye of
  the lane before the dispatcher's `git rev-parse`. Row 10's gate checks
  only that a line exists, with `[0-9a-f]{7,40}`.
- **The pre-push hook has no review-line check:** a hand `git push` skips
  row 10's gate
  (`git grep -n -i review origin/master -- csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push | wc -l` -> 0).
- **bash LONG ceilings to lower** (2 NOTEs from `bash-cleancode.tst.sh`):
  `do_gcp_002_delete_project_service_account` 132 under 133, `do_tf_init`
  93 under 95.
- **Coverage:** `cmd/spool` still has 19 functions at 0.0 %: `hub.go` 12,
  `key.go` 4, `hub_repo_edit.go` 2 (`repoEdit`, `nonEmpty`), `main.go` 1.
  `repoEdit` returns nil on 3 guards before it needs Postgres
  (`hub_repo_edit.go:27-40`).
- **WUI LONG left:** `channel.ts <anon>` 576, `notification.ts <anon>` 430,
  `live.ts setup` 304, `createLiveClient` 499, `createSpoolClient` 545.

<a id="ws-doc-e516feea-4ddf-4088-a978-06234a551e6d"></a>
## 5. Branches (R8 steps 1-2)

`cd csi-spl-orc && ROUND="5,6,7,10" DRY_RUN=1 ./run -a do_git_prune_round_branches`
on `eb1d01ae1`: **18 listed, 10 kept unlanded**. Round 10: the 10
`review/r10-NN` branches and `wip/m-524-r10-mistral-review` listed (their
tips are landed); kept: `wip/fix/r10-05-helper-path` (2 unlanded: m-135's
fix attempts, superseded by `6535dd26d`) and
`wip/m-524-r10-mistral-review-seat` (1 unlanded). Older: `review/r5-02` (1),
`review/r7-05*` (4 branches) and 3 r7 `wip/` tips kept; 6 `review/r6-*` and
`wip/m-689-r5-panel-mistral` listed. C7 (section 2) ran first; the round 10
prune (`ROUND=10 DRY_RUN=0`) runs after this retro lands, and its output goes
to the orchestrator with the kept list.

<a id="ws-doc-f4ce10ce-cab0-4313-bffb-e2bd13891c6e"></a>
## 6. What worked, what to change

- **Worked:** 10 of 10 rows landed in 6 h 1 min (20:45Z to 02:46Z), none
  reverted, C7 10 of 10, every review line cross-vendor. The dispatcher's
  "landed = reviewed" check (`git diff <reviewed> <landed>` per file) and its
  journal reads caught every bad line before an ACCEPT.
- **Change 1:** a review line must point to the run it claims, so anyone
  can check it in a minute (section 7, input 1).
- **Change 2:** a refactor that adds a `source` line runs its tests from a
  tree without `/opt/csi/csi-spl` (the CI shape), or a test refuses the
  absolute path (input 3).
- **Change 3:** R14 held: the one mistral row (05) caused the round's only
  red and needed a claude takeover after 2 tries; mistral review seats were
  the round's weak link (4 of 9 lines unbacked or void). Keep mistral off
  bash DRY rows; give mistral reviewers the checkable format first.

<a id="ws-doc-d6358d96-3306-4191-aced-7d469c5f9d81"></a>
## 7. Round 11 inputs

1. **Proposal (R7 checkable):** the review line gains a `log:` field: the
   path of the reviewer's own session journal that holds the run, on the
   reviewer's box (`log: <id>@<box>:<path>`). The `ran:` field names only
   commands found in that file, and the cited sha is pasted from
   `git rev-parse`, never typed. Two parts: `do_spl_push_master` refuses a
   row line whose sha does not resolve to a commit or that has no `log:`
   field; a named action, run by the dispatcher on the reviewer's box, checks
   that every `ran:` test file appears as a command in the `log:` file. The
   rulebook's 2.7.4 line format changes with it.
2. **Test gap:** extend part 3 of `gcp-actions-isolated-config.tst.sh` to
   every helper caller (12 blind of 23).
3. **Gate gap:** a static test refusing a box-absolute `source`/`.` line in
   `run/` and `lib/` bash (the row 05 red).
4. **Gate gap:** the pre-push hook runs the same review-line check as
   `do_spl_push_master` (a hand push skips it).
5. **DRY:** the last 3 CLOUDSDK files.
6. **Small functions (WUI):** `live.ts setup` 304, then `notification.ts`
   430 (they share the LONG map file: two batches).
7. **Small functions (bash):** `do_tf_init` 93, and lower the
   `do_gcp_002_delete_project_service_account` ceiling to 132.
8. **Tests:** `repoEdit`'s 3 early returns and `nonEmpty` with no Postgres.
9. **Not a row:** the round 10 prune (section 5), then the kept list to the
   orchestrator.

<a id="ws-doc-5f135cfc-3a5d-4cf3-9f17-86b6cbc0f3c8"></a>
## 8. Commands

```bash
git log origin/master -E --grep='r10-[0-9]{2}' --format='%h %cI %s'
git log origin/master -E --grep='r10-[0-9]{2}' --format=%B | grep -c '^review: '
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 120 --json databaseId,headSha,conclusion,createdAt
gh run view <run> --json jobs --jq '.jobs[]|select(.conclusion=="failure")|.name'
cd csi-spl-orc && ROUND="5,6,7,10" DRY_RUN=1 ./run -a do_git_prune_round_branches
cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out
bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh
git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' origin/master -- csi-spl-iac | wc -l
```
