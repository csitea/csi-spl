# Refactor round 04 - panel seat claude (c-804)

Seat: **c-804** (claude), the cross-vendor panel seat of rulebook 3.2 for the agy
planner/editor **a-852**. Issue SPL-6547, epic SPL-2402, spec
`csi-spl-doc/specs/011-spool-project-refactor`.

## 1. Verdict on v0.1

**FAIL** on v0.1 **`4ded3bf46a50baf4ace5e7919ea9720857af5db7`**
(`review/c002-refactor-round-04-planner`, `git ls-remote` read 2026-11-26T01:24Z), plan
file `csi-spl-doc/doc/md/refactor-round-04-plan.md`, base
`ffba818456f9b6f171c0fac34a2d7c6d94918a02`.

Both rows are sound, small and verified as written: every file:line exists, all 9 head
files rebuild byte-for-byte from the plan's verbatim blocks (sha256 match 9/9), and every
count of 1.5 (row suites, 8 red/guard controls, 5 mutations) reproduced exactly. The FAIL
is on two text defects, both foldable into v1.0 with no row, site, batch or vendor change:

- **W1**: row 01 changes a file mode the plan says it keeps (a behaviour change in a
  refactor row, stated as none).
- **W2**: r03 section 7's row-01 input (`*_read` and `*_apply` scaffolding) is neither
  served nor accounted for.

Once W1 and W2 are folded, I expect to sign v1.0 PASS.

## 2. Checks (brief 1 to 8), each with the command and what it printed

All reads n=1 unless stated, run 2026-11-26T01:24Z to 01:45Z as the agent user. Scratch
tree: `git archive ffba81845` into a fresh `git init` repo (so `no-literal-paths.tst.sh`
sees a git tree) and one `git clone` of it per head and per control. Nothing under the
repo checkout was edited apart from this file.

Two c-804 sessions, one seat: the checks ran in session `def16804-5cc5-4bdd-82c4-b19c2f5d093f`
(rotated at its 60-min deadline, 01:41Z); session `55bbd52a-82ec-4824-951b-c782185d2762`
read its 45 recorded shared-suite runs, filled 2.9, re-ran the hygiene check and committed.

### 2.1 Check 1: slug r04 unused since `W`

- `W=2026-11-26T02:43:46+02:00`, plan 1.1. Re-read:
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r03-plan'` ->
  `ffba818456f9b6f171c0fac34a2d7c6d94918a02 2026-11-26T02:43:46+02:00 docs(r03-plan, SPL-6540): refactor round 03 closed: ...`
  (matches the plan).
- `git log origin/master --since="$W" --oneline -E --grep='\(r04-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r04-[0-9]{2}|refactor-round-04'` ->
  `4ded3bf46a50baf4ace5e7919ea9720857af5db7 refs/heads/review/c002-refactor-round-04-planner`
  only (the planner's branch; mine was not pushed yet at that read).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r04-[0-9]{2}|refactor-round-04'` -> no
  output on this seat's box. The plan's count of 2 briefs is "on the planner/holder box
  only"; my own brief sits in `/var/spool-hub/spawn-remote/briefs/` here. **Not
  verified** by me on the planner's box (N1).

### 2.2 Check 2: sites exist on base and still on origin/master

- Every cited line checked with `git show ffba81845:<file> | sed -n <N>p` /
  `cat -n`: `brc:35-55, 41-54, 69-77, 71-77, 88-97, 90-97`;
  `oq:34-53, 38, 39-52, 71-80, 73-79, 91-100, 93-100, 140`;
  `spl-spawn-remote-install-cron.func.sh:43, 58-92, 93`;
  `spl-unanswered-sweep-install-cron.func.sh:52, 71-105, 106`;
  `spl-workspace-delivery-probe-install-cron.func.sh:48, 64-94, 95`;
  `setup-box-stats-cron.func.sh:64-105, 67-105`;
  `spl-issue-blocker-rca-close.tst.sh:130` (`[[ $fails -eq 0 ]] && echo "ALL PASS" ...`),
  `spl-issue-owner-question-diss.tst.sh:89` (same line) and `:74` (the r90-02
  `if spl_issue_brc_one` assertion), `box-stats-cron.tst.sh:273` (`echo`) and `:274`
  (`if [ "$fails" -eq 0 ]`), `setup-gh-runner-cpu-budget-cron.tst.sh:83`
  (`# 4. red control: the installer without the floor`),
  `dispatch-setup-check.tst.sh:456` (CLI string), `spl-box-deploy.tst.sh:57` (stub).
  **All match** the plan's description.
- File lengths on base (`wc -l`): brc 158, oq 162, box-stats 105, spawn-remote 93,
  unanswered-sweep 106, delivery-probe 95; tests 130, 89, 275. All as the plan says.
- Drift: `git diff --name-only ffba81845 origin/master -- <the 12 paths of plan 2.2>` with
  origin/master `5aa360afc9d15f9a7e637c7097c1588c6c1d7247` (01:24Z, 9 commits past base) ->
  **empty** (`drift-files=0`).

### 2.3 Check 3: red controls, re-run on base

Heads built by `apply_heads.py` (my scratch script: it takes the 12 fenced `bash` blocks
of the plan in order and applies them at the cited line ranges, bottom-up, plus the three
`local ... current` drops). Result, `git diff --numstat` per head: `+20 -10`, `+9 -34`,
`+46 -0`, `+29 -0` (head1); `+9 -7`, `+6 -36`, `+6 -36`, `+5 -32`, `+92 -0` (head2), the
plan's numbers. `sha256sum | cut -c1-12` per file:

| head | file | plan | mine | lines |
|---|---|---|---|---|
| 1 | `spl-issue-blocker-rca-close.func.sh` | `c9476da5a155` | `c9476da5a155` | 168 |
| 1 | `spl-issue-owner-question-diss.func.sh` | `3cfae296d937` | `3cfae296d937` | 137 |
| 1 | `spl-issue-blocker-rca-close.tst.sh` | `29126e34f396` | `29126e34f396` | 176 |
| 1 | `spl-issue-owner-question-diss.tst.sh` | `d880d5189ac1` | `d880d5189ac1` | 118 |
| 2 | `setup-box-stats-cron.func.sh` | `a8f432f1ec34` | `a8f432f1ec34` | 107 |
| 2 | `spl-spawn-remote-install-cron.func.sh` | `ade87c1e55a7` | `ade87c1e55a7` | 63 |
| 2 | `spl-unanswered-sweep-install-cron.func.sh` | `58b1daf259b0` | `58b1daf259b0` | 76 |
| 2 | `spl-workspace-delivery-probe-install-cron.func.sh` | `a87a26a30b2e` | `a87a26a30b2e` | 68 |
| 2 | `box-stats-cron.tst.sh` | `1b6142ee1ab6` | `1b6142ee1ab6` | 367 |

Every suite run: `cd <tree>/csi-spl-orc && env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID
SPOOL_TEST=1 bash src/bash/tests/<t> </dev/null`, counts with the plan's
`grep -ciE '^ *(ok|pass)'` / `grep -ciE '^ *(not ok|fail)'`.

| run | tree | rc / pass / fail | last line | plan |
|---|---|---|---|---|
| `spl-issue-blocker-rca-close.tst.sh` | base | 0 / 18 / 0 | `ALL PASS` | = |
| same | head1 | 0 / 22 / 0 | `ALL PASS` | = |
| `spl-issue-owner-question-diss.tst.sh` | base | 0 / 11 / 0 | `ALL PASS` | = |
| same | head1 | 0 / 14 / 0 | `ALL PASS` | = |
| `box-stats-cron.tst.sh` | base | 0 / 44 / 0 | `box-stats-cron: all passed` | = |
| same | head2 | 0 / 54 / 0 | `box-stats-cron: all passed` | = |
| **rc1a** head1's brc test on base | base | 1 / 19 / 3 | `3 FAILED` | = |
| **rc1b** head1's oq test on base | base | 1 / 13 / 1 | `1 FAILED` | = |
| **rc2** head2's box-stats test on base | base | 1 / 53 / 4 | `box-stats-cron: 4 FAILED` | = |
| **gc1a** head1, `declare -F _spl_issue_brc_run_plan` line deleted in oq | head1 | 1 / 12 / 2 | `2 FAILED` | = |
| **gc1b** head1, `declare -F _spl_issue_brc_query` line deleted in oq | head1 | 1 / 13 / 1 | `1 FAILED` | = |
| **gc2a** head2, guard deleted in spawn-remote | head2 | 1 / 52 / 2 | `box-stats-cron: 2 FAILED` | = |
| **gc2b** head2, guard deleted in unanswered-sweep | head2 | 1 / 52 / 2 | `box-stats-cron: 2 FAILED` | = |
| **gc2c** head2, guard deleted in delivery-probe | head2 | 1 / 52 / 2 | `box-stats-cron: 2 FAILED` | = |

The FAIL lines, verbatim (cut, scratch paths shortened to `…`):

- rc1a: `FAIL: r04-01 plan_path/run_plan (rc=1): P=…/state/sub/issue-blocker-rca/t1-….plan.tsv MODE=600 DMODE=700`;
  `FAIL: r04-01 query ok (rc=0): …/spl-issue-blocker-rca-close.func.sh: line 103: TENANT_ID: unbound variable`;
  `FAIL: r04-01 brc one copy`.
- rc1b: `FAIL: r04-01 oq one copy: own=[38:  plan="$(spl_issue_oq_plan_path)" || return 1`.
- rc2: `FAIL: 5. empty noun: FAIL the widget cron is NOT installed (no line tagged csi-spl:widget): no widget`;
  `FAIL: 5. one copy spl-spawn-remote-install-cron.func.sh: own=[70: …`;
  `… spl-unanswered-sweep-install-cron.func.sh: own=[83: …`;
  `… spl-workspace-delivery-probe-install-cron.func.sh: own=[73: …`.
- gc1a: `FAIL: r90-02 sourced alone (rc=1): …: line 39: spl_issue_brc_plan_path: c…` and
  `FAIL: r04-01 oq solo dry (rc=1): …: line 39: spl_issue_brc_plan_path: com…`.
- gc1b: `FAIL: r04-01 oq solo query (rc=127): …: line 73: _spl_issue_brc_query: co…`.
- gc2a/b/c: `FAIL: 5. lazy sr|us|dp (rc=127)` and `FAIL: 5. sr|us|dp ok (rc=127)`,
  `… line 59|72|65: _spl_simple_cron_apply: command not found`.

**Reason:** each control fails for the reason the plan gives (a helper or argument that
base lacks, or a removed guard), not for an environment reason: the same suites are green
on base and on the heads in the same scratch trees. rc1a's `query ok` fails with
`TENANT_ID: unbound variable` because base's `_spl_issue_brc_query` ignores `my_sql` and
runs `spl_issue_brc_sql`; that is the plan's stated reason.

**Live state:** none touched. Row 01's checks stub `spl_psql_ro` / `spl_sql_proxy_stop` /
the desk, and write plans under the test's `mktemp -d` `$T`. Row 02's section 5 puts
`$T/bin` first on `PATH` in every call, and `box-stats-cron.tst.sh:175` makes
`$T/bin/crontab` a stub that writes `$FAKE_CRONTAB` (`$T/crontab`, `$T/crontab.s5`). Read
from the code, not traced at the syscall level.

**Mutations** (n=1 each, one-line `sed` on a clone of the head, `git diff --shortstat` ->
`1 file changed, 1 insertion(+), 1 deletion(-)` each):

| mutation | rc / pass / fail | FAIL lines | plan |
|---|---|---|---|
| m1a (oq calls `spl_issue_brc_plan_path` with no subdir) | 1 / 13 / 2 | `oq one copy`, `oq solo dry` | = |
| m1b (oq calls `_spl_issue_brc_query` with no SQL_FN) | 1 / 12 / 2 | `oq one copy`, `oq solo query` | = |
| m2a (spawn-remote drops arg 11 `""`) | 1 / 52 / 2 | `5. lazy sr`, `5. sr ok` | = |
| m2b (unanswered-sweep passes `""` as `miss_why`) | 1 / 53 / 1 | `5. lazy us` | = |
| m2c (delivery-probe drops arg 11 `""`) | 1 / 52 / 2 | `5. lazy dp`, `5. dp ok` | = |

### 2.4 Check 4: equivalence per row

- **Row 01**, read on base `brc:35-55, 69-97`, `oq:34-53, 71-100, 136-162`: the driver
  (`brc:41-54` vs `oq:39-52`) and the query body (`brc:90-97` vs `oq:93-100`) differ only
  in the function names and `spl_issue_brc_sql` vs `spl_issue_oq_sql`. The extracted
  `_spl_issue_brc_run_plan` and `_spl_issue_brc_query [SQL_FN]` keep the same commands,
  log lines, `mktemp` / `rm -f`, return codes and proxy stop. `do_spl_cloud_cnf` stays
  where it was in each file (brc's driver before the plan path; oq's `spl_issue_oq_read`
  after it). Equivalent, **except the plan-file mode, W1**. The controls would catch
  a lost subdir, a lost SQL function and a lost guard (2.3). **No test catches W1.**
- **Row 02**, read on base `setup-box-stats-cron.func.sh:64-105` and the three
  installers' `:58-92`, `:71-105`, `:64-94`: the state machines are line-for-line the
  helper's with `$label cron` -> the job name; delivery probe's
  `[[ -n "$current" ]] || {…}` is the same test as `if [[ -z ]]`, and its empty
  `miss_why` yields the same text. `noun="${11- cron}"` (dash without colon) keeps
  `" cron"` for the 6 callers that pass 10 args (`git grep -n _spl_simple_cron_apply
  ffba81845`: the 6 call sites, none with an 11th arg) and gives the bare subject for an
  explicit `""`. Messages, exit codes, crontab line and order of reads
  (`spl_desk_cron_line` after `line` is built) are unchanged. Dropping the now-unused
  `current` from each `local` is safe: the helper declares its own. Equivalent. Section
  5's direct `widget` check and the 6 standalone runs would catch a `" cron"` coming back
  or a lost `miss_why` (m2a to m2c).

### 2.5 Check 5: rows' columns

Read from plan section 2, row table (`plan.md:776-777`), section 4 (`:892-912`, R7) and section 5 (`:913-977`):

| row | R2 control red then green | test list | vendor | kind | batch | R7 |
|---|---|---|---|---|---|---|
| 01 | yes: rc1a, rc1b red on base, green on head1 (2.3) | 11 suites + shellcheck + `do_check_pre_push` | claude | simple_coding | 1 | agy seat; claude waiver backup under `dc84300a`; never mistral |
| 02 | yes: rc2 red on base, green on head2 (2.3) | 19 suites + shellcheck + `do_check_pre_push` | claude | simple_coding | 1 | same |

No mistral row; no mistral review seat. **R1:** batch 1's file sets (plan 2.1) share no
path: row 01 touches the 4 `spl-issue-*` files, row 02 the 4 cron `.func.sh` files and
`box-stats-cron.tst.sh`. Rulebook 3.1's "at most 5 sites": row 02 lists exactly 5 files.

### 2.6 Check 6: R3

- `bash …/spawn-agents/scripts/lane-map.sh --check <the 12 paths of plan 2.2, comma-separated> --agent c-804`
  at 2026-11-26T01:31:40Z -> **exit 4**: `WARN no live lane lists <the 12 paths>, but 4
  live lane(s) record no files: their scope is unknown, not free`; the unknown lanes,
  all on the planner's box: `a-835` (`a-835-rotate`), `a-852` (the planner),
  `c-298` (`c002-csitea-reporting-costs-taxes-tab`),
  `c-722` (`c002-e3b16fea-lat-a7-hub-records-seen-live-shown-ack`). The plan read 18
  unknown lanes at 00:50:51Z; the set has shrunk since, as live state does.
- Their pushed branches (`git ls-remote origin | grep -E 'a-835|c-298|c-722|…'`, then
  `git diff --name-only $(git merge-base origin/master <sha>) <sha> | grep -cE '<the 6 row file stems>'`):
  `review/c-298-taxes-{0326,build,tab}` 0, 0, 0;
  `review/c-722-…-lat-a7-hub-records-seen-live-shown-ack` 0, `…-lat-a7-shown-ack-r2` 0;
  `review/c-741-c002-wui-notes-delete-key-selected` 0. `a-835` has no branch on origin:
  **not verified** (N2).
- `git log origin/master --since='2026-11-26T00:47:49Z' --format='%h %s' -- <the 6 row .func.sh files> | wc -l` -> `0`.
- No row file is touched by a lane I could read. The holder re-checks at placement (R3).

### 2.7 Check 7: inputs accounted for; one refactor each, no behaviour change

- **Candidates file:** `ls /var/spool-hub/dispatch/c002-next-round-candidates.md` ->
  `No such file or directory` on this seat's box (it lives on the holder's box). **NOT
  RUN**: I could not compare it with plan 1.2 (c) (N3).
- **r03 section 7 vs r04** (`git show origin/master:csi-spl-doc/doc/md/refactor-round-03-plan.md | awk '/^## 7\./,/^## 8\./'`), row by row:
  1. 6 cron installers: 3 served by row 02, 3 left out in r04 7 row 1. Accounted for.
  2. brc / oq "duplicate `do_spl_*` driver, `*_plan_path`, `*_read`, `*_query`, and
     `*_apply` scaffolding": driver, plan path and query served by row 01; **`*_read` and
     `*_apply` neither served nor listed in r04 section 7: W2.**
  3. `spl-msg-{dedup,wipe}`: r04 7 row 3. Accounted for.
  4. `spl-box-restart-install-cron` / `spl-peer-crons` / 5 probes: r04 7 row 4.
  5. `gcp-*alert*` (secret-class): r04 7 row 5.
  6. `spl-channel-agent-*`, `spl-{accepted-close,desk-poll-ack,review-go}`: r04 7 row 6.
  7. the rest (box band, perf report, utl, secret-class, `sec-*`, scripts, Go/WUI): r04 7
     row 7.
  - r03 section 8's c-784 note (vacuous red control,
    `setup-gh-runner-cpu-budget-cron.tst.sh:83-91`): r04 7 row 2 (a test bug, routed to
    a bug round). Accounted for.
- **One logical refactor each:** yes, both rows are "one fact, one copy" extractions.
  **No behaviour change:** row 02 none found (2.4). Row 01 changes the mode of a
  pre-existing `ISSUE_PLAN` file for `do_spl_issue_owner_question_diss` (W1).

### 2.8 Check 8: hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` in this seat's worktree (origin/master
`5aa360afc`, before this file existed) -> last lines
`ok - retired relay estate (SPL-1910)`, `ok - no tracked .vibe/ dir`,
`INFO distribution-hygiene: clean over the tracked tree of …`, **exit 0**. Re-run with
this file staged: see section 5.

### 2.9 Shared column (R2) on base, head1, head2

Counts as rc / pass / fail; `-` = not in that row's shared column (each row's Tests list, `plan.md:776-777`).

| suite | base | head1 | head2 |
|---|---|---|---|
| `iac:no-box-path-source.tst.sh` | 0 / 10 / 0 | 0 / 10 / 0 | 0 / 10 / 0 |
| `iac:action-header-tags.tst.sh` | 0 / 6 / 0 | 0 / 6 / 0 | 0 / 6 / 0 |
| `iac:param-required.tst.sh` | 0 / 17 / 0 | 0 / 17 / 0 | 0 / 17 / 0 |
| `iac:run-lazy-loader.tst.sh` | 0 / 30 / 0 | 0 / 30 / 0 | 0 / 30 / 0 |
| `iac:bash-cleancode.tst.sh` | 0 / 15 / 0 | 0 / 15 / 0 | 0 / 15 / 0 |
| `iac:gcloud-account-pinned.tst.sh` | 0 / 48 / 0 | 0 / 48 / 0 | 0 / 48 / 0 |
| `orc:run-eager-files.tst.sh` | 0 / 14 / 0 | 0 / 14 / 0 | 0 / 14 / 0 |
| `orc:no-literal-paths.tst.sh` | 0 / 15 / 0 | 0 / 15 / 0 | 0 / 15 / 0 |
| `orc:func-name-unique.tst.sh` | 0 / 2 / 0 | 0 / 2 / 0 | 0 / 2 / 0 |
| `orc:spawn-remote-cron.tst.sh` | 0 / 8 / 0 | - | 0 / 8 / 0 |
| `orc:unanswered-sweep.tst.sh` | 0 / 73 / 0 | - | 0 / 73 / 0 |
| `orc:workspace-delivery-probe.tst.sh` | 0 / 28 / 0 | - | 0 / 28 / 0 |
| `orc:check-disk-headroom.tst.sh` | 0 / 43 / 0 | - | 0 / 43 / 0 |
| `orc:prune-go-build-cache.tst.sh` | 0 / 58 / 0 | - | 0 / 58 / 0 |
| `orc:check-env-order.tst.sh` | 0 / 34 / 0 | - | 0 / 34 / 0 |
| `orc:route-ci-overflow.tst.sh` | 0 / 38 / 0 | - | 0 / 38 / 0 |
| `orc:apply-gh-runner-cpu-budget.tst.sh` | 0 / 90 / 0 | - | 0 / 90 / 0 |
| `orc:setup-gh-runner-cpu-budget-cron.tst.sh` | 0 / 17 / 0 | - | 0 / 17 / 0 |

45 runs (18 base, 9 head1, 18 head2), all rc 0, fail 0, every head count equal to base. Source: my scratch `out/shared.txt`, one line per run.

`shellcheck` 0.10.0 `-S warning -x` (`cd <dir> && shellcheck -S warning -x <files>`):
head1 `run/` 2 files rc 0, head1 `tests/` 2 files rc 0, head2 `run/` 4 files rc 0, head2
`tests/` 1 file rc 0. `do_sec_shellcheck` and `do_check_pre_push` on the heads: **NOT
RUN** (row gates, run by the row lanes; my scratch trees are not lane worktrees).

## 3. Defects

- **W1 (row 01, plan `:155-157`, `:265`, `:393-398`, `:788-790`; site `oq:77`):** the
  plan says row 01 keeps "the exact … file modes (0700 dir, 0600 plan)" and that "no
  output, exit code, env var, path or file a caller sees changes", but `oq`'s base
  creator is `(umask 077; : >"$p") || return 1` with no `chmod 600`, and head1 routes
  `oq` through brc's `(umask 077; : >"$p") && chmod 600 "$p" || return 1`. `umask` does
  not change an existing file, so the two differ when `ISSUE_PLAN` names an existing
  file. Measured, n=1 each: a 0644 `$d/plan.tsv` as `ISSUE_PLAN`, then the oq plan-path
  function of each tree -> **base `rc=0 | mode=644`, head1 `rc=0 | mode=600`**.
  It also adds a new failure exit: where `chmod` fails on an existing writable file
  (another owner, group-writable), head1 returns 1 where base returned 0 (read from the
  code, not run). It is a tightening toward the 0600 contract that `oq:72` already
  states, but it is a behaviour change in a row whose subject, Behaviour paragraph and
  `Docs: none` line all say none. **Fold, either way:** (a) keep the change and say so:
  correct 1.3 "Behaviour", 2's row text and the Docs line to name it ("oq's plan file is
  now 0600 also when `ISSUE_PLAN` names an existing file, as `oq:72` states"), and add one
  check that a pre-existing 0644 `ISSUE_PLAN` becomes 600 (red on base, green on head1),
  or (b) leave `spl_issue_oq_plan_path` out of row 01 so the row is pure. I lean to (a):
  the comment already promises 0600 and the change is one line of plan text plus one
  check.
- **W2 (plan section 7, `:991-1001`; 1.2 (a), `:104-108`):** r03 section 7's second row
  listed brc/oq `*_read` and `*_apply` scaffolding as duplicated too. Row 01 serves the
  driver, the plan path and the query; `*_read` (`brc:81-86` vs `oq:83-89`, oq adds
  `do_spl_cloud_cnf`) and `*_apply` (`brc:126-151` vs `oq:136-162`: `diff` of the two
  ranges -> 15 differing lines, the rest the same undo header, loop, undo `printf`,
  tallies and final logs) are in no r04 row and no r04 section 7 row
  (`awk 'NR>=991' plan.md | grep -c apply` -> 1, and that one is
  `_spl_simple_cron_apply`). **Fold:** one section 7 row naming them, with why they stay
  out (distinct re-read semantics in `*_apply`, `do_spl_cloud_cnf` placement in `*_read`)
  and that they are `r05`+ candidates.

## 4. Notes

- **N1:** the plan 1.1 brief count (2) and the R3 queue/brief reads of 2.2 are on the
  holder's box; I read only this seat's box. Not a defect.
- **N2:** `a-835` (`a-835-rotate`) has no remote branch and records no files; the plan
  names its lane "WUI notes Delete key". I could not verify its paths.
- **N3:** the candidates file is not on this seat's box; check 7's candidates part is NOT
  RUN here. The holder can confirm plan 1.2 (c) (142 lines, one bug-shaped addition).
- **N4 (row 01, not a defect):** head1's oq driver sources brc when
  `_spl_issue_brc_run_plan` is undefined, which also (re)defines `spl_issue_brc_one`.
  Base sourced brc only inside `spl_issue_oq_apply`, and only when `spl_issue_brc_one`
  was undefined, so a caller that stubbed `spl_issue_brc_one` alone would now see it
  replaced. `git grep -n 'spl_issue_brc_one *()' ffba81845` -> only the definition at
  `brc:154`: no test or caller stubs it, so no effect today.
- **N5:** my m2b is the plan's "drops `miss_why`" done as passing `""` in its place
  (arg 10), so arg 11 stays `""`. Same result as the plan's (rc 1, 53/1, `5. lazy us`).
- **N6:** plan 1.5's note on counting `OK` lines inside failure dumps holds for rc2's 53
  (the plan: 50 `PASS:` + 3 `OK`); I matched the total, not the split.

## 5. Signatures

- v0.1 `4ded3bf46a50baf4ace5e7919ea9720857af5db7`: **FAIL** (W1, W2), c-804 claude.

## 6. Re-review of v0.2

**PASS** on v0.2 **`84178fd66cb774ff2b05402815cc7da78f880833`**
(`git ls-remote origin refs/heads/review/c002-refactor-round-04-planner` -> that sha,
2026-11-26T01:5xZ; parent `4ded3bf46`). Base unchanged, `ffba81845`. Session
`55bbd52a-82ec-4824-951b-c782185d2762`, n=1 each, 01:50Z to 01:59Z.

### 6.1 What changed

- `git diff --stat 4ded3bf46 84178fd66` -> `refactor-round-04-plan.md | 194`, 1 file,
  `+135 -59`. Read in full.
- The 12 fenced `bash` blocks of v0.1 and v0.2 compared one by one -> only block **7**
  differs (row 01's `spl-issue-owner-question-diss.tst.sh` checks, the new mode check).
  Row 02's blocks are unchanged, so the head2 results of 2.3 and 2.9 stand.

### 6.2 W1 folded (option a)

- Text: intro, 1.3 (Shape, Behaviour), row 01, the Docs paragraph, section 3 and section 5
  now name the tightening: a pre-existing `ISSUE_PLAN` becomes `0600`, and a failing
  `chmod` returns 1. Row 01's `Docs: none (...)` line names it.
- head1 rebuilt from v0.2 (`apply_heads.py`, fresh `git clone` of base): `git diff --numstat`
  `+20 -10`, `+9 -34`, `+46 -0`, `+35 -0`; `sha256sum | cut -c1-12`: `c9476da5a155`,
  `3cfae296d937`, `29126e34f396`, **`fcd6c8c7efbd`** (plan: same), oq test 124 lines.
- Runs (`SPOOL_TEST=1 bash src/bash/tests/<t>`), all as the plan says:

| run | rc / pass / fail | last line / FAIL lines |
|---|---|---|
| base oq test | 0 / 11 / 0 | `ALL PASS` |
| base brc test | 0 / 18 / 0 | `ALL PASS` |
| head1 oq test | 0 / 15 / 0 | `ALL PASS` |
| head1 brc test | 0 / 22 / 0 | `ALL PASS` |
| rc1b (head1's oq test on base) | 1 / 13 / 2 | `oq one copy: own=[38: ...`, **`r04-01 existing plan mode (rc=0): 644`** |
| gc1a (head1, oq `:39` `declare -F` deleted) | 1 / 13 / 2 | `r90-02 sourced alone`, `r04-01 oq solo dry` |
| gc1b (head1, oq `:73` deleted) | 1 / 14 / 1 | `r04-01 oq solo query (rc=127)` |
| m1a (oq `:40` plan path with no subdir) | 1 / 14 / 2 | `oq one copy`, `oq solo dry` |
| m1b (oq `:74` query with no SQL fn) | 1 / 13 / 2 | `oq one copy`, `oq solo query` |
| **m1c** (mine: brc `:75` `&& chmod 600 "$p"` dropped) | oq 1 / 14 / 1; brc 1 / 21 / 1 | oq `r04-01 existing plan mode (rc=0): 644`; brc `existing plan mode: 644` |

  m1c shows the new check guards the W1 contract from both suites.
- `shellcheck -S warning -x` on head1's oq test -> rc 0.

### 6.3 W2 folded

Plan `:1049` (section 7) names brc/oq `*_read` (`brc:81-86` vs `oq:83-89`) and `*_apply`
(`brc:126-151` vs `oq:136-162`), why they stay out (`do_spl_cloud_cnf` placement, distinct
re-read semantics) and `r05`+; `:115` adds the 1.2 (a) note. Accounted for.

### 6.4 Re-checks

- Slug: `git log origin/master --since=2026-11-26T02:43:46+02:00 --oneline -E --grep='\(r04-' | wc -l` -> `0`.
- Drift: `git diff --name-only ffba81845 origin/master -- <the 9 row files>` with
  origin/master `7e7962df5` -> `0` lines.
- R3: `lane-map.sh --check <the 9 row files> --agent c-804` at 01:59:03Z -> exit 4,
  unknown lanes `c-298@sat`, `c-722@sat` (no files recorded; their pushed branches touch
  no row file, 2.6). The holder re-checks at placement.
- Hygiene: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `clean`, rc 0.

### 6.5 Notes on v0.2

- **N7:** after W1(a) row 01 is a refactor with one stated, tested tightening (mode of a
  pre-existing plan file, and rc 1 where `chmod` fails, which base did not run). That is
  the holder's ruling (send-back 78253b0d, option a); it is named everywhere the plan said
  "no change". I sign on that basis.
- **N8:** N1 and N3 (briefs, candidates file) are answered from the holder's box by the
  holder; I still have not read them myself.

- v0.2 `84178fd66cb774ff2b05402815cc7da78f880833`: **PASS**, c-804 claude.

## 7. Signature on v1.0

**PASS** on v1.0 **`31060f1b86b749041c9838436fa1a7b954e23ce2`**
(`git ls-remote origin refs/heads/review/c002-refactor-round-04-planner` -> that sha).

- `git merge-base --is-ancestor 84178fd66 31060f1b8` -> true (fast-forward on v0.2).
- `git diff --stat 84178fd66 31060f1b8` -> 1 file, `+38 -12`; read in full: status line,
  1.3 Behaviour (N7 named as the holder's option (a) ruling, `78253b0d`, with my `m1c`
  counts `1/14/1` and `1/21/1`, as I measured), the panel and changelog entries (N8).
- The 12 fenced `bash` blocks of v0.2 and v1.0 compared one by one -> `12 12 []`: none
  differs, so the v0.2 head1/head2 results of section 6 and 2.3 stand.

- v1.0 `31060f1b86b749041c9838436fa1a7b954e23ce2`: **PASS**, c-804 claude.
