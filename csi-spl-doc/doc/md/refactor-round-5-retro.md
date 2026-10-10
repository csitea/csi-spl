# Refactoring round 5 - retrospective

Measured 2026-10-10 between 05:50Z and 06:30Z on trunk **`da36dad94`**. Doc only. Each count names the command that produced it; n is that count, n=1 per command unless stated. This is R8 of `refactor-round-5-plan.md`; its section 6 is the input list for round 6.

Plan: `csi-spl-doc/doc/md/refactor-round-5-plan.md`, baseline trunk `d5d136053`, consensus `49e21c570` (3 seats signed), 10 actions.

## 1. What landed

`git log origin/master --grep='r5-' --format='%h %cI %s'` -> **17** commits: 1 seat proposal (`fb933b786`), 14 action commits, 2 trunk repairs whose message names r5.

| action | commit(s) on `origin/master` | n | held on `da36dad94`? (command -> result) |
|---|---|---|---|
| 01 `r5-01-wui-dead-code` | `70e1eb26b` | 1 | **yes.** `ls csi-spl-wui/src/utils/verbosity.mjs` -> no such file; `grep -rlw useLiveStore csi-spl-wui/src csi-spl-wui/tests \| wc -l` -> 0; the same for `perfCollector` -> 0; `grep -rn 'i18n/i18n.config.ts' csi-spl-wui/nuxt.config.ts csi-spl-wui/src/node/i18n/split-catalogue.mjs \| wc -l` -> 0. The 3 remaining `verbosity` hits name the `verbosity-notify-v1.md` contract or the r5-01 note in `util-docs.test.mjs`, not the module |
| 02 `r5-02-go-dead-code` | `8bb97690e`, then `d4fa39b61` (restore), `e071eeb96` (test fix) | 3 | **yes, after two repairs.** `grep -rn 'func (s \*Session) Lost' csi-spl-api \| wc -l` -> 0; `func DumpJSON` outside `_test.go` -> 0; `^func Send(` outside `_test.go` in `internal/action` -> 0. Section 4.1 and 4.2 |
| 03 `r5-03-bash-dead-code` | `023aa1b0f` | 1 | **yes.** `tf-apply-local-step-bucket.func.sh` -> gone; `grep -ln '^ *# *do_backup_region_dynamo_db_tables' csi-spl-iac/src/bash/run/*.sh \| wc -l` -> 0; `grep -rlw do_load_pat --include=*.sh . \| wc -l` -> 0; `grep -cE 'SC2034.*(gcp-sync-s3-to-local\|gcp-sync-local-to-s3\|resolve-oap)' .shellcheck-warning-baseline.txt` -> 0 |
| 04 `r5-04-bash-db-connect-helper` | `6794a7fe6` | 1 | **yes.** `grep -ln 'cfg=$(mktemp -d)' csi-spl-orc/src/bash/run/*.func.sh \| wc -l` -> 0; each of the 5 sites calls `spl_db_require_bins` / `spl_db_query_rc` from `csi-spl-orc/lib/bash/funcs/spl-db-connect.func.sh` (`grep -cE` -> 3 per site, 5 of 5) |
| 05 `ci(r5-05-baseline-down)` | `1065b5878` | 1 | **yes.** `grep -ln 'sec-baseline.func.sh\|sec_baseline' csi-spl-iac/src/bash/run/sec-*.func.sh` -> the 4 gates; `.shellcheck-warning-baseline.txt` 126 lines |
| 06 `ci(r5-06-long-ceiling)` | `2744226c8` | 1 | **yes.** `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> rc 0, its controls `a listed function at its ceiling passes` / `under its ceiling prints the NOTE` PASS. WUI: 20 `[name, ceiling]` pairs in `cleancode.test.mjs:35-54`; wf 10 `wui: unit tests + typecheck` success on `63c82bbb4` (run 38024914899). Not run locally: the worktree has no `node_modules` |
| 07 `ci(r5-07-prepush-orc)` | `672ad2598`, `a9498ac7d` (iac full-tier budget 600 s) | 2 | **yes.** `grep -n 'local all=' csi-spl-iac/src/bash/run/check-pre-push.func.sh` -> `:821 local all="hygiene blog iac orc wui-vendor wui api"` |
| 08 `ci(r5-08-e2e-verdict)` | `05b5919f4` | 1 | **yes.** wf 10 run 38015971127 (head `20f37ba42`, 02:10Z): orc red (ORC-2, `spl-lane-mix.tst.sh`) and the e2e shards still ended with their own verdicts (1/3 and 3/3 failure, 2/3 success). Before 08, a hub or orc red killed them (plan section 2: 55 of 56 e2e ends were kills) |
| 09 `ci(r5-09-format-python)` | `13e9219f9` (format), `9fefb364d` (lint-py), `a4767dd65`, `8e3a55bdd` (its test: env, timeout) | 4 | **yes.** `git ls-files '*.py' \| xargs ruff format --no-cache --check` -> `54 files already formatted` |
| 10 `ci(r5-10-go-coverage-floor)` | `45f3c1da2` | 1 | **yes.** `csi-spl-api/src/bash/tests/go-coverage-floor.txt` (48 lines, 42 packages); `grep -c coverprofile csi-spl-api/src/bash/tests/run-all-tests.sh` -> 3; `go test -cover` on 4 low packages reads their floor: `cmd/spool` 26.8, `internal/action` 30.2 (floor 30.3, inside the 1.0 tolerance), `internal/files` 32.9, `internal/edge` 38.2 |

10 of 10 actions landed and held. Every action commit is an ancestor of `63c82bbb4` (`git merge-base --is-ancestor 1065b5878 63c82bbb4` -> 0), the head of the last green wf 10 run (38024914899, every job success).

**R5, served.** `SHA=<sha> ENV=<env> ./run -a do_check_deploy_lag` (orc): `70e1eb26b` (01) and `e071eeb96` (02, its last hub commit) on dev and prd -> `the env serves this commit or a later one` for hub (served `c52eed56`) and WUI (served `63c82bbb`), n=4. Bash and CI actions: the `sat` checkout `/opt/csi/csi-spl` HEAD `63c82bbb4` contains `1065b5878` (the last of them). The `PC` checkout was proved by c-002 for 04 (msg to c-699, 00:49Z); not re-measured here.

## 2. Lanes

Lane and box from the spool mail (each lane's result or review request names its row) and `registry.retired.tsv` on `sat`. Spawn is the registry stamp (`sat` lanes only; the `PC` registry is not readable from `sat`). Land is the committer time of the row's last r5 commit, in UTC.

| action | lane | kind | box | spawn | land | min |
|---|---|---|---|---|---|---|
| 01 | c-742 (after g-738) | claude | PC | ~23:57Z | 00:29:20Z | ~32 |
| 02 | m-702 | mistral | sat | 23:50:08Z | 01:06:54Z (+ repairs by c-001 01:10Z, c-744@PC 01:26Z) | 77 |
| 03 | c-703 | claude | sat | 23:55:30Z | 00:19:44Z | 24 |
| 04 | c-699 | claude | sat | 23:50:00Z | 00:26:12Z | 36 |
| 05 | c-705 | claude | sat | 00:35:44Z | 02:37:08Z | 121 |
| 06 | c-743 (after g-739) | claude | PC | 23:57:07Z (spawn-reply) | 00:30:35Z | 33 |
| 07 | c-698 | claude | sat | 23:49:55Z | 01:13:22Z | 83 |
| 08 | c-740 | claude | PC | not read | 00:45:19Z | - |
| 09 | c-704 | claude | sat | 23:55:33Z | 01:29:30Z | 94 |
| 10 | c-741 | claude | PC | not read | 00:59:11Z | - |

The plan placed 4 rows on grok (01, 03, 06, 09) and 1 on mistral (02). Landed: **9 claude, 1 mistral, 0 grok**. All 4 grok lanes spawned for the wave were dead on arrival on the weekly limit: g-700 and g-701 on `sat` (registry: spawned 23:50:06Z, retired 23:55:00Z), g-738 and g-739 on `PC` (c-002 blocker 23:54:44Z: `You hit your weekly limit`). Their rows were re-placed on claude within 1..7 minutes.

Spawn to land, n=8 with a known spawn: min 24, median 55, max 121 (05, which waited for 03 by design and then for an ORC-2 trunk red, c-705 blocker 02:36:57Z).

## 3. CI

`gh run list --workflow 10_ci-quality.yml --branch master -L 100 --created '>=2026-10-09T23:40:00Z'`, runs created before 05:00Z: **39** = 33 cancelled, 3 failure, 2 success, 1 running.

| failure head | run | is it an r5 commit? | what was red |
|---|---|---|---|
| `fc17e2cb6` | 38010676622 | no | wui e2e 2/3 `tests/e2e/roadmap.test.mjs` (c-742 routed it, 01:40Z) |
| `20f37ba42` | 38015971127 | no | orc ORC-2 `spl-lane-mix.tst.sh`, fixed by `30d1b0e6f` (c-751) |
| `892f26545` | 38021028676 | no | not an r5 path |

0 of 3 failure heads is an r5 commit. 33 of 39 cancelled: 16 r5 commits plus the feature lanes landed within about 3 hours, and each push cancels the previous head's run.

The red r5 DID cause never reached a wf 10 verdict on its own head: `8bb97690e`'s run (38011894493) was cancelled by the next push. It was caught by a lane (c-698 blocker 01:10:56Z) and by the orchestrator's diff against the reviewed sha, not by CI. Section 4.1.

## 4. What the round taught

### 4.1 A stale-tree push reverted 26 landed paths

`8bb97690e` (r5-02, m-702) changed **33** files; its row names 4 sites plus `_test.go` files. The other 26 were set back to blobs they held before recent commits by other lanes. Measured with a detector that, per touched path, walks the last 40 commits that touched it and asks whether the new blob equals the blob before one of them (and not the parent's): on `8bb97690e` -> **26 of 33** paths. c-001 STOPPED m-702 (01:10:00Z) and landed `d4fa39b61` (01:13Z), which restores those 26 paths and keeps the 7 the row owns. Reviewed sha `81e7d849f` vs pushed `8bb97690e`: different trees; the R7 reviewer had checked the former.

The same detector over the last **300** non-merge commits on `origin/master` (2m 59s): 10 commits restore at least one path; **2** restore 3 or more: `8bb97690e` (26) and its repair `d4fa39b61` (26). Every other hit is 1 path and names its restore in the subject (`back to <sha>^`, `Revert "..."`). So a threshold of 3 paths separates the clobber from deliberate restores in n=300.

### 4.2 Moving an export to `_test.go` broke another package's test

r5-02 moved `action.Send` into `internal/action/action_helpers_test.go`. A `_test.go` file is visible only to its own package's tests, and `internal/hub/fleet_send_test.go` called `action.Send`. The hub test went red; `e071eeb96` (c-744@PC) switched it to `action.SendCtx`. The plan's test column (R2) listed `fleet_send_test.go` but the lane did not run the `internal/hub` package. R2 maps tests by the site's name, not by cross-package callers of what moves.

### 4.3 R7 peer review ran, but not across vendors

`git log origin/master --grep='r5-' --format=%B | grep -c '^review: '` -> **12** lines over 10 actions: 9 of 10 actions carry one (all but 02). **0** of the 12 is a cross-vendor review: every reviewer is a claude lane, and every line says why (`grok out of quota`, `m-702 gave no answer in 15 min`, `m-702 busy`). The one action with no review line is the one by the only non-claude lane, and it is the one that clobbered trunk. The non-claude reviewer pool was one lane that was also a row author and was stuck in one command for 50+ minutes (c-001 to c-699, 00:43Z).

### 4.4 Gate tests leaked the caller's environment

Rows 07 and 09 needed follow-up commits for their own tests, not for the product: `a9498ac7d` (07: the iac part needed its own full-tier budget, 600 s), `a4767dd65` (09: `check-pre-push-lint.tst.sh` went red under an inherited `PRE_PUSH_TIER=full`), `8e3a55bdd` (09: a 300 s test timeout). 3 of 14 action commits are a gate lane fixing its own test after the first push.

### 4.5 Briefs carried a machine-parsed site list that was short

c-001 at 23:56:41Z to all r5 lanes: the brief's file list "was machine-parsed from the plan row and may be SHORT. It drops globs such as tf-*". c-703 asked (23:56:24Z) about 8 files its brief omitted; they were row 03's own sites.

### 4.6 One id named two lanes

c-703 was both the r5-03 lane on `sat` and a spec 109 lane on `PC` until 23:58:20Z (c-001@PC, 23:59:14Z). Messages for one could reach the other for about 3 minutes.

## 5. Rework, stalls, re-seats

- Re-seats: 4 grok lanes, all on the quota (section 2); rows 01 and 06 re-placed on claude in about 3 minutes, 03 and 09 on `sat` in about 5.
- Rework that took another commit: 02 (2 repair commits by other lanes), 07 (1), 09 (2). n=3 of 10 actions.
- Stalls: 05 waited by design for 03 (batch 2), then on the ORC-2 trunk red (c-705 blocker 02:36:57Z, c-751 placed 02:38:19Z). R7 waits: c-740 waited 40 minutes for m-702 before the orchestrator assigned a claude reviewer (00:41Z, 00:43Z).

## 6. Round 6

Each one is a rule, a gate or an action. The owner names who changes it.

1. **Gate.** Pre-push refuses a commit that sets 3 or more paths back to a blob they held before one of their last 40 commits, unless its subject says it restores (`Revert`, `restore`). Owner: the pre-push gate (round 6 action). Cost: section 4.1, 26 paths of other lanes' work on trunk for about 3 minutes and a STOP.
2. **Rule.** R7 names each row's reviewer in the plan, from another vendor than the row's lane, with one named backup; the panel's non-claude seats are the first reviewers (they are not row authors). A same-vendor review is allowed only after the named backup has not answered in 15 minutes, and the line says so. Owner: the round-6 planner. Cost: section 4.3, 0 of 12 cross-vendor.
3. **Rule.** R2 adds cross-package callers: when an exported name moves into a `_test.go` or is deleted, the test column carries every package where `grep -rn '<pkg>\.<Name>\b' --include=*_test.go` hits. Owner: the round-6 planner. Cost: section 4.2.
4. **Rule.** A gate lane runs its own test once under `PRE_PUSH_TIER=full` and once from a shell with no inherited `PRE_PUSH_*` variables before the first push. Owner: each gate row's brief. Cost: section 4.4, 3 follow-up commits.
5. **Rule.** A row brief carries its plan row verbatim (the table row and its section-4 bullet), never a parse. Owner: the orchestrator. Cost: section 4.5.
6. **Rule.** Before a wave, the spawner checks each vendor's live state (`do_spl_lane_mix` with its kind; it already skips a vendor with a fresh S2 limit verdict) and reads the new pane 2 minutes after spawn. Owner: the spawner. Cost: section 2, 4 of 4 grok lanes dead on arrival before any verdict existed.
7. **Carry-over actions** (r5 plan section 7 D3, D4, section 8): the WUI `fetch` calls with no `signal`, the function-level `exit 1` in two sourced iac actions, the shellcheck scope gap on `csi-spl-api` and `csi-spl-wui` `.sh`, the next Go coverage packages (`internal/action`, `internal/files`, `internal/edge` under 40%), and the DRY groups left out (cron "drop tagged line", probe scaffold).

## 7. Commands

Re-run from a checkout of `origin/master`.

```text
git log origin/master --grep='r5-' --format='%h %cI %s'
git log origin/master --grep='r5-' --format=%B | grep -c '^review: '
git show --stat --format= <sha>
git merge-base --is-ancestor <sha> <head>
gh run list --workflow 10_ci-quality.yml --branch master -L 100 --created '>=2026-10-09T23:40:00Z'
gh run view <run> --json jobs
```

Served: `cd csi-spl-orc && SHA=<sha> ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd`. Lane stamps: `registry.retired.tsv` on the box that spawned the lane. Lane-to-row: the lane's result mail or review request in the spool.

The stale-tree detector of section 4.1, per commit `c` (bash, run in the checkout):

```text
for p in $(git show --name-only --format= $c); do
  new=$(git rev-parse -q --verify $c:$p) || continue
  par=$(git rev-parse -q --verify $c^:$p) || continue
  for h in $(git log --format=%h -n 40 $c^ -- "$p"); do
    b=$(git rev-parse -q --verify $h^:$p) || continue
    [ "$b" = "$new" ] && [ "$b" != "$par" ] && { echo "$p"; break; }
  done
done | wc -l
```
