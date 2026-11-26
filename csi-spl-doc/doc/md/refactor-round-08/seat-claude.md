# Refactor round 08 plan: claude panel seat (c-157)

Seat: **c-157** (claude), the cross-vendor panel seat of rulebook 3.2 (editor a-121, agy).
Issue SPL-6604, epic SPL-2402, spec `csi-spl-doc/specs/011-spool-project-refactor`.

## 0. Verdict

**FAIL on v0.1 `fa70bea3bc7dec4c38d58344b09777a0b394309f`**, three defects (W1-W3),
each one fold in the plan text. The rows themselves hold: the slug is free, the sites
match on base and on master, all 9 head sha256s match, both red controls go RED for the
stated reason and GREEN on the heads, all 6 mutations are caught with the plan's counts,
the column passes equal on base and the heads, R1 and R3 hold and the hygiene is clean.
W1 is a safety defect in row 01's test block (a mutated or regressed head reaches the
caller's live tmux server); W2 and W3 are plan-text defects. I sign v1.0 once W1-W3 are
folded.

- Plan read: `git show fa70bea3b:csi-spl-doc/doc/md/refactor-round-08-plan.md`
  (917 lines). `git ls-remote origin refs/heads/review/c002-refactor-round-08-planner`
  -> `fa70bea3bc7dec4c38d58344b09777a0b394309f`. `git log --oneline origin/master..fa70bea3b`
  -> one commit, `fa70bea3b docs(r08-plan, SPL-6604): refactor round 08 plan v0.1 (2 rows)`;
  `git merge-base fa70bea3b origin/master` -> `fea2cc504`.
- Measurement base `e5af88d93`; `origin/master` at review time `fea2cc504`
  (fetched 2026-11-26T15:45Z).
- Heads, red controls and mutations were built in scratch trees (`git archive e5af88d93`
  into this seat's scratch dir, removed after the review), applied by a script from the
  plan's fenced blocks (plan lines 220-238, 242-247, 251-254, 258-261, 266-270, 271-273,
  274-351 for head1; 416-464, 467-478, 481-492, 498-500, 501-556 for head2) at the line
  ranges the plan names.
- Every suite ran with `SPOOL_TEST=1`, `TMUX`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID`
  unset, stdin from `/dev/null`, as the seat's agent user on the seat's box, n=1. A logging `tmux` shim
  (exits 1) was first on `PATH` for every run except the re-run noted in 4.

## 1. Slug and window (rulebook 5.3)

- `W=2026-11-26T15:42:29+02:00`, as recorded in plan 1.1:
  `git log -1 --format='%H %cI' 34d67a385` -> `34d67a38514d599902ca3971ebe06bb5d2995932 2026-11-26T15:42:29+02:00`.
  The newest `docs(r07-plan` commit is now `fea2cc504` (r07's close record,
  `2026-11-26T17:36:12+02:00`), landed after the plan read `W`; per 5.3 `W` stays.
- `git log origin/master --since="$W" --oneline -E --grep='\(r08-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r08-[0-9]{2}|refactor-round-08'` -> one line,
  `fa70bea3b... refs/heads/review/c002-refactor-round-08-planner` (my seat branch did
  not exist yet). Nothing else.
- `git ls-remote origin 'refs/heads/review/r08-*' 'refs/heads/wip/*r08*' 'refs/heads/*-r08-*'`
  -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r08-[0-9]{2}|refactor-round-08'` on the seat's box
  -> nothing (rc 1). The planner's and this seat's briefs are on the planner's box;
  this seat's brief is under `spawn-remote/briefs/` here. Not a defect: the dir is
  box-local, as plan 1.1 says.

## 2. Sites on base and on master

- Line count and sha256 (12 chars) of the 9 row files on `e5af88d93`
  (`git show e5af88d93:<file> | wc -l`, `| sha256sum`): `cron-tagged-line.func.sh` 56,
  `install-box-crons.func.sh` 278, `spl-agent-hooks-install.func.sh` 97,
  `spl-agent-identity-install.func.sh` 108, `cron-tagged-line.tst.sh` 167,
  `spl-git-pager-off-install.func.sh` 43, `spl-vibe-output-cap-install.func.sh` 44,
  `spl-vibe-push-guard-install.func.sh` 45, `test-y16-git-pager-off.sh` 103: each as the
  plan says.
- Read with `git show e5af88d93:<file> | sed -n <N>p` (`cat -n` over the range):
  - `cron-tagged-line.func.sh:42-44` the comment, `:45` `cron_refuse_linked_worktree() {`,
    `:56` `}`.
  - `install-box-crons.func.sh:55` `local i missing="" gd cd du dct`; `:65-70` the guard
    (`:67` `if [[ "$act" == install && ... "${BOX_CRONS_ALLOW_WORKTREE:-0}" != 1 ]]`,
    `:68` FATAL `install from the main checkout`, `:69` WARN `the paths below`).
  - `spl-agent-hooks-install.func.sh:30` `local gd cd`, `:31-32` comment, `:33-40` the
    guard (`:36` `if [[ "$dry" == 0 && "$un" != 1 ]]`, `:37` FATAL `run the install`,
    `:39` WARN `the paths below`).
  - `spl-agent-identity-install.func.sh:35` `local ct=... rc=0 gd cd`, `:36-37` comment,
    `:38-45` the guard (`:41` `if [[ "$dry" == 0 && "$un" != 1 ]]`, `:42` FATAL, `:44` WARN).
  - `cron-tagged-line.tst.sh:11` `#   6. a refusing crontab: FATAL, rc 1`, `:94` the
    host grep for literal `install from the main checkout`, `:166` blank, `:167`
    `[ "$fails" -eq 0 ] && echo "ALL PASS" ...`; `:85`, `:88` pin the default wording.
  - `spl-git-pager-off-install.func.sh:16-43`, `spl-vibe-output-cap-install.func.sh:17-44`,
    `spl-vibe-push-guard-install.func.sh:18-45`: each is the whole action function.
  - `test-y16-git-pager-off.sh:16` the last header item (`git config untouched`), `:101`
    blank, `:102` the summary `echo`.
  - `boot-cron-gate.tst.sh:60`, `test-agent-hook.sh:311` (`source "$ACT_FILE"`),
    `test-agent-identity-reconcile.sh:144`: each sources its action file standalone, so
    the lazy-load the plan adds is needed.
  - `satellite-ansible.tst.sh:405,410` name `do_spl_agent_identity_install` /
    `spl-agent-identity-install.func.sh`.
- `gd`/`cd` are used only by the guard: `grep -nE '\$\{?(gd|cd)\b|\b(gd|cd)=|local .*\b(gd|cd)\b'`
  on the 3 row 01 callers -> the `local` line and the 3 guard lines in each, nothing else.
- The three copies of row 02 differ only where the helper takes an argument:
  `diff <(sed -n 17,44p output-cap) <(sed -n 18,45p push-guard)` -> the function name,
  step path, `*_USERS` var, label (INFO / OK) and step function; `diff` of pager-off
  `:16-43` against output-cap `:17-44` -> the same plus `do_require_bin git|python3` and
  `$home` vs `$home/.vibe`.
- `git grep -n "is a linked worktree:" e5af88d93 -- csi-spl-orc/src/bash/run/` -> 10
  lines in 6 files (plan 1.2 (a): 10 / 6).
- Drift: `git diff --name-only e5af88d93 origin/master -- <the 9 row files> | wc -l`
  -> `0` (origin/master `fea2cc504`).

## 3. Heads, red controls, mutations

sha256 (12 chars) of every head file, built from the plan's blocks:

| file | measured | plan |
|---|---|---|
| `cron-tagged-line.func.sh` (58 lines) | `35815c400147` | `35815c400147` |
| `install-box-crons.func.sh` (276) | `8e966e56793f` | `8e966e56793f` |
| `spl-agent-hooks-install.func.sh` (90) | `0d2593700f57` | `0d2593700f57` |
| `spl-agent-identity-install.func.sh` (102) | `0912482b3903` | `0912482b3903` |
| `cron-tagged-line.tst.sh` (247) | `8068b26331f2` | `8068b26331f2` |
| `spl-git-pager-off-install.func.sh` (62) | `0900fd75c3b6` | `0900fd75c3b6` |
| `spl-vibe-output-cap-install.func.sh` (26) | `7bef959013de` | `7bef959013de` |
| `spl-vibe-push-guard-install.func.sh` (27) | `be118d1a811a` | `be118d1a811a` |
| `test-y16-git-pager-off.sh` (159) | `e3554ae3158c` | `e3554ae3158c` |

Control files (full sha256): head1 `cron-tagged-line.tst.sh`
`8068b26331f23a51178cf6f892bc4d912a23b779ef91605693db64fb8e41eb23`, head2
`test-y16-git-pager-off.sh`
`e3554ae3158cddf060e759571831f9b057c6b1203f67e304a3b364853eee340f`. Neither is a new
file: each control is the head's test run on base.

| run | rc | pass | fail | last line |
|---|---|---|---|---|
| `rc1` (head1 test on base) | 1 | 40 | 6 | `6 FAILED` |
| head1 | 0 | 46 | 0 | `ALL PASS` |
| base `cron-tagged-line.tst.sh` | 0 | 31 | 0 | `ALL PASS` |
| `rc2` (head2 test on base) | 1 | 13 | 9 | `--- y16 git pager off: 13/22 passed, 0 skipped` |
| head2 | 0 | 22 | 0 | `--- y16 git pager off: 22/22 passed, 0 skipped` |
| base `test-y16-git-pager-off.sh` | 0 | 11 | 0 | `--- y16 git pager off: 11/11 passed, 0 skipped` |

- `rc1` fails for the reason the plan gives, not an environment one: `FAIL: 7. host one
  copy`, `FAIL: 9. custom dry=0` (base prints `install from`), `FAIL: 9. custom dry=1`
  (base prints `the path below`), and `FAIL: 9. one copy` on `install-box-crons.func.sh`
  `:66`, `spl-agent-hooks-install.func.sh` `:34`, `spl-agent-identity-install.func.sh`
  `:39`. All 9 standalone caller checks pass on base, which is the equivalence proof.
- `rc2` likewise: 6 `FAIL: 8.` with `_spl_user_step_install: command not found` (rc 127),
  `FAIL: 8. host one copy`, `FAIL: 8. one copy` on output-cap `:27` and push-guard `:28`;
  both standalone vibe dry-run checks pass on base.
- Mutations, each one planted on its head (`pass` = `grep -ciE '^ *(ok|pass)'`, `real` =
  `grep -c '^PASS'`):

| mutation | rc | pass | real | fail | failing checks | plan |
|---|---|---|---|---|---|---|
| `m1a` box-crons allow `"1"` | 1 | 46 | 44 | 2 | box-crons dry=0, dry=1 | `46*/2` |
| `m1b` hooks allow `"1"` | 1 | 43 | 43 | 3 | hooks dry=0, dry=1, uninstall | `43/3` |
| `m1c` identity allow `"1"` | 1 | 46 | 43 | 3 | identity dry=0, dry=1, uninstall | `46*/3` |
| `m2a` output-cap no `"/.vibe"` | 1 | 22 | 21 | 1 | vibe-output-cap | `22*/1` |
| `m2b` push-guard no `"/.vibe"` | 1 | 22 | 21 | 1 | vibe-push-guard | `22*/1` |
| `m2c` helper skips dedup | 1 | 22 | 20 | 2 | dedup, box.env | `22*/2` |

- **Live state.** Section 8 (row 02) runs only a fake step function and two dry runs.
  Section 9 (row 01) writes only under `$T`: `BOX_CRONS_CRONTAB` / `IDENTITY_CRONTAB` are
  the fixture's `$T/fake-crontab` (it writes `$T/crontab`), `BOX_CRONS_DESK_USER=$(id -un)`
  leaves no desk crontab, `HOOKS_SETTINGS=$T/hooks-set.json`. On base and on the heads
  nothing reaches a live server: the tmux shim log shows only
  `tmux -u -S /tmp/tmp.*/no.sock show-hooks -g ...` from the identity dry=1 and
  uninstall checks. **Under `m1c` it does not hold**: W1.

## 4. Column (R2): base, head1, head2

24 suites, run in each tree (`git init` + one commit of the archive so the git-reading
suites work), 2026-11-26T15:49:48Z-15:58:13Z; rc / pass / fail:

| suite | base | head1 | head2 |
|---|---|---|---|
| `cron-tagged-line.tst.sh` | 0/31/0 | 0/46/0 | 0/31/0 |
| `install-box-crons.tst.sh` | 0/40/0 | = | = |
| `test-agent-hook.sh` | 0/225/0 | = | = |
| `test-agent-identity-reconcile.sh` | 0/46/0 * | 0/46/0 * | not re-run |
| `boot-cron-gate.tst.sh` | 0/10/0 | = | = |
| `cron-no-stack.tst.sh` | 0/26/0 | = | = |
| `od-pool-replace.tst.sh` | 0/9/0 | = | = |
| `reliability-checks-cron.tst.sh` | 0/9/0 | = | = |
| `spl-box-deploy.tst.sh` | 0/36/0 | = | = |
| `spl-box-update-install-cron.tst.sh` | 0/12/0 | = | = |
| `spl-cost-labels-translate-install-cron.tst.sh` | 0/29/0 | = | = |
| `satellite-ansible.tst.sh` | 0/96/0 | = | = |
| `test-y16-git-pager-off.sh` | 0/11/0 | = | 0/22/0 |
| `test-y15-vibe-output-cap.sh` | **0/16/0** | = | = |
| `test-y12-vibe-push-guard.sh` | **0/35/0** | = | = |
| `run-eager-files.tst.sh` | 0/14/0 | = | = |
| `no-literal-paths.tst.sh` | 0/15/0 | = | = |
| `func-name-unique.tst.sh` | 0/2/0 | = | = |
| `no-box-path-source.tst.sh` | 0/10/0 | = | = |
| `action-header-tags.tst.sh` | 0/6/0 | = | = |
| `param-required.tst.sh` | 0/17/0 | = | = |
| `run-lazy-loader.tst.sh` | 0/30/0 | = | = |
| `bash-cleancode.tst.sh` | 0/15/0 | = | = |
| `gcloud-account-pinned.tst.sh` | 0/48/0 | = | = |

\* With the tmux shim first on `PATH`, `test-agent-identity-reconcile.sh` was `1/23/23`
on all three trees (it drives a real tmux on its own `$T` socket; the shim exits 1): an
environment reason, equal on all three. Re-run without the shim, `TMUX` unset: base and
head1 `rc 0`, `-- test-agent-identity-reconcile.sh: 46 passed, 0 failed`. head2 does not
touch its tree (the 1/23/23 run is equal to base).

The bold counts differ from plan 1.5: W3. `gcloud-account-pinned` reads 48 here and 45 in
the plan (N4).

`shellcheck` and `do_sec_shellcheck` on the 9 head files: NOT RUN by this seat (the
column's `bash-cleancode`, `func-name-unique`, `run-lazy-loader` and
`param-required` ran; the row lanes run `shellcheck -S warning -x` and
`do_check_pre_push` before their push, plan section 5).

## 5. Equivalence of the rows

- **Row 01.** `cron_refuse_linked_worktree`'s new 3rd and 4th args default to the old
  literals, so every 2-arg caller prints the same bytes (`cron-tagged-line.tst.sh:85,88`
  pin them; the 10 existing callers' suites are equal in 4).
  - `install-box-crons`: the old guard ran only for `act == install`; the new call sits in
    `if [[ "$act" == install ]]`. FATAL via `do_log`, WARN via `echo`, rc 1 / 0, the
    allow knob: unchanged.
  - `spl-agent-hooks-install` / `spl-agent-identity-install`: old = FATAL when
    `dry == 0 && un != 1`, else WARN; new passes `dry' = 1` when `un == 1`, else `dry`, to
    a helper that FATALs on `dry' == 0`. The truth table is the same for every `dry` in
    {0,1} and every `un`.
  - The helper adds `|| true` to the two `git rev-parse` assignments, which the three
    old copies did not have. Not observable: `run.sh:7` is `set -E` (no `-e`) and
    `run.sh:169-172` drops the ERR trap around the action (`trap - ERR`), so a failing
    assignment never aborted the old code either (N3).
  - The lazy-load path `$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/...` is the
    form `install-box-crons.func.sh:101,133` already uses.
  - The controls catch a difference: the 9 standalone checks pin FATAL / WARN text, rc
    and the uninstall / remove bypass per caller (`m1a`-`m1c`).
- **Row 02.** `_spl_user_step_install` keeps the order (step readable -> users -> per
  user: dedup, `getent`, INFO, `bash -c` or `sudo -n -u`, rc) and every message.
  `users` override: old `${X:-$agent $me}` and new `[[ -z "$users" ]]` treat an empty
  value the same; the old code read `box.env` even when overridden, without effect. The
  step function gets the same two args (`"${@:3}"` = target, dry; no `repo` in wave 1).
  The controls catch a difference: the 6 helper checks, and the two standalone vibe dry
  runs pin the INFO / OK text and the `/.vibe` suffix (`m2a`-`m2c`).
- Neither row changes an exit code, a message, a path or a default: both are refactor
  rows, not bug rows.

## 6. Rows (R1, R2, R5-R7)

- Row table (plan lines 679-680): each row has a red control that fails today and passes
  after, a test list, vendor `claude`, kind `simple_coding`, batch 1. No mistral row;
  each R7 reviewer is an agy seat with the claude waiver backup under ruling `dc84300a`
  (plan section 4, lines 806-817), never mistral.
- R1: row 01's 5 files and row 02's 4 files are disjoint (plan 2.1).
- R2, my own grep: `git grep -lE '<row 01 names>' e5af88d93 -- '*test*' '*tst*' .github`
  -> the 12 suites of row 01's column plus `box-crons-desk-reach.py` (run by
  `install-box-crons.tst.sh`) and `orc-shard-weights.txt` (not a test). The same for row 02
  -> `test-y16-git-pager-off.sh` and `csi-spl-doc/doc/md/test-round-2/seat-claude.md` (a
  doc). Nothing missing from either column.

## 7. R3: lane map

- `lane-map.sh --check <the plan's 24 paths of 2.2> --agent c-157` at
  2026-11-26T15:50:36Z -> **exit 4**: `WARN no live lane lists <paths>`, 0 owned, 7
  `unknown:` lanes, all on the planner's box: `a-048` (bug round 51 planner), `a-099` (rotate),
  `a-121` (this planner), `a-126` (SPL-6603 composer agy reviewer), `c-076` (s153 Q3
  queue route holds), `c-119` (WUI sorted window snackbar), `c-123` (s186 M7 e2e
  multicast).
- Their pushed branches: `git ls-remote origin | grep -E 'a-048|...|bug-round-51'` -> 4
  heads (`review/c002-bug-round-51-{claude-seat,planner}`,
  `review/c002-wui-sorted-window-line-snackbar`, `review/s153-q3`). Over the 60 newest
  `origin/review/*` heads, `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 9 row files>`
  -> no head touches a row file.
- The plan's 19 `unknown:` lanes were read from the planner's box and are on the seat's box; I read from the seat's box and
  see the planner's box's. Both reads show 0 owned. The holder re-reads at placement (R3).

## 8. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md`: **NOT RUN**: not on the seat's box
  (`ls` -> `No such file or directory`); it is on the planner's box. Plan 1.2 (c) and
  section 7's candidates row are taken unverified.
- r07 section 7 (`git show e5af88d93:csi-spl-doc/doc/md/refactor-round-07-plan.md`,
  lines 758-769) against r08 section 7 (plan lines 898-908): r07's linked-worktree row is
  served by r08-01 and its remainder accounted (line 904); brc/oq (905); non-matching
  cron installers, probes, `gcp-*alert*`, `spl-msg-{dedup,wipe}`, `spl-channel-agent-*`
  (906); the candidates items (907). **Not accounted**: W2.
- spec 011: `git log 34d67a385..e5af88d93 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> `0`, as plan 1.2 (d).

## 9. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` with this worktree detached at
`fa70bea3b`: rc 0, `INFO distribution-hygiene: clean over the tracked tree`, 0
`not ok`/`FAIL` lines.

## 10. Defects

- **W1 (safety, row 01's test block, plan lines 336-350).** The identity `DRY_RUN=0` check
  (plan line 336) sets no `SPOOL_TMUX_SOCKET`, and the `ai_tmux() { return 0; }` stubs
  (lines 342, 347) never take effect: `do_spl_agent_identity_install` sources
  `agent-identity.inc.sh` (which defines `ai_tmux`, `:50` on `e5af88d93`) inside the
  function, after the stub. On a correct head the check FATALs before any tmux call. On
  the regression it exists to catch, it does not: under `m1c`, with a logging tmux shim
  and `TMUX=/tmp/FAKE-LIVE-SERVER.sock,123,0`, the shim log shows
  `tmux -u -S /tmp/FAKE-LIVE-SERVER.sock set-hook -g after-new-window[1] run-shell -b "bash /tmp/tmp.*/wt-linked/.../agent-identity-reconcile.sh --apply --delay 8 ..."`
  and the same for `pane-exited[1]` (n=1). In an agent pane (`TMUX` set), or with the
  default socket `/tmp/tmux-<uid>/default`, that is the caller's live tmux server: a
  control must never touch live state.
  - Fold: add `SPOOL_TMUX_SOCKET="$T/no.sock"` to line 336's `env`. Drop the dead
    `ai_tmux() { return 0; }` from lines 342 and 347, or put a fake `tmux` first on that
    check's `PATH` if a stub is wanted.
  - Plan 1.5 records `m1c` as run (n=1, 15:08Z-15:34Z, on the planner's box). If that run
    had `TMUX` set and the server's `after-new-window[1]` / `pane-exited[1]` were empty,
    it set those hooks on that server, pointing at a removed scratch path. I did not check
    that server (not mine); the planner can read it with
    `tmux show-hooks -g after-new-window` / `pane-exited` (index 1 only).
- **W2 (inputs, section 7, plan lines 898-908).** r07 section 7's last row (line 769 of
  that plan at `e5af88d93`) names refactor-shaped inputs that r08 neither serves nor
  lists: the `spl-{accepted-close,desk-poll-ack,review-go}` action bodies,
  `spl-hub-box-band.func.sh`, `spl-wui-perf-report.func.sh`, `csi-spl-utl/**`,
  `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh` and the Go / WUI duplicates. r08 line 906
  keeps only `spl-channel-agent-*` of that row. Fold: one section 7 row carrying them
  with r07's reason, or each with its own.
- **W3 (measurement, plan 1.5 table, lines 586-587).** `test-y15-vibe-output-cap.sh` and
  `test-y12-vibe-push-guard.sh` are recorded `0 / 11 / 0` on base; on `e5af88d93` they
  print `y15-vibe-output-cap: 16/16 passed, 0 skipped` and
  `y12-vibe-push-guard: 35/35 passed, 0 skipped` (n=1 each, base, head1 and head2 alike).
  I believe, unchecked, that neither suite reads the box. The `=` verdict holds, but the base counts are not what
  the suites print. Fold: `0 / 16 / 0` and `0 / 35 / 0`, or say how they were counted.

## 11. Notes

- **N1 (plan line 902).** Section 7's command `git grep -n "s/\^SPOOL_AGENT_USER=//p" e5af88d93 -- csi-spl-orc/src/bash/run/`
  prints 12 lines in 12 files, not "5 matching `spool-install` actions": it also matches
  `repair-worktree-acl`, `spl-box-state-backup`, `spl-cost-labels-translate-install-cron`,
  `spl-cost-tokens-read`, `spl-lane-mix`, `spl-role-id-switch` and
  `tmp-scratch-sweep-install-cron`. The 5 are right, but the command does not show them
  alone; add the filter.
- **N2 (row 02, plan lines 379-381 and 431).** `_spl_user_step_install`'s 7th `repo` arg
  has no wave-1 caller; it is there for r09. It is behaviour-neutral when empty and the
  `repo` check covers it. Acceptable, but r09 should take it as is or drop it.
- **N3 (row 01).** The `|| true` the helper adds is not observable (5, `run.sh:7,169-172`);
  recorded so the R7 seat need not re-derive it.
- **N4 (plan 1.5 line 596).** `gcloud-account-pinned.tst.sh` reads `0/48/0` on the seat's box and
  `0/45/0` in the plan, equal on base and the heads on each box. I believe, unchecked,
  that the count depends on the box's keys and cnf.
- **N5 (wording).** Plan line 55 and section 3 (line 794) say "24-line copies", 1.4 (line
  363) "~22-line loop"; the replaced ranges are 28 lines each (`:16-43`, `:17-44`,
  `:18-45`). Cosmetic.
- **N6 (R3).** None of the 7 `unknown:` lanes of the planner's box is in the plan's list (they are read
  from the other box); none has a pushed head touching a row file.

## 12. v1.0: signed

**PASS on v1.0 `6c477fd56cac6c501ce5a65528031bf9d3f05a56`.** W1-W3 are folded.

- `git ls-remote origin refs/heads/review/c002-refactor-round-08-planner` ->
  `6c477fd56cac6c501ce5a65528031bf9d3f05a56`;
  `git merge-base --is-ancestor fa70bea3b 6c477fd56` -> yes (fast-forward);
  `git diff --stat fa70bea3b 6c477fd56` -> the plan file only, 76 insertions, 21 deletions.
- The bash blocks of v0.1 and v1.0, diffed line by line: only block 7 (section 9) changed,
  in 3 lines. The identity `DRY_RUN=0` check gains `SPOOL_TMUX_SOCKET="$T/no.sock"`, and
  the identity dry=1 and uninstall checks drop `ai_tmux() { return 0; }`.
- **W1:** head1 rebuilt from v1.0's blocks on `e5af88d93`. The 4 code files have the
  same sha256s as v0.1 (`35815c400147`, `8e966e56793f`, `0d2593700f57`, `0912482b3903`).
  `cron-tagged-line.tst.sh` is `c56e361e4bb2`, 247 lines, as v1.0 line 942 says. Each
  run had a logging tmux shim first on `PATH` and
  `TMUX=/tmp/FAKE-LIVE-SERVER.sock,123,0`, n=1:
  - `rc1`: rc 1, 40 / 6, the same 6 FAILs as v0.1.
  - head1: rc 0, 46 / 0, `ALL PASS`.
  - `m1a`: rc 1, 44 real / 2 fail.
  - `m1b`: rc 1, 43 / 3.
  - `m1c`: rc 1, 43 real / 3 fail.
  - The shim recorded 24 calls, 0 of them on `FAKE-LIVE-SERVER.sock`. Under `m1c`, the
    two `set-hook -g ...[1]` calls now go to `-S <scratch>/no.sock`.
- **W2:** v1.0 section 7 names `accepted-close`, `desk-poll-ack`, `spl-hub-box-band`,
  `spl-wui-perf-report`, `csi-spl-utl/`, `sec-*`, `*-cron.sh` and the Go/WUI duplicates
  (one hit each in `sed -n '/^## 7/,/^## 8/p'`).
- **W3:** v1.0 lines 590-591 give `0 / 16 / 0` and `0 / 35 / 0`.
- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` with this worktree detached at
  `6c477fd56`: rc 0, clean.
- Not re-run for v1.0: row 02 and the 24-suite column. Row 02's blocks are byte-identical
  to v0.1 (block diff above), so the v0.1 results in sections 3 and 4 still apply.
