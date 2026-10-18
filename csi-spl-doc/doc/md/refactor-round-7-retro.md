# Refactoring round 7 - retrospective

> Generated from qto doc `8682460e-ab22-4701-ab22-b33b9e3978d0`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Measured 2026-10-11 between 07:05Z and 07:45Z on trunk **`2a6b1401a`** (CI re-read at 07:30Z on `3f0949fbd`). Doc only. Each count names the command that produced it; n is that count, n=1 per command unless stated. This is R8 of `refactor-round-7-plan.md`; its section 6 is the input list for round 8. Times are UTC (commit times converted from `+03:00`). As in the plan, the boxes are `sat` and `PC`.

Plan: `csi-spl-doc/doc/md/refactor-round-7-plan.md`, baseline trunk `b161a015b`, signed `6cf5d67cd` (3 seats), fold with the SIGNED line `faba74cb1` (committed 23:15:57Z on 10-10), 10 actions.

<a id="ws-doc-6a894a31-a52a-43b5-afa2-d94d55c92a05"></a>
## 1. What landed

`git log origin/master --grep='r7-' --format='%h %cI %s'` -> **15** commits: 1 plan draft (`6cf5d67cd`), 2 seat files (`30453a19a` agy, `0b7eb4b69` mistral), 1 fold (`faba74cb1`), 11 action commits.

| action | commit(s) on `origin/master` | n | held on `2a6b1401a`? (command -> result) |
|---|---|---|---|
| 01 `test(r7-01-wui-fetch-signal-scan)` | `13ed6850a` (m-946's commit, landed by c-966), `00be0cbab` (the missing imports) | 2 | **yes, by text.** `grep -cE "walk\|readdirSync\|await fetch" csi-spl-wui/tests/unit/fetch-timeouts.test.mjs` -> 8. WUI unit tests not run here (no `node_modules` in the worktree); CI: `wui: unit tests + typecheck` success in run 38107027693 (section 3). Served: `SHA=ad7216f58 ENV=<env> ./run -a do_check_deploy_lag` -> dev and prd WUI `served=462bc14f`, a descendant of both commits |
| 02 `ci(r7-02-gate-first-red)` | `fbb1a8a3c` | 1 | **yes.** `bash csi-spl-iac/src/bash/tests/report-ci-gate.tst.sh` -> rc 0; `CI_GATE_RUNS=70 ./run -a do_report_ci_gate` prints the `first red per JOB` and `last green` sections (used in section 3) |
| 03 `test(r7-03-strip-resize-settle)` | `e5d773f7e` | 1 | **yes.** `grep -nE '^\s*sleep [0-9]' spool-strip-resize-proof.sh` -> 0 lines; `bash test-strip-resize.sh` on `sat` -> rc 0. CI: section 3, 12 of 12 feature-test jobs pass it |
| 04 `test(r7-04-go-coverage-hubclient)` | `16940ef59` | 1 | **yes.** `go test -count=1 -cover ./internal/hubclient/` -> 83.2 % (plan 51.9); `go-coverage-floor.txt:25` -> `internal/hubclient 83.1` |
| 05 `refactor(r7-05-bash-cron-checkout-helper)` | `ae6991bf4` (c-955); test fixes `0423e6cb5` (m-793) and `bea56984e` | 3 | **yes, after 2 test fixes.** `bash spl-desk-cron-checkout.tst.sh` -> `ALL PASS`, n=3 (plain, under `trap "" PIPE`, under `timeout 60`). Its case 5 was red on CI: section 4.5 |
| 06 `refactor(r7-06-bash-cron-checkout-rest)` | `66032c5e1` | 1 | **yes.** `git grep -n 'worktree add -q --detach "$src" "origin/$trunk"' -- '*.sh' \| grep -v /tests/ \| wc -l` -> 1, the helper (plan: 9) |
| 07 `refactor(r7-07-bash-small-functions-iac)` | `cf109ec3e` | 1 | **yes.** `grep -cE 'do_check_weekly_full_scan\|do_gcp_backup_env\|spl_dispatch_setup_steps\|do_spl_responder_run' bash-cleancode.tst.sh` -> 0; `bash bash-cleancode.tst.sh` -> rc 0 |
| 08 `refactor(r7-08-bash-small-functions-orc)` | `a429f5430` | 1 | **yes.** The same grep and run (07 and 08 share the file) |
| 09 `refactor(r7-09-wui-small-functions)` | `ad7216f58` (c-977, the respawn) | 1 | **yes.** `grep -cE 'useLive.ts useLive\|live-ws.mjs handle\|useMentionPicker' cleancode.test.mjs` -> 0; `live-ws.mjs` 756 lines, `grep -cE 'function timedReconnect\|timedReconnect = '` -> 1. Served on dev and prd (`do_check_deploy_lag`, both `served=462bc14f`) |
| 10 `test(r7-10-go-coverage-spool-cli)` | `1499dda91` | 1 | **yes.** `go test -count=1 -cover ./cmd/spool/` -> 50.9 % (plan 26.8); floor line 8 -> `cmd/spool 50.9` |

10 of 10 actions landed and held. 2 rows took a later commit: 01 (the imports, found by the landing lane before the push) and 05 (two CI-only test fixes, about 6 h after landing). Bash rows on `sat`: `git -C /opt/csi/csi-spl merge-base --is-ancestor <sha> HEAD` -> rc 0 for `fbb1a8a3c`, `e5d773f7e`, `ae6991bf4`, `66032c5e1`, `cf109ec3e`, `a429f5430`, `bea56984e` (n=7). The `PC` checkout was not re-measured here.

<a id="ws-doc-19641da0-6211-4026-9413-500414c3e4cd"></a>
## 2. Lanes

Lane and spawn time from the spawn-replies and lane results in the hub's `messages` table (`do_spl_db_query`, `body ~ 'spawn-reply'`) and `sat`'s spool; land = committer time of the row's first action commit. Where the first lane failed a row has two spawn times: the row's first spawn, and the lane that landed it.

| action | lane(s), first -> landing | kind | box | first spawn | landing spawn | land | first spawn -> land (min) | landing lane (min) |
|---|---|---|---|---|---|---|---|---|
| 01 | m-946 (mistral) -> c-966 | simple_coding | PC | 23:23:51Z | 02:10:30Z | 02:34:49Z | 191 | 24 |
| 02 | c-944 | complex_coding | PC (plan: `sat`) | 23:20:05Z | | 23:48:07Z | 28 | 28 |
| 03 | c-945 | tests | PC (plan: `sat`) | 23:21:05Z | | 23:30:34Z | 9 | 9 |
| 04 | c-948 | tests | PC | 23:23:51Z (report time) | | 23:46:07Z | 22 | 22 |
| 05 | m-950 (mistral) -> c-955 | simple_coding | PC (plan: `sat`) | 23:23:02Z | 00:19:11Z | 00:23:29Z | 60 | 4 |
| 06 | c-964 | simple_coding | PC (plan: `sat`) | 01:29:06Z | | 01:48:10Z | 19 | 19 |
| 07 | c-949 | secret | PC (plan: `sat`) | 23:22:04Z | | 23:29:59Z | 8 | 8 |
| 08 | c-956 | secret | PC (plan: `sat`) | 00:20:08Z | | 00:29:17Z | 9 | 9 |
| 09 | m-947 (mistral) -> c-977 | simple_coding | PC | 23:23:51Z | 05:35:58Z | 05:51:37Z | 388 | 16 |
| 10 | c-957 | tests | PC | 00:21:07Z | | 00:37:31Z | 16 | 16 |

Landed: **10 claude, 0 mistral, 0 agy, 0 grok.** Placed: 13 row lanes, 3 of them mistral; **0 of 3 mistral lanes landed** (section 4.2). Landing lane, n=10: min 4, median 16, max 28. SIGNED (23:15:57Z) to the last row landed (05:51:37Z): **6 h 36 min**; without row 09, 3 h 19 min (round 6: about 14 h).

All 13 lanes ran on `PC`. The plan put 6 rows on `sat`; `sat`'s spawn requests were served on `PC` by the box pick (c-001@sat 00:21:42Z: "box pick placed all three on" the other box). The times above come from `PC`'s clock (commits, spawn-replies). Three landings are fast enough to re-check: 05 (4 min from spawn to land, review included), 07 (8 min) and 03 (9 min). The review branches agree: `review/r7-07` `fa3684df0` committed 23:25:33Z, `review/r7-05-c955` `18a2e21b3` 00:22:18Z.

**R10, placement.** Batch 2 rows were placed 50 min (08, after 07), 35 min (10, after 04) and 66 min (06, after 05) after their dependency landed. A failed first lane was re-placed after 16 min (05: m-950 retired 00:02:56Z, c-955 00:19:11Z), about 2 h (01: m-946 stalled from its 00:10:43Z blocker; its own "SESSION TERMINATING" at 02:00:34Z, c-966 02:10:30Z) and about 5 h 16 min (09: m-947 idle since about 00:17Z with 11 unread messages, seen at c-001@PC's 05:33:38Z sweep, c-977 05:35:58Z). `PC`'s uplink was degraded 01:50Z-05:20Z (c-001@PC 05:37:06Z), which covers most of 09's gap. The hourly check did not see a stalled lane: it looks for a commit or a live lane, and m-947 was a live lane with no progress.

<a id="ws-doc-9dae8c33-4c75-4ef9-98b3-90affd1a2f1c"></a>
## 3. CI

`gh run list --workflow 10_ci-quality.yml --branch master -L 1000 --created '>=2026-10-10T23:15:00Z'` (07:12Z) -> **62** runs: 50 cancelled, **10 failure, 0 success**, 2 not finished. The last green wf 10 on master is still run 38024914899 on `63c82bbb4`, 2026-10-10T04:41Z (`--status success -L 5`). Rounds 6 and 7 both ran with no green trunk gate.

`CI_GATE_RUNS=70 ./run -a do_report_ci_gate` (row 02's new section) over the 13 failed runs it found, first red per job: **iac 9**, orc hermetic 1/2 3, orc hermetic 2/2 3, orc feature 3, wui nuxt generate 2, wui e2e 3/3 1, wui e2e 1/3 1. The per-job section of the same report reads orc hermetic 12 + 12, hub 10, iac 9: the fail-fast stops row 02 set out to separate. **3 of the 13 runs are branch dispatches, not master** (38099188187 `c-954-perf-proof`, 38103331704 `c-783-ci-proof`, 38115081399 `c-972-iac-stale-tree-shallow`; `gh run view <id> --json headBranch,event`): `report-ci-gate.func.sh:36` calls `gh run list` with no `--branch`. Its `last green` line for 6 jobs names 38115081399, a branch run.

**R11, per row**: the first completed (not cancelled) master wf 10 run whose head contains the row's sha (`git merge-base --is-ancestor <row sha> <head>` over the 10 completed runs), and whether the job that runs the row's tests reached them.

| action | R11 run (head, completed) | first red (`red in this run:`, per failed job log) | the row's tests in that run |
|---|---|---|---|
| 02, 03, 04, 05, 07, 08, 10 | 38099075488 (`1499dda91`, 01:45Z) | iac (4 bash tests timed out; c-002 01:47:37Z) | 03: `orc: feature tests` success, `test-strip-resize.sh: 8 passed, 0 failed`. 04, 10: the hub job ran `go test` before its stop: `hubclient` ok 83.1 %, `cmd/spool` ok 50.9 %, both floors `ok`. 02, 07: their job **is** iac, red, not from these rows; iac first green on master in 38118720855 (06:52Z), about 7 h after they landed. 05, 08: orc hermetic stopped by fail-fast |
| 06 | 38105201815 (`e2a663fe6`, 03:09Z) | iac (stale-tree case 9 SKIP; c-964) | orc hermetic stopped |
| 01 | 38107027693 (`456687a4e`, 03:45Z) | iac | `wui: unit tests + typecheck` success, e2e 3/3 success |
| 09 | 38118720855 (`0423e6cb5`, 06:52Z) | orc feature tests (`test-spool-harness.sh`: `CLE-3 announced on box-a`); also `wui: nuxt generate` `FAIL ci_initial_gzip_kb 155.1 > 155` | `wui: unit tests + typecheck` success. The budget red is spec 109's `1db5fe64b`, not row 09: c-977 measured `1db5fe64b~1` 154.7, `1db5fe64b` 155.1, master with `ad7216f58` reverted 155.1 (runner node 20.20.2, n=1 per tree) |

So the verdict R11 asks for exists for 7 rows (01, 02, 03, 04, 07, 09, 10; 02 and 07 only from 06:52Z) and is missing for **3 (05, 06, 08)**: in all 10 completed master runs, `spl-desk-cron-checkout.tst.sh` (row 05's own test) appears in **0 of 20** orc hermetic job logs (10 runs x 2 shards, `gh api .../jobs/<id>/logs | grep -c spl-desk-cron-checkout`). The two runs that did reach it were branch dispatches, and both show the red: `FAIL: 5. exit/trap` in 38103331704 and 38115081399 (n=2 of 2).

`test-strip-resize.sh`, row 03's target, over every feature-test job of the 12 failed wf 10 runs since 23:30Z (master and branch): **12 of 12 pass** (plan: 7 of 20 failed jobs carried its red). Other feature-test reds in the same 12: `test-strip-two-envs.sh` 2 cases in 1 job (38119329018), the vibe-close case 1 in 1 job (38119329018), the harness `CLE-3` in 1 job (38118720855). Each n=1.

<a id="ws-doc-2d358cde-6e59-4015-9e87-8e1d04eb7c64"></a>
## 4. What the round taught

<a id="ws-doc-6c671633-203f-4ac6-97c4-9ae2beb83f2d"></a>
### 4.1 R7 held: 10 of 10 rows had a cross-vendor PASS before the push

`git log origin/master --grep='r7-' --format=%B | grep -c '^review: '` -> **11** (01 carries one per commit); `... | grep '^review: ' | grep -c 'same vendor'` -> **0**. Every line names `a-943@PC agy PASS`. Every landing lane was claude, so every line crosses vendors (round 6: 0 of 10 before the push). R13 held in the review lines: 11 of 11 name the box.

C7 (reviewed sha = pushed sha for the row's files), `git diff <reviewed> <landed> -- <the landed commit's files> | grep -c '^[-+][^-+]'`: **0 for 6 rows** (01 for both commits, 03, 05, 07, 09). For 4 rows the reviewed sha is not in a fresh clone (`git cat-file -e`): 02 `cd3e0c9b3`, 06 `a922a0bdc`, 08 `6b6d94b91`, 10 `e5388540e`. 04's line names no sha and no message. Those 5 cannot be re-checked after the round.

**What the reviews caught and missed.** a-943 sent a FIX that changed a row twice: 02 (`FIX C1`, scope) and 09 (m-947: "3 copies of each handler", c-001@PC 05:33:38Z). It passed 2 diffs that were broken:

- 01 `7841bea52` (msg e283c14d, PASS): 5 files use `HUB_READ_TIMEOUT_MS` / `HUB_WRITE_TIMEOUT_MS` with no import; `pnpm run test:unit` red on 2 cases (`00be0cbab` body). The landing lane c-966 found it.
- 05 `0b0a12b8b` (m-950): the test only, the helper it sources never written. c-002 found it and withdrew the PASS (00:00:36Z).

The PASSes came fast. From the review branch commit to the landed commit: 05 1.2 min, 03 2.4 min, 09 3.4 min, 07 4.4 min (n=4). In those windows the reviewer had no time to run the row's test column (R7 C4), and nothing in the line says it did.

<a id="ws-doc-d954454d-757a-4b8b-bf74-ac3e3859ecb0"></a>
### 4.2 The mistral lanes landed 0 of 3 code rows

Each of the 3 cost its row hours, and each needed an orchestrator to close it and save the work on a `wip/` ref:

- **m-946 (01)**: blocked twice on lane-map exit 4 from other lanes' empty rows (23:25:18Z, 00:10:43Z), then could not push its review branch ("stuck pre-push gate") and ended its own session at 02:00:34Z. Its commit `7841bea52` lacked the imports (4.1).
- **m-950 (05)**: committed only the test (`0b0a12b8b`, +113), asked twice for `SPL_PREPUSH_OVERRIDE=1`, and left c-002's reject unread in its inbox (c-002 00:01:04Z). Retired 00:02:56Z.
- **m-947 (09)**: `git show origin/wip/m-947-r7-09:csi-spl-wui/src/utils/live-ws.mjs | grep -cE 'function timedReconnect|timedReconnect = '` -> **2**, `wc -l` -> **933** (master 756); the commit is +609/-224 over 4 files, and the worktree held uncommitted `package.json` and `pnpm-lock.yaml` changes. Idle from about 00:17Z with 11 unread messages.

The lane mix sends `simple_coding` to mistral; in this round that was 3 of the 4 `simple_coding` rows (01, 05, 09; 06 was placed on claude after 05's loop).

<a id="ws-doc-d6f16a65-a7d7-4ec2-aa89-346a34bb04c2"></a>
### 4.3 A review seat wrote code, and its report cited a sha not on master

a-943, a review-only seat, made its own attempt at row 05 while m-950 held it. `git log origin/master..origin/review/r7-05-clean` -> `cfddfd607` (23:30:00Z, `refactor(r7-05...): extract repeated checkout block`) and `f036f58e0` (23:48:37Z, an SC2034 suppression in the row's test). They are not on master (`git merge-base --is-ancestor cfddfd607 origin/master` -> 1), but they are **on origin**: `git ls-remote origin 'refs/heads/review/r7-05*'` -> 5 branches (`review/r7-05`, `-c955`, `-clean`, `-final`, `-squashed`), 4 of them built on `cfddfd607`. a-943's 10/10 report cited `f036f58e0` (c-001@PC 73c7f367). Nothing of it reached master: row 05 is c-955's `ae6991bf4`, a different helper (`git diff --stat cfddfd607 ae6991bf4 -- <helper> <test>` -> 2 files, +86/-126). A seat that edits code and reviews the row it edited is the conflict R7 exists to prevent.

<a id="ws-doc-36ab0f5c-8229-47b4-9383-3ac2d8155810"></a>
### 4.4 R11 found no verdict for the orc rows, and the trunk gate stayed red

Section 3. The rule works for rows whose tests run in a job that runs to the end, or that runs them before its stop (hub's `go test`, WUI unit). It gives no verdict for rows whose tests sit late in a job that fail-fast stops: in 10 of 10 completed master runs, the orc hermetic shards stopped before `spl-desk-cron-checkout.tst.sh`. Row 05's CI-only red was therefore visible only in 2 branch dispatches, and it stayed on trunk from 00:23Z to the fixes at 06:38Z and 07:02Z. The trunk reds that stopped those shards were not round-7 code: iac test timeouts and the stale-tree case 9 SKIP (9 first reds), then the WUI budget (`1db5fe64b`) and the feature-test flakes.

<a id="ws-doc-357999d2-581d-4da3-8ac8-b28b730a9ad4"></a>
### 4.5 Row 05's test: green locally, red on CI

`0423e6cb5` (06:38Z): case 5 compared `trap -p` after the call against an empty list, and a CI runner inherits a signal trap (c-846 06:34:22Z, the SIGPIPE case; c-964 03:19:42Z saw `trap -- '' SIGTSTP` under `timeout`). The fix captures `trap -p` before and after. `bea56984e` (07:02Z) is a 1-line follow-up (`rc=$?` before the echo). c-964 had reported the trap behaviour at 03:19:42Z ("Info only"), 3 h 19 min before the fix; nobody placed it, because no master run had shown it red (4.4).

<a id="ws-doc-b73cf6ae-ecfe-4b1f-a1df-48d27a115239"></a>
### 4.6 What went right

- 10 of 10 rows landed and hold (section 1); 7 of 10 landed within 2 h 15 min of SIGNED (round 6: 8 of 10 in 55 min, the other 2 after 14 h).
- R7: every row had a cross-vendor PASS before its push, and the review lines are uniform (4.1).
- Row 03 removed the most frequent feature-test red: 12 of 12 jobs pass it since (section 3).
- Row 02's first-red section gives the per-run cause in one command; this retro used it for section 3.
- Row 05's red control and row 06's A/B (30/30 `cmp SAME`, c-964) proved the DRY rows kept behaviour.

<a id="ws-doc-189eff61-f3fe-402a-87f8-d49e69c2c536"></a>
## 5. Rework, stalls, re-seats

- Re-seats: 3, all mistral to claude (01, 05, 09), section 2.
- Rework that took another commit: 01 (imports, before the push), 05 (2 test fixes after landing). n=2 of 10.
- Stalls: 09 about 5 h 16 min with a stalled live lane, 01 about 2 h, 05 about 1 h (section 2); `PC`'s uplink 01:50Z-05:20Z.
- Seats after the round: a-943 exited at 07:03:36Z on its ACCEPTED, before this retro read its lines (R8 says after). The mistral seat m-781@sat reviewed nothing (its outbox holds one message, the signature at 23:14:16Z) and is still up; so is the planner c-776@sat (`tmux list-windows`, 07:2xZ). This retro has read the review lines: both can close.
- Left on origin: `git ls-remote origin 'refs/heads/review/r7-*' 'refs/heads/wip/*r7*'` -> **15** branches.

<a id="ws-doc-96bb3651-137b-400c-896d-742810dd9a58"></a>
## 6. Round 8

Each one is a rule, a gate or an action. The owner names who changes it.

1. **Rule.** A mistral lane on a code row gets a progress check at 30 minutes (a commit on its branch or a message), and is re-placed on claude at its first override request or first loop, not hours later. Or the lane mix sends `simple_coding` refactor rows to claude until a mistral lane lands one. Owner: the orchestrator and the lane-mix owner. Measure: 0 of 3 mistral lanes landed; first spawn to land 191, 60 and 388 min against a landing-lane median of 16 (section 2, 4.2), n=3.
2. **Rule.** A review seat never commits code: its lane-map row is its seat file only, and a commit or branch push from a seat outside that file is a stop. A report cites a sha only after `git-fetch-fresh.sh --landed` holds for it. Owner: the spawn lane (seat brief) and the orchestrator. Measure: a-943's `cfddfd607` and `f036f58e0` on 4 of 5 `review/r7-05*` branches, `f036f58e0` cited in its 10/10 report (4.3), n=1.
3. **Rule.** A review line names the reviewed sha, and the review branch stays on origin until the retro has run C7; the retro lane then deletes the round's `review/` and `wip/` branches. A PASS says which of the row's tests the reviewer ran, or whose output it read (C4). Owner: the round-8 planner (R7.4). Measure: C7 re-checkable for 6 of 10 rows; 2 PASSes on broken diffs; PASS within 1.2-4.4 min, n=4 (4.1); 15 branches left (5).
4. **Gate.** A row's CI verdict reaches its tests: either the orc hermetic shards run before fail-fast can stop them, or a scheduled run with fail-fast off tests the newest master head once an hour. Measure first (`lesson-speed-up-measure-first.md`). Owner: the CI lane, a round-8 action. Measure: `spl-desk-cron-checkout.tst.sh` in 0 of 20 master hermetic job logs; rows 05, 06, 08 with no verdict (section 3, 4.4).
5. **Action.** `do_report_ci_gate` reports master only (`--branch master`, or a column that names the branch), so a branch dispatch is never read as a trunk red or a trunk last-green. Owner: a round-8 CI row. Measure: 3 of 13 failed runs in the report were branch dispatches; 6 `last green` lines name branch run 38115081399 (section 3).
6. **Action, only if still red when round 8 is measured.** The WUI initial-JS budget: `FAIL ci_initial_gzip_kb 155.1 > 155` is still red on master in the newest completed run, 38120064586 (head `bea56984e`, completed 07:27Z; job `wui: nuxt generate`, `FAIL ci_initial_gzip_kb 155.1 > 155`), as in 38119329018 before it, and `git log 1db5fe64b..origin/master -- csi-spl-wui/src/plugins/ csi-spl-wui/src/utils/read-sync.mjs csi-spl-wui/src/utils/sidebar-tabs.mjs` -> 0 commits. c-001 sent it to c-790 at 07:01:01Z; if c-790's fix lands first, drop the row. Measure: c-977's perf-budget, 154.7 -> 155.1 at `1db5fe64b`, n=1 per tree (section 3).
7. **Rule.** R8 seat order: the reviewer seats close after the retro, the planner closes them, and a seat that reviewed nothing is closed when the last row lands. Owner: the orchestrator. Measure: a-943 exited before the retro; m-781 reviewed 0 rows and is still up (5).
8. **Flake watch, no lane yet** (R11.3, third sighting): `test-strip-two-envs.sh` (2 cases, n=1; it still sleeps a fixed 1 s before its captures, row 03's practice not applied there: `grep -nE '^sleep|; sleep' test-strip-two-envs.sh`), the vibe-close case 1 (n=1), the harness `CLE-3 announced on box-a` (n=1, c-001 watching). Owner: the orchestrator.
9. **Carry-over actions** (r7 plan section 8): the `cmd/spool/hub.go` server wiring (needs Postgres), the big Pinia setup stores and client factories, the next bash LONG entries (`spawn_main` 185, `do_gcp_import_to_cloudsql` 175, `do_provision_firebase_dns` 169), shfmt and prettier.

<a id="ws-doc-db0c6a80-def2-4898-af02-19b0a12a7062"></a>
## 7. Commands

Re-run from a checkout of `origin/master`.

```text
git log origin/master --grep='r7-' --format='%h %cI %s'
git log origin/master --grep='r7-' --format=%B | grep -c '^review: '
git diff <reviewed sha> <landed sha> -- $(git show --name-only --format= <landed sha>)
git ls-remote origin 'refs/heads/review/r7-*' 'refs/heads/wip/*r7*'
gh run list --workflow 10_ci-quality.yml --branch master -L 1000 --created '>=2026-10-10T23:15:00Z'
gh run view <run> --json jobs,headBranch,event
gh api repos/csitea/csi-spl/actions/jobs/<job>/logs | grep -o 'red in this run: .*'
```

CI by job: `cd csi-spl-iac && CI_GATE_RUNS=70 ./run -a do_report_ci_gate`. Served: `cd csi-spl-orc && SHA=<sha> ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd`. Spawn and lane messages: `cd csi-spl-orc && ENV=prd SQL="select ts, from_id, left(body,200) from messages where body ~ 'spawn-reply' and ts >= '2026-10-10 23:15'" ./run -a do_spl_db_query`. Lane stamps: `registry.retired.tsv` on the box that spawned the lane.
