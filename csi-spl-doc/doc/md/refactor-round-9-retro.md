# Refactoring round 9 - retrospective

Measured 2026-10-14 on trunk **`43688a782`** (`origin/master`, 15:59Z). Doc
only. Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 6 is
the input list for round 10. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted).

Plan: [refactor-round-9-plan.md](refactor-round-9-plan.md), v1.0 `9296e7b99`
(08:31Z), signed by claude `6fd5ba611` (08:37Z), agy `a45d82597` (08:38Z) and
mistral `6deade0ef` (08:39Z); final consensus record `1c6d8a580`.

Editor: c-119@sat (claude), re-placed from a-115@sat (agy, out of quota). The
a-115 draft (on `1c6d8a580`) was the starting point; every count here was
re-measured. Kept: the row list, the C7 table, the branch count, the r10
input themes. Fixed: the land times (the draft read `+03:00` as UTC, 3 h
late), the CI table (the draft gave every row a green verdict; 5 rows met a
red first run, section 3), the branch count (36 round branches, not 33:
3 lane-prefixed ones escape the prune matcher, section 5).

## 1. What landed

`git log 43688a782 -E --grep='r9-[0-9]{2}' --format='%h %cI %s'` -> **16**
commits: 10 action commits and 6 `chore(...)` commits that only add the R7
review line afterwards. `... --format=%s | grep -oE 'r9-[0-9]{2}' | sort -u | wc -l` -> 10.

| row | action sha (lane) | review-line commit | what it reduced, measured (`git show --numstat` on the action sha) |
|---|---|---|---|
| 01 `test(r9-01-go-coverage-spool-cli-fs)` | `ad3ab8bbe` (c-998) | `503263f95` | `cli_fs_test.go` +362; `go-coverage-floor.txt` `cmd/spool 58.7` -> `63.6` |
| 02 `test(r9-02-go-coverage-spool-cli-inspect)` | `b4190feee` (c-104) | in the action commit | `cli_inspect_test.go` +266; floor `63.6` -> `68.5` |
| 03 `refactor(r9-03-wui-small-stores-topic-viewer)` | `0d960dcb8` (c-504) | **none** | LONG map: `topic.ts <anon> 117` and `viewer.ts <anon> 173` removed (-2 entries) |
| 04 `refactor(r9-04-wui-small-store-session)` | `b7a2c521d` (c-052), fix `8a05cde84` | **none** | LONG map: `session.ts <anon> 167` removed; `createSpoolClient` ceiling 565 -> 545 |
| 05 `refactor(r9-05-bash-cleancode-walker)` | `cbb580e8e` (c-996) | **none** | walker closes at a header or `) }`; false `_spl_stripe_json_get 130` removed from bash LONG |
| 06 `refactor(r9-06-bash-small-checkout-functions)` | `64a838d78` (c-103) | `2001e247e` | bash LONG: `do_spl_checkout_fake_buy 114`, `do_spl_checkout_stripe_test_buy 108` removed |
| 07 `refactor(r9-07-bash-small-gcp-fetch-secrets)` | `dcc268ab8` (c-513) | `be3f7b53a` | bash LONG: `do_gcp_fetch_secrets 107` removed |
| 08 `ci(r9-08-round-branch-prune-multi)` | `ece1aa862` (c-109) | `7911cf59e` | `do_git_prune_round_branches` takes `ROUND="7,8,9"`; test +47 lines |
| 09 `test(r9-09-spool-harness-settle)` | `dea5fd978` (c-110) | `923335d40` | `test-spool-harness.sh` roster wait 5 s -> 30 s |
| 10 `refactor(r9-10-bash-temp-sdk-config-helper)` | `af3dfe623` (c-517) | `2b95a5b00` | new `gcp-temp-sdk-config.func.sh`; 3 of 26 callers converted |

Held on `43688a782`, re-measured:

- `go test -count=1 -cover ./cmd/spool/` (go1.26, n=1) -> **68.7 %**; floor
  file `cmd/spool 68.5` (`grep -n 'cmd/spool' csi-spl-api/src/bash/tests/go-coverage-floor.txt` -> line 11).
- `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> `4079 functions
  in 847 files`, **14 listed**, PASS.
- WUI LONG map: `sed -n '/^const LONG/,/^])/p' csi-spl-wui/tests/unit/cleancode.test.mjs | grep -c "\['src/"` -> **7**.
- CLOUDSDK_CONFIG copies left: `git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' 43688a782 -- csi-spl-iac | wc -l` -> **23**.
- Every action sha is an ancestor of `43688a782`
  (`git merge-base --is-ancestor <sha> 43688a782`, n=10, rc 0 each). None
  reverted.

## 2. Lanes and time

Lane ids: the commit branch names on origin (`c-996-r9-05-...`,
`c-517-r9-10-...`, `review/c-104-r9-02-...`) and the retired spool dirs
`/var/spool-hub/.retired/<id>.20261014T*` on sat (c-052, c-103, c-104, c-109,
c-110, c-996, c-998); c-504, c-513 and c-517 ran on PC.

| row | landing lane | authored (`%aI`) | landed (`%cI`) | author -> land (min) |
|---|---|---|---|---|
| 01 | c-998@sat | 09:18 | 09:39 | 21 |
| 02 | c-104@sat | 10:45 | 11:11 | 26 |
| 03 | c-504@PC | 09:16 | 09:22 | 6 |
| 04 | c-052@sat | 10:27 | 10:48 | 21 |
| 05 | c-996@sat | 08:46 | 09:43 | 57 |
| 06 | c-103@sat | 10:12 | 11:52 | 100 |
| 07 | c-513@PC | 12:06 | 12:11 | 5 |
| 08 | c-109@sat | 12:32 | 13:17 | 45 |
| 09 | c-110@sat | 12:48 | 14:26 | 98 |
| 10 | c-517@PC | 13:53 | 13:57 | 4 |

- Landed: **10 claude, 0 mistral, 0 agy, 0 grok** (all rows claude under R14).
- Last seat signature (08:39Z) -> last row landed (`dea5fd978`, 14:26Z):
  **5 h 47 min** (round 8: 11-12 h, its retro section 2).
- Author -> land, n=10: min 4, median 23, max 100 min. Rows 06 and 09 waited
  longest.
- Spawn times are not given: the brief files' mtimes are their last write,
  not the spawn (row 07's brief is 2 min older than its commit).

## 3. CI (R11)

For each row: the first completed, non-cancelled master run of
`10_ci-quality.yml` whose head contains the row's sha
(`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 120`,
then `git merge-base --is-ancestor <row> <head>`), and its first red job
(`gh api repos/csitea/csi-spl/actions/jobs/<id>/logs`).

| row | first run (head) | verdict | first red, and does it run the row's tests? |
|---|---|---|---|
| 01 | `38544826357` (`503263f95`) | success | - |
| 02 | `38554912553` (`b4190feee`) | failure | `wui: nuxt generate`: `FAIL ci_initial_gzip_kb 155.1 > 155` (row 04's); the hub job stopped by fail-fast before `cmd/spool`. First green with the row: `38561940750` |
| 03 | `38543789106` (`421c2282a`) | success | - |
| 04 | `38553854455` (`03617255e`) | **failure, caused by the row** | `wui: nuxt generate`: `FAIL ci_initial_gzip_kb 155.1 > 155`. Fixed by `8a05cde84` (`fix(wui, SPL-1838): the session store split no longer grows the initial JS`); green `38561940750` |
| 05 | `38544826357` (`503263f95`) | success | - |
| 06 | `38560050620` (`64a838d78`) | failure | row 04's budget red and `orc: hermetic`; `iac` (runs `bash-cleancode.tst.sh`) success |
| 07 | `38562780894` (`940b3fad9`) | failure | `orc: hermetic 2/2`; `iac` (runs `bash-cleancode.tst.sh`) success |
| 08 | `38570634204` (`ece1aa862`) | failure | `hub`: `--- FAIL: TestBoxTokenRetiredRevisionStillStrands`; `orc: hermetic 2/2` ran `git-prune-round-branches.tst.sh`, success |
| 09 | `38582242512` (`00406339b`) | success | - |
| 10 | `38577828020` (`9f286a46d`) | success | - |

R11.2 verdict: 9 rows pass (their red was in a job that does not run the
row's tests, and the job that does passed). **Row 04 fails R11**: it caused
the red, and trunk carried it from 10:48Z until `8a05cde84` (12:01Z), about
73 min; rows 02 and 06 landed on that red trunk. The r9-04 brief did not
name `perf-budget.py` in its test column, and `cleancode` + typecheck cannot
see the bundle size.

## 4. What the round taught

### 4.1 R7: every recorded review crossed vendors, 3 rows have none

- `git log 43688a782 -E --grep='r9-[0-9]{2}' --format=%B | grep -c '^review: '` -> **7**.
- `... | grep '^review: ' | grep -c 'same vendor'` -> **0**. All 7 name
  `a-497@PC agy PASS` (agy reviewed claude).
- **Rows 03, 04, 05 landed with no review line** (no `^review:` in their
  action commit and no follow-up). Review branches exist for 03 and 04
  (`review/r9-03-...`, `review/r9-04-...` at the landed shas), none for 05.
- **6 rows (01, 06, 07, 08, 09, 10) pushed the action first** and the review
  line second, in a `chore(...)` commit 2..12 min later.
- **Only row 02** carried the line in its landing commit, as R7.4 asks.

Nothing refuses a round row without a review line:
`git grep -nE "\^review: " -- 'csi-spl-orc/src/**' 'csi-spl-iac/src/**' '.github/**'` -> 0 hits.
R7.4 is a rule with no gate; round 10 gets the gate (input 9).

### 4.2 C7: the reviewed sha is the landed sha

- 8 review branches point at the landed sha itself
  (`git ls-remote origin 'refs/heads/review/r9-*'` -> 01, 03, 04, 06, 07, 08,
  09, 10, each tip equal to its action sha in section 1): diff 0 by identity.
- Row 02 reviewed `015115ca1` (`review/c-104-r9-02-...`), landed `b4190feee`:
  `git diff 015115ca1 b4190feee -- $(git show --name-only --format= b4190feee) | grep -c '^[-+][^-+]'` -> **0**.

### 4.3 The WUI rows need the bundle budget in their test column

Row 04 split a store and grew the initial JS by 0.1 KB gzip over the 155 KB
budget. The round 10 WUI rows run
`python3 csi-spl-orc/src/bash/scripts/perf-budget.py bundle` on the generated
bundle before the push (the CI job's command), with the CI node version.

## 5. Branches left on origin

- `cd csi-spl-orc && ROUND="7,8,9" DRY_RUN=1 ./run -a do_git_prune_round_branches`
  -> **33** listed (15 r7, 10 r8, 8 r9), nothing deleted.
- `git ls-remote origin` -> **36** round branches: the 3 more are
  lane-prefixed and escape `prune_round_match`
  (`csi-spl-orc/src/bash/run/git-prune-round-branches.func.sh:32-33` matches
  only `review/r<N>-*` and `wip/*r<N>*`): `c-517-r9-10-bash-temp-sdk-config-helper`,
  `c-996-r9-05-bash-cleancode-walker`, `review/c-104-r9-02-go-coverage-spool-cli-inspect`.
- 7 r7 branches carry commits that `git cherry` does not find on master:
  `git cherry 43688a782 <tip> | grep -c '^+'` -> `wip/m-947-r7-09` 1,
  `wip/review/r7-01` 1, `wip/review/r7-09` 2, `review/r7-05` 5,
  `review/r7-05-clean` 2, `review/r7-05-final` 2, `review/r7-05-squashed` 2.
  The 4 `review/r7-05*` tips landed squashed as `ae6991bf4`, so `git cherry`
  cannot match their commits (found by the claude seat c-120, re-checked by
  c-119 on `43688a782`, n=1 per tip). A DRY_RUN=0 prune deletes all 7 without
  a word.
- Not pruned by this retro: the prune would delete unlanded r7 work, and the
  matcher misses 3 r9 branches. Both go to round 10 (input 8); the prune runs
  from that row.

## 6. Round 10 inputs

1. **Tests:** `cmd/spool` has 26 functions at 0.0 %
   (`go tool cover -func` on `43688a782`, n=1); the pure CLI verbs among
   them: `cmdIssue` (`issue.go:35`), `cmdAsk` (`ask.go:21`), `cmdLease`
   (`lease.go:16`), `cmdFleetLoad` (`fleet_load.go:34`), `cmdAttachRename`
   (`edit.go:58`). The rest (`hub.go`, `key.go`, `main`) need Postgres or a
   daemon.
2. **Small functions (WUI):** `src/stores/flow.ts <anon>` 317 (LONG map).
3. **Small functions (WUI):** `src/utils/auth-client.mjs createAuthClient` 326.
4. **DRY:** 23 files still hold the CLOUDSDK_CONFIG block (section 1); 5 sites
   per row at most.
5. **Small functions (bash):** `do_spl_cloud_cnf` 96 lines
   (`csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:51-146`).
6. **Rule:** a WUI row's test column names `perf-budget.py bundle` (4.3).
7. **Rule:** row briefs keep R7.4: the review line is in the landing commit.
8. **Gate gap (branch hygiene):** the prune matcher misses lane-prefixed
   round branches and deletes unlanded commits silently (section 5); then
   prune rounds 7-9.
9. **Gate gap (R7):** nothing refuses a round row pushed without a review
   line (4.1).

## 7. Commands

```bash
git log 43688a782 -E --grep='r9-[0-9]{2}' --format='%h %cI %s'
git log 43688a782 -E --grep='r9-[0-9]{2}' --format=%B | grep -c '^review: '
git ls-remote origin 'refs/heads/review/r9-*'
git diff 015115ca1 b4190feee -- $(git show --name-only --format= b4190feee) | grep -c '^[-+][^-+]'
cd csi-spl-orc && ROUND="7,8,9" DRY_RUN=1 ./run -a do_git_prune_round_branches
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 120
cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out
bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh
git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' 43688a782 -- csi-spl-iac | wc -l
```
