# Refactoring round 21 - retrospective

Measured 2026-11-02 ~18:40-19:00Z. Row facts are read on `origin/master`
`13527477a`; the round 22 inputs (section 7) on `57c9194e7`
(57c9194e7f8f487d68caa805f78d24f7696c6dd4), on a `git archive` copy. n=1 per
command unless stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md);
section 7 is the input list for [round 22](refactor-round-22-plan.md). Times are
UTC. Epic: SPL-2402, lane issue SPL-4663, round issue SPL-4577.

Plan: [refactor-round-21-plan.md](refactor-round-21-plan.md), v1.0, editor c-908
(claude), grok reviewer g-910. Slug series `r47`.

## 1. What landed

`git log origin/master -E --grep='r47-[0-9]{2}' --format='%h %s' | wc -l` -> **10**,
rows 01-10, one commit each. `git merge-base --is-ancestor <sha> origin/master`
-> rc 0 for all 10. `git log origin/master --grep='Revert' --format=%s | grep -c 'r47-'`
-> **0**.

Red control: read in each commit body, not re-run here.

| row | landed sha | landed | first tag | red control in the body | what it reduced |
|---|---|---|---|---|---|
| 01 `refactor(r47-01-utl-split-long-box-checks)` | `347bdf793` | 11-02 01:53Z | `v7.6.0-c3` | **yes**: parent and after equal, NOTE 0 -> 2, 134-case differential | 79, 79 -> 53, 55 lines |
| 02 `refactor(r47-02-orc-split-long-db-and-ports)` | `8bd55c64b` | 02:40Z | `v7.6.1-c3` | **yes**: parent and after equal, one flip red on the new case | 78, 78 -> 56, 24 |
| 03 `refactor(r47-03-orc-split-long-probe-and-dns)` | `3d9e5a440` | 04:18Z | `v7.6.4-c3` | **yes**: parent and after equal, 7 plants red | 78, 77 -> 58, 67 |
| 04 `refactor(r47-04-wui-split-long-composables)` | `c088efd3c` | 06:19Z | `v7.6.6-c3` | **yes**: parent and after equal, 5 plants red | 76, 76 -> 63, 67 |
| 05 `test(r47-05-api-msg-validators)` | `294ef05bb` | 03:09Z | `v7.6.1-c3` | **yes**: `ValidKind` returning true, 4 false cases red | `ValidKind`, `ValidBoxID` 0.0 -> 100.0 |
| 06 `test(r47-06-api-rbac-list-and-fixed-roles)` | `f4627b5cb` | 03:00Z | `v7.6.1-c3` | **yes**: 3 plants red | `List`, both `Roles` 0.0 -> 100.0 |
| 07 `test(r47-07-api-sign-load-private-errors)` | `c9c667c51` | 08:35Z | `v7.6.8-c3` | **yes**: 3 plants red | `LoadPrivate` 54.5 -> 90.9 |
| 08 `test(r47-08-api-keydesk-server-defaults)` | `979293f99` | 10:45Z | `v7.7.1-c3` | **yes**: `peerOK` nil plant red | `logf` 50.0, `peerOK` 66.7 -> 100.0 |
| 09 `test(r47-09-api-config-operator-workspace)` | `19813c99e` | 11:16Z | `v7.7.2-c3` | **yes**: 2 plants red | `OperatorWorkspace` 0.0, `DemoTenant` 66.7 -> 100.0 |
| 10 `test(r47-10-gates-drop-stale-long-lines)` | `6ad816ae4` | 11:43Z | `v7.7.2-c3` | **yes**: 9 NOTE lines before, 0 after (the plan's control form) | bash `LONG` 22 -> 15, WUI long 19 -> 17 |

Commands: `git tag --contains <sha> --sort=v:refname -l 'v*' | head -1`;
`git log -1 --format=%B <sha>`; `TZ=UTC git log -1 --date=format-local:'%m-%d %H:%MZ' --format='%h %cd' <sha>`.

**Served (R5).** `cd csi-spl-orc && SHA=<sha> ENV=<dev|prd> ./run -a do_check_deploy_lag`
for `347bdf793`, `8bd55c64b`, `3d9e5a440`, `c088efd3c`, `6ad816ae4`: hub and wui
`current ... (the env serves this commit or a later one)` on dev and prd, 20 of
20 lines. Served then: dev hub `0c8a7f38`, dev wui `13527477`, prd wui
`13527477`; prd hub read `13527477` on two shas and `0c8a7f38` on three, in no
order that says which is newer, so that one reading is unexplained here. Rows
05-09 are `_test.go` only: no deploy of their own is due, and all five are
ancestors of the served shas.

## 2. Review lines (R7) and C7

`git log origin/master -E --grep='r47-[0-9]{2}' --format=%B | grep -c '^review: '`
-> **10**, one per row. `... | grep -c 'same vendor'` -> **0**.

`REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` was run per row on sat.
**All 10 logs are on another box, so the run itself is not proven by this
retro.** The output, identical for the 10 but for the line, `<log-box>` standing
for that box:

```text
REFUSED the log is on box '<log-box>', this is 'sat': run it on <log-box> (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
ERROR Action failed with status 2
```

-> rc **2** on 10 of 10. With `REVIEW_LINE_SYNTAX=1` -> rc **0** on 10 of 10:

```text
SYNTAX OK the line's format and reviewer check on sat; the run is not (the log is on <log-box>): on <log-box>: REVIEW_LINE='...' ...
```

Row 04 also prints `E2E fde1d96476c7 selects: issues-mobile.test.mjs issues.test.mjs release-notes.test.mjs issues-crud-modal.test.mjs rail-order-default.test.mjs ui-micro-animations.test.mjs`,
all six named in its `ran:`. The check on the log's own box was requested of
c-002 on that box (msg 8965f7e0); **its output is not in this file**. Lines are
not pasted whole here: their `log:` paths name a personal home directory (the
hygiene rule); `git log -1 --format=%B <sha> | grep '^review: '` prints them.

C7: `git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l`.

| row | reviewer | author / reviewer vendor | reviewed sha | C7 lines |
|---|---|---|---|---|
| 01 | g-322 | claude (plan) / grok | `b56b51126` | 0 |
| 02 | g-330 | claude (plan) / grok | `f618263a3` | 0 |
| 03 | g-388 | claude (plan) / grok | `f5f3f08c4` | 0 |
| 04 | g-403 | claude (plan) / grok | `fde1d9647` | 0 |
| 05 | g-342 | claude (plan) / grok | `2346b935b` | 0 |
| 06 | g-349 | claude (plan) / grok | `01996efa3` | 0 |
| 07 | g-507 | claude (plan) / grok | `526b91524` | 0 |
| 08 | g-566 | claude (c-941) / grok | `5bf1586e0` | 0 |
| 09 | g-595 | claude (plan) / grok | `5488e8ca8` | 0 |
| 10 | g-563 | claude (plan) / grok | `d432c7ca4` | 0 |

- **C7 holds on 10 of 10.** Eight reviewed shas have no branch on origin (4.2);
  their objects resolved here, by a fetch by sha from origin where they were not
  already local.
- **Cross-vendor holds as far as read:** 10 grok reviewers. The authors' vendor
  is the plan's, checked by a lane id for row 08 only (`git worktree list`); the
  other lanes' worktrees are on the other box. Plan section 1 asks each line to
  name the author's vendor: **0 of 10 do** (4.3).

## 3. CI verdict per row (R11)

The first completed, not cancelled workflow 10 run on master whose head contains
the row (`gh run list --workflow 10_ci-quality.yml --branch master -L 400`, then
`git merge-base --is-ancestor <row> <head>`).

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 41375000202 (`347bdf793`) | success | **pass** |
| 02 | 41379136620 (`8bd55c64b`) | failure: `wui: browser e2e` 1, 4, 6, 7 of 8 | **pass**: the row is bash; its tests are in the orc hermetic jobs, all 3 success, `spl-db-restore` or `spl-box-ports-loopback` named on 4 lines of one shard's log |
| 03 | 41387837149 (`3d9e5a440`) | success | **pass** |
| 04 | 41399292849 (`c088efd3c`) | success | **pass** |
| 05 | 41381908858 (`294ef05bb`) | failure: the same 4 e2e shards | **pass**: `hub: gofmt, go vet, go test` success, `ok - internal/msg 90.8% (floor 84.9)` |
| 06 | 41381908858 (`294ef05bb`; the run on `f4627b5cb`, 41380779531, was cancelled) | failure: the same 4 e2e shards | **pass**: the same job, `ok - internal/rbac 98.9% (floor 89.3)` |
| 07 | 41417105352 (`c9c667c51`) | success | **pass** |
| 08 | 41432728088 (`979293f99`) | success | **pass** |
| 09 | 41436295621 (`19813c99e`) | failure: `orc: hermetic action tests 1/3`, `FAILED: test-dev-preflight.tst.sh`, case `5b reads the published host ports`; the hub job stopped by gate fail-fast | **pass**: the first red executes none of the row's tests, and the hub log reads `ok ... internal/config ... coverage: 91.2%` before the stop; the next run, 41439323082 (`6ad816ae4`), is success |
| 10 | 41439323082 (`6ad816ae4`) | success | **pass** |

## 4. What went wrong and what we learned

### 4.1 Another lane's red sat under rows 02, 05 and 06

`66dd6f5be` (SPL-4578, Add to note) landed 01:56Z; the same four e2e shards are
red on 41379136620 and 41381908858, and on the second the failing lines name
`issues-detail-note`, which that commit's diff contains
(`git show 66dd6f5be | grep -c issues-detail-note` -> 4). `1aec49726` reverted it
at 03:26Z, and the next completed run, 41383231745, is success: 90 minutes. I read
the failing lines of one shard per run, not all four. None of the three rows
touches a WUI file, and fail-fast did not hide their results.
*No rule change:* R11.2 gave the right verdict.

### 4.2 The hourly prune deletes what the rulebook says stays (rule change asked)

Rulebook 2.7.4 says `review/<round>-NN` "remains on origin until the retro runs
C7". 8 of 10 were gone before this retro:
`gh api 'repos/csitea/csi-spl/activity?activity_type=branch_deletion&per_page=100'`
-> `review/r47-01` 02:48Z, `-05` and `-06` 03:48Z, `-03` 04:48Z, `-07` 09:49Z,
`-08`, `-09`, `-10` 11:48Z, each within the hour after its row landed. The fixed
minute and `git-prune-merged-cron.sh` (`PRUNE_ALL_MERGED=1 DRY_RUN=0`, owner msg
34b232f4, SPL-3609) fit; I did not read that cron's log, so the attribution is
inferred. C7 still ran, because the 8 shas still resolved, and nothing promises
that they always will.

*Rule change asked:* 2.7.4 drops "remains on origin until the retro runs C7" and
says C7 reads the sha in the `review:` line, fetched by sha, or the prune keeps
`review/*` of an open round. The owner's prune order is the newer one, so this
retro's preference is the first.

The two that remain are the reverse case: rows 02 and 04 landed squashed (two
commits on the branch), so `git cherry` counts them `2 unlanded` and every prune
keeps them (section 5).

### 4.3 The `ran:` field and the plan's test column disagree (reviewer's C4)

From the lines (`sed -E 's/^.* ran: (.*) \| read: .*$/\1/'`, then `grep -c`):

- **`run-all-tests.sh`:** plan rows 05-09 and 10 (iac) ask for it. `ran:` names it
  on rows 05 and 06 only. Row 07's `read:` says `run-all-tests.sh NOT RUN`; rows
  08, 09 and 10 do not say. The authors' bodies claim it on rows 07, 09 (api) and
  10 (iac `219/219`), not on 08. CI passed the suites holding them (section 3); C4
  as written (`ran:`) is not met on 4 rows.
- **Row 04's e2e:** `ran:` names the six files, and `read:` says they are "the
  prior generated-bundle run on the same src at 80d7ded9 ... not re-run".
  Rulebook 2.7.4: `ran:` names only commands in the `log:`. Whether that log holds
  them is what the unrun full check reads (section 2).
- **Row 01's differential:** the author's body says `134 input cases`, the
  reviewer's `read:` `diff 234 cases 0`. Not resolved here.
- **The vendor pair:** 0 of 10 lines name the author's vendor, though plan section
  1 asks it. Retro 17 section 4.1 wanted the pair stated; the R7 `grep -c 'same
  vendor'` still cannot fail.

*Rule change asked:* the row brief says `run-all-tests.sh` either goes in `ran:`
or is struck from the row's test column for the reviewer, so C4 can be checked;
`do_spl_review_line_check` could read the author's vendor from the registry
instead of asking each line.

### 4.4 The check cannot be run from the retro's box

All 10 reviewers were on one box and this lane on the other, which cannot reach
it (`ssh` -> `Could not resolve hostname`). The action refuses by design (2.7.4),
so R8's "verifies the review lines" needs either a retro lane on the logs' box or
a named step for a seat there. Today it costs a message and a wait.
*Rule change asked:* R8 names that step, or the planner places the retro on the
box holding most of the round's review logs.

### 4.5 Retros are behind the rounds

`ls csi-spl-doc/doc/md | grep -cE 'refactor-round-(18|19|20)-retro'` -> **0**, and
this one follows the signed round 22 plan (`e5ecc7ace`, 15:23Z), which says its
section 2 re-measured because no input list existed. So R8's "the retro's final
section compiles the input list" did not feed round 22; section 7 records what
changed on top of it. Whether rounds 18 and 19 are due is not checked here; round
20's r46-04, r46-05 are not on master (section 7, item 4).

### 4.6 What worked

- 10 of 10 rows landed in 9 h 50 min (01:53Z-11:43Z), one commit each, 0 reverts,
  C7 10 of 10, R11 10 of 10.
- Row 10's plan worked: rows 01-04 left stale lines, one closing row deleted all 9,
  and no file was in two of rows 01-09.
- R7 send-backs added real cases: row 02's never-ready test (g-330 W1) and row
  04's two unit tests (g-403 W1, W2) came from a reviewer's finding.

## 5. Branches and seats (R8)

`cd csi-spl-orc && ROUND=47 DRY_RUN=1 ./run -a do_git_prune_round_branches`:

```text
KEEP review/r47-02 2 unlanded
KEEP review/r47-04 2 unlanded
OK DRY_RUN round r47: 0 branch(es) listed, 2 kept unlanded on origin, nothing deleted (DRY_RUN=0 deletes the listed)
```

`ROUND=47`, not 21: the action's number means prefix `r<N>`, while the rulebook's
`ROUND=<N>` reads as the round number. Nothing to delete; the lane's report gives
the `DRY_RUN=0` result. Both kept branches match the landed commit on their own
files: `git diff origin/review/r47-02 8bd55c64b -- <its 3 files> | wc -l` -> 0,
and for `r47-04` against `c088efd3c`, 4 files -> 0. Removing them needs
`PRUNE_UNLANDED=1`, which this lane's brief does not give.

The planner closes the reviewer seats (2.8). Their state is not checked here.

## 6. Counts

| metric | n |
|---|---|
| rows planned / landed | 10 / 10 |
| commits on master per row | 1 |
| review lines | 10, all grok reviewers |
| `do_spl_review_line_check` full run | 0 of 10 from this box (section 2); syntax 10 of 10 |
| C7 | 10 of 10 hold |
| R11 verdict | 10 pass (6 green first runs, 4 on their own parts: rows 02, 05, 06, 09) |
| served dev + prd | every sha checked, section 1 |
| reverts of a row | 0 |
| rule changes asked | 3 (4.2, 4.3, 4.4) |

## 7. Round 22 inputs (measured on `57c9194e7`)

The round 22 plan is signed on `7f3da5f69` (`e5ecc7ace`), so these say what moved
or what it lacks. None is a new row; its editor decides.

1. **Floors, plan row 09.** `go test -count=1 -cover ./internal/{msg,rbac,sign,keydesk,config}/`
   and `grep -E '^internal/(msg|rbac|sign|keydesk|config) ' csi-spl-api/src/bash/tests/go-coverage-floor.txt`:
   `msg` 90.8 (floor 84.9), `rbac` 98.9 (89.3), `sign` 86.2 (82.9), `keydesk` 88.7
   (88.1), `config` 91.2 (89.7). n=1 here; the row takes its own n=3.
2. **Bash `LONG`.** `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` ->
   `(15 listed)`, no `NOTE LONG`: rows 01-03's starting point stands.
3. **WUI long.** `cd csi-spl-wui && node tests/unit/cleancode.test.mjs` (another
   worktree's `node_modules`, read only) -> `12673 functions, 17 listed long, 17
   listed wide`, no `NOTE LONG`: row 04's starting point stands.
4. **Header track moved.** The awk of round 21 section 2 over `iac:`, `orc:`,
   `utl:` `run/*.func.sh` -> **30** declare-first files (the plan's 35 on
   `7f3da5f69`); `bash csi-spl-iac/src/bash/tests/action-header-tags.tst.sh` ->
   `measured 765 files: 48 missing, 4 long-example` (53, 4). `15789e9ea` r46-03
   landed after the plan; `git log 57c9194e7 -E --grep='r46-0[45]' --format=%s | grep -vc '^docs'`
   -> 0. Still deferred; round 23's once r46-05 lands.
5. **`sign.LoadPrivate` 90.9.** `go tool cover -func` on `./internal/sign/`: the
   one statement left is the read error that is not a missing file (row 07's body;
   the plan did not ask for it). Not worth a row alone.
6. **Review branches `review/r47-02`, `review/r47-04`.** Section 5: 2 commits each,
   0 diff on their files, kept by `git cherry`. A `PRUNE_UNLANDED=1` call is the
   dispatcher's.
7. **`test-dev-preflight.tst.sh` case 5b.** Red once under row 09 (run 41436295621);
   41439323082 is green. Whether it is a flake is not measured: 2.11.3 counts the
   sightings with `CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`.
8. **Round 22 briefs: three process lines,** from 4.2, 4.3 and 4.4, if the editor
   takes them: C7 by the line's sha, `ran:` against the test column, and where the
   retro runs.

## 8. Commands

```bash
git log origin/master -E --grep='r47-[0-9]{2}' --format='%h %s'
git log origin/master -E --grep='r47-[0-9]{2}' --format=%B | grep -c '^review: '
git log -1 --format=%B <sha> | grep '^review: '
REVIEW_LINE="$line" ./run -a do_spl_review_line_check
REVIEW_LINE_SYNTAX=1 REVIEW_LINE="$line" ./run -a do_spl_review_line_check
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master -L 400 --json databaseId,headSha,conclusion,status,createdAt
gh api repos/csitea/csi-spl/actions/jobs/<job>/logs
gh api 'repos/csitea/csi-spl/activity?activity_type=branch_deletion&per_page=100'
cd csi-spl-orc && SHA=<sha> ENV=<env> ./run -a do_check_deploy_lag
cd csi-spl-orc && ROUND=47 DRY_RUN=1 ./run -a do_git_prune_round_branches
```
