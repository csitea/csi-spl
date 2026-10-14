# Refactor round 10 - claude seat review (c-120@sat)

The claude seat's review of [../refactor-round-10-plan.md](../refactor-round-10-plan.md),
draft v0.1 (landed in `d7d0e557c`). Editor: c-119@sat, task `dispatch-3209f8b8`,
issue SPL-1865. A seat commits this file and nothing else (R7.6).

**One sha:** every count below is measured on **`3cd461397`** (`origin/master`,
2026-10-14 16:29Z), n=1 per command unless stated. Between the plan's
`43688a782` and `3cd461397` no row site changed: `git diff --stat 43688a782
3cd461397 --` over every row path (the 01 `cmd/spool` dir and floor file,
`flow.ts`, `auth-client.mjs`, `cleancode.test.mjs`, `csi-spl-iac/src/bash/run`,
`csi-spl-iac/src/bash/tests`, `spl-cloud-cnf.func.sh`, the prune and push
actions, `csi-spl-orc/src/bash/tests`) -> empty. One change does touch the
WUI rows: `3cd461397` itself moves typescript 5.9.3 -> 6.0.3 (rows 02, 03
below).

## 1. Re-measured counts

| row | command (on `3cd461397`) | plan says | measured |
|---|---|---|---|
| 01 | `go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out \| awk '$3=="0.0%"' \| wc -l` (go1.26.9) | 26 at 0.0 %, total 68.7 %, floor 68.5 | 26; `total: (statements) 68.7%`; `grep 'cmd/spool' go-coverage-floor.txt` -> `cmd/spool 68.5` |
| 01 | same profile, the 5 verbs | `issue.go:35`, `ask.go:21`, `lease.go:16`, `fleet_load.go:34`, `edit.go:58` | the same 5 lines, each `0.0%` |
| 01 | statements with count 0 in those functions, summed from `cov.out` | - | `ask.go` 70 (with its helpers `askPoolFlags:85`, `splitList:115`), `cmdAttachRename` 14, `cmdFleetLoad` 16, `cmdIssue` 15, `cmdLease` 16 = **131 of 2677**: the ceiling is 73.6 % ((1840 + 131) / 2677), so a raised floor is reachable |
| 02, 03 | `git show 3cd461397:csi-spl-wui/tests/unit/cleancode.test.mjs \| sed -n '/^const LONG/,/^])/p'` | 7 entries; `flow.ts <anon>` 317, `createAuthClient` 326 | the same; entries at `cleancode.test.mjs:36` and `:39`; `flow.ts:50` and `auth-client.mjs:222` are the store and the factory |
| 02, 03 | `node tests/unit/cleancode.test.mjs` (after `pnpm install --frozen-lockfile`, typescript 6.0.3) | - | `cleancode: 9828 functions, 7 listed long, none deeper than 4 or wider than 6` |
| 02, 03 | `pnpm run typecheck` (typescript 6.0.3) | - | rc 0 |
| 03 | `git grep -lE "auth-client(\.mjs)?['\"]\|createAuthClient" -- csi-spl-wui/tests \| wc -l` | 13 | 13 |
| 04-07 | `git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' 3cd461397 -- csi-spl-iac \| wc -l` | 23 | 23; `git grep -n` puts the block at exactly the 20 `file:line` sites of rows 04-07 |
| 04-07 | each named test, `git ls-files '*/<name>.tst.sh'` | 16 distinct tests | all 16 exist (`heal-hub-deploy` and `cloud-actions` under `csi-spl-orc/src/bash/tests`, the rest under `csi-spl-iac/src/bash/tests`) |
| 07 | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | `do_gcp_002_delete_project_service_account 133` | LONG line `... 133`; the function measures 133 |
| 08 | same test | 14 listed, `do_spl_cloud_cnf` 96 at 51-146, LONG line 30 | `PASS: no function over 80 lines outside LONG or over its ceiling (14 listed)`; the function spans 51-146 = 96; `grep -n 'do_spl_cloud_cnf 96'` -> line 30 |
| 08 | `git grep -lw do_spl_cloud_cnf -- '*.tst.sh' \| grep -v bash-cleancode \| wc -l` | 71 | 71 |
| 09 | `git ls-remote --heads origin`, names matching `(^\|[/-])r[789]([^0-9]\|$)` | 36 | 36; the 3 the matcher misses: `c-517-r9-10-bash-temp-sdk-config-helper`, `c-996-r9-05-bash-cleancode-walker`, `review/c-104-r9-02-go-coverage-spool-cli-inspect` |
| 09 | `ROUND="7,8,9" DRY_RUN=1 ./run -a do_git_prune_round_branches` | 33 listed | `OK DRY_RUN round 7 8 9: 33 branch(es) listed on origin, nothing deleted` |
| 09 | `git cherry origin/master <tip> \| grep -c '^+'` for **each of the 36** tips | 3 tips with unlanded commits | **7**: `wip/m-947-r7-09` 1, `wip/review/r7-01` 1, `wip/review/r7-09` 2, and `review/r7-05` 5, `review/r7-05-clean` 2, `review/r7-05-final` 2, `review/r7-05-squashed` 2 |
| 10 | `awk` over `spl-push-master.func.sh` | worker at 128, identity check at 151 | `_spl_push_master_worker` 128-170 (43 lines); `bad="$(git log --no-mailmap ...)"` at 151 |
| 10 | `git grep -nE "\^review: " -- 'csi-spl-orc/src/**' 'csi-spl-iac/src/**' '.github/**' \| wc -l` | 0 | 0 |
| R3 | `lane-map.sh --check csi-spl-doc/doc/md/refactor-round-10/seat-claude.md --agent c-120` | c-296@PC records no files | rc 4: `c-296@<box2> c-296-cga-editor` and `c-519@<box2> c-519-go-mod-cache-auto-warm` record no files |

## 2. Verdict per row

| row | verdict | why, with the command behind any change |
|---|---|---|
| 01 | **agree with changes** | Sites and counts hold. Change: name `askPoolFlags` (`ask.go:85`) and `splitList` (`ask.go:115`) in the row's test text. They are 2 of the 26 zero functions and come with `cmdAsk`, so the `ask` cases drive the pool flags and a comma list, not only the bare verb. Sections 2 and 6 then read "5 CLI verbs + 2 `ask.go` helpers; 19 left out" instead of "21 in `hub.go`, `key.go`, `main`": measured `hub.go` 12, `key.go` 4, `main.go` 1, `hub_repo_edit.go` 2 (`repoEdit`, `nonEmpty`), `ask.go` 2 (the same `awk '$3=="0.0%"'` list). The floor target is reachable: 73.6 % ceiling (section 1). |
| 02 | **agree** | 317 and the LONG entry hold. Note for the row brief: trunk builds with typescript 6.0.3 since `3cd461397`; `pnpm run typecheck` rc 0 on it here, but CI has no green read on that sha (`gh run view 38598565319`: `10 ci: quality gate`, cancelled, superseded). The lane's own typecheck is the read that counts. |
| 03 | **agree** | 326, 13 test files, batch 2 after 02 (shared `cleancode.test.mjs`): hold. Same typescript note as 02. |
| 04 | **agree** | 5 sites at the plan's lines (`git grep -n`, section 1). Vendor grok, backup claude after 2 tries, as the owner rule says. This seat reviews it (grok author). |
| 05 | **agree** | 5 sites at the plan's lines. This seat reviews the row (mistral author), section 5. |
| 06 | **agree** | 5 sites at the plan's lines; the 8 named tests exist. This seat reviews it (grok author). |
| 07 | **agree** | 5 sites hold. Follow-up, not a change: after 07, `do_gcp_002_delete_project_service_account` measures under its 133 ceiling and the test prints the NOTE. 07 may not edit `bash-cleancode.tst.sh` (08 holds it in batch 1), so the stale ceiling goes to round 11, or to whichever of 07 and 08 lands second if the editor prefers. |
| 08 | **agree** | 96 lines at 51-146, LONG line 30, 14 listed, 71 other tests: all hold. |
| 09 | **agree with changes** | The KEEP rule (`git cherry` `+` lines) is right, but it keeps **7** tips, not 3 (section 1, all 36 tips checked). The 4 `review/r7-05*` tips are drafts of row r7-05, which landed squashed as `ae6991bf4` (`git log origin/master -E --grep='r7-05' --oneline` -> `ae6991bf4 refactor(r7-05-bash-cron-checkout-helper): ...`). A squash changes the patch id, so `git cherry` reports their commits as unlanded. Changes: (a) the after-landing expectation reads "`ROUND="7,8,9" DRY_RUN=1` matches 36, prints 7 `KEEP`, lists 29" instead of "lists 33 (36 - 3 kept)"; (b) the red-control fixtures add a squash-landed tip (2 commits that landed as 1) and assert it is KEPT, so nobody later turns the rule into deleting it; (c) the 7 `KEEP` lines go to the orchestrator as the plan says, with the `ae6991bf4` note on the 4 r7-05 tips, so it can decide `PRUNE_UNLANDED=1` for those. |
| 10 | **agree** | Worker 43 lines, identity check at 151, 0 gates today: hold. The row's own landing commit matches its regex, so it lands with its review line like every other row. |

## 3. Left out that should be named

- **Row 10 covers `do_spl_push_master` only.** A lane that pushes by hand
  (`git push origin HEAD:master`: the seed forbids it, nothing refuses it)
  passes no review-line gate:
  `git grep -n 'review' -- csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push | wc -l` -> 0.
  Round 11 input: the same check in the pre-push hook, beside its non-ff guard.
- **Section 3.2:** the lane map now places c-296 on the second box (`<box2>`), not PC, and shows
  c-519@<box2> (go mod cache warm-up) as a second lane with no files recorded
  (section 1, R3 line). The spawner's per-row `--check` (R3) still asks both.

## 4. Signature

Pending the editor's v1.0 sha.
