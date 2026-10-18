# Refactoring round 6 - retrospective

> Generated from qto doc `7b0cbf18-7bc2-46b9-96d2-d22d246c9360`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Measured 2026-10-10 between 22:15Z and 22:40Z on trunk **`49ce4503d`**. Doc only. Each count names the command that produced it; n is that count, n=1 per command unless stated. This is R8 of `refactor-round-6-plan.md`; its section 6 is the input list for round 7. Times are UTC (commit times converted from `+03:00`).

Plan: `csi-spl-doc/doc/md/refactor-round-6-plan.md`, baseline trunk `da36dad94`, signed `eb8cbfc1c` (3 seats, section 10 at `cf031192c`), 10 actions.

<a id="ws-doc-cd043d2f-5b2a-45d8-8529-ea3ee8acb69e"></a>
## 1. What landed

`git log origin/master --grep='r6-' --format='%h %cI %s'` -> **18** commits: 1 plan draft (`ed453dd77`), 2 seat proposals (`111646392`, `6910f8313`), 2 plan folds (`eb8cbfc1c`, `cf031192c`), 13 action commits.

| action | commit(s) on `origin/master` | n | held on `49ce4503d`? (command -> result) |
|---|---|---|---|
| 01 `r6-01-wui-fetch-signal-hours` | `0c2fc3016` | 1 | **yes.** `grep -c 'signal: AbortSignal.timeout'` -> `hours-timer.mjs` 1, `hours-calendar-api.mjs` 1, `hours-team-api.mjs` 2, `human-status.mjs` 2: the 6 calls of the row |
| 02 `r6-02-wui-fetch-signal-calendar` | `83d9be675` | 1 | **yes.** The same grep -> `calendar-events-api.mjs` 2, `msg-ai-actions.mjs` 1, `release-notes-api.mjs` 1: the 4 calls of the row. A new call with no signal came in after the round: section 4.5 |
| 03 `r6-03-bash-return-not-exit` | `236123d22` | 1 | **yes.** `grep -cE '^\s+exit 1$'` on `gcp-import-to-cloudsql.func.sh` and `gcp-export-dns-settings.func.sh` -> 0, 0; `bash csi-spl-iac/src/bash/tests/return-not-exit-gcp.tst.sh` -> rc 0, `ALL PASS` |
| 04 `ci(r6-04-shellcheck-api-wui)` | `154d46269` (fix the 6), `7b7ef35f0` (scope) | 2 | **yes.** `sec-shellcheck.func.sh:22` `_SEC_SHELLCHECK_TREES` names `csi-spl-api/src` and `csi-spl-wui/src`; `wc -l < .shellcheck-warning-baseline.txt` -> 126 (unchanged from the plan) |
| 05 `ci(r6-05-prepush-stale-tree)` | `6472cc938`, `012432510` (review record + `pre-push-gate.md` row) | 2 | **yes.** `check-pre-push.func.sh:868` `all="hygiene stale-tree ..."`; `bash csi-spl-iac/src/bash/tests/check-pre-push-stale-tree.tst.sh` -> rc 0, `ALL PASS`; over the whole round, `STALE_TREE_RANGE=da36dad94..origin/master ./run -a do_check_pre_push_stale_tree` -> `PASS 334 outgoing commit(s), none sets 3 or more paths back` (30 s) |
| 06 `test(r6-06-go-coverage-raise)` | `6eb06ce68` | 1 | **yes.** `go test -count=1 -cover ./internal/{edge,files,action}/` -> 98.9 / 82.9 / 70.3 % (plan baseline 38.2 / 32.9 / 30.2); floors in `go-coverage-floor.txt` 98.9 / 82.9 / 59.2 |
| 07 `refactor(r6-07-bash-cron-drop-helper)` | `b1bced96b` | 1 | **yes.** `git grep -l 'awk -v suf=" # $tag"' -- '*.sh' \| grep -v /tests/` -> 1 file, the helper `csi-spl-orc/lib/bash/funcs/cron-tagged-line.func.sh` (plan: 5 copies); `cron-tagged-line.tst.sh` -> rc 0, `ALL PASS` |
| 08 `refactor(r6-08-bash-probe-scaffold)` | `8e2e24f8a` | 1 | **yes.** `spl-probe-preamble.func.sh` exists; `grep -c spl_probe` -> 4 in each of the 5 probes; `probe-preamble.tst.sh` -> rc 0 |
| 09 `refactor(r6-09-wui-small-functions)` | `701b8c53b` | 1 | **yes.** `cleancode.test.mjs` LONG list: the 4 entries (`useLive.ts ensure`, `stores/search.ts`, `useTopicRowActions`, `useMessageEdit`) -> gone, 20 -> 16 entries; side effect, the `useLive.ts useLive` ceiling 178 -> 113. WUI unit tests not run here: the worktree has no `node_modules` |
| 10 `refactor(r6-10-bash-small-functions)` | `3334f42e1`, `1a6d18cd4` (the s3 auth step ignores a failed `config set project`, as before) | 2 | **yes.** `grep -nE 'do_gcp_tail_logs\|do_gcp_s3_download_all' csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> 0 lines; `bash-cleancode.tst.sh` -> rc 0 (lane: 117 -> 32 and 130 -> 57 lines) |

10 of 10 actions landed and held. 3 of 10 took a second commit: 04 by the plan's own split, 05 for its review, 10 for a behaviour its reviewer caught (`/var/spool-hub/reports/c-727.md`: "FIX C2 on 387628254, PASS on e7473a19a").

**R5, served.** `SHA=83d9be675 ENV=<env> ./run -a do_check_deploy_lag` (orc), the last WUI row, on dev and prd -> `the env serves this commit or a later one` for hub (served `a3eaf9b3`) and WUI (served `469c5652`), n=2; 01 and 09 are its ancestors. 06 is test-only: nothing to serve. Bash and CI rows: `git -C /opt/csi/csi-spl merge-base --is-ancestor 012432510 HEAD` on `sat` -> rc 0 (HEAD `aaab9179c`). The `PC` checkout was not re-measured here.

<a id="ws-doc-6e03d35e-6150-4bcd-8e37-0d05f173d043"></a>
## 2. Lanes

Lane and box from the spool mail (each lane's result, review line or spawn-reply) and `registry.retired.tsv` on `sat`. Spawn: the `sat` registry stamp, or the `PC` spawn-reply time. Land: committer time of the row's first action commit.

| action | lane | kind | box | spawn | land | min |
|---|---|---|---|---|---|---|
| 01 | c-768@PC (by elimination: the 3 `PC` batch-1 lanes were c-768, c-769, c-771; 06 = c-769, 09 = c-771) | claude | PC | 06:50:13Z | 07:16:43Z | 26 |
| 02 | c-920@PC | claude | PC | 20:36:22Z (placed) | 20:57:12Z | 21 |
| 03 | c-723 | claude | sat | 06:48:59Z | 06:57:16Z | 8 |
| 04 | c-724 | claude | sat | 06:49:03Z | 09:01:46Z | 133 |
| 05 | c-768@sat | claude | sat | 20:50:23Z | 21:07:57Z (review fix 22:10:54Z) | 18 |
| 06 | c-769@PC | claude | PC | 06:51:12Z | 07:12:07Z | 21 |
| 07 | c-725 | claude | sat | 06:49:09Z | 07:24:59Z | 36 |
| 08 | c-726 | claude | sat | 06:49:15Z | 07:12:28Z | 23 |
| 09 | c-771@PC (`c-727.md`: "return review: row 09 ... sent to c-771") | claude | PC | 06:52:17Z | 07:42:09Z | 50 |
| 10 | c-727 | claude | sat | 06:49:21Z | 07:15:02Z | 26 |

Landed: **10 claude, 0 mistral, 0 agy, 0 grok.** Spawn to land, n=10: min 8, median 24.5, max 133 (04: the push race, section 4.4).

Plan signed 06:47Z; 8 rows landed by 07:42Z (55 minutes). **Rows 02 and 05 got no lane for about 14 hours:**

- c-001's 07:06:07Z report: "batch1 placed (8 rows)". Batch 1 has 9 rows; `sat` spawned 5 of its 6 (`registry.retired.tsv`: c-723..c-727, no r6-05 lane). The spool does not say why 05 was left out.
- 02 was batch 2, due "as soon as 01 is on trunk" (plan section 5). 01 landed 07:16:43Z; 02 was placed 20:36:22Z, 13 h 20 min later.
- Neither gap was reported. The owner's "go do it" (t1 4f46ce09 msg 33e3e883, 20:29:59Z) started both. c-002's answer (msg 4a09013e, 20:31:17Z): "Round 6 landed 8 of its 10 rows this morning ... I did not post them here as I promised; sorry." c-002's plan post (msg 3eaff5dd, 06:47:32Z) had said "I post each row here as it lands"; the hub has no post on that topic between 06:47:32Z and 20:29:59Z (`do_spl_db_query` on its `task_id`: 5 rows after 06:30Z).

One id named two lanes again (round 5 section 4.6): **c-768** was r6-01 on `PC` (06:50Z) and r6-05 on `sat` (20:50Z); **c-769** was r6-06 on `PC` and a cost-rollup lane on `sat` (20:52Z). The r6-06 review line `c-768 PASS` means the `PC` one; nothing in the line says which box.

<a id="ws-doc-6255cc2a-ff17-4845-9045-9ebd99505125"></a>
## 3. CI

`gh run list --workflow 10_ci-quality.yml --branch master -L 500 --created '>=2026-10-10T06:45:00Z'` -> **266** runs: 245 cancelled, 19 failure, **0 success**, 2 not finished (`a3eaf9b32` in progress, `2c5f2fa3b` pending). The last green wf 10 on master is run 38024914899 on `63c82bbb4`, 04:41Z, before the round started (`--status success --created '>=2026-10-10T00:00:00Z'` -> 3 runs, the newest 04:41Z). So **no r6 commit has a green trunk gate behind it**, and trunk had no green gate for the whole round.

Per r6 action commit (`gh run list --commit <sha>`, n=13): 11 have a wf 10 run, **11 of 11 cancelled**; 2 (`3334f42e1`, `154d46269`) were pushed under the next commit and have no run of their own. The fast workflows finished: every `15`, `61`, `63`, `64`, `67` and `85` run on an r6 sha reads success, and the WUI deploys (wf 30) succeeded on `0c2fc3016`, `701b8c53b` and `83d9be675`.

The 19 failure heads, by the first red the gate's fail-fast step names (`red in this run:` in a failed job's log; the other failed jobs are its stops). A run can name two or three:

| first red | runs | what |
|---|---|---|
| `wui: nuxt generate` | 8 (11:13Z..12:42Z) | the step "Initial JS gzip stays within the performance budget" (read on `ee78bd1b3`) |
| `orc: hermetic action tests` | 7 | not read |
| `iac` | 4 | test files timed out on the runner (read on 3): `tpl-gen-step-render-parity` (>120 s), `check-pre-push-scope`, `check-pre-push-lint` (>300 s) |
| `hub` | 4 | not read |
| `orc: feature tests` | 3 | `test-tmux-close-window-vibe.sh` (`926c265b0`), `test-spool-harness.sh` (`fc4f47138`), `test-strip-resize.sh` + `test-strip-two-envs.sh` (`7b77a1d44`) |

**0 of 19 failure heads is an r6 commit.** No red was traced to an r6 site.

**The vibe-close case 4.** The brief says CI red n=2. Measured over the 5 failed `orc: feature tests` jobs of the period (`gh api repos/csitea/csi-spl/actions/jobs/<id>/logs | grep -c 'FAIL - 4. control'`): **n=1**, job 114315587597 of run 38086810661 (`926c265b0`). c-001's note to c-768 (22:05:01Z) counts "38086810661 on 926c265b0, and job 114315587597": that job belongs to that run, so the two are one red. `test-strip-resize.sh` is the more frequent feature-test red: it fails in 3 of the 5 jobs (`07d141ee4`, `4f2ff434c`, `7b77a1d44`).

<a id="ws-doc-0f0331a1-a874-43ec-8aed-66b683f95a48"></a>
## 4. What the round taught

<a id="ws-doc-4c4f4557-b7d4-4165-ad17-e823b5e5d9c5"></a>
### 4.1 R7 cross-vendor review held for 0 of 10 rows before the push

`git log origin/master --grep='r6-' --format=%B | grep -c '^review: '` -> **10** lines. They cover **9** of 10 actions: 04 carries one in each of its 2 commits, and **02 carries none** (`git show -s --format=%B 83d9be675 | grep -c '^review: '` -> 0). Of the 10 lines:

- 9 are claude reviewing claude, each saying `(same vendor, panel seats exited)`.
- 1 crossed vendors: `a-937 FIX (C2, C4 commit body) -> fixed in this commit` on `012432510`, row 05. It is a **late** review: 05 landed at 21:07:57Z with no review, c-002 sent it back, and c-768 asked for a reviewer at 22:05:14Z because "the plan's reviewer for a claude lane is agy seat a-763, which is on no lane map; the backup m-710 was retired at 20:49Z". a-937 was placed at 22:06:25Z.

So 0 of 10 rows had a cross-vendor review before its push, the plan's tightened R7 (round 5 retro 6.2). Every line gives the same cause: the panel's agy and mistral seats exited after signing (a-763 no longer answered at 06:43Z, c-711's blocker; m-710 retired 20:49:28Z, `registry.retired.tsv`), and R7 names those seats as the reviewers.

**A count sent to the owner that the history does not support.** c-002's round-6-done post (t1 4f46ce09 msg 134edbfe, 22:11:54Z) says: "all 10 rows of round 6 now carry a cross-vendor review line on master (10 of 10)". The command above gives 1 cross-vendor line, late, and one row with no line. That post needs a correction.

<a id="ws-doc-79fe80b0-d6e3-489c-80fb-1b5f609409f8"></a>
### 4.2 Two rows went unplaced for 14 hours, and nothing noticed

Section 2. 8 of 10 rows landed within 55 minutes of the signature; the other 2 had no lane until the owner asked at 20:29:59Z. R6 ("no hand-kept status", plan section 5) gives the state in one command, but nothing ran it between the last batch-1 result (09:30Z) and 20:30Z: no one owned "are all 10 placed?", and the promised per-row posts were not made.

<a id="ws-doc-0c60fc68-20c3-476a-88a0-a477534d8324"></a>
### 4.3 The trunk gate gave no verdict for the whole round

Section 3: 266 runs, 0 green, 245 cancelled. Round 5 had 33 of 39 cancelled and 2 green; round 6 had none. Every r6 lane relied on its own local runs, and CI could not have caught an r6 regression. The `stale-tree` part (05) now covers the round-5 failure locally, and its replay over the round's 334 commits finds no stale-tree push. c-002 flagged the cancel churn at 07:24:05Z ("the trunk gate has not completed for ~50 min"); it lasted the rest of the day.

<a id="ws-doc-2c9fc21d-8704-4297-9a31-8297a9bb99cd"></a>
### 4.4 A green hook still lost the push race 9 times

r6-04 (c-724 blocker 08:33:51Z): "push to master loses the ref-lock race, 9 of 9 tries (07:25-08:33Z)". The pre-push hook passed every time, but its WUI part re-ran on each new base (~312 s) and trunk moved inside that window. It landed on try 15 at 09:01:46Z, with no override (c-002 09:30:08Z). Spawn to land: 133 minutes, of which about 96 were the race.

<a id="ws-doc-2b65799b-67ab-4062-b6a8-b6105c4a156a"></a>
### 4.5 The fetch-timeout rows fixed a list, not the rule

01 and 02 added one source-scan assertion per named call. A call added after the round has no signal: `csi-spl-wui/src/utils/sign-in-emails.mjs:133` (`git log -S 'await fetch(' -- <file>` -> `54128e731`, 14:34Z, after 01 had landed). The plan's own scan (`grep -rnE "await fetch\(" csi-spl-wui/src/utils/`, then `sed -n "$l,$((l+8))p" | grep -c signal` per hit) -> 20 hits, **1** with no signal; `grep -c sign-in-emails csi-spl-wui/tests/unit/fetch-timeouts.test.mjs` -> 0. Nothing failed.

<a id="ws-doc-311900c3-61c1-4432-a567-30e43c0d5ea7"></a>
### 4.6 What went right

- Every row held (section 1), every lane recorded its red control, and no row needed a repair by another lane (round 5: 02 needed 2).
- The stale-tree part replays the round-5 clobber as REFUSED and passes every commit since the baseline (section 1, row 05).
- The R7 reviews, same-vendor included, caught 2 real items: the s3 auth step's ignored failure in 10 (`1a6d18cd4`) and the missing proof in 05's body (a-937).

<a id="ws-doc-a299668f-f9db-4b55-8749-37344a6b7823"></a>
## 5. Rework, stalls, re-seats

- Re-seats: none. All 10 rows ran on claude.
- Rework that took another commit: 05 (review record), 10 (review FIX C2). n=2 of 10. 04's second commit is the plan's own split.
- Stalls: 02 and 05 unplaced for about 14 h (section 4.2); 04 in the push race for about 96 min (4.4); 05 waited for a reviewer after its push (4.1); c-920 (02) stopped on a lane-map `unknown` (exit 4, 14 live rows with no files; c-920 20:36:27Z) before it could push.

<a id="ws-doc-650f298a-9f31-46e2-905b-6d2bccab2315"></a>
## 6. Round 7

Each one is a rule, a gate or an action. The owner names who changes it.

1. **Rule.** R7 reviewers are seats that stay up until the round is served: the panel's non-claude seats keep running after they sign, or the planner names one review seat per vendor that lives until the last row lands. A row whose named reviewers are gone gets a new cross-vendor seat placed **before** its push, never after. Owner: the round-7 planner, and the orchestrator for placing. Measure: `git log origin/master --grep='r6-' --format=%B | grep '^review: '` -> 10 lines, 9 `same vendor, panel seats exited`, 1 cross-vendor and late, n=10.
2. **Rule.** One placement check per round: after the wave, the orchestrator runs R6 (`git log origin/master --grep='r7-' --format='%h %s'`) against the plan's row list every hour until every row has a lane, and a batch-2 row is placed by whoever sees its dependency land. Owner: the orchestrator. Measure: 2 of 10 rows unplaced for 13 h 20 min (02) and about 14 h (05), section 2, n=10.
3. **Gate.** CI's per-commit verdict survives master churn: either wf 10 stops cancelling a run whose head carries a row subject, or a scheduled run tests the newest head to completion at least once an hour. Owner: the CI lane, a round-7 action. Measure: `gh run list --workflow 10_ci-quality.yml --branch master -L 500 --created '>=2026-10-10T06:45:00Z'` -> 266 runs, 245 cancelled, 19 failure, 0 success; 11 of 11 r6 heads cancelled (section 3).
4. **Action.** The fetch-timeouts test scans every `await fetch(` under `csi-spl-wui/src/utils/` instead of a list, so a new call with no signal fails. First site: `sign-in-emails.mjs:133`. Owner: a round-7 WUI row. Measure: section 4.5, 20 hits, 1 with no signal, 0 tests name it, n=1.
5. **Rule.** A count sent to the owner carries the command that produced it (global CLAUDE.md, "make claims that carry their own check"). Owner: the dispatcher; c-002 corrects msg 134edbfe's "10 of 10 cross-vendor". Measure: section 4.1, 1 of 10.
6. **Flake watch.** `test-tmux-close-window-vibe.sh` case 4: CI red **n=1** in the period (not 2; section 3), local green n=3 (c-001 on `a3eaf9b32`). Below c-001's own threshold of 3; no lane. `test-strip-resize.sh` fails in 3 of the 5 failed feature-test jobs: it is the one at the threshold. Owner: the orchestrator decides the lane. Measure: the `grep` of section 3, per job log, n=5 jobs.
7. **Rule.** A spawn reply and a review line name the box when an id is live on two boxes (`c-768@PC PASS`), or ids stay unique across boxes. Owner: the spawn lane. Measure: c-768 and c-769 each named two lanes in this round (section 2), n=2; round 5 section 4.6, n=1.
8. **Carry-over actions** (r6 plan section 8): `cmd/spool` coverage (26.8 %, 73 functions at 0 %), the 13-copy `CLOUDSDK_CONFIG` preamble, the 9-copy install-cron `SPL_DESK_CRON_CREATE` block, the `gcp-backup-env` and `check-weekly-full-scan` LONG entries (each needs its baseline line), the big Pinia setup stores, shfmt and prettier.

<a id="ws-doc-b54443d8-28bc-48cc-b2ba-d99079999621"></a>
## 7. Commands

Re-run from a checkout of `origin/master`.

```text
git log origin/master --grep='r6-' --format='%h %cI %s'
git log origin/master --grep='r6-' --format=%B | grep -c '^review: '
git show -s --format=%B <sha> | grep '^review: '
gh run list --commit <full sha>
gh run list --workflow 10_ci-quality.yml --branch master -L 500 --created '>=2026-10-10T06:45:00Z'
gh run view <run> --json jobs
gh api repos/csitea/csi-spl/actions/jobs/<job>/logs | grep -o 'red in this run: .*'
```

Served: `cd csi-spl-orc && SHA=<sha> ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd`. Stale-tree replay: `cd csi-spl-iac && STALE_TREE_RANGE=da36dad94..origin/master ./run -a do_check_pre_push_stale_tree`. Owner topic posts: `cd csi-spl-orc && ENV=prd SQL="select ts||' | '||from_id||' | '||left(msg_id::text,8)||' | '||left(body,60) from messages where task_id='<uuid>' order by ts" ./run -a do_spl_db_query`. Lane stamps: `registry.retired.tsv` on the box that spawned the lane.
