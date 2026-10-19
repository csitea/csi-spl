# Test round 2: claude seat verdict on plan v0.1

Seat: **c-487@sat** (claude). Plan: [test-round-2-plan.md](../test-round-2-plan.md)
v0.1 (`f7e038464`). Rules: [rounds-rulebook.md](../rounds-rulebook.md).
Task: `dispatch-4555450c`. Issue: SPL-2559 (epic SPL-2402).

**Tree:** every repo command ran on `b7fad2def` (`origin/master`,
2026-10-19 ~14:20Z). None of the plan's sites changed between `59ffb5dd3` and
`b7fad2def`, apart from the A6 fix itself (row 08).
**Box:** sat, 16 cores, load average 9-15 during the runs. Local runs went
one at a time, never in parallel with each other, between 14:19Z and 14:45Z, as
`sudo -u <DEV_USER> env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 SPOOL_NOW=2026-10-01T00:00:00Z bash <test>`
and bash `time`. **CI:** wf 10 master runs 39263949281 (`0abb8eb05`),
39259601111 (`59ffb5dd3`), 39242128622 (`f82adb508`) and 39240464295
(`8f2dbb83e`). For the per-file numbers I read the "every file (wall s)" and
"slowest 10 (wall s, cpu s)" blocks of the three orc hermetic job logs of each
run (n=4).

## 1. Summary

**0 agree / 4 agree with changes / 8 disagree / 2 proposals.**

The plan's two measuring methods produced most of the disagreements:

1. **"Idle = (CI wall - CI cpu) / CI wall" is not sleep.** The orc CI runner
   has `nproc=4` (job log line "runner-cpus nproc=4") and runs
   `ORC_TEST_JOBS=6` files at once
   (`csi-spl-orc/src/bash/tests/run-all-tests.sh:85`, "njobs=6" when
   `GITHUB_ACTIONS=true`), next to Postgres files that use more than one core
   (`desk-rebox-pg` 237.7 s cpu in 175.2 s wall). Wall time beyond cpu is
   mostly time spent waiting for a core. Run alone, all five "idle" files of
   rows 01, 05, 09 and 12 use as much cpu as wall (table 2.1). They are
   cpu-bound, not sleeping.
2. **"0 tests" came from grepping the file name in `tests/`.** Tests import
   these modules through re-exports, call them by function name, or test the
   pure module behind a composable. Rows 03, 07, 10 and 11 are already
   covered, and row 04's package is 89.1% covered from its parent package.

### 2.1 Solo vs CI timings (the speed rows)

| file | CI wall s (n=4 runs) | CI cpu s | solo wall s (sat, n=3) | solo cpu s (user+sys) | `grep -c sleep` test / action |
|---|---|---|---|---|---|
| `peer-poll.tst.sh` | 367 / 361 / 336 / 360 | 143-167 | 174.1 / 172.5 / 168.6 | 197 / 191 / 190 | 2 / 2 |
| `desk-up-all.tst.sh` | **42** / 165 / 152 / 165 | 42-47 | 42.8 / 43.5 / 42.9 | 44 / 45 / 44 | 7 / 0 |
| `desk-welcome.tst.sh` | **21** / 96 / 86 / 101 | 20-23 | 21.0 / 23.5 / 25.8 | 22 / 25 / 25 | 0 / 0 |
| `desk-pin.tst.sh` | 82 / 98 / 105 / 112 | 28-30 | 29.1 / 28.0 / 27.4 | 29 / 29 / 28 | 0 / 0 |
| `spool-install.tst.sh` | 71 / 93 / 78 / 93 | 48-62 | 59.6 / 62.5 / 61.2 | 62 / 64 / 63 | (wrapper) |

The bold cells are run 39263949281, where `desk-up-all` and `desk-welcome`
ran in shard 1/3 instead of 3/3. It is the same code as `59ffb5dd3` for
these files (`git log 59ffb5dd3..0abb8eb05` touches none of them), and they
took 42 s and 21 s, already under the plan's targets. Every solo run passed
(37, 98, 31, 50 and 111 PASS, 0 FAIL).

## 2. Verdict per row

| # | verdict | measured reason (command -> number) |
|---|---|---|
| 01 peer-poll | **agree with changes** | It is the slowest orc file and worth a row, but the cost is cpu, not idle: solo 168.6-174.1 s wall at 190-197 s cpu (n=3). The test already runs on a virtual clock (`LEASE_NOW`, hub stub `peer-poll.tst.sh:54`). "Mock clock / event-driven polling" will not move it. **Change:** the practice becomes "cut forks": the python hub stub runs once per hub call, section 2 loops `seq 0 19` (`:300`) and section 3 runs `seq 0 11` rounds twice (`:334`, `:345`). Target: solo cpu < 100 s (n=3), same box and method before and after. Red control: unchanged. |
| 02 tf-destroy tests | **agree with changes** | Still 0 tests (`git grep -lw -e tf-destroy-target -e do_tf_destroy_target -- csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/tests` -> 0, the same for `tf-destroy-local-step-bucket`). But neither action has a dry run (`grep -c DRY_RUN` -> 0 and 0), so "asserting dry-run default" and the red control "inverting DRY_RUN guard" fail on today's code with no code change. Round 1 row 08 hit the same gap (spin-off SPL-2270). **Change:** split it into (a) a code commit that adds `DRY_RUN` (default 1) and (b) the test, or test only what exists: `STEP`/`TARGET` refusal (`${STEP:?}`, `${TARGET:?}`), the `-target=` per comma item, and the `-lock=false` it passes today. **Safety:** the test must stub `do_tf_init` AND put a fake `terraform` first on `PATH`; on a box holding `~/.gcp/.csi/key-csi-spl-*.json`, a missed stub is a real targeted destroy. |
| 03 msg-apply unit | **disagree** | Already tested. The file's only export, `applyEdit` (`grep -n ^export src/utils/msg-apply.mjs` -> 1, line 28), is called 9 times in `tests/unit/msg-edit-wire.test.mjs` (through the re-export `msg-edit.mjs:293`, which the test imports at `:30`), plus `feed-rows-shallow` (3) and `view-api` (1). The file is 39 lines, not 1-150, and it does no insertion, dedup or sorting (it replaces in place, `:21` "never re-sorts"). The grep found 0 only because it searched the file name. |
| 04 fakeidp coverage | **disagree** | Not a real gap. `go test -count=1 -cover ./internal/auth/fakeidp/` -> 3.5% (n=3), but `go test -count=1 -coverpkg=./internal/auth/fakeidp/ ./internal/auth/` -> **89.1%** of fakeidp's statements (n=1): the auth flow tests (`flow_test.go`, `oidc_flow_test.go`, ...) drive it. A `fakeidp_test.go` would duplicate them to satisfy a per-package counter. The floor is at `go-coverage-floor.txt:23`, not `:18`. If the floor must move, proposal 2 below is the cheaper fix. |
| 05 desk-up-all | **disagree** | Target already met. Solo 42.8 / 43.5 / 42.9 s wall at 44-45 s cpu (n=3), and 42 s CI wall in shard 1/3 (run 39263949281). The 7 `sleep` lines are fake `hub-run` background processes that get killed (`:340`, `:408-410`, `:468`), plus one `sleep 0.2` (`:412`), not wait loops. 165 s happens only in the packed shard 3/3. |
| 06 tf-state/step tests | **agree with changes** | 0 tests for all 3 (same grep -> 0), 0 `DRY_RUN` in all 3: the same change as row 02. Also, `tf-remove-step` is not a state action. It runs `sleep 5` then `rm -rv src/terraform/${step}*` relative to the cwd (`tf-remove-step.func.sh:8-12`), so its test must `cd` into a sandbox copy, or a bad `STEP` deletes the lane's own tree. `tf-state-push` passes `-lock=false` to `state push` (`:23`), and the test should pin that it does so. |
| 07 tenant-host-core unit | **disagree** | Already tested: `tests/unit/tenant-host.test.mjs` imports `pageTenant`, `isTenantHostOf` and `siteHostOf` through `tenant-host.mjs:17` (the re-export), with 16 + 11 + 2 call sites. `node --test --experimental-test-coverage tests/unit/tenant-host.test.mjs` (node 20.19.2, sat) -> `tenant-host-core.mjs` **96.92% lines, 84.38% branches**, uncovered lines 56-57 only. The file is 65 lines, not 1-120. |
| 08 message-order A6 | **disagree** | Not a flake, and fixed. A6 was a real regression from `dedf3e9bb` (SPL-2506, 11:18Z), fixed by `59ffb5dd3` (13:17Z, its body says "the unread opener moved to the bottom edge"). All 10 A6 failures fall between the two (`git merge-base --is-ancestor` for every wf 10 run in the last 30). Completed runs since the fix: 39259601111, 39262008084 and 39263949281 succeeded, and 39264153837 failed on `calendar.test.mjs` AC-02 and `close-pane-key.test.mjs`, not A6 (n=4, 0 A6). "0 flakes in 20 runs" would only re-prove the fix. The two new reds belong to their feature lanes, not to this round. |
| 09 desk-welcome + desk-pin | **disagree** | No sleeps at all: `grep -c sleep` in both tests and both actions -> 0. Solo 21.0-25.8 s and 27.4-29.1 s wall at the same cpu (n=3), already under the "< 40 s" target, and desk-welcome took 21 s in CI shard 1/3. The "70-76% idle" is time spent queued for a core in shard 3/3. |
| 10 gcp apis disable tests | **disagree** | Already tested: `csi-spl-iac/src/bash/tests/gcp-tf-shared-bodies.tst.sh:22` lists `project-apis-disable` and `modify-project-apis-disable`, and `:101-113` runs `do_gcp_project_apis_disable` and `do_gcp_modify_project_apis_disable` against a stubbed gcloud, asserting the 11 APIs, `--project csi-spl-dev --account=stub-sa@...` and no login or config write. A verb CONTROL is at `:118-119`. Ran it 3× -> rc 0, 63 PASS, 0.84-0.93 s. The plan's grep missed it because the test builds the names (`do_gcp_${a//-/_}`). |
| 11 composables unit | **disagree** | The logic is in pure modules that already have tests: `useBuildWatch.ts` (32 lines) imports `utils/build-watch.mjs` (`tests/unit/build-watch.test.mjs`, 152 lines), `useOpenMessage.ts` (73) types against `utils/open-message.mjs` (`open-message.test.mjs`, 335), and `useRoadmapGoals.ts` (83) wraps `utils/roadmap-goals.mjs` (`roadmap-goals.test.mjs`, 126). What remains is Pinia and Nuxt glue (`~/stores/*`, `useSpoolApi`), which the plain-node runner cannot import: no unit test imports a `.ts` composable today (`git grep -lE "from '\.\./\.\./src/composables/" -- tests/unit` -> 3 files, all importing `.mjs` modules). Building a Nuxt test harness is its own spec, not one row. |
| 12 spool-install | **agree with changes** | The site is wrong: `csi-spl-orc/src/bash/tests/spool-install.tst.sh` is a 4-line `exec` wrapper, and the work is in `csi-spl-orc/src/bash/features/spool-install/tests/test-install.sh`. It is cpu-bound, not idle: solo 59.6-62.5 s wall at 62-64 s cpu (n=3, 111 PASS). **Change:** the site becomes `test-install.sh`, the practice becomes "cut forks / reuse one install fixture", and the target becomes solo cpu < 35 s (n=3). Low yield: rank it last. |

### 3. The checks the brief asks for

- **R1 disjoint files:** holds as written. I compared every site path across
  the four rows of each batch: no path repeats within a batch.
  `orc-shard-weights.txt` is kept out of every row.
- **Speed rows, before/after the same way, n>=3:** not met. Rows 01, 05, 09
  and 12 state one CI wall number each (n=1, run 39259601111) and a CI-wall
  target. CI wall for the same code varies 4× with shard placement (desk-up-all
  42 vs 165 s), so a before/after on CI wall cannot show a change. Use
  **solo cpu, n=3, same box** before and after (table 2.1 is the "before").
- **Row 08 vs `59ffb5dd3`:** not needed (row 08 above).
- **Coverage targets:** row 04's "> 70%" is already 89.1% from the parent
  package. Rows 03, 07 and 11 aim at code that is already covered.
- **prd / GCP mutation:** no row needs one. Rows 02 and 06 become a risk
  only if their stubs leak (the `terraform` and `do_tf_init` stub
  requirement in row 02).

## 4. Proposals (things the plan missed)

### 4.1 P1: right-size the orc CI pool to the runner, then refresh the weights

- **Measured:** the runner has `nproc=4`, and `run-all-tests.sh:85` runs 6
  files at once on CI. The same unchanged files take 4× longer in a packed
  shard: desk-up-all 42 s (shard 1/3) vs 152-165 s (3/3), desk-welcome 21 vs
  86-101 s (table 2.1, n=4 runs). Job wall per shard: 510-679 s (runs
  39263949281, 39259601111, 39242128622). `orc-shard-weights.txt` is from
  the 2-shard era (header: runs 38159252847..38207328805, 2026-10-11/12)
  and has drifted: `spl-session-prune 243` is measured at 21 s in all 4
  runs, and `desk-actions 366` reads 46-47 s in the same 4 runs (after round 1 row 07).
- **Row:** derive `njobs` on CI from `nproc` (plus a test of the
  derivation), refresh `orc-shard-weights.txt` from the "every file" block,
  and measure the three shard job walls on a throwaway branch
  (`gh workflow run 10_ci-quality.yml --ref <branch>`, n=3) against the same
  three on master. One lane, files `run-all-tests.sh` +
  `orc-shard-weights.txt` + its test. It replaces the plan's
  "refresh weights post-Batch 3" note and fits any batch, since no other row
  touches these files.

### 4.2 P2: measure "untested" with a coverage report, not a file-name grep

- **Measured:** the grep method reported 0 for 4 targets that are covered:
  `tenant-host-core.mjs` 96.92% lines (`node --test
  --experimental-test-coverage`, node 20 = the CI node, `10_ci-quality.yml`
  "node-version: 20"), `internal/auth/fakeidp` 89.1% (`-coverpkg`), the 2
  gcp-apis-disable actions (63 PASS suite), and `applyEdit` (9 calls).
- **Row:** add a `-coverpkg` (or merged-profile) mode to the Go floor
  check and a per-file node coverage listing for `csi-spl-wui/src/utils/*.mjs`.
  The next round then picks its "0 tests" targets from that list. The input
  is measured on sat here without `node_modules` only for tests that import
  no package (`msg-edit-wire.test.mjs` needs `vue`): a CI run or a
  `pnpm install --frozen-lockfile` worktree gives the full list.

## 5. Signature

signed: c-487@sat on c80e765756afff89d1aa257af200f9f0b01221b6

The v1.0 plan as refined in `c80e76575` fixes every blocker in sections 6
and 7 (section 8 shows the checks).

## 6. Review of v1.0 (`b784c1a98`)

**Folded correctly:** rows 01 (cpu target, solo, n=3), 02 and 06 (`DRY_RUN`
code commit, terraform and `do_tf_init` stubs, sandbox cwd, pinning
`-lock=false`), 03 (P1), 04 (P2, `-coverpkg`), 12 (site `test-install.sh`)
and dropping A6.

**Blocking:** the six new rows 05 and 07-11 come from the file-name grep that
section 4.2 (P2) warned about, and 5 of the 6 are fully or partly done.
Measured on `origin/master` after `b784c1a98`, with
`grep -rlE -e <name> -e <name_with_underscores>` over
`csi-spl-{orc,iac,api}/src/bash/tests` and every
`csi-spl-orc/src/bash/features/*/tests`. (A wildcard git pathspec such as
`features/*/tests` matches no file inside that directory and reads 0, which
is a trap for whoever re-measures.)

| row | actions said to have 0 tests | already tested by | left |
|---|---|---|---|
| 05 | identity-reconcile, name-resume | both actions are wrappers: `spawn-agents/tests/test-agent-identity-reconcile.sh` (209 lines, sources `lib/agent-identity.inc.sh`), and `test-agent-name-shape.sh` section 5 runs `agent-name-resume.sh` (`:56-74`) | the two 25-27 line `do_` wrappers only: drop the row |
| 07 | msg-edit-probe, wire-probe, desk-live-proof | `csi-spl-orc/src/bash/tests/desk-live-proof.tst.sh` (195 lines, with a RED CONTROL) covers `spl_desk_live_*` | msg-edit-probe and wire-probe |
| 08 | lb-list, list-cloudsql, list-firewall-rules, list-static-dns-addresses | `csi-spl-iac/src/bash/tests/gcp-tf-shared-bodies.tst.sh:21` (`LISTS=(cloudsql ... firewall-rules ... static-dns-addresses ...)`) runs all three against a stubbed gcloud and checks `--account` | `gcp-compute-lb-list` only |
| 09 | vibe-output-cap-install, vibe-push-guard-install, vibe-loop-cost | the install actions wrap spool-install steps Y15 and Y12 (`spl-vibe-push-guard-install.func.sh:22`), which `spool-install/tests/test-y12-vibe-push-guard.sh` and `test-y15-vibe-output-cap.sh` drive, dry run included. `vibe-loop-cost.py` is part 5 of the Y15 test (`:18`, `:29`) | the thin `do_` wrappers only: drop the row |
| 10 | sync-local-to-s3, tail-logs, satellite-image-latest | none found | all 3: keep |
| 11 | lane-age-report, rotate-status, local-hub-status, dispatch-deploy-lag | `spawn-agents/tests/test-lane-age-report.sh` runs `lane-age-report.sh` | rotate-status, local-hub-status, dispatch-deploy-lag |

**Fix:** keep row 10; shrink 07 to msg-edit-probe + wire-probe, 08 to
`gcp-compute-lb-list`, and 11 to its 3 untested actions; drop 05 and 09 (or
replace them with actions the `grep -r` above shows at 0, e.g. merging 07, 08
and 11's leftovers). Each row's "number now" should cite that `grep -r`
command.

## 7. Review of the v1.0 refinement (`d31332fce`)

**Fixed:** rows 07 (msg-edit-probe and wire-probe), 08
(`gcp-compute-lb-list`), 10 and 11 (rotate-status, local-hub-status and
dispatch-deploy-lag) now name only actions with 0 tests, which matches
section 6.

**Still blocking:**

| row | claim | measured on `origin/master` (2026-10-19 ~15:00Z) | fix |
|---|---|---|---|
| 09 | `spl-token-burn-push-env`, `spl-wd-orch-outcome` and `spl-standby-bench-helpers` have 0 tests | `csi-spl-orc/src/bash/tests/wd-orch-outcome.tst.sh` (170 lines) sources `spl-watchdog.func.sh` and drives `spl_wd_orch_outcome`. `csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh` (221 lines) drives `do_spl_standby_bench`, which calls every `_spl_standby_bench_*` helper, through refusals, dry run and the prd opt-in. `grep -rlE 'token.burn.push.env\|token_burn_push_env'` over every test dir -> 0 | keep `spl-token-burn-push-env` only, or add 2 actions the same `grep -r` shows at 0 |
| 05 | `check-pre-push-{baseline,override,timeout-label}.tst.sh` have no red control | the only evidence is the absence of the word "control" (plan 3.7). The three tests already assert their failure paths: override case 1 "duplicate migration prefix -> REFUSED" (`check-pre-push-override.tst.sh:9`), baseline cases 3-4 "still broken -> WARN" and "a part that HANGS -> killed" (`check-pre-push-baseline.tst.sh:9-10`), timeout-label case 3 "TIMED OUT after 1s" (`:9`, `:63`) | state per test which code break no current case catches (planted, and run to show it stays green), or replace the row |

## 8. Review of the second refinement (`c80e76575`)

- **Row 09:** now `spl-token-burn-push-env` only. It has 0 tests: the
  `grep -r` from section 7 over every test dir -> 0.
- **Row 05:** I checked each of the three named gaps against the current
  tests by reading them. I did not plant any of them.
  1. Override with failing hygiene: `check-pre-push-override.tst.sh:37`
     stubs `do_check_dist_hygiene` to always return 0, so no case sees
     hygiene fail under the override.
  2. `TIMED OUT` on a passing part: every case in
     `check-pre-push-timeout-label.tst.sh` (`:7-11`, `:35` "whose suites all
     hang") runs a part that hangs, and none asserts that a passing part
     prints no note.
  3. HEAD unparseable against a clean base: `check-pre-push-baseline.tst.sh`
     has `bad bad _mute_part` (7c, `:96`) but no `good bad _mute_part`
     (`grep -c 'good bad _mute_part'` -> 0).
