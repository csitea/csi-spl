# Refactoring round 10 - plan (10 actions)

Owner HUM-10, t1 topic `4f46ce09-15ee-4b9a-b05f-edd9812b51fb`, msg 3d22fcea:
rounds run continuously, **no owner go for the round, its panel or its
lanes**. Refactoring share: owner t1 3209f8b8 (msgs a25bfdd6, 36ee9cec,
8cb6cc7d). Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items,
push caps, bands, R1-R16), by pointer, not copied. Issue: SPL-1865.

**Status: DRAFT v0.1**, for the panel. The rows spawn from the signed sha
(rulebook 1.4: consensus, then build, no second go).

Editor: **c-119@sat** (claude), re-placed from a-115@sat (agy, out of quota
until about 2026-10-15T09:50Z). a-115's uncommitted draft (on `1c6d8a580`)
was the start; what changed is in section 7.

**One sha:** every count is measured on **`43688a782`** (`origin/master`,
2026-10-14 15:59Z), n=1 per command unless stated. Input:
[refactor-round-9-retro.md](refactor-round-9-retro.md) section 6.

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept, or for a gate a **red control**: the
  check fails on the bad input before the change and passes after.
- **Paths:** `api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` =
  `csi-spl-wui/`, `orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`. Lines as
  of `43688a782`.
- **Box:** the preferred box; the spawner's box pick may move a row (no pin).
- **Vendor:** the owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`
  on `43688a782`: tests -> claude; simple_coding -> grok, backup claude;
  cnf `agent_split_by_kind.simple_coding` = grok 41, mistral 39, claude 20),
  then R14. Rounds 7-9 landed 30 of 30 rows on claude; this round puts the
  3 most mechanical rows (04, 05, 06) on grok and mistral, so the mix gets a
  measured try. Each has claude as its backup after 2 tries (owner 10-12).
- **Subject** (R6 reads it): `<type>(r10-NN-<slug>, SPL-<row issue>): ...`.
- **R7.4:** the `review:` line is in the landing commit, never a later
  `chore(...)` (round 9: 6 of 10 rows did that, retro 4.1).

## 2. Where the rows come from (measured on `43688a782`)

| source | command | n | row |
|---|---|---|---|
| retro 6.1: pure CLI verbs at 0.0 % | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out \| awk '$3=="0.0%"'` | 26 functions at 0.0 %, 5 of them CLI verbs; total 68.7 %, floor 68.5 | 01 |
| retro 6.2 | `sed -n '/^const LONG/,/^])/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `flow.ts <anon>` 317 (7 entries) | 02 |
| retro 6.3 | same | `auth-client.mjs createAuthClient` 326 | 03 |
| retro 6.4 | `git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' 43688a782 -- csi-spl-iac \| wc -l` | 23 files | 04, 05, 06, 07 (20 files) |
| retro 6.5 | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | 14 listed; `do_spl_cloud_cnf` 96 (`spl-cloud-cnf.func.sh:51-146`) | 08 |
| retro 6.8 | `ROUND="7,8,9" DRY_RUN=1 ./run -a do_git_prune_round_branches` vs `git ls-remote origin` | 33 listed of 36 round branches; 3 r7 `wip/` tips with unlanded commits | 09 |
| retro 6.9 | `git grep -nE "\^review: " -- 'csi-spl-orc/src/**' 'csi-spl-iac/src/**' '.github/**'` | 0 gates; round 9: 3 rows with no review line | 10 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `test(r10-01-go-coverage-spool-cli-verbs)` | tests, coverage | 5 CLI verbs at 0.0 % | `api:cmd/spool/issue.go:35`<br>`api:cmd/spool/ask.go:21`<br>`api:cmd/spool/lease.go:16`<br>`api:cmd/spool/fleet_load.go:34`<br>`api:cmd/spool/edit.go:58` | 5 functions at 0.0 % | new `cmd/spool/cli_verbs_test.go` on `newScriptHub` (`scripthub_test.go:39`); raise `cmd/spool` in `csi-spl-api/src/bash/tests/go-coverage-floor.txt` to the measured value (n=3 reads). **Red control:** without the new test file the raised floor fails | PC | claude | tests | 1 |
| 02 `refactor(r10-02-wui-small-store-flow)` | small functions | store setup 317 lines | `wui:src/stores/flow.ts:50`<br>`wui:tests/unit/cleancode.test.mjs:36` | 1 LONG entry | named module functions under 80 lines; delete the LONG entry (7 -> 6). Tests: `cleancode.test.mjs`, `flow-badge.test.mjs`, `pnpm run typecheck`, **`perf-budget.py bundle`** on the generated bundle (retro 4.3) | PC | claude | simple_coding (R14) | 1 |
| 03 `refactor(r10-03-wui-small-auth-client)` | small functions | factory 326 lines | `wui:src/utils/auth-client.mjs:222`<br>`wui:tests/unit/cleancode.test.mjs:39` | 1 LONG entry | named factory helpers under 80 lines; delete the LONG entry (6 -> 5). Tests: the 13 unit tests that import it (`git grep -lE "auth-client(\.mjs)?['\"]\|createAuthClient" -- csi-spl-wui/tests`), typecheck, **`perf-budget.py bundle`** | PC | claude | simple_coding (R14) | 2 (after 02: `cleancode.test.mjs`) |
| 04 `refactor(r10-04-bash-temp-sdk-config-compute-dns)` | DRY | the 4-line block, 5 copies | `iac:src/bash/run/gcp-compute-lb-cleanup.func.sh:9`<br>`…/gcp-compute-lb-list.func.sh:9`<br>`…/gcp-export-dns-settings.func.sh:7`<br>`…/gcp-export-dns.func.sh:8`<br>`…/gcp-tail-logs.func.sh:23` | 5 files | `spl_gcp_temp_sdk_config` + caller RETURN trap, as `af3dfe623`. Tests: `gcp-actions-isolated-config.tst.sh`, `gcp-temp-sdk-config.tst.sh`, `return-not-exit-gcp.tst.sh`. **Control:** the old-literal grep on the 5 files -> 0; `wc -l` per file within +3/-4 (C3) | sat | grok (backup claude) | simple_coding | 1 |
| 05 `refactor(r10-05-bash-temp-sdk-config-storage-sync)` | DRY | 5 copies | `iac:src/bash/run/gcp-s3-download-all.func.sh:13`<br>`…/gcp-sync-local-to-s3.func.sh:9`<br>`…/gcp-sync-s3-to-local.func.sh:9`<br>`…/gcp-sync-src-bucket-data-to-tgt-bucket.func.sh:8`<br>`…/gcp-sync-src-s3-to-tgt-s3.func.sh:8` | 5 files | as 04. Tests: `gcp-actions-isolated-config.tst.sh`, `gcp-key-path-no-eval.tst.sh`, `gcp-s3-download-all-mkdir.tst.sh`, `gcp-exit-status-checks.tst.sh`. Control as 04 | sat | mistral (backup claude) | simple_coding | 1 |
| 06 `refactor(r10-06-bash-temp-sdk-config-secrets-keys)` | DRY | 5 copies | `iac:src/bash/run/gcp-copy-secret.func.sh:22`<br>`…/gcp-fetch-secrets.func.sh:12`<br>`…/spl-gh-app-key-put.func.sh:20`<br>`…/spl-vendor-key-grant-check.func.sh:26`<br>`…/spl-vendor-key-pepper-put.func.sh:21` | 5 files | as 04. Tests: `gcp-actions-isolated-config.tst.sh`, `adhoc-harvest-gcp-actions.tst.sh`, `gcp-exit-status-checks.tst.sh`, `github-app-key-put-rotate.tst.sh`, `hub-github-app-key-030.tst.sh`, `spl-gh-app.tst.sh`, `spl-vendor-key-grant-check.tst.sh`, `spl-vendor-key-pepper-put.tst.sh`. Control as 04 | sat | grok (backup claude) | simple_coding | 1 |
| 07 `refactor(r10-07-bash-temp-sdk-config-projects-iam)` | DRY | 5 copies | `iac:src/bash/run/gcp-002-delete-project-service-account.func.sh:6`<br>`…/gcp-audit-iam.func.sh:24`<br>`…/gcp-backup-env.func.sh:30`<br>`…/gcp-delete-service-account.func.sh:7`<br>`…/gcp-hub-restart.func.sh:24` | 5 files | as 04. Tests: `gcp-actions-isolated-config.tst.sh`, `adhoc-harvest-gcp-actions.tst.sh`, `gcp-hub-restart.tst.sh`, `heal-hub-deploy.tst.sh`, `bash-cleancode.tst.sh` (run, **not edited**: `do_gcp_002_delete_project_service_account 133` may only print its NOTE) | sat | claude | simple_coding (R14) | 1 |
| 08 `refactor(r10-08-bash-small-spl-cloud-cnf)` | small functions | 96 lines | `orc:lib/bash/funcs/spl-cloud-cnf.func.sh:51`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:30` | 1 LONG entry | named steps under 80 lines, same exports and exits; delete the LONG line (14 -> 13). Tests: `bash-cleancode.tst.sh`, `cloud-actions.tst.sh`, and the 71 other `.tst.sh` naming it (`git grep -lw do_spl_cloud_cnf -- '*.tst.sh' \| grep -v bash-cleancode \| wc -l` -> 71; run the orc suite) | sat | claude | simple_coding (R14) | 1 |
| 09 `ci(r10-09-round-branch-prune-lane-prefixed)` | nothing ad hoc, branch hygiene | 3 of 36 round branches escape the matcher; unlanded commits deleted silently | `orc:src/bash/run/git-prune-round-branches.func.sh:27-33`<br>`orc:src/bash/run/git-prune-round-branches.func.sh:58`<br>`orc:src/bash/tests/git-prune-round-branches.tst.sh` | 3 missed, 3 unlanded tips | `prune_round_match` also takes `<id>-r<N>-*` and `review/<id>-r<N>-*` (`<id>` = `[acgmq]-[0-9]{3}`); a tip with `git cherry origin/master <tip>` `+` lines prints `KEEP <branch> <n> unlanded` and stays unless `PRUNE_UNLANDED=1`. **Red control:** fixtures for a lane-prefixed branch (missed before) and an unlanded tip (deleted before) fail on the old code. After landing: `ROUND="7,8,9" DRY_RUN=1` lists 33 (36 - 3 kept), then `DRY_RUN=0` (rulebook R8 step 2) | sat | claude | simple_coding (R14) | 1 |
| 10 `ci(r10-10-push-master-review-line)` | review before merge, gate | round rows land without a review line, no gate | `orc:src/bash/run/spl-push-master.func.sh:128`<br>`orc:src/bash/tests/spl-push-master.tst.sh` | 0 gates; 3 of 10 r9 rows with no line | the push worker refuses, beside the identity check (line 151), a commit in `<remote>/<branch>..HEAD` whose subject matches `^(test\|refactor\|ci\|fix\|feat\|perf)\(r[0-9]+-[0-9]{2}-` and whose body has no `^review: \S+@\S+ \S+ PASS [0-9a-f]{7,40} `: `REFUSED round row <sha> has no R7 review line`. **Red control:** a fixture `refactor(r99-01-x)` commit with no line is refused, with the line it pushes; a `chore(r99-01-x)` and a `docs(...)` commit pass. R9: `PRE_PUSH_TIER=full` | sat | claude | simple_coding (R14) | 1 |

### 3.1 Disjoint files (R1)

- **Batch 1:** 01, 02, 04, 05, 06, 07, 08, 09, 10. No path is in two of
  them: 01 Go + floor file; 02 `flow.ts` + `cleancode.test.mjs`; 04-07 five
  different `iac:src/bash/run/` files each (20 in all, no file twice); 08
  `spl-cloud-cnf.func.sh` + `bash-cleancode.tst.sh` (07 runs it, never edits
  it); 09 the prune action + its test; 10 the push action + its test.
- **Batch 2:** 03, after 02 lands (`cleancode.test.mjs`); placed within 30 min
  of 02 landing (R16).
- Rows 04-07 only call the helper; none edits `gcp-temp-sdk-config.func.sh`
  or `gcp-actions-isolated-config.tst.sh`.

### 3.2 Off every live lane (R3)

`lane-map.sh --check <every row path> --agent c-119` on `43688a782` -> rc 4:
no live lane lists any of them; one live lane records no files: c-296@PC
(`c-296-cga-editor`, CI gate analysis, spec 133, then the standing
CI-refactor seat). Its brief (`dispatch/briefs/c001-cga-editor.md`) names
`.github/workflows/10_ci-quality.yml`, `pre-push-gate.md` and spec 131/133,
none of the row paths; asked on the spool before the plan was posted. The
spawner re-runs `--check` per row (R3).

## 4. Per row: what the lane does

- **01:** write `api:cmd/spool/cli_verbs_test.go` that drives `issue`
  (list/show/new/edit/close), `ask`, `lease` (get/cas), `fleet-load` and
  `attach-rename` against `newScriptHub`: no Postgres, no network. Assert the
  frames sent and the exit codes, refusals included. Read `cmd/spool` 3 times,
  set the floor to the lowest read.
- **02:** split the `useFlowStore` setup body (`flow.ts:50`) into
  module-level step functions under 80 lines; the store's exported API and
  reactivity stay as they are. Measure `ci_initial_gzip_kb` before and after
  with the CI node version; it may not rise.
- **03:** split `createAuthClient` (`auth-client.mjs:222`) into named helper
  factories under 80 lines; the returned object, its credentialed calls and
  its errors stay as they are. Same bundle check as 02.
- **04-07:** in each named file, replace the 4-line block (`local
  _spl_sdk_saved=...`, `mktemp -d`, `export CLOUDSDK_CONFIG`, the RETURN trap)
  with `local _spl_sdk_saved _spl_sdk_dir`, `spl_gcp_temp_sdk_config || return 1`
  and `trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN`, and
  source the helper when the file is loaded alone (the `af3dfe623` pattern).
  No other line changes. Commit body: `git diff --stat` and `wc -l` before and
  after each file.
- **08:** split `do_spl_cloud_cnf` into named steps under 80 lines; the same
  exported variables, cache and exit codes. Delete line 30 of
  `bash-cleancode.tst.sh`.
- **09:** as in the table; then run the prune for rounds 7-9 and paste the
  `DRY_RUN=1` and `DRY_RUN=0` output in the result. The kept unlanded tips go
  to the orchestrator as a list, not deleted.
- **10:** as in the table; the refusal lives in a helper so
  `_spl_push_master_worker` stays under 80 lines. The rows of this round land
  with the line already, so the gate refuses none of them.

## 5. Panel and reviewers (R7)

agy has no quota until about 2026-10-15T09:50Z, so the panel is **claude +
mistral + grok** (grok if it has quota at spawn; else claude + mistral). The
plan has no multilingual text: no agy language review is needed.

- Seats write `refactor-round-10/seat-<vendor>.md` (verdict per row: agree,
  agree with changes, disagree, with the command behind any change), commit
  that file only (R7.6), then sign the editor's v1.0 sha.
- Seats stay up after signing: they are this round's reviewers until R6
  shows 10 of 10 rows on trunk (R7.1).
- Reviewer per row, cross-vendor (R7.2): claude rows (01, 02, 03, 07, 08,
  09, 10) -> the mistral seat, backup the grok seat; grok rows (04, 06) ->
  the claude seat, backup the mistral seat; the mistral row (05) -> the
  claude seat, backup the grok seat. Where round 9 named agy, a claude or
  mistral seat of the other vendor takes it.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| 3 CLOUDSDK_CONFIG files: `gcp-import-to-cloudsql`, `gcp-project-delete`, `gcp-sync-src-s3-to-tgt-s3-silent` | 5 sites per row, 10 rows per round; round 11 | the 23-file grep, section 2 |
| `cmd/spool` `hub.go`, `key.go`, `main` (21 functions at 0.0 %) | need Postgres, a key daemon or the process entry | `go tool cover -func`, section 2 |
| WUI LONG `channel.ts` 576, `notification.ts` 430, `live.ts setup` 304, `live-ws.mjs` 499, `spool-client.mjs` 545 | larger live stores; 02 and 03 first | LONG map |
| bash LONG `check-pre-push 137`, `spawn_main 185`, `run.sh do_log 143` (x2) and the gcp-001/002 actions | the pre-push gate is c-296's CI area; the rest next rounds | `bash-cleancode.tst.sh` |
| a-115's draft row "prune rounds 7-9 now" | it would delete 3 unlanded r7 tips and miss 3 r9 branches; row 09 fixes the matcher first | retro section 5 |

## 7. What changed from the a-115 draft

- Re-measured on `43688a782` (the draft used `1c6d8a580`); the counts that
  matter held (23 files, 68.7 %, 14 bash LONG, 7 WUI LONG, 33 listed).
- Rows 01+02 of the draft (two Go coverage rows sharing the floor file) are
  one row, 01, with all 5 zero-coverage verbs (`ask` added).
- The draft's prune row ran `DRY_RUN=0` straight away; row 09 now fixes the
  matcher and keeps unlanded tips first.
- New row 10: the R7 review-line gate (retro 4.1).
- DRY rows: 20 of 23 files (the draft did 19 and called the rest
  destructive; they are left only for the row cap). Vendors per the owner
  mix (04, 06 grok; 05 mistral) instead of all claude.
- The draft's test `spl-cloud-cnf.tst.sh` does not exist
  (`ls csi-spl-orc/src/bash/tests | grep -c cloud-cnf` -> 0); row 08 names the
  real tests. WUI rows gain the bundle budget check (retro 4.3).
- a-115's `seat-agy.md` is not landed: its seat is closed and its numbers
  were not re-measured.

## 8. Counts

| | n |
|---|---|
| rows | 10 (tests 1, refactor 7, ci 2) |
| vendor | claude 7, grok 2, mistral 1 |
| box (preferred) | sat 7, PC 3 |
| batches | batch 1: 9; batch 2: 1 |

## 9. Consensus

Signed plan sha: **pending**.

| seat | id | signed | file |
|---|---|---|---|
| editor (claude) | c-119@sat | draft v0.1 | this file |
| claude seat | pending | - | `refactor-round-10/seat-claude.md` |
| mistral seat | pending | - | `refactor-round-10/seat-mistral.md` |
| grok seat | pending (if quota) | - | `refactor-round-10/seat-grok.md` |
