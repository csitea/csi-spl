# Refactor round 09 plan: claude panel seat verdict

Seat: **claude**, cross-vendor panel seat `c-342` (placement
`c002-refactor-round-09-claude-panel-seat`), task `dispatch-refactor-r09`,
issue SPL-6632 (epic SPL-2402, spec 011). Rules: `rounds-rulebook.md`
sections 1 to 3 and 5.

Review of: `csi-spl-doc/doc/md/refactor-round-09-plan.md` **v0.1**, branch
`review/c002-refactor-round-09-planner` =
**`feb3c1917bb2b27788ae1de13c32a6cb080e3149`**, editor `a-260` (agy), base
`ecc05e480b429bb9385725a257bc15f7d21a79de`.

## Verdict

**PASS on `feb3c1917bb2b27788ae1de13c32a6cb080e3149`.** Fold W1 and W2 into v1.0;
neither blocks the rows.

I rebuilt both heads from the plan's verbatim blocks. All 7 files match the plan's
sha256 values. Both red controls fail for the reason the plan gives, and all 6
mutations are caught. The 13-suite column is equal on base and heads. I found no
change to an exit code, message, path or default. Both rows are one logical
refactor each and share no file.

## Checks, with the command and what it printed

Run 2026-11-26T23:0xZ-23:18Z, n=1 each. Scratch clones at `ecc05e480` live
outside the repo, are never committed, and touch no live state. Tests ran with
`SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from
`/dev/null`. I count pass lines with `grep -ciE '^ *(ok|pass)'` and fail lines with
`grep -ciE '^ *(not ok|fail)'`, as the plan does.

### 1. Slug r09 and window

- `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r08-plan'` ->
  `26c6b91eddaa182cb36b2390950fa560a9618033 2026-11-27T00:36:21+02:00 docs(r08-plan, SPL-6604): ...`
  This is the plan's `W=2026-11-27T00:36:21+02:00` (plan :83).
- `git log origin/master --since="$W" --oneline -E --grep='\(r09-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r09-[0-9]{2}|refactor-round-09'` ->
  `feb3c1917bb2b27788ae1de13c32a6cb080e3149 refs/heads/review/c002-refactor-round-09-planner`
  only. This is the planner's branch; my seat branch did not exist yet.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r09-[0-9]{2}|refactor-round-09'` on
  this seat's box -> nothing (grep rc 1). The planner's and the holder's briefs live
  on the planner's box; my brief is in `spawn-remote/briefs`.
- `git ls-tree -r --name-only origin/master csi-spl-doc/doc/md/ | grep -E 'refactor-round-0?9[-/.]'`
  -> only `refactor-round-9-plan.md`, `-9-retro.md` and `refactor-round-9/seat-*`.
  No `-09` name is taken, so 5.3 needs no date suffix (plan :99-101 holds).
- origin/master was `39bb380f8` at the read; `git merge-base --is-ancestor ecc05e480 origin/master` -> ancestor.

### 2. Sites exist on the base and on origin/master

- `git diff --name-only ecc05e480 origin/master -- <the 7 row files + spl-git-pager-off-install.func.sh>`
  -> empty. Nothing drifted.
- Each cited line, read with `git show ecc05e480:<file> | cat -n`:
  - `spl-grok-memory-install.func.sh`: 50 lines; :18-50 is `do_spl_grok_memory_install`,
    :33 the `sed -n 's/^SPOOL_AGENT_USER=//p'`, :23-28 the repo derivation.
  - `spl-agy-memory-install.func.sh`: 52 lines; :20-52, :35 sed, :25-30 repo derivation.
  - `spl-git-pager-off-install.func.sh`: :29-62 is `_spl_user_step_install` with the optional 7th `repo` arg.
  - `wui-dev.func.sh` (25 lines): :10-25, preamble :12-18.
  - `wui-build.func.sh` (22 lines): :10-22, preamble :11-17.
  - `wui-test.func.sh` (16 lines): :6-16, preamble :7-13.
  - `test-y18-grok-memory.sh` (128 lines): :19 is the last header item, :126 blank, :127 the summary `echo`.
  - `wui-actions.tst.sh` (141 lines): :18, :21 and :22 are the greps the plan names, :139 blank, :140 `[[ "$fails" -eq 0 ]]`.
  - All match.
- Base sha256 (12 chars): grok `92e1ad904fac`, agy `8ff6df44b9ab`, y18 test `296fcd6ec36e`,
  wui-dev `93a973b0ec93`, wui-build `0d15ac8f7e50`, wui-test `534cb2c590c7`,
  wui-actions `9945e3c95c93`.

### 3. Red controls

I rebuilt head1, head2, rc1 and rc2 from the plan's 8 `bash` blocks (plan :206-488)
with a splice script, using the splice points of 1.3 and 1.4. Then I ran
`git diff --numstat` and `sha256sum` on each changed file:

- head1: y18 test `+65 -0` `4c0375ed42ea`, agy `+6 -31` `60f5071ab943`,
  grok `+16 -25` `50391c1df5bb`.
- head2: wui-build `+8 -11` `04930c0f2976`, wui-dev `+15 -8` `d863b23a49f1`,
  wui-test `+6 -9` `97d8fa671ff3`, wui-actions `+65 -0` `30c31e86be17`.
- All 7 equal the plan's values (:199-201, :362-364).

| control | sha256 of the control file | rc | pass / fail | last line |
|---|---|---|---|---|
| base `test-y18-grok-memory.sh` | `296fcd6ec36e` | 0 | 15 / 0 | `--- y18 grok memory: 15/15 passed, 0 grok checks not run` |
| rc1 = head1's y18 test on base | `4c0375ed42ea…6b1e` | **1** | 17 / 8 | `--- y18 grok memory: 17/25 passed, 0 grok checks not run` |
| head1 | `4c0375ed42ea` | 0 | 25 / 0 | `--- y18 grok memory: 25/25 passed, 0 grok checks not run` |
| base `wui-actions.tst.sh` | `9945e3c95c93` | 0 | 28 / 0 | `PASS: all wui-actions.tst.sh assertions` |
| rc2 = head2's wui-actions on base | `30c31e86be17…3475` | **1** | 30 / 8 | `FAIL: 7 assertion(s) in wui-actions.tst.sh` |
| head2 | `30c31e86be17` | 0 | 38 / 0 | `PASS: all wui-actions.tst.sh assertions` |

Why they fail:

- **rc1** fails for the plan's reason, not an environment one. Five checks end in
  `_spl_memory_step_install: command not found` (rc 127). `grok host` names `:33`,
  `agy delegate` names `:27`, and `5/5 loop hosts` lists the 3 files. Both standalone
  checks pass on base.
- **rc2** fails the same way. Four checks end in `_wui_prepare: command not found`.
  The other failures are `one copy: wui-dev host`, `one copy wui-build.func.sh` naming
  `:13` and `one copy wui-test.func.sh` naming `:9`, plus the summary. All 3 standalone
  checks pass on base.

Live state: none. Every new check uses `mktemp -d` dirs (`$T`, `$WUI_T`), a stubbed
`getent`, `pnpm`, `do_require_bin` and `do_lde_cnf`, users = the running user (no
`sudo -n -u`), and `DRY_RUN=1`. The standalone y18 checks assert `[ ! -e "$H10/.grok/rules" ]`.

Counts differ from the plan by +2 on the y18 suite only: 15 / 17 / 25 here against
13 / 15 / 23 in the plan. `command -v grok` -> found on this seat's box and
`grep -c 'not run'` -> the summary reads `0 grok checks not run`, so 2 grok checks ran
here that the plan's box skipped (plan :525-527 says so). The fail set is identical
(N1).

### 4. Equivalence

**Row 01.** I read base :18-50 and :20-52 against `_spl_user_step_install` (:29-62)
and the head blocks:

- The order is the same: `DRY_RUN`, then the step check, then the repo derivation,
  then the loop.
- Messages are the same. `FATAL cannot tell the repo of $PROJ_PATH (set <X>_MEMORY_REPO)`
  is kept through `repo_var`. `INFO <label>: $u ($home), repo $repo, DRY_RUN=$dry`
  is kept because `hsuf` is empty and `${repo:+...}` always has a repo. `OK <label>: $users (DRY_RUN=$dry)`
  is kept because `users` resolves to the same `"$agent $me"` default, and an empty
  override takes that default too, as `:-` did.
- Each user's call is the same: `<fn> "$home" "$dry" "$repo"`. Dedup, the `ERROR no passwd entry`
  branch and the return code are unchanged.
- The only additions are a second, redundant step-readability check inside
  `_spl_user_step_install` and an unreachable `source ... || return 1`.
- The lazy `declare -F ... || source "$(dirname "${BASH_SOURCE[0]}")/..."` form is
  already used in 10 `orc` run files on `ecc05e480`
  (`git grep -nE 'declare -F [_a-z]+ >/dev/null \|\| source "\$\(dirname' ecc05e480 -- csi-spl-orc/src/bash/run`).

**Row 02.**

- `FATAL missing <dir>` and `INFO pnpm install in <dir>` have the same text with
  `WUI_DIR` in place of `wui`. The install runs only without `node_modules`.
- `do_lde_cnf` still runs first in `do_wui_dev`, and the pnpm commands and their
  return codes are unchanged.
- An edge case with no effect: `local WUI_DIR` is set and not exported, but if a
  caller had exported `WUI_DIR`, the `pnpm` children now see the wui path. I tested
  it with `export WUI_DIR=/app; f(){ local WUI_DIR=""; WUI_DIR=/x; bash -c 'echo child=[${WUI_DIR-unset}]'; }; f`
  -> `child=[/x]`. `git grep -n WUI_DIR ecc05e480 -- csi-spl-wui` -> 0 hits. Only the
  local-hub container script reads it, and these actions never run it, so nothing
  changes (N2).

Would the controls catch a difference? Each mutation was planted on a fresh copy of
its head:

| mutation | rc | pass / fail | FAIL lines |
|---|---|---|---|
| m1a agy passes `"/wrong"` | 1 | 25 / 1 | `10. agy standalone` |
| m1b `"" ""` instead of `"" "$repo"` | 1 | 25 / 4 | `10. wt derive`, `repo override`, `grok standalone`, `agy standalone` |
| m1c `dirname` line dropped | 1 | 25 / 3 | `wt derive`, `grok standalone`, `agy standalone` |
| m2a `if false; then` | 1 | 34 / 4 | `wui-prepare no-nm`, `standalone wui-dev`, `standalone wui-build`, summary |
| m2b wui-build sets `WUI_DIR` itself | 1 | 36 / 2 | `standalone wui-build`, summary |
| m2c wui-test `:` | 1 | 36 / 2 | `standalone wui-test`, summary |
| **x2d (mine)** `do_lde_cnf` moved after `_wui_prepare` in `do_wui_dev` | **0** | 38 / 0 | none: **not caught** (W1) |

The plan's 6 mutations are all caught, with the same fail sets as plan :549-572.
The y18 pass counts are +2 for the reason in N1.

### 5. Rows: R2, vendor, kind, batch, R7, R1

- Each row has a control that fails today and passes after (section 3), a test list,
  vendor `claude`, kind `simple_coding` and batch 1 (plan :595-596).
- No row is mistral. R7 is an agy seat, with the claude waiver backup only under ruling
  `dc84300a` and never mistral (plan :709-720, :759-761, :780-782).
- 2 rows meets 5.1 (aim 2, max 3), and each row edits at most 5 files (3 and 4).
- R1: the file sets are disjoint (plan :613-616). Re-read from the head diffs: head1
  touches 3 files and head2 touches 4, with no file in both.

### 6. R3: lane map

- At 2026-11-26T23:16:43Z, `lane-map.sh --check <the 7 row paths, comma-separated> --agent c-342`
  -> **exit 4**. It printed `WARN no live lane lists <paths>, but 9 live lane(s) record no files`,
  0 owned. The unknown lanes were `a-260` (this planner), `a-262` and `a-274` (agy
  reviewers of SPL-6605 and SPL-6633), `c-119` (WUI sorted window), `c-129`,
  `c-195` and `c-197` (s150 B14 and B15a), and `c-269` and `c-270` (SPL-6615 and
  SPL-6616 rotate fixes). The planner saw 22 unknowns from its own box at 22:54Z; the
  view is per box and time.
- To settle the unknowns I checked every origin branch whose tip moved in the last 48 h
  (36 branches, `git for-each-ref --format='%(committerdate:unix) %(refname:short)' refs/remotes/origin`).
  For each one, `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 7 paths>`
  -> 0 hits. The only branch of those lanes on origin is `review/c-197-s150-b15a`, and it
  doesn't touch them.
- `git log origin/master --since='48 hours ago' -- <the 7 paths>` -> empty.
- `grep -lE 'wui-(dev|build|test)\.func|wui-actions\.tst|(grok|agy)-memory-install|test-y18-grok' /var/spool-hub/spawn-remote/briefs/*.md`
  -> 6 briefs. The newest is the r08-02 row brief (2026-11-26 20:06), which landed as
  `48431f0f5`; the rest are from October and November rounds that have landed. No live
  brief names a row file.
- No live or queued lane touches a row file. The planner's claim (plan :647-678) holds
  for this box's view.

### 7. Inputs accounted for

- **r08 section 7** (`git show origin/master:csi-spl-doc/doc/md/refactor-round-08-plan.md`),
  item by item:
  - Rows 1 and 2 (memory wave 2 and the wui preamble) are served as r09-01 and r09-02.
  - The `is a linked worktree:` sites, `spl-issue-*` scaffolding, cron, probe, gcp and PG
    items, r07 leftovers, candidates-file items and spec 011 tasks are all carried into
    r09 section 7 (plan :801-806).
  - One new r10 candidate (the CLI installer wrappers) is added (:800).
  - Nothing is dropped.
- **The candidates file**: NOT RUN. `/var/spool-hub/dispatch/c002-next-round-candidates.md`
  is not on this seat's box (`ls` -> `No such file or directory`). A read-only
  `ssh satellite 'cat -n ...'` as the push user -> `Permission denied`. So I can't
  confirm plan :137-144 (lines 113, 115, 125, 147-148 and 153-167); it is the planner's
  claim (N3).
- Row shape: each row is one logical refactor (one fact, one copy). Neither changes an
  exit code, a message, a path or a default (section 4), so neither is a bug row.
- Plan 1.2 (a) on other `pnpm install` callers:
  `git grep -n "pnpm install" ecc05e480 -- csi-spl-orc/src/bash/run/ csi-spl-iac/src/bash/run/`.
  - The only bare `( cd ... && pnpm install )` calls are the 3 wui files.
  - `deploy-wui:150`, `deploy-hosted-site:122` and the check-pre-push lines use
    `--frozen-lockfile`.
  - `wui-up:34` runs the install in a container.
  - `sec-scan:178` is a message and `spl-tenant-host-reconcile:371` a comment.
  - The plan holds.

### 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` on this worktree (`3aa767190`) -> rc 0,
  `INFO distribution-hygiene: clean over the tracked tree`.
- The same command in a scratch clone at `feb3c1917` (the plan's tree) -> rc 0, clean.

### Regression column (plan 1.5), base / head1 / head2

Each suite was run with `env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 bash <suite> </dev/null`.
Every one gave rc 0 with these pass counts, and fail 0 everywhere:

- y20 agy memory: 68 (base) = 68 (head1)
- y16 git pager off: 22 = 22
- run-eager-files: 14 / 14 / 14
- no-literal-paths: 15 / 15 / 15
- func-name-unique: 2 / 2 / 2
- no-box-path-source: 10 / 10 / 10
- action-header-tags: 6 / 6 / 6
- param-required: 17 / 17 / 17
- run-lazy-loader: 30 / 30 / 30
- bash-cleancode: 15 / 15 / 15
- gcloud-account-pinned: 48 / 48 / 48

These equal plan :504-518.

`shellcheck 0.10.0 -S warning -x` on the 3 head1 and 4 head2 files -> rc 0 for each.
Not run: `do_sec_shellcheck` and `do_check_pre_push` on the heads. Those are the row
lanes' gates.

Perf floor, rulebook 4.4 command at 2026-11-26T23:18:03Z ->
`perf 36 refactor 113 perf-share 24.2% floor-met`. The plan read 114 at 22:52Z: one r row
aged out of the 14-day window. The floor still holds.

## Defects (fold into v1.0)

- **W1 (plan :491-494, :473; row 02 control).** The plan says `do_lde_cnf` stays first
  in `do_wui_dev`, and the shape keeps it there, but no check guards it. Mutation x2d
  (moving `local WUI_DIR=""; _wui_prepare || return 1` above `do_lde_cnf`) leaves
  `wui-actions.tst.sh` at rc 0, 38 / 0. Fix: add one standalone check where `do_lde_cnf`
  returns 1 and assert rc 1 with no `REQ:pnpm` and no `PNPM:` line. Then a reorder
  fails, and the row's "same order" claim has a control.
- **W2 (plan :352-353).** The text reads "replace `:10-25` with `do_wui_dev` calling
  `_wui_prepare` + `_wui_prepare`", which names `_wui_prepare` twice. It should read
  "`do_wui_dev` (calling it) + `_wui_prepare`". Text only; the verbatim block at
  :369-393 is right.

## Notes

- **N1.** The y18 counts depend on the box. With `grok` on PATH, base, rc1 and head1 read
  15/0, 17/8 and 25/0, against the plan's 13/0, 15/8 and 23/0. The row brief should quote
  the fail set and rc, not the absolute pass counts, so a lane on a grok box doesn't
  think its red control is wrong.
- **N2.** `WUI_DIR` is a caller-scoped local. A caller-exported `WUI_DIR` would now reach
  the `pnpm` children, but nothing in `csi-spl-wui` reads it (0 hits), so nothing changes.
  A lower-case local name would avoid the question; that's optional.
- **N3.** The candidates-file read is NOT RUN on this seat (not present here; permission
  denied over ssh). Plan :137-144 and the section 7 row citing it are the planner's
  measurement only.
- **N4.** Plan :89 shortens the perf-floor command to `awk ...`. The full form is in
  rulebook 4.4, which the plan points to, and I re-ran that form (section 8). Writing it
  out in full would meet R12 by itself.
- **N5.** The lane-map view differs by box: 22 unknowns from the planner's box at 22:54Z,
  9 from this one at 23:16Z, with 0 owners both times. The holder re-reads at placement
  (R3), as the plan says.
- **N6.** Plan :800 says the r10 candidate has "4 files" but names 3
  (`install-agy-cli`, `install-mistral-vibe`, `install-openai-codex`). Plan :124-128
  says "3-file", so :800 should say 3. Text only.

## Sign-off

- v0.1 `feb3c1917bb2b27788ae1de13c32a6cb080e3149`: **PASS** (W1, W2 to fold).
- v1.0: pending. I'll sign it in a second commit on this branch once the editor sends
  the sha.
