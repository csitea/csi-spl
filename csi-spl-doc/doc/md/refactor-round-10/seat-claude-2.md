# Refactor round 10 - second claude seat review (c-522@PC)

The second claude seat's review of [../refactor-round-10-plan.md](../refactor-round-10-plan.md),
draft v0.2 (`bcc48824a`). It replaces the mistral seat m-127 (closed after 2
tries with no seat file). Editor: c-119@sat, task `dispatch-3209f8b8`, issue
SPL-1865. A seat commits this file and nothing else (R7.6).

**One sha:** every count below is measured on **`050b06e65`** (`origin/master`,
2026-10-14 18:11Z), n=1 per command unless stated.
`git diff --stat 43688a782 050b06e65 --` over every row path (the 01
`cmd/spool` dir and floor file, `flow.ts`, `auth-client.mjs`,
`cleancode.test.mjs`, `csi-spl-iac/src/bash/run`, `csi-spl-iac/src/bash/tests`,
`spl-cloud-cnf.func.sh`, the prune and push actions and their tests) -> 3
files: `cmd/spool/doctree.go` +32/-3 and `doctree_test.go` +28 (`e6338d7ab`),
and `spl-cloud-cnf.func.sh` +9/-1 (`b8a8afa5e`). Rows 01 and 08 below.

## 1. Re-measured counts

| row | command (on `050b06e65`) | plan says | measured |
|---|---|---|---|
| 01 | `go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out \| awk '$3=="0.0%"' \| wc -l` (go1.26.9) | 26 at 0.0 %, total 68.7 %, floor 68.5 | 26; `total: (statements) 69.1%`; `grep -n 'cmd/spool' go-coverage-floor.txt` -> line 11 `cmd/spool 68.5` |
| 01 | same list | the 5 verbs + `askPoolFlags:85`, `splitList:115`; 19 left out | the same 7; left out: `hub.go` 12, `key.go` 4, `main.go` 1, `hub_repo_edit.go` 2 = 19 |
| 02, 03 | `git show 050b06e65:csi-spl-wui/tests/unit/cleancode.test.mjs \| sed -n '/^const LONG/,/^])/p' \| grep -c "src/"` | 7; `flow.ts <anon>` 317, `createAuthClient` 326 | 7; the same two entries, at `cleancode.test.mjs:36` and `:39`; `flow.ts:50` and `auth-client.mjs:222` hold |
| 03 | `git grep -lE "auth-client(\.mjs)?['\"]\|createAuthClient" 050b06e65 -- csi-spl-wui/tests \| wc -l` | 13 | 13 |
| 04-07 | `git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' 050b06e65 -- csi-spl-iac \| wc -l` | 23 | 23; `git grep -n` puts the block at the 20 `file:line` sites of rows 04-07 exactly, plus the 3 left out in section 6 |
| 04-10 | `git ls-files "*/<name>.tst.sh" \| wc -l` for each of the 18 named tests | each exists | 1 each |
| 07, 08 | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | 14 listed; LONG `do_gcp_002_delete_project_service_account 133`, `do_spl_cloud_cnf 96` at line 30 | `PASS: no function over 80 lines outside LONG or over its ceiling (14 listed)`; `grep -n` -> line 22 `... 133`, line 30 `... 96` |
| 08 | `awk` over `spl-cloud-cnf.func.sh`, `do_spl_cloud_cnf()` to its `}` | 51-146 | **59-154**, 96 lines: `b8a8afa5e` (`fix(orc): do_spl_cloud_cnf reads the cnf cache through one open ...`) put `spl_cnf_copy_cache` (8 lines with its comment) above it |
| 08 | `git grep -lw do_spl_cloud_cnf 050b06e65 -- '*.tst.sh' \| grep -v bash-cleancode \| wc -l` | 71 | 71; it includes `host-spool-no-rebuild.tst.sh`, which `b8a8afa5e` extended for the cache copy |
| 09 | `git ls-remote --heads origin`, names matching `(^\|[/-])r[789]([^0-9]\|$)` | 36 | 36 |
| 09 | `ROUND="7,8,9" DRY_RUN=1 ./run -a do_git_prune_round_branches` | 33 listed | `OK DRY_RUN round 7 8 9: 33 branch(es) listed on origin, nothing deleted` |
| 09 | `git cherry origin/master <tip> \| grep -c '^+'` for each of the 36 tips | 7 KEEP | 7: `review/r7-05` 5, `review/r7-05-clean` 2, `review/r7-05-final` 2, `review/r7-05-squashed` 2, `wip/m-947-r7-09` 1, `wip/review/r7-01` 1, `wip/review/r7-09` 2 |
| 09 | `sed -n 29,34p git-prune-round-branches.func.sh` | matcher at 27-33 | `prune_round_match` 29-34; `review/r${n}-*` and `wip/*r${n}*` only |
| 10 | `awk` over `spl-push-master.func.sh` | worker at 128, identity check at 151 | `_spl_push_master_worker` 128-170; `bad="$(git log --no-mailmap ...)"` at 151 |
| 10 | `git grep -nE "\^review: " 050b06e65 -- 'csi-spl-orc/src/**' 'csi-spl-iac/src/**' '.github/**' \| wc -l` | 0 | 0 |
| R3 | `lane-map.sh --check <every row path, 34 paths> --agent c-522` | rc 4, c-296 records no files | rc 4: no live lane lists a row path; 3 lanes record no files: `c-119@sat` (the editor), `c-125@sat` (`c-125-qto-tree-drag-reorder`), `c-126@sat` (`c-126-public-repo-customer-name`). c-296 and c-519 are no longer listed |

## 2. Verdict per row

| row | verdict | why, with the command behind any change |
|---|---|---|
| 01 | **agree** | 7 functions and 19 left out hold. Note for the brief: the baseline is now 69.1 %, not 68.7 % (`e6338d7ab` added `doctree_test.go`), so "raise the floor to the measured value" starts above 69.1; the red control (floor fails without the new file) still works. |
| 02 | **agree** | 317, LONG entry at line 36, `flow.ts:50`: hold. |
| 03 | **agree** | 326, 13 tests, batch 2 after 02: hold. |
| 04 | **agree** | 5 sites at the plan's lines. |
| 05 | **agree** | 5 sites at the plan's lines. |
| 06 | **agree** | 5 sites at the plan's lines; the 8 named tests exist. |
| 07 | **agree** | 5 sites hold; LONG line 22 `133` holds. The claude seat's follow-up (stale 133 ceiling after 07) stands. |
| 08 | **agree with changes** | (a) Site `spl-cloud-cnf.func.sh:51` -> **`:59`** (59-154; `b8a8afa5e` moved it 8 lines down, size still 96). (b) The split keeps `spl_cnf_copy_cache` as it is and keeps the cache read going through it: the one-open copy fixes a CI FATAL (`b8a8afa5e` body), and a split that inlines `cp` again would bring it back. (c) Name `host-spool-no-rebuild.tst.sh` in the test column by name: it is the test `b8a8afa5e` extended for that copy (it is among the 71, but the column should not leave it to "run the orc suite"). |
| 09 | **agree** | 36 matched, 33 listed, 7 KEEP, matcher lines: hold (v0.2 already folds the 7). Line nit only: the matcher is at 29-34 on `050b06e65`, the plan says 27-33. |
| 10 | **agree** | Worker 128-170, identity check 151, 0 gates: hold. |

## 3. Left out, or to change outside the rows

- **Section 5, reviewers (must change).** v0.2 sends the 9 claude rows (01,
  02, 03, 04, 06, 07, 08, 09, 10) to "the mistral seat". This seat replaces
  m-127 and is **claude**, so the panel is now claude + claude: no seat can
  give those 9 rows a cross-vendor review (R7.2), and a claude review of a
  claude row breaks R7.5 (`grep -c 'same vendor'` must stay 0). This seat can
  review row 05 only (mistral author), the same as c-120. If row 05 falls to
  its claude backup, it needs a non-claude reviewer too. v1.0 should name a
  non-claude reviewer for the claude rows before they spawn: agy (quota back
  about 2026-10-15T09:50Z, plan header) or a new mistral reviewer seat
  placed by the spawner (R7.3), and say which rows wait for it.
- **Section 3.2 (R3):** on `050b06e65` the lanes with no files recorded are
  c-119, c-125 and c-126 (all `@sat`), not c-296; the spawner's per-row
  `--check` still asks them.
- **Section 9:** the mistral seat row reads "pending (queued, ask 34f3c665)";
  it is this seat, c-522@PC (claude), with this file.

## 4. Signature

signed v1.0 40057b1a5

Checked on `40057b1a5`: every change of sections 2 and 3 is in (rows 01, 08, 09; sections 3.2, 5, 9; section 7.2).
