# Refactoring round 7 - plan: clean code round 20261011-a (10 actions)

> Generated from qto doc `7791043a-2c81-467b-a96d-40ae4c127b05`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Owner HUM-10, prd t1, topic `4f46ce09-15ee-4b9a-b05f-edd9812b51fb`, msg 3d22fcea: rounds run continuously, **no owner go is needed for this round, its panel or its lanes** (rule home: `SPEC-spool-fleet-roles.md` section 1.2). Requested by the dispatch holder c-002 per round 6 plan R8, once `refactor-round-6-retro.md` was on trunk (`b161a015b`).

**Status: SIGNED.** All three seats signed plan sha **`6cf5d67cd`** (section 10). Batch 1 = 01, 02, 03, 04, 05, 07, 09; batch 2 = 06 after 05, 08 after 07, 10 after 04. The row lanes are spawned by the orchestrator from that sha. The reviewer seats a-943 (on the other box; `sat` has no agy) (agy) and m-781@sat (mistral) stay up until all 10 rows are on trunk (R7.1).

Panel: the claude seat (planner and editor c-776, `sat`; proposal `refactor-round-7/seat-claude.md`), the agy seat a-943 (the other box, `sat` has no agy; `refactor-round-7/seat-agy.md`, `30453a19a`) and the mistral seat m-781@sat (`refactor-round-7/seat-mistral.md`, `0b7eb4b69`), placed by the orchestrator c-001. Inputs: the shape and rules R1-R9 of `refactor-round-6-plan.md`; **`refactor-round-6-retro.md` section 6** (items 1-8); round 6's section 8 (left out).

Every site was measured on ONE trunk sha: **`b161a015b`** (`origin/master`, 2026-10-10T22:40Z), n=1 per count unless stated otherwise. Re-checked on `40af1ecdb` (trunk when this plan was written): `git diff --stat b161a015b 40af1ecdb -- <the 36 paths of section 3>` -> empty, so every line number holds.

<a id="ws-doc-d1e87177-f97e-4b78-94eb-9977abb7c1e0"></a>
## 1. How to read this

- One action = one practice = one lane. The lane applies the practice at the sites named and nowhere else, with a test that proves behaviour did not change, or, for a gate or a test fix, a **red control** that proves the check now fails on the bad input.
- **Paths:** `api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/src/bash/run/`, everything else is from the repo root. Line numbers are as of `b161a015b`.
- **Boxes:** `sat` and `PC`, as in round 6 (`sat` has Chrome and Postgres). `sat` 6, `PC` 4.
- **Agent kind** = a `do_spl_lane_mix` kind, not a vendor: `LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` per row at spawn time. Kinds here: `simple_coding` 4, `tests` 3, `secret` 2, `complex_coding` 1. Round 6 landed 10 of 10 on claude (retro section 2); the mix decides, this plan does not pin a vendor.
- **No new dependency.** 01 and 03 change what a test catches; 02 changes a report; 04 and 10 add tests only; 05-09 are behaviour-preserving.
- **Commit subject** (R6 reads it): `refactor(r7-NN-<slug>): ...` for code, `ci(r7-NN-<slug>): ...` for 02, `test(r7-NN-<slug>): ...` for 01, 03, 04, 10.
- **Off every live lane:** `lane-map.sh --check <the 36 paths> --agent c-776` -> rc 3, one path owned: `test-strip-resize.sh` by c-771@sat (`c-771-spawncore-lanemap`). Row 03 edits the proof script that test runs, not the test; it only READS it. Every other path: free. Re-run per action before its spawn (R3).

<a id="ws-doc-e8cf9abb-9ed7-40c7-9d80-90e9fb27cb35"></a>
## 2. Where the actions come from (measured)

| source | command on `b161a015b` | n | action |
|---|---|---|---|
| retro 6.4: fetch-timeouts fixed a list, not the rule | `grep -rnE "await fetch\(" csi-spl-wui/src/utils/` -> 20; per hit `sed -n "$l,$((l+8))p" \| grep -c signal`; the same over `csi-spl-wui/src` outside `utils/` | utils: 20 calls, **1** with no signal (`sign-in-emails.mjs:133`). Outside utils: 20 calls, 5 with none, of which 1 is a test server (`src/node/test/serve-generated.mjs:74`) and **4** are product calls: `pages/roadmap.vue:100`, `pages/goals/[id].vue:129`, `components/CalendarPhonePeek.vue:214`, `components/ApiDocViewer.vue:218`. Non-`await` `fetch(` forms: 6 hits, read by hand: 3 pass a signal, 2 are inline boot-script strings (`runtime-config.mjs:140`, `early-session-script.mjs:35`), 1 a comment | 01 |
| retro 6.3: no CI verdict for the round | `gh run list -R csitea/csi-spl --workflow 10_ci-quality.yml --branch master -L 1000 --created '>=2026-10-09T00:00:00Z' --json conclusion,createdAt,startedAt,updatedAt` | 06:45Z..22:40Z on 10-10: **271** runs, 251 cancelled, **19 failure, 0 success**, 1 running. The day before (10-09 00:00Z..10-10 06:45Z): 342 runs, 271 cancelled, 59 failure, 12 success. Completed runs, start to end: median 29.1 min (10-10), 18.5 min (10-09) | 02, R11 |
| retro 6.3, why "cancelled" | `.github/workflows/10_ci-quality.yml:103-117` | `cancel-in-progress: false`: a cancel is a **superseded pending** run, by design (gate `gate10-concurrency.tst.sh`). Every started run finished: 19 verdicts in the round, all red. The verdict survived the churn; trunk was red the whole time | R11 |
| retro 6.3, which job | `CI_GATE_REPO=csitea/csi-spl CI_GATE_RUNS=300 ./run -a do_report_ci_gate` (iac) | 24 failed runs; per job 20, 20, 20, 20, 15, 14, 11, 7, 6. **Inflated**: `gate-fail-fast.sh:72` stops every other job of a red run and they conclude `failure` too. The FIRST red per run (retro section 3, read by hand from `red in this run:`): nuxt generate 8, orc hermetic 7, iac 4, hub 4, feature 3 | 02 |
| retro 6.6: `test-strip-resize.sh` flake | for each failed `orc: feature tests` job of `gh run list -L 300 --status failure` (all branches, n=20 jobs, 10-09 02:07Z..10-10 21:30Z): `gh api .../jobs/<id>/logs \| grep 'test-strip-resize.sh:'` | **7 of 20** jobs: `7 passed, 1 failed`, every one the same case: `FAIL - the width case reports it unmoved (missing 'top transcript row: TX-001')`. Local on `sat`: `bash test-strip-resize.sh`, 5 runs -> 5 of 5 pass, 10 s each. The proof sleeps a fixed 1 s, then 1 s or 1.5 s, before `capture-pane` (`spool-strip-resize-proof.sh:110-113, 157-162`): a busy runner had not painted yet | 03 |
| retro 6.8: Go coverage | `go test -count=1 -coverprofile=<tmp> ./<pkg>/` (go1.26.9), then `go tool cover -func \| awk '$3=="0.0%"'` | `internal/hubclient` 51.9 % (55 functions at 0 %: `hubclient.go` 17, `host.go` 5, `flush.go` 5, `edit.go` 5, `backfill.go` 5); `cmd/spool` 26.8 % (73 at 0 %: `hub.go` 36, of which 22 are server wiring that needs Postgres; `main.go` 12, `memory.go` 5, `lifecycle.go` 4, `box_stats.go` 3) | 04, 10 |
| retro 6.8: install-cron DRY | `git grep -n 'worktree add -q --detach "$src" "origin/$trunk"' -- '*.sh' \| grep -v /tests/` | **9 copies** of the 5-line "create the self-updating checkout" block, each with its DRY_RUN twin line (`DRY_RUN would: git worktree add`) 9 lines above | 05, 06 |
| retro 6.8: LONG bash with a baseline line | `bash-cleancode.tst.sh:18-45`, the test's `measure` awk; `grep -c <basename> .shellcheck-warning-baseline.txt` | `do_check_weekly_full_scan` 128 (0 baseline lines for the `.func.sh`; the 1 hit is its `.tst.sh`), `do_gcp_backup_env` 82 (1 line: `SC2034\|gcp-backup-env.func.sh\|1`). Round 6 kept them out because its row 04 owned the baseline; this round no other row touches it | 07 |
| small functions (bash, orc) | the same awk | `spl_dispatch_setup_steps` 86, `do_spl_responder_run` 105; 0 baseline lines each | 08 |
| small functions (WUI) | `wui:tests/unit/cleancode.test.mjs:34-51` (16 LONG entries) | the 3 smallest that are not a Pinia store or a client factory: `useLive.ts useLive` 113, `live-ws.mjs handle` 117, `useMentionPicker.ts useMentionPicker` 130 | 09 |

Kept out by the same measure: section 8.

<a id="ws-doc-ff9e22fd-0a36-4c13-aa7f-01b9737b2a1d"></a>
## 3. The 10 actions

| # | practice | why (one line) | sites file:line (max 5) | n + command | test or red control | box | agent kind | batch |
|---|---|---|---|---|---|---|---|---|
| 01 `test(r7-01-wui-fetch-signal-scan)` | a hung call ends; the test states the rule, not a list (retro 6.4) | A call added after round 6 shipped with no timeout and nothing failed | `wui:src/utils/sign-in-emails.mjs:133`<br>`wui:src/pages/roadmap.vue:100` + `wui:src/pages/goals/[id].vue:129`<br>`wui:src/components/CalendarPhonePeek.vue:214`<br>`wui:src/components/ApiDocViewer.vue:218`<br>`wui:tests/unit/fetch-timeouts.test.mjs` | 5 calls, section 2 row 1 | **fetch-timeouts.test.mjs** gains one test that walks every `.ts/.mjs/.vue` under `src/` (not `src/node/test/`), finds each `await fetch(` and requires `signal` in its init (the call's balanced parentheses, not a fixed line window); the per-site assertions stay. The 5 calls get `signal: AbortSignal.timeout(<budget>)` from `fetch-timeouts.mjs` (read budget for the GETs, write budget for the DELETE). Every test that names the 5 files or their exports (R2), typecheck. **Red control:** remove `signal:` from `sign-in-emails.mjs:133` -> the scan FAILS naming that file and line; put it back -> PASS. The same with a NEW `await fetch('/x')` in a temp `.vue` | PC | simple_coding | 1 |
| 02 `ci(r7-02-gate-first-red)` | measure the right thing (`lesson-speed-up-measure-first.md`) | The per-job count says 20 jobs broke when 1 did: a fail-fast stop counts as red | `csi-spl-iac/src/bash/run/report-ci-gate.func.sh` (`do_report_ci_gate`)<br>`csi-spl-iac/src/bash/tests/report-ci-gate.tst.sh` | 24 runs, per-job counts inflated 3-5x, section 2 row 4 | the report gains a `first red` section: per failed run, the jobs named after `red in this run:` in the `::error::gate fail-fast` annotation (`gate-fail-fast.sh:72`), counted per job; plus one `last green: <run> <sha8> <time>` line per job. The old per-job section stays (other readers). **Red control:** the test's fixture run with 1 red job and 8 stopped -> the first-red section counts 1 job; without the annotation parse it counts 9 -> FAIL. report-ci-gate.tst.sh; `bash-cleancode.tst.sh` (read only: the function stays under 80 or is split in the same file) | sat | complex_coding | 1 |
| 03 `test(r7-03-strip-resize-settle)` | a test waits for a state, never for a time | 7 of 20 failed feature-test jobs carry this one false red | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-strip-resize-proof.sh:110-113` (height case)<br>`:157-162` (width case) | 7 of 20 jobs, section 2 row 5 | each fixed `sleep` before a `capture-pane` becomes a bounded poll (every 0.1 s, at most 10 s) for the painted state (`TX-001` on row 1 before the split; two equal captures in a row after it), then it measures as today. What the proof claims does not change, nor any line it prints. `test-strip-resize.sh`, `test-strip-two-envs.sh` (READ only: `test-strip-resize.sh` is in c-771's lane). **Red control:** in a temp copy, delay the painter's first paint by 2 s -> the old proof FAILS the width case with the CI message; the new one PASSES; a painter that never paints -> the new one fails within 10 s naming the timeout, never hangs. 20 local runs under a planted load -> 20 of 20 | sat | tests | 1 |
| 04 `test(r7-04-go-coverage-hubclient)` | comprehensive tests, high coverage | The box CLI's hub client runs at 51.9 %: 55 functions never executed | `api:internal/hubclient/hubclient.go`<br>`api:internal/hubclient/{host,flush,edit,backfill}.go`<br>`csi-spl-api/src/bash/tests/go-coverage-floor.txt:25` | 51.9 %, 55 at 0 %, section 2 row 6 | new `_test.go` files only (`git diff --stat` names only `_test.go` + the floor file), against `httptest` and `internal/testkit/fakehub`; no Postgres. Target: at least +15 points; raise line 25 by hand to `%.1f` of the new value. **Red control:** delete one new test file -> `run-all-tests.sh` FAILS the floor; restore -> PASS. `go test ./internal/hubclient/ ./cmd/spool/` (R2: `cmd/spool` calls hubclient) | PC | tests | 1 |
| 05 `refactor(r7-05-bash-cron-checkout-helper)` | DRY | Nine install-cron actions repeat the same "create the self-updating checkout" block | a new `csi-spl-orc/lib/bash/funcs/spl-desk-cron-checkout.func.sh`<br>`orc:check-disk-headroom-install-cron.func.sh:67,76-80`<br>`orc:setup-box-stats-cron.func.sh:69,78-82`<br>`orc:setup-gh-runner-cpu-budget-cron.func.sh:62,71-75`<br>`orc:setup-go-cache-prune-cron.func.sh:67,76-80` | 9 copies, 4 here, section 2 row 7 | one helper `spl_desk_cron_checkout <src> <trunk>` (creates when `SPL_DESK_CRON_CREATE=1`, the same FATAL text, rc 1) and `spl_desk_cron_checkout_dry <src> <trunk>` (the DRY_RUN line), auto-sourced from `lib/bash/funcs/`; its own new `spl-desk-cron-checkout.tst.sh` (CREATE=0 -> no git call; CREATE=1 with a stub git -> the two calls in order; git fails -> FATAL text byte for byte, rc 1). check-disk-headroom, box-stats-cron, apply-gh-runner-cpu-budget, setup-gh-runner-cpu-budget-cron, prune-go-build-cache, desk-install-service-envs (.tst.sh) | sat | simple_coding | 1 |
| 06 `refactor(r7-06-bash-cron-checkout-rest)` | DRY | The other five copies of the same block | `orc:spl-agent-boot-restore-install-cron.func.sh:83,93-97`<br>`orc:spl-dispatch-rotate-install-cron.func.sh:77,87-91`<br>`orc:spl-orch-rotate-install-cron.func.sh:64,73-77`<br>`orc:spl-spawn-remote-install-cron.func.sh:67,76-80`<br>`orc:spl-unanswered-sweep-install-cron.func.sh:71,80-84` | 5 copies, section 2 row 7 | call 05's helper; each caller keeps its other messages and rc. test-agent-boot-restore.sh, boot-cron-gate, wd-reboot, dispatch-rotate, orch-rotate, spawn-remote-cron, unanswered-sweep, dispatch-setup-check, satellite-ansible, spl-box-deploy (.tst.sh) | sat | simple_coding | 2 (after 05: uses its helper) |
| 07 `refactor(r7-07-bash-small-functions-iac)` | small functions | Two iac actions at 128 and 82 lines; kept out of round 6 only for the baseline file | `csi-spl-iac/src/bash/run/check-weekly-full-scan.func.sh` (`do_check_weekly_full_scan`, 128)<br>`csi-spl-iac/src/bash/run/gcp-backup-env.func.sh` (`do_gcp_backup_env`, 82)<br>`csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh:21,25` (their 2 LONG lines go)<br>`.shellcheck-warning-baseline.txt` (the `gcp-backup-env` line: kept, or dropped if the finding goes, to match `do_sec_shellcheck`) | 2, section 2 row 8 | split under 80 by named steps in the same file, delete the 2 LONG entries. bash-cleancode, check-weekly-full-scan, adhoc-harvest-gcp-actions, gcp-actions-isolated-config, gcloud-account-pinned, gcp-key-path-no-eval (.tst.sh); `./run -a do_sec_shellcheck` -> 0 new findings, baseline count equal to the code's | sat | secret (backup env, key paths) | 1 |
| 08 `refactor(r7-08-bash-small-functions-orc)` | small functions | Two orc functions at 86 and 105 lines | `orc:spl-dispatch-setup.func.sh` (`spl_dispatch_setup_steps`, 86)<br>`orc:spl-responder-run.func.sh` (`do_spl_responder_run`, 105)<br>`csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh:42,44` (their 2 LONG lines go) | 2, section 2 row 9 | split under 80, delete the 2 LONG entries. bash-cleancode, spl-take, responder-run, responder-sweep, responder-cross-box, responder-reboot-test, desk-agent-ids (.tst.sh) | sat | secret (dispatch lease and settings) | 2 (after 07: shares `bash-cleancode.tst.sh`) |
| 09 `refactor(r7-09-wui-small-functions)` | small functions | Two composables and the live socket's message handler over the limit | `wui:src/composables/useLive.ts` (`useLive`, 113)<br>`wui:src/utils/live-ws.mjs` (`handle`, 117)<br>`wui:src/composables/useMentionPicker.ts` (`useMentionPicker`, 130)<br>`wui:tests/unit/cleancode.test.mjs:35,36,49` (their 3 LONG lines go) | 3, section 2 row 10 | split into named steps under 80; keep each export's signature. **cleancode.test.mjs**, **fetch-timeouts.test.mjs** (READ: its `useLive.ts` regex must still match), live-ws, live-follow, live-revision, last-data-clock, newest-live, msg-merge, msg-edit-wire, agent-at-box, perf-mark, mention-autocomplete, feedback-channel, names-not-ids (`.test.mjs`), typecheck, `perf-budget.py` with CI's node | PC | simple_coding | 1 |
| 10 `test(r7-10-go-coverage-spool-cli)` | comprehensive tests, high coverage | The box CLI's client commands run at 26.8 % | `api:cmd/spool/main.go` (12 at 0 %)<br>`api:cmd/spool/memory.go` (5), `lifecycle.go` (4), `box_stats.go` (3)<br>`api:cmd/spool/hub.go`, client half only (`cmdHubPin`, `cmdHubSync`, `cmdHubTail`, `cmdHubGetFile`, `boxClient`, `envOr`, `inviteMailFlags`)<br>`csi-spl-api/src/bash/tests/go-coverage-floor.txt:8` | 26.8 %, 73 at 0 %, section 2 row 6 | new `_test.go` files only, against `internal/testkit/fakehub`; no Postgres. Target: at least +10 points; raise line 8 by hand. **Red control:** as 04. `go test ./cmd/spool/` | PC | tests | 2 (after 04: shares `go-coverage-floor.txt`) |

Paths: 36 in all (the `lane-map` set, this plan and the seat file included). Line ranges for 05 and 06 are the DRY_RUN twin line and the create block the `git grep` found; the lane reads each function whole before it extracts.

<a id="ws-doc-8b8013db-f625-4c12-98b0-a722aa56e241"></a>
### 3.1 Disjoint files (R1)

- No path is in two actions of the same batch. `lane-map --check` over all 36: one owned (`test-strip-resize.sh`, c-771), read-only for 03.
- **Shared files, serialised:** `bash-cleancode.tst.sh` LONG list: 07, then 08 (batch 2); 02 only reads it. `go-coverage-floor.txt`: 04, then 10 (batch 2). The cron helper: 05 adds it, 06 uses it (batch 2). `.shellcheck-warning-baseline.txt`: 07 only (`grep -c <basename>` -> 0 for every other bash site of 02, 03, 05, 06, 08). `cleancode.test.mjs`: 09 only. `fetch-timeouts.test.mjs`: 01 only; 09 reads it (its `useLive.ts` regex) and must not move the `/v1/wui/revision` fetch out of `useLive.ts`.
- A test file named in the test column of two actions is READ by both, never edited by both: the editing action is the one whose sites include it.

<a id="ws-doc-aec8409b-44d7-48d4-aa44-5d642dd799d1"></a>
## 4. Per action: what the lane does

- **01.** The scan is the rule; round 6's per-site assertions stay as the budget check. Parse the init by balanced parentheses from `fetch(`: a fixed line window is what made `calendar-reminder-timer.ts:37` look unsignalled in round 6. Exclude `src/node/test/` by path, nothing else; a new exception is a named entry with its reason.
- **02.** Measure first: before changing the report, count the first reds by hand on the last 24 failed runs and put the numbers in the commit body; the new section must reproduce them.
- **03.** Change only how the proof waits. Keep every printed line: `test-strip-resize.sh` greps them, and it is c-771's file.
- **04.** Table tests against `httptest`; floor `%.1f` of the new value, by hand, same commit.
- **05.** The helper never `exit`s and sets no trap. Name it after what it does.
- **06.** Only after 05 is on trunk. One commit.
- **07.** Named steps inside the same file; no change to the `--account` pin or the key-path resolution (`gcloud-account-pinned.tst.sh`). Re-measure the baseline on the rebased tree.
- **08.** After 07 is on trunk. Keep every log line byte for byte (the responder tests grep them).
- **09.** Split by named inner functions; no `.vue` change; `perf-budget.py` with CI's node (the box node reads about 0.7 KB low).
- **10.** After 04 is on trunk. Client commands only; the server half of `hub.go` (`cmdServe`, `openStore`, `wirePayments`, ...) needs Postgres and stays out (section 8).

<a id="ws-doc-9a1ddb80-d954-4c35-9edc-effe95f48652"></a>
## 5. Spawn, done, status (R1-R13)

- **R1** disjoint files: section 3.1.
- **R2** test column: every test file that names the site's basename, a function it defines, or (WUI) its import path; plus every test that holds a 30-character string from a comment within the site (+/- 3 lines); plus every package or file that references an exported name the action moves or deletes. Bold = a test that reads source text.
- **R3, before the wave.** The orchestrator re-runs `lane-map.sh --check <action paths> --agent <its id>` per action. An owned path: wait for that lane, never spawn on top.
- **R4, one spawn per slug across all boxes.** `sat` spawns 02, 03, 05, 06, 07, 08; `PC` spawns 01, 04, 09, 10. Before a spawn: `git log origin/master --grep='r7-NN-' --oneline` is empty and no live lane carries the slug. The brief carries the plan row verbatim (its section-3 row and section-4 bullet) and **names the row's reviewer seat (R7.2)**. The spawner reads the new pane 2 minutes after spawn.
- **Batch order.** Batch 1 = 01, 02, 03, 04, 05, 07, 09, all at once (4 on `sat`, 3 on `PC`). Batch 2 = 06 after 05, 08 after 07, 10 after 04, **placed by whoever first sees the dependency on trunk**: the dependency's lane says so in its final report, and R10's hourly check catches it otherwise.
- **R5, done = served.** WUI changes (01, 09): `cd csi-spl-orc && SHA=<sha> ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd`. Go tests (04, 10): test-only, nothing to serve. Bash, CI and test changes: on `origin/master` and in each box's checkout (`git -C <box checkout> merge-base --is-ancestor <sha> HEAD` on `sat` and `PC`), plus the red control's proof in the commit body. **Plus R11's CI verdict, for every row.**
- **R6, no hand-kept status.** `git fetch origin master && git log origin/master --grep='r7-' --format='%h %cI %s'`, then the R5 commands per sha.
- **R7, peer review across vendors, by seats that outlive the round (rewritten, retro 6.1).** Round 6: 0 of 10 rows had a cross-vendor review before the push; 9 lines read `same vendor, panel seats exited` (retro 4.1). So:
  1. **The reviewer seats are not closed at SIGNED.** This panel's agy seat and mistral seat stay up until R6 shows all 10 rows on trunk. Their seat briefs say so in the first line ("stay up until the round-7 plan status reads SERVED: you review rows, you do not exit after signing"). The orchestrator does not close or retire them before that, and schedules no `--defer` close at signing.
  2. **The reviewer is named per row before the spawn**, in the row brief: a claude or mistral lane is reviewed by the agy seat, an agy or grok lane by the mistral seat, a mistral lane by the claude seat (the editor). Backup: the other non-author seat.
  3. **A gone seat is re-placed, never skipped.** If the named seat and its backup are not on the lane map, or neither has answered in 15 minutes, the lane sends a `blocker` to the orchestrator, which places a new seat of a vendor other than the lane's (`/agy-spawn` or `/mistral-spawn`) within that hour (R10). The row waits. **Round 6's same-vendor fallback is withdrawn: a row never pushes without a cross-vendor `PASS`.**
  4. Before the push, the lane sends its diff (a pushed `review/r7-NN` branch, never master) to its reviewer, who answers `PASS` or `FIX: <item>` against C1-C7. The commit body carries `review: <reviewer id>@<box> <vendor> PASS` (R13).
  5. R6 counts: `git log origin/master --grep='r7-' --format=%B | grep -c '^review: '` must reach 10, and `... | grep '^review: ' | grep -c 'same vendor'` must stay 0.
  - C1 the diff touches only the action's sites and its tests (`git diff --stat`).
  - C2 behaviour preserved (code), or the red control was seen RED then GREEN (gate, test fix), with the command and its output in the body.
  - C3 no file shrank by more than the lines the action removes (`wc -l` before and after).
  - C4 every test in the action's test column ran and passed, named in the body.
  - C5 no comment states something the code does not do.
  - C6 hygiene and pre-push passed with no override.
  - C7 the pushed sha is the reviewed sha (`git diff <reviewed> <pushed> --stat` -> only the rebase's trunk files; none of the row's own sites changed after review).
- **R8, retro.** After the 10 actions are served, one lane writes `refactor-round-7-retro.md` in the shape of `refactor-round-6-retro.md`; its section 6 feeds round 8. Then the dispatcher requests round 8's planner at once. The reviewer seats (R7.1) close after the retro lane has read their review lines.
- **R9, gate lanes.** 02 and 03 run their own test once under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` variable unset, before the first push.
- **R10 (new, retro 6.2), placement check every hour.** From SIGNED until every row has a lane, the orchestrator runs, once an hour: `git log origin/master --grep='r7-' --format='%h %s'` against section 3, plus `lane-map.sh` (every box) for each `r7-NN` slug and for the two reviewer seats. A row with no commit and no live lane is placed in that hour (batch 2 too, once its dependency is on trunk). A reviewer seat gone: R7.3. The check posts on `dispatch-4f46ce09` only when it placed or re-placed something (no filler). Round 6: rows 02 and 05 had no lane for 13 h 20 min and about 14 h, and nobody ran the one command that showed it (retro 4.2).
- **R11 (new, retro 6.3), a CI verdict per row that survives master churn.** Measured (section 2, rows 2-4): a `cancelled` wf 10 run on master is a superseded PENDING run, by design; every started run finishes, so the newest completed run covers every commit before its head. What round 6 lacked was a green one: 19 verdicts, all red, from 5 jobs' defects. So:
  1. **A row's CI verdict** is the first COMPLETED wf 10 run whose head contains the row's sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed`, then `git merge-base --is-ancestor <row sha> <head>`), not a run on the row's own sha. The lane records that run id and its first red in its report.
  2. That run is green, or its first red (02's report, or `red in this run:` by hand until 02 lands) names **no job that runs the row's tests**. Otherwise the row is not done: that red is the row's to fix.
  3. **Trunk-red watch**, in R10's hourly check: `CI_GATE_RUNS=40 ./run -a do_report_ci_gate`. A first-red job seen in 2 completed runs in a row gets an owner that hour: the lane whose commit turned it red, else a new `tests` lane. A first red that comes and goes with no code change behind it is a flake: it gets a lane at its 3rd sighting (retro 6.6's threshold).
  4. No change to wf 10's concurrency: the comment at `10_ci-quality.yml:103-114` and `gate10-concurrency.tst.sh` hold the measured reason. A lane that wants one starts with a measurement (`lesson-speed-up-measure-first.md`) and a row of its own in round 8.
- **R12 (new, retro 6.5), a count sent to the owner carries its command.** A post on the owner topic that states a count of this round ("N of 10 ...") quotes the R6 or R7.5 command that produced it and its output on that sha. The dispatcher holds this.
- **R13 (new, retro 6.7), an id names its box.** A spawn reply, a review line and a placement report write `<id>@<box>` (`c-768@PC PASS`) whenever the id is live on more than one box; the review line always does (R7.4).

<a id="ws-doc-fa5470cd-5dae-4c20-988a-35b6fc922ed8"></a>
## 6. Process practices, measured (no lane)

| owner practice | measured state on `b161a015b` | verdict |
|---|---|---|
| peer code review with a checklist before merge | `git log origin/master --grep='r6-' --format=%B \| grep '^review: '` -> 10 lines, 1 cross-vendor, and late (retro 4.1) | **tightened:** R7 seats outlive the round, a gone seat is re-placed, no same-vendor fallback |
| work is placed, not forgotten | 2 of 10 r6 rows unplaced for about 14 h (retro 4.2) | **new:** R10 hourly placement check |
| CI that blocks broken builds | 19 of 19 completed wf 10 runs red during round 6, 0 green (section 2) | **new:** R11 per-row verdict and trunk-red watch; action 02; action 03 removes the most frequent false red of the feature tests |
| claims carry their own check | c-002 msg 134edbfe "10 of 10 cross-vendor" against a measured 1 (retro 4.1) | **new:** R12 |
| regular training, a retro per round | `ls csi-spl-doc/doc/md \| grep retro` -> rounds 3, 5, 6 | **in place:** R8 |
| formatting enforced | Go `gofmt -l` 0, Python `ruff format --check` (r5-09) | **in place** for Go and Python; bash and WUI: section 8 |

<a id="ws-doc-403a9dcc-04c6-498a-9522-aa286ca43415"></a>
## 7. Disagreements

Seat verdicts on `6cf5d67cd`: claude 10 agree (the planner's proposal); agy 10 agree, rules and left-out agree; mistral 5 agree + 5 "agree with changes" (01, 05, 07, 08, 09). No seat proposed a new row or dropped one. Each mistral change, read against the row, asks for what the row already says, so no row changed and nothing was re-measured.

| # | seat | item | settled |
|---|---|---|---|
| D1 | mistral (m-781) | 01: "the scan must parse the fetch call's balanced parentheses to avoid false negatives" | **Already in the row.** Section 3 row 01: "requires `signal` in its init (the call's balanced parentheses, not a fixed line window)"; section 4 bullet 01 gives the reason. No change |
| D2 | mistral | 05: its `git grep` first returned 0 copies (repository ownership), then 9 | **A seat-side tooling note, not a row change.** The plan's 9 stands, and the seat reproduced it. A worktree owned by another user needs `sudo -u <owner> git` (dubious ownership); the planner hit the same |
| D3 | mistral | 07: the files are 250 and 161 lines, more than 128 and 82 | **Already in the row.** 128 and 82 are the FUNCTIONS (`do_check_weekly_full_scan`, `do_gcp_backup_env`), measured by `bash-cleancode.tst.sh`'s `measure` awk, which is what the LONG list gates; the row splits the functions, not the files. No change |
| D4 | mistral | 08: the files are 428 and 304 lines, more than 86 and 105 | **As D3.** `spl_dispatch_setup_steps` 86, `do_spl_responder_run` 105, the same awk. No change |
| D5 | mistral | 09: the files are 253, 752 and 157 lines, more than 113, 117 and 130 | **As D3.** The ceilings are `cleancode.test.mjs:35,36,49`, per function (`useLive`, `handle`, `useMentionPicker`). No change |

Two notes on the seats' evidence, for the retro, not the rows: the agy seat gives verdicts with no command (round 6's agy seat re-ran 3 counts); the mistral seat's row-10 command measures `internal/hubclient` (51.9 %, row 04's package), not `cmd/spool` (26.8 %). Neither changes a row: the plan's own command and n stand in section 2.

<a id="ws-doc-c308a0bc-e812-4d28-b9dc-1630fc669a73"></a>
## 8. Measured and left out

| what | why it is out | measured by |
|---|---|---|
| the `_spl_sdk_saved` / `CLOUDSDK_CONFIG` preamble (now in 24 production files) | the RETURN trap must stay in each caller (round 4 section 6), so a helper saves about 3 lines a copy; most callers are destructive gcp actions | `git grep -l '_spl_sdk_saved' -- '*.sh' \| grep -v /tests/ \| wc -l` -> 24 |
| `cmd/spool/hub.go` server wiring (22 of its 36 functions at 0 %: `cmdServe`, `openStore`, `wirePayments`, ...) | needs Postgres and the full hub; it belongs with `hub-pg.tst.sh`, not a unit-test lane | `go tool cover -func` |
| the big Pinia setup stores (`channel.ts` 576, `notification.ts` 430, `flow.ts` 321, `live.ts` 304) and the client factories (`spool-client.mjs` 565, `live-ws.mjs createLiveClient` 507, `auth-client.mjs` 326) | each is a live feature area; a split is its own planned row with the feature lane's owner | `cleancode.test.mjs:34-51` |
| `test-tmux-close-window-vibe.sh` case 4 | CI red n=1 in round 6, below the threshold of 3 (retro 6.6); R11.3 watches it | retro section 3 |
| wf 10 concurrency | measured as designed (section 2 row 3); R11.4 | `10_ci-quality.yml:103-117` |
| shfmt and prettier | no config and no tool; one format wave over every live lane's files | r5 section 8 |
| the other bash LONG entries (`spawn_main` 185, `do_gcp_import_to_cloudsql` 175, `do_provision_firebase_dns` 169, ...) | two bash rows per round keep the `bash-cleancode.tst.sh` serialisation to one hop; the largest are destructive gcp actions or the spawn core (c-771's lane today) | `bash-cleancode.tst.sh:18-45` |

<a id="ws-doc-84c06477-ab53-4c88-b8d6-955645f22c0f"></a>
## 9. Counts

| | Go | TS/Vue | bash | CI / gate | total |
|---|---|---|---|---|---|
| code actions | 0 | 1 (09) | 4 (05, 06, 07, 08) | 0 | 5 |
| test actions | 2 (04, 10) | 1 (01) | 1 (03) | 0 | 4 |
| gate / report actions | 0 | 0 | 0 | 1 (02) | 1 |
| per box | `sat`: 02, 03, 05, 06, 07, 08 | | | `PC`: 01, 04, 09, 10 | 10 |
| agent kind | simple_coding: 01, 05, 06, 09 | tests: 03, 04, 10 | secret: 07, 08 | complex_coding: 02 | 10 |
| rules | R1-R6, R8, R9 carried; R7 rewritten; R10-R13 new | | | | 13 |

<a id="ws-doc-1e14876b-316d-4b5d-bdff-868c4520b0e2"></a>
## 10. Consensus

Signed plan sha: **`6cf5d67cd`** (the draft; no row changed at the fold, so the seats signed the rows as written). This fold commit edits only the status line, the panel line, section 7 and this section.

| seat | signed | how |
|---|---|---|
| claude (planner and editor c-776@sat) | `6cf5d67cd` | the planner's proposal, 10 agree; this fold |
| agy (a-943) | `6cf5d67cd` | `refactor-round-7/seat-agy.md` (`30453a19a`): 10 agree, "Signed: plan sha 6cf5d67cd"; spool msg b21c3d86 |
| mistral (m-781@sat) | `6cf5d67cd` | `refactor-round-7/seat-mistral.md` (`0b7eb4b69`): 5 agree + 5 agree with changes (D1-D5, no row change), "Signed: plan sha `6cf5d67cd`"; spool `dispatch-4f46ce09` msg c17b76d5 |
