# Refactoring round 6 - plan: clean code round 20261010-b (10 actions)

Owner HUM-10, prd t1, topic `4f46ce09-15ee-4b9a-b05f-edd9812b51fb`, msg 3d22fcea: "refactoring is something which we should have embedded in our system core way of operating. We will do refactoring constantly, all of the time. You just pick all the best practices and you implement them. You shouldn't need my go-ahead for that." **No owner go is needed for this round, its panel or its lanes** (rule home: `SPEC-spool-fleet-roles.md` section 1.2). Requested by the dispatch holder c-002 (msg a4792677), placed by c-001@sat.

**Status: SIGNED.** All three seats signed plan sha **`eb8cbfc1c`** (section 10). Batch 1 = 01, 03-10; batch 2 = 02 after 01 is on trunk. The row lanes are spawned by the orchestrator from that sha.

Panel: the claude seat (proposal `refactor-round-6/seat-claude.md` by the planner c-709; editor c-711, `sat`), the agy seat a-763 (`refactor-round-6/seat-agy.md`) and the mistral seat m-710 (`refactor-round-6/seat-mistral.md`). Inputs: the row format and rules R1-R8 of `refactor-round-5-plan.md`; `refactor-round-5-retro.md` section 6; round 5's leftovers (its section 7 D3, D4 and section 8); the owner's practice list (round 5 plan header, msg e30c2bf1).

Every site was measured on ONE trunk sha: **`da36dad94`** (`origin/master`, 2026-10-10T05:48Z), n=1 per count unless stated otherwise. Re-checked on `ab17d6547` (the trunk when this plan was written): `git diff --stat da36dad94 ab17d6547 -- <every site path of section 3>` -> empty, so every line number holds. Re-checked again at the fold on `5c3f1fe42`: the same `git diff --stat da36dad94 5c3f1fe42 -- <every site path>` -> empty.

## 1. How to read this

- One action = one practice = one lane. The lane applies the practice at the sites named and nowhere else, with a test that proves behaviour did not change, or, for a gate, a **red control** that proves the gate now fails on the bad input.
- **Paths:** `api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` = `csi-spl-wui/`, everything else is from the repo root. Line numbers are as of `da36dad94`.
- **Boxes:** `sat` and `PC`, as in round 5 (`sat` has Chrome and Postgres). Each box gets at least 2: `sat` 6, `PC` 4.
- **Agent kind** = a `do_spl_lane_mix` kind, not a vendor. The spawner runs `LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` per row at spawn time; it picks the vendor from the box split, skips a vendor that is out (round 5: 4 of 4 grok lanes dead on the weekly limit), and sends `secret` to claude or mistral only (data rule). Kinds here: `simple_coding` 4, `secret` 3, `complex_coding` 2, `tests` 1.
- **No new dependency.** Actions 01-03 and 06-10 are behaviour-preserving (03 changes only how a failure ends: `return` instead of killing the caller's shell). Actions 04 and 05 change a gate: what it lets through, never what the product does.
- **Commit subject** (R6 reads it): `refactor(r6-NN-<slug>): ...` for a code action, `ci(r6-NN-<slug>): ...` for a gate action, `test(r6-NN-<slug>): ...` for 06.
- **Off every live lane:** `lane-map.sh --check <all 51 paths: the sites, the new files, the edited tests and this plan> --agent c-709` -> `free`, rc 0 (2026-10-10, twice). Live and kept off: c-707@sat (`spawn-agents/spawn-window.sh`), a-753@PC and m-754@PC (`csi-spl-doc/blog`, `spl-blog-check.func.sh`). Re-run the check per action before its spawn (R3).

## 2. Where the actions come from (measured)

| source | command on `da36dad94` | n | action |
|---|---|---|---|
| r5 D3: WUI `fetch` with no timeout signal | `grep -rnE "await fetch\(" csi-spl-wui/src/utils/ \| grep -v signal \| wc -l` -> 13; per hit, `sed -n "$l,$((l+8))p" \| grep -c signal` | 13 line hits; 3 pass `signal:` on a later line (`calendar-reminder-timer.ts:37`, `roadmap-goals-api.mjs:55`, `public-calendar-web.mjs:76`); **10 real calls in 7 files** | 01, 02 |
| r5 D4: `exit` at function level in a sourced `.func.sh` | `grep -rnE '^\s+exit [0-9]' --include=*.func.sh csi-spl-{iac,orc}/{src,lib}` -> 11; each read by hand | 2 real (`gcp-import-to-cloudsql.func.sh:168`, `gcp-export-dns-settings.func.sh:39`); 7 run inside `( ... )` or `bash -c` (`spl-auth-idp-secret-seed`, `spl-domain-verify`, `spl-wd-peers`, `sec-shellcheck:162`); 2 are `require-var.func.sh`, whose job is to stop the run | 03 |
| r5 section 8: shellcheck skips `csi-spl-api` and `csi-spl-wui` `.sh` | `git ls-files 'csi-spl-api/*.sh' 'csi-spl-wui/*.sh' \| wc -l` -> 22; `shellcheck -S warning -f gcc <those 22>` | 6 findings in 3 files: SC2144 (error) `spool-smoke.tst.sh:57`, SC2046 `hub-e2e.tst.sh:81,248`, SC2155 x3 `standalone-public.proof.sh:52`; scope is `_SEC_SHELLCHECK_TREES` at `sec-shellcheck.func.sh:22` | 04 |
| r5 retro 6.1: stale-tree push | the detector of retro section 7 over the last 300 non-merge commits on `origin/master` (2m 59s) | 2 commits restore >= 3 paths: `8bb97690e` (26, the clobber) and its repair `d4fa39b61` (26, subject says "restore"); 8 restore 1 path, each a named restore | 05 |
| r5 retro 6.7 + r5-10 "raising the low packages is round 6": test coverage | `nice go test -count=1 -coverprofile=<tmp> ./internal/{action,files,edge}/` in `api:`, then `go tool cover -func \| awk '$3=="0.0%"'` | `internal/action` 30.2% (25 functions at 0%), `internal/files` 32.9% (10), `internal/edge` 38.2% (8); `cmd/spool` 26.8% (73 at 0%: too wide for one lane) | 06 |
| r5 section 8: DRY, cron "drop tagged line" | a hash of every 6-line window (comments and blanks dropped, windows under 120 chars skipped) over the production `.sh` (`git ls-files '*.sh'` minus tests) | 25 groups of 3+ files; the `awk -v suf=" # $tag"` drop + `cmp -s "$before" "$after"` block: **5 copies** | 07 |
| r5 section 8: DRY, probe scaffold | the same hash | the DRY_RUN preamble + `do_require_bin yq python3` + key/pw file checks of the reply probes: **5 copies** (from `do_require_bin yq python3` to the pw-file check; read by hand) | 08 |
| small functions (WUI) | `wui:tests/unit/cleancode.test.mjs:35-54` (20 LONG entries with ceilings, r5-06) | 4 entries within 30 lines of the 80 limit: `useLive.ts ensure` 89, `stores/search.ts <anon>` 97, `useTopicRowActions` 105, `useMessageEdit` 110 | 09 |
| small functions (bash) | `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh:18-46` (LONG with ceilings) and its `measure` awk on each file | `do_gcp_tail_logs` 117, `do_gcp_s3_download_all` 130; both have no `.shellcheck-warning-baseline.txt` line (`grep -c` -> 0), so no baseline edit (R1) | 10 |

Kept out by the same measure: section 8.

## 3. The 10 actions

| # | practice | why (one line) | sites file:line (max 5) | n + command | test or red control | box | agent kind | batch |
|---|---|---|---|---|---|---|---|---|
| 01 `r6-01-wui-fetch-signal-hours` | a hung call ends (failure path, round 3 rows 6-7) | Hours and status calls have no timeout: a hung connection is an endless spinner | `wui:src/utils/hours-timer.mjs:118`<br>`wui:src/utils/hours-calendar-api.mjs:50`<br>`wui:src/utils/hours-team-api.mjs:55,80`<br>`wui:src/utils/human-status.mjs:411,432`<br>`wui:src/utils/fetch-timeouts.mjs` (a budget if none fits) | 6 calls, section 2 row 1 | **fetch-timeouts.test.mjs** (owned here: one source-scan assertion per call, `signal:` built from a named budget), hours-timer, hours-calendar, hours-mine, hours-team, human-status, notify, notify-pause-status (`.test.mjs`), typecheck. **Red control:** remove `signal:` from one call -> the new assertion FAILS; put it back -> PASS | PC | simple_coding | 1 |
| 02 `r6-02-wui-fetch-signal-calendar` | the same | The same gap in the calendar, AI-action and release-notes calls | `wui:src/utils/calendar-events-api.mjs:34,89`<br>`wui:src/utils/msg-ai-actions.mjs:288`<br>`wui:src/utils/release-notes-api.mjs:31` | 4 calls, section 2 row 1 | fetch-timeouts.test.mjs (adds its 4 assertions after 01), calendar-drag, calendar-trash, msg-ai-actions, release-notes-paging, release-note-links, release-link (`.test.mjs`), typecheck. **Red control:** as 01 | PC | simple_coding | 2 (after 01: shares `fetch-timeouts.test.mjs` and `.mjs`) |
| 03 `r6-03-bash-return-not-exit` | a sourced function returns, never exits (round 3 row 13) | An `exit 1` inside a function sourced by `./run` kills the caller's shell and skips its error report | `csi-spl-iac/src/bash/run/gcp-import-to-cloudsql.func.sh:168`<br>`csi-spl-iac/src/bash/run/gcp-export-dns-settings.func.sh:39` | 2, section 2 row 2 | a new `return-not-exit-gcp.tst.sh`: source each file in a subshell with stubbed `gcloud`/`psql`, drive the branch (unsupported file format; missing key file), assert rc 1 AND that the next line of the calling shell runs. **Red control:** restore `exit 1` -> the "next line runs" assertion FAILS. bash-cleancode (.tst.sh; `do_gcp_import_to_cloudsql` is LONG 175: its ceiling must not move) | sat | secret (a key-path branch) | 1 |
| 04 `ci(r6-04-shellcheck-api-wui)` | lint and static analysis enforced | 22 `.sh` under api and wui are never scanned; one holds an error-level finding | `csi-spl-iac/src/bash/run/sec-shellcheck.func.sh:22` (`_SEC_SHELLCHECK_TREES`) and `:75-77` (the scope comment)<br>`csi-spl-api/src/bash/tests/spool-smoke.tst.sh:57`<br>`csi-spl-api/src/bash/tests/hub-e2e.tst.sh:81,248`<br>`csi-spl-api/src/bash/tests/standalone-public.proof.sh:52`<br>`.shellcheck-warning-baseline.txt` | 6 findings, section 2 row 3 | fix the 6 (the SC2144 `-f` on a glob becomes a loop or `compgen -G`), add `csi-spl-api/src/bash` and the wui `.sh` dirs to the scope, baseline unchanged (0 new lines). **Red control:** a planted SC2144 in a temp copy of an api `.sh` must FAIL `do_sec_shellcheck`; the tree today must PASS. sec-shellcheck, check-pre-push-lint (.tst.sh); `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (the 3 api files still run) | sat | complex_coding | 1 |
| 05 `ci(r6-05-prepush-stale-tree)` | CI blocks broken builds (locally, before the push) | A push from a stale tree silently reverted 26 paths of other lanes (r5-02); CI never saw it (its run was cancelled) | `csi-spl-iac/src/bash/run/check-pre-push.func.sh:821` (part list) and the part selector<br>a new `csi-spl-iac/src/bash/run/check-pre-push-stale-tree.func.sh`<br>a new `csi-spl-iac/src/bash/tests/check-pre-push-stale-tree.tst.sh` | 300 commits -> 2 over the threshold, section 2 row 4 | a `stale-tree` part, every tier: per outgoing commit, count paths set back to a blob they held before one of their last 40 commits (not the parent's); 3 or more -> REFUSED, unless the subject starts `Revert` or contains `restore`. **Red control:** in a temp clone, `8bb97690e` on its parent `9fefb364d` -> REFUSED naming 26 paths; `d4fa39b61` -> PASS (subject); `70e1eb26b` -> PASS. Time it on a 1-commit push (budget: under 5 s, else report). check-pre-push, check-pre-push-tree-pass, check-pre-push-scope (.tst.sh) | sat | complex_coding | 1 |
| 06 `test(r6-06-go-coverage-raise)` | comprehensive tests, high coverage | Three hub packages run under 40%; `files` resolves and extracts paths, `edge` is the request guard | `api:internal/edge/edge.go` (`NewGuard`, `Wrap`, `acquire`, `release`, `refuse`, `Probe`)<br>`api:internal/files/files.go` (`RefBlob`, `isSHA256Hex`, `Resolve`, `GetDir`, `extractOne`)<br>`api:internal/action/{action,archive,ask,claim}.go` (`sendHub`, `Get`, `ExitCode`, `Archive`, `Ask`, `Claim`)<br>`csi-spl-api/src/bash/tests/go-coverage-floor.txt` (3 lines) | 30.2 / 32.9 / 38.2 %, section 2 row 5 | new `_test.go` files only, no production change (`git diff --stat` names only `_test.go` + the floor file). Target: each package at least +15 points; raise its 3 floor lines by hand to the new value. **Red control:** delete one new test file -> `run-all-tests.sh` FAILS the floor; restore -> PASS. `go test ./internal/edge/ ./internal/files/ ./internal/action/ ./internal/hub/` (R2 cross-package: hub tests call `action.SendCtx`) | PC | tests | 1 |
| 07 `refactor(r6-07-bash-cron-drop-helper)` | DRY | Five hand copies of the block that drops a tagged crontab line and reports a change | `csi-spl-orc/src/bash/run/box-disk-sweep-install-cron.func.sh:42-58`<br>`csi-spl-orc/src/bash/run/prune-docker-images-install-cron.func.sh:43-59`<br>`csi-spl-orc/src/bash/run/spl-agent-id-reap-install-cron.func.sh:39-55`<br>`csi-spl-orc/src/bash/run/spl-box-update-install-cron.func.sh:52-68`<br>`csi-spl-orc/src/bash/run/tmp-scratch-sweep-install-cron.func.sh:38-54` | 5 copies, section 2 row 6 | one helper in a new `csi-spl-orc/lib/bash/funcs/cron-tagged-line.func.sh` (auto-sourced, `run.sh:511`), keeping each caller's messages and rc; its own new `cron-tagged-line.tst.sh` (drop present tag -> changed; absent -> unchanged, rc same; a line that only CONTAINS the tag mid-line stays). box-disk-sweep, prune-docker-images, agent-id-reap, spl-box-deploy, spl-box-update-install-cron, satellite-ansible, tmp-scratch-sweep (.tst.sh) | sat | simple_coding | 1 |
| 08 `refactor(r6-08-bash-probe-scaffold)` | DRY | Five reply probes repeat the same DRY_RUN, tenant and key/pw-file preamble; a sixth probe would copy it again | `csi-spl-orc/src/bash/run/spl-backfill-probe.func.sh:37-67`<br>`csi-spl-orc/src/bash/run/spl-fallback-probe.func.sh:42-73`<br>`csi-spl-orc/src/bash/run/spl-reply-count-probe.func.sh:37-67`<br>`csi-spl-orc/src/bash/run/spl-reply-probe.func.sh:37-66`<br>`csi-spl-orc/src/bash/run/spl-topic-reply-probe.func.sh:28-52` | 5 copies, section 2 row 7 | one helper in a new `csi-spl-orc/lib/bash/funcs/spl-probe-preamble.func.sh`; every FATAL message and rc kept byte for byte (each probe's test greps them). A RETURN trap stays in the CALLER (round 4 section 6). backfill-probe, fallback-probe, reply-count-probe, reply-probe, topic-reply-probe (.tst.sh) + the helper's own test (t1 refused, non-0600 key refused, DRY_RUN prints and returns 0) | sat | secret (root key, pw file) | 1 |
| 09 `refactor(r6-09-wui-small-functions)` | small functions | Four functions just over the limit; each split takes it off the LONG list for good | `wui:src/composables/useLive.ts` (`ensure`, 89)<br>`wui:src/stores/search.ts` (setup, 97)<br>`wui:src/composables/useTopicRowActions.ts` (105)<br>`wui:src/composables/useMessageEdit.ts` (110)<br>`wui:tests/unit/cleancode.test.mjs:35,38,42,47` (their 4 LONG lines go) | 4, section 2 row 8 | split into named steps under 80, delete the 4 LONG entries. **cleancode.test.mjs** (now fails if any of the 4 grows back over 80), **search-door.test.mjs** and **search.test.mjs** (read `stores/search.ts` source), initial-js-trims, fetch-timeouts (reads useLive), last-data-clock, live-follow, topic-row-archive, topic-kind (`.test.mjs`), typecheck, `perf-budget.py` (initial chunk must not grow) | PC | simple_coding | 1 |
| 10 `refactor(r6-10-bash-small-functions)` | small functions | Two iac actions at 117 and 130 lines with no named steps | `csi-spl-iac/src/bash/run/gcp-tail-logs.func.sh` (`do_gcp_tail_logs`, 117)<br>`csi-spl-iac/src/bash/run/gcp-s3-download-all.func.sh` (`do_gcp_s3_download_all`, 130)<br>`csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh:29,30` (their 2 LONG lines go) | 2, section 2 row 9 | split under 80, delete the 2 LONG entries. bash-cleancode, gcp-s3-download-all-mkdir, gcp-key-path-no-eval, gcp-actions-isolated-config, gcloud-account-pinned (.tst.sh). `./run -a do_sec_shellcheck` on the 2 files -> 0 findings (both have no baseline line; a new finding fails) | sat | secret (key paths) | 1 |

Sites: 33 (01: 5, 02: 3, 03: 2, 04: 5, 05: 3, 06: 4, 07: 5, 08: 5, 09: 5, 10: 3). Line ranges for 07 and 08 are the duplicated windows the hash found; the lane reads each copy whole before it extracts.

### 3.1 Disjoint files (R1)

- No path is in two actions of the same batch. `lane-map --check` over every path: free.
- **Shared files, serialised:** `wui:tests/unit/fetch-timeouts.test.mjs` and `wui:src/utils/fetch-timeouts.mjs` belong to 01, then 02 (batch 2). `.shellcheck-warning-baseline.txt` belongs to 04 only; no other row's site has a line in it (`grep -c <basename>` -> 0 for every bash site of 03, 05, 07, 08, 10), and since r5-05 a count below its line fails, so a row that removes a finding there would need that file. `bash-cleancode.tst.sh` LONG list: 10 only (03 must not move `do_gcp_import_to_cloudsql`'s line). `cleancode.test.mjs` LONG set: 09 only. `go-coverage-floor.txt`: 06 only. `check-pre-push.func.sh`: 05 only.
- 07 and 08 each add a NEW file under `csi-spl-orc/lib/bash/funcs/`; no shared loader list (`run.sh:511` sources the dir).
- A test file named in the test column of two actions is READ by both, never edited by both: the editing action is the one whose sites include it.

## 4. Per action: what the lane does

- **01.** Each call gets `signal: AbortSignal.timeout(<budget>)` from `fetch-timeouts.mjs` (reads: the read budget; the hours timer start/stop and status PUT: the write budget). A timeout surfaces as the call's existing failure path, never a new UI state.
- **02.** As 01, after 01 is on trunk. `msg-ai-actions.mjs:288` creates a calendar event: the write budget.
- **03.** `exit 1` -> `return 1`, and the caller already maps a non-zero rc to its FATAL. No other line in either function changes.
- **04.** Fix the 6 findings first (one commit), then widen the scope (second commit, with the red control in its body). Re-measure the baseline on the rebased tree: it must not change.
- **05.** Model the part on `release-note` (per outgoing commit) but REFUSE, not WARN. `SPL_PREPUSH_OVERRIDE=1` still skips it, as every part. The 40-commit window and the 3-path threshold are constants at the top of the file with the retro's n=300 in their comment.
- **06.** Table tests against fakes already in the tree (`internal/testkit`, `httptest`); no Postgres. Floors: `%.1f` of the new value, by hand, same commit.
- **07.** Name the helper after what it does (drop a tagged line, report changed or not). Each caller keeps its own messages and rc.
- **08.** The helper returns the resolved key and pw paths through out-params (round 3 row 29 rule: `# shellcheck disable=SC2034` naming the reader). It never `exit`s and never sets a trap: none of the 5 sites has one today (`grep -c trap <the 5 files>` -> 0 each, on `5c3f1fe42`), and a `RETURN` trap set inside the helper would fire when the helper returns, before the caller reads the paths (section 7, D1).
- **09.** Split by named inner functions; keep each export's signature. No `.vue` change. `perf-budget.py` with CI's node (round 5 memory: box node reads ~0.7 KB low).
- **10.** Named steps inside the same file; no change to the `--account` pin or the key-path resolution (`gcloud-account-pinned.tst.sh`).

## 5. Spawn, done, status (R1-R8)

- **R1** disjoint files: section 3.1.
- **R2** test column: every test file that names the site's basename, a function it defines, or (WUI) its import path; plus every test that holds a 30-character string from a comment within the site (+/- 3 lines); **plus (new, retro 6.3) every package or file that references an exported name the action moves or deletes** (`grep -rn '<pkg>\.<Name>\b' --include=*_test.go`, or `grep -rlw <name>` for bash and WUI). Bold = a test that reads source text.
- **R3, before the wave.** The orchestrator re-runs `lane-map.sh --check <action paths> --agent <its id>` per action. An owned path: wait for that lane, never spawn on top.
- **R4, one spawn per slug across all boxes.** `sat` spawns 03, 04, 05, 07, 08, 10; `PC` spawns 01, 02, 06, 09. Before a spawn: `git log origin/master --grep='r6-NN-' --oneline` is empty and no live lane carries the slug. **The brief carries the plan row verbatim** (its section-3 row and section-4 bullet), never a parse (retro 6.5). The spawner reads the new pane 2 minutes after spawn (retro 6.6).
- **Batch order.** Batch 1 = 01, 03-10, all at once (6 on `sat`, 3 on `PC`). Batch 2 = 02, as soon as 01 is on trunk.
- **R5, done = served.** Hub and WUI changes (01, 02, 06, 09): `cd csi-spl-orc && SHA=<sha> ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd`. Bash and CI changes (03, 04, 05, 07, 08, 10): on `origin/master` and in each box's checkout (`git -C <box checkout> merge-base --is-ancestor <sha> HEAD` on `sat` and `PC`), plus the red control's proof in the commit body. A lane exit-cleans once its commit is on trunk; one deploy lane proves served.
- **R6, no hand-kept status.** `git fetch origin master && git log origin/master --grep='r6-' --format='%h %cI %s'`, then the R5 commands per sha.
- **R7, peer review across vendors (tightened, retro 6.2).** Before the push, a lane sends its diff (a pushed `review/r6-NN` branch, never master) to its named reviewer, who answers `PASS` or `FIX: <item>` against C1-C7. The reviewer is the panel seat of another vendor than the lane: **the agy seat reviews the rows a claude or mistral lane takes; the mistral seat reviews the rows an agy or grok lane takes; the claude seat (editor) reviews a mistral lane's rows.** Backup: the other non-author seat. Only when both have not answered in 15 minutes may a same-vendor lane review, and the line says so. The commit body carries `review: <reviewer id> PASS`. R6 counts: `git log origin/master --grep='r6-' --format=%B | grep -c '^review: '` must reach 10, and the retro counts how many crossed vendors.
  - C1 the diff touches only the action's sites and its tests (`git diff --stat`).
  - C2 behaviour preserved (code) or the red control was seen RED then GREEN (gate), with the command and its output in the body.
  - C3 no file shrank by more than the lines the action removes (`wc -l` before and after).
  - C4 every test in the action's test column ran and passed, named in the body.
  - C5 no comment states something the code does not do.
  - C6 hygiene and pre-push passed with no override.
  - **C7 (new, retro 4.1) the pushed sha is the reviewed sha** (`git diff <reviewed> <pushed> --stat` -> only the rebase's trunk files, none of the row's own sites changed after review).
- **R8, retro.** After the 10 actions are served, one lane writes `refactor-round-6-retro.md` in the shape of `refactor-round-5-retro.md`; its section 6 feeds round 7. Then, per `SPEC-spool-fleet-roles.md` section 1.2, the dispatcher requests round 7's planner at once.
- **R9 (new, retro 6.4), gate lanes.** 04 and 05 run their own test once under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` variable unset, before the first push.

## 6. Process practices, measured (no lane)

| owner practice | measured state on `da36dad94` | verdict |
|---|---|---|
| peer code review with a checklist before merge | `git log origin/master --since=2026-10-03 --format=%B \| grep -ciE '^review: '` -> 13 (12 of them r5); 0 of the 12 r5 lines crossed vendors (retro 4.3) | **tightened:** R7 names cross-vendor reviewers from the panel, plus C7 |
| regular training, a retro per round | `ls csi-spl-doc/doc/md \| grep retro` -> rounds 3 and 5 | **in place:** R8 |
| regular refactoring alongside features | owner msg 3d22fcea: rounds need no go; the next round starts when this one is served | **in place as a rule:** `SPEC-spool-fleet-roles.md` section 1.2 |
| shared standards | `fleet-rules-index.md` section 2 (one home per rule), drift-gated | **in place** |
| CI that blocks broken builds | round 5 made the e2e verdict real (r5-08) and added an orc pre-push part (r5-07); the r5 clobber was invisible to CI (retro 3) | action 05 |
| formatting enforced | Go `gofmt -l` 0, Python `ruff format --check` 54 of 54 (r5-09) | **in place** for Go and Python; bash and WUI: section 8 |

## 7. Disagreements

Seat verdicts on `ed453dd77`: claude 10 agree (the planner's proposal), agy 10 agree, mistral 9 agree + 08 "agree with changes". No seat proposed a new row or dropped one, so no row's sites changed and nothing was re-measured beyond the fold check in the header.

| # | seat | item | settled |
|---|---|---|---|
| D1 | mistral (m-710) | 08: "Move the `RETURN` trap to the helper", to avoid repeating it in every caller | **Refuted by a command, not folded.** (a) There is no trap to move: `grep -c trap csi-spl-orc/src/bash/run/spl-{backfill,fallback,reply-count,reply,topic-reply}-probe.func.sh` -> 0, 0, 0, 0, 0 on `5c3f1fe42`; the preamble validates paths, it creates no temp file to clean. (b) A `RETURN` trap set inside a helper fires when the HELPER returns, not the caller: `bash -c 'h(){ trap "echo TRAP; trap - RETURN" RETURN; echo helper-end; }; c(){ h; echo caller-next; }; c'` prints `helper-end`, `TRAP`, `caller-next`, so a cleanup moved into the helper would run before the caller uses what it cleans (the round 4 section 6 reason the rule exists). Row 08 stays as written; section 4 bullet 08 now says why. Put to m-710 once on `dispatch-4f46ce09`; its answer is recorded in section 10. |

## 8. Measured and left out

| what | why it is out | measured by |
|---|---|---|
| `cmd/spool` coverage 26.8% (73 functions at 0%) | too wide for one lane; first after 06 shows the per-package pace | `go tool cover -func` |
| the `_spl_sdk_saved` / `CLOUDSDK_CONFIG` preamble, 13 copies (`gcp-002-delete-project-service-account`, `gcp-compute-lb-*`, `gcp-fetch-secrets`, ...) | the RETURN trap must stay in each caller (round 4 section 6), so a helper saves about 3 lines a copy; destructive gcp actions | the 6-line-window hash |
| the install-cron `SPL_DESK_CRON_CREATE` block, 9 copies | after 07 lands, the same lane pattern; one cron DRY row per round keeps R1 simple | the hash |
| `gcp-backup-env.func.sh` (82) and `check-weekly-full-scan.func.sh` (128) LONG entries | each has a `.shellcheck-warning-baseline.txt` line; a split that drops it needs the baseline file, which is 04's this round | `grep -c <name> .shellcheck-warning-baseline.txt` -> 1 each |
| the big Pinia setup stores (`channel.ts` 576, `notification.ts` 430, `flow.ts` 321) | each is a live feature area; a split is its own planned row with the feature lane's owner | `cleancode.test.mjs:43-46` |
| shfmt and prettier | no config and no tool; one format wave over every live lane's files (r5 section 8) | `git ls-files` counts |
| `require-var.func.sh` `exit 1` (iac and orc) | its job is to stop the run when a variable is missing | read by hand |

## 9. Counts

| | Go | TS/Vue | bash | CI / gate | total |
|---|---|---|---|---|---|
| code actions | 0 | 3 (01, 02, 09) | 4 (03, 07, 08, 10) | 0 | 7 |
| test actions | 1 (06) | 0 | 0 | 0 | 1 |
| gate actions | 0 | 0 | 0 | 2 (04, 05) | 2 |
| per box | `sat`: 03, 04, 05, 07, 08, 10 | | | `PC`: 01, 02, 06, 09 | 10 |
| agent kind | simple_coding: 01, 02, 07, 09 | secret: 03, 08, 10 | complex_coding: 04, 05 | tests: 06 | 10 |

## 10. Consensus

Signed plan sha: **`eb8cbfc1c`** (the fold of the three seats; this section and the status line are the only edits after it).

| seat | signed | how |
|---|---|---|
| claude (editor c-711; proposal by the planner c-709) | `eb8cbfc1c` | the editor's fold, 10 agree |
| mistral (m-710) | `eb8cbfc1c` | spool `dispatch-4f46ce09` msg 06475b3b: "SIGN eb8cbfc1c"; accepts D1, row 08 unchanged |
| agy (a-763) | `eb8cbfc1c` | signed `ed453dd77` (10 agree); carried over to `eb8cbfc1c` by the orchestrator, no row changed (`git diff --stat ed453dd77 eb8cbfc1c -- refactor-round-6-plan.md` -> 1 file, +9/-5; 0 changed lines start `\| 01`..`\| 10`). Orchestrator c-001, msg a0ae9d37 |
