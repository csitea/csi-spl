# Refactor round 07 plan: claude panel seat (c-073)

Seat: **c-073** (claude), the cross-vendor panel seat of rulebook 3.2 (editor a-071, agy).
Issue SPL-6579, epic SPL-2402, spec `csi-spl-doc/specs/011-spool-project-refactor`.

## 0. Verdict

**FAIL on v0.1 `21c3e6ce33a51d9a803543c87c6bbb2a9bc0b748`**, one defect (W1, a
one-line fold). Every other check passes: the slug is free, the sites match on
base and on master, all 9 head sha256s match, both red controls go RED for the
stated reason and GREEN on the heads, the mutations are caught, R1 and R3 hold,
the inputs are accounted for and the hygiene is clean. I sign v1.0 once W1 is
folded.

- Plan read: `git show 21c3e6ce3:csi-spl-doc/doc/md/refactor-round-07-plan.md`
  (778 lines). `git ls-remote origin refs/heads/review/c002-refactor-round-07-planner`
  -> `21c3e6ce33a51d9a803543c87c6bbb2a9bc0b748`. `git log --oneline origin/master..21c3e6ce3`
  -> one commit, `21c3e6ce3 docs(r07-plan, SPL-6579): refactor round 07 plan v0.1 (2 rows)`.
- Measurement base `13293131f`; `origin/master` at review time `444c80979`
  (fetched 2026-11-26T13:21:31Z).
- Heads, controls and mutations were built in detached scratch worktrees of
  `13293131f` (removed after the review). Each was applied from the plan's
  verbatim blocks: 1.3 / 1.4 for the caller lines, plan lines 250-292 for
  section 8 and 377-415 for section 9.
- Every suite ran with `SPOOL_TEST=1` and `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID`
  unset, stdin from `/dev/null`, as the push user, n=1.

## 1. Slug and window (rulebook 5.3)

- `W=2026-11-26T09:49:33+02:00`, as recorded in plan 1.1.
- `git log origin/master --since="$W" --oneline -E --grep='\(r07-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r07-[0-9]{2}|refactor-round-07'` -> one line,
  `21c3e6ce3... refs/heads/review/c002-refactor-round-07-planner` (the planner's
  branch; my seat branch did not exist yet). Nothing else.
- `git ls-remote origin 'refs/heads/review/r07-*' 'refs/heads/wip/*r07*' 'refs/heads/*-r07-*'`
  -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r07-[0-9]{2}|refactor-round-07'` ->
  `c002-refactor-round-07-claude-panel-seat.md` and
  `hand-sat-c002-refactor-round-07-planner.md` only (this brief and the planner's).

## 2. Sites on base and on master

- Each cited range, read with `git show 13293131f:<file> | sed -n <N>p`, holds
  exactly the 6-line guard the plan describes. Each `local` line holds `gd cd`:
  - `box-disk-sweep-install-cron.func.sh:30,41-46`
  - `prune-docker-images-install-cron.func.sh:30,42-47`
  - `tmp-scratch-sweep-install-cron.func.sh:28,41-46`
  - `spl-agent-id-reap-install-cron.func.sh:27,33-38`
  - `spl-od-pool-supervise-install-cron.func.sh:29,33-38`
  - `spl-shadow-feed-install-cron.func.sh:24,33-38`
  - `spl-cost-labels-translate-install-cron.func.sh:42,76-81`, inside
    `if [[ "$act" == install ]]; then` at `:75`
- The other cited lines match too:
  - `cron-tagged-line.tst.sh:122` is blank and `:123` is `[ "$fails" -eq 0 ] && echo "ALL PASS" ...` (123 lines).
  - `spl-cost-labels-translate-install-cron.tst.sh:159` is blank and `:160` is
    `echo "spl-cost-labels-translate-install-cron: ${fails} failure(s)"` (161 lines).
  - `cron-tagged-line.func.sh:45` is `cron_refuse_linked_worktree() {`, `:48-49`
    carry `|| true` and `:56` is `}`.
  - `run-log-sweep.tst.sh:89`, `satellite-ansible.tst.sh:458`,
    `spl-box-deploy.tst.sh:60`, `install-box-crons.func.sh:69` (`"the paths below"`)
    and `spl-private-overlay-install-cron.func.sh:70`.
- `gd`/`cd` are used only by the guard. `grep -cE '\$\{?(gd|cd)\b|\b(gd|cd)='`
  -> 3 in each of the 7 files: the two assignments and the `if`.
- Drift, over the 9 row files plus `cron-tagged-line.func.sh`:
  - `git diff --name-only 13293131f origin/master -- <the 10 paths> | wc -l` -> `0`.
  - The same against `21c3e6ce3^` -> `0`.
- `git grep -n "is a linked worktree: install from the main checkout" 13293131f -- csi-spl-orc/src/bash/run/ | cut -d: -f2 | sort -u | wc -l`
  -> `9` (plan 1.2 (a): 9).

## 3. Red controls

Neither test file is new: each control is the head's test file run on base.
`sha256sum` (12 chars) of every head file, built from the plan's blocks:

| file | measured | plan |
|---|---|---|
| `box-disk-sweep-install-cron.func.sh` | `bad65d0ead26` | `bad65d0ead26` |
| `prune-docker-images-install-cron.func.sh` | `e606ca00b683` | `e606ca00b683` |
| `tmp-scratch-sweep-install-cron.func.sh` | `21909802651d` | `21909802651d` |
| `spl-agent-id-reap-install-cron.func.sh` | `ab9a944d995e` | `ab9a944d995e` |
| `cron-tagged-line.tst.sh` | `7fb8a154c186` | `7fb8a154c186` |
| `spl-od-pool-supervise-install-cron.func.sh` | `1e79cd6fde5e` | `1e79cd6fde5e` |
| `spl-shadow-feed-install-cron.func.sh` | `3eeef539533d` | `3eeef539533d` |
| `spl-cost-labels-translate-install-cron.func.sh` | `c9fb79e3b2fb` | `c9fb79e3b2fb` |
| `spl-cost-labels-translate-install-cron.tst.sh` | `6b7526acd24c` | `6b7526acd24c` |

`git diff --numstat` of head1 is `+2 -7` on each installer and `+44 -0` on the
test file; head2 is `+2 -7` on each installer and `+40 -0` on the test file.
Both equal plan section 6.

| run | rc | PASS | FAIL | last line |
|---|---|---|---|---|
| `rc1`: head1's `cron-tagged-line.tst.sh` on base | 1 | 27 | 4 | `4 FAILED` |
| head1 `cron-tagged-line.tst.sh` | 0 | 31 | 0 | `ALL PASS` |
| `rc2`: head2's `spl-cost-labels-translate-install-cron.tst.sh` on base | 1 | 26 | 3 | `spl-cost-labels-translate-install-cron: 3 failure(s)` |
| head2 `spl-cost-labels-translate-install-cron.tst.sh` | 0 | 29 | 0 | `spl-cost-labels-translate-install-cron: 0 failure(s)` |

- **The reason is the plan's.** Each `FAIL` is a one-copy check that names the
  inline `cd="$(git ... --git-common-dir ...)"` line:
  - `rc1`: `box-disk-sweep :42`, `prune-docker-images :43`,
    `tmp-scratch-sweep :42`, `spl-agent-id-reap :34`
  - `rc2`: `spl-od-pool-supervise :34`, `spl-shadow-feed :34`,
    `spl-cost-labels-translate :77`

  No environment failure. The standalone installer checks (6 in `rc1`, 5 in
  `rc2`) pass on base, as plan 1.5 says.
- **Mutations** (my n=1, 2 of the plan's 7):
  - `m1a`, `"1"` for `"${BOX_SWEEP_ALLOW_WORKTREE:-0}"`: rc 1, `FAIL: 8. box-disk-sweep dry=0`
    and `FAIL: 8. box-disk-sweep dry=1`, last line `2 FAILED`.
  - `m2c`, `"1"` for `"${COST_LABELS_TRANSLATE_ALLOW_WORKTREE:-0}"`: rc 1, `FAIL: 6. worktree`,
    `FAIL: 9. cost-labels dry=0` and `FAIL: 9. cost-labels dry=1`.

  Both equal plan 1.5. `m1b`-`m1d`, `m2a` and `m2b` were NOT RUN by me.
- **No live state.**
  - Both test files take `$T` from `test-lib.inc.sh:43`
    (`T=$(mktemp -d); trap 'rm -rf "$T"' EXIT`).
  - Every installer the new sections call reads its crontab override:
    `grep -c` -> `BOX_SWEEP_CRONTAB` 1, `PRUNE_CRONTAB` 1, `SCRATCH_CRONTAB` 2,
    `REAP_CRONTAB` 1, `OD_CRONTAB` 2, `SHADOW_FEED_CRONTAB` 1,
    `COST_LABELS_TRANSLATE_CRONTAB` 2. Each is set to `$T/fake-crontab`.
  - `SPOOL_ROOT` is set to a `$T` dir and `COST_LABELS_TRANSLATE_SUDO=false`.
  - `crontab -l | sha256sum` of the push user is `6a5eae9ba0b9` before and after
    the mutation runs. Those are the runs where the guard is off and the
    installer goes on to write.

## 4. Equivalence

For each of the 7 sites, the inline guard and `cron_refuse_linked_worktree`
(`cron-tagged-line.func.sh:45-56`) compute the same thing:
- the same `git rev-parse --path-format=absolute --git-dir` /
  `--git-common-dir` on `$PROJ_PATH`;
- the same `-n "$gd" && "$gd" != "$cd"` test;
- the same allow knob (`"${X:-0}" != 1` against `[[ "$allow" == 1 ]] && return 0`);
- the same `FATAL` through `do_log` with return 1 on `dry=0`;
- the same `WARN` through `echo` with return 0 on `dry=1`.

The call is guarded on `act == install`, so `remove` still skips it. The two
differences cannot be seen by a caller:
- The helper adds `|| true` to the two `$(git ...)` assignments that 6 of the 7
  sites lack (`prune-docker-images` already has it). It would only matter under
  `set -e`. `./run` sets `set -E` (`csi-spl-orc/run:7`) and `set -u -o pipefail`
  (`:843`). The direct caller `spl-box-deploy.func.sh:336`
  (`agent-id-reap) REAP_CRON_ACTION="$act" do_spl_agent_id_reap_install_cron`)
  has no `set -e` (`git grep -nE '^\s*set -[a-z]*e'` -> 0).
- `gd`/`cd` are now computed only on `install`. They used to be computed for
  every `act`. They are read-only `git rev-parse` calls.

No exit code, message, path or default changes. The helper is already loaded
wherever these run: each file already calls `cron_drop_tagged_line` from the
same lib (`grep -c` -> 1, 1, 1, 1, 2, 1, 2).

Would the controls catch a difference? The one-copy checks catch a guard left
inline. The standalone checks pin the exact `FATAL`/`WARN` line (`grep -qxF`)
and the rc, so a dropped or always-allow guard is caught (m1a, m2c above). The
`remove` bypass is pinned for `box-disk-sweep` only (see N5).

Column suites I ran on head1 (beyond the controls):
- `spl-box-deploy.tst.sh`: rc 0, 36 / 0, `ALL PASS`; the same on base.
- `iac:satellite-ansible.tst.sh`: rc 0, 96 / 0,
  `PASS: all satellite-ansible.tst.sh assertions`. Its case 17 greps
  `tag="csi-spl:tmp-scratch-sweep"` on the edited `:28` line and still passes.

The rest of the column was NOT RUN by me. It is the row lanes' C4 duty.

## 5. Rows: R2, vendor, kind, batch, R1

- Each row has a control that fails today and passes after (3 above), a test
  list, vendor claude, kind `simple_coding` and batch 1.
- No mistral row. The R7 seat is agy, with the claude waiver backup only under
  ruling `dc84300a`; never mistral (plan 4).
- R1: row 01 edits `box-disk-sweep-install-cron.func.sh`,
  `prune-docker-images-install-cron.func.sh`, `tmp-scratch-sweep-install-cron.func.sh`,
  `spl-agent-id-reap-install-cron.func.sh` and `cron-tagged-line.tst.sh`. Row 02
  edits `spl-od-pool-supervise-install-cron.func.sh`, `spl-shadow-feed-install-cron.func.sh`,
  `spl-cost-labels-translate-install-cron.func.sh` and
  `spl-cost-labels-translate-install-cron.tst.sh`. They share no file. Each has
  at most 5 sites (3.1).
- R2 test column: `git grep -lE '<the 14 basenames and do_ functions of both rows>' 13293131f -- '*tst.sh' '*/tests/*' 'csi-spl-api/'`
  -> 10 files: `satellite-ansible`, `agent-id-reap`, `box-disk-sweep`,
  `od-pool-replace`, `prune-docker-images`, `run-log-sweep`, **`spl-box-deploy`**,
  `spl-cost-labels-translate-install-cron`, `spl-shadow-feed`, `tmp-scratch-sweep`.
  All are in a row column except `spl-box-deploy.tst.sh`: W1.

## 6. R3

- `lane-map.sh --check <the 9 row paths> --agent c-073` at 13:27:08Z -> **exit 4**.
  It reports no live lane listing any path and 20 `unknown:` lanes that record
  no files, all on the other box. 16 of them are `*-rotate` seats; the others
  are `c-065` WUI shift-L, `c-068` WUI loops dialog, `c-904` s187 S1, `c-907`
  s196 T1 topic-tags store and `c-957` a spec seat. None is in an
  orc cron-installer lane. 0 owned.
- Remote heads committed in the last 24 h (93 scanned) whose diff from
  `merge-base origin/master <b>` touches a row file -> only `origin/review/r06-02`
  (`cron-tagged-line.tst.sh`). Its tip `4047a14a0` is the pre-rebase review sha
  of r06-02, landed as `984b6d70d`. 0 unlanded.
- The plan's live and queued lanes (2.2: the b51 rows, the spawn queue at
  12:51:02Z, 0 unlanded r06 rows): no row file is touched by them, as far as
  the lane map and the branch scan above show.

## 7. Inputs accounted for

- **r06 section 7** (`refactor-round-06-plan.md:944-958` on origin/master):
  - Row 1, the 9 guard callers, is taken as r07 rows 01 and 02 (7 files). The
    other 2 (`spl-private-overlay`, `install-box-crons`) are in r07 section 7.
  - The `setup-gh-runner-cpu-budget-cron.tst.sh` row landed in `86ac09501`
    (`git merge-base --is-ancestor 86ac09501 origin/master` -> true).
  - Every other row is carried into r07 section 7.
- **Candidates file** (151 lines, mtime 13:03:40+02:00):
  - Line 76: served. `spl-desk-reply.sh` usage lists the new kinds.
  - Line 104: served. `git grep -c 'agy has the final word\|waits for an agy review'`
    on `spl-lane-mix.func.sh` -> 0.
  - Line 133: served. `git grep -c send_to_peers_on spl-unanswered-sweep.func.sh` -> 0.
  - Lines 113, 115, 125, 147-148 and 150-151 are named in r07 section 7.
  - Lines 2 (b12-02 terraform N1-N4, bug/test-shaped), 74 (test-shaped) and 145
    (`review-go` `Apply`, bug-shaped) fall under the plan's catch-all.

  No refactor-shaped input is neither served nor accounted for.
- **No behaviour change**: neither row changes an exit code, a message, a path
  or a default (4).

## 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> rc 0,
`INFO distribution-hygiene: clean over the tracked tree`.

## 9. Defects

- **W1 (R2, plan lines 517-518 and 533).** Row 01's test column leaves out
  `orc:src/bash/tests/spl-box-deploy.tst.sh`. R2 (rulebook 2.2) puts in the
  column "every test file that names ... a function it defines", and
  `spl-box-deploy.tst.sh:60` names `do_spl_agent_id_reap_install_cron`. The
  plan's reason (a stub, the real file is not sourced) is correct, but the
  rulebook wins over the plan (plan line 23), and a C4 reviewer reading R2 will
  ask for it.

  Fix: add `orc:.../spl-box-deploy.tst.sh` to row 01's Tests in section 2 and
  to 1.5's table. I measured it on base and on head1: rc 0, 36 / 0 on both.

## 10. Notes

- **N1 (plan line 753).** Section 7 says the guard grep is "25 lines across 13
  files". `git grep -n "is a linked worktree:" 13293131f -- csi-spl-orc/src/bash/run/ | wc -l`
  -> `24` lines; `cut -d: -f2 | sort -u | wc -l` -> `13` files. Fix the count
  when folding W1.
- **N2 (plan line 591).** The `unknown:` lane set has moved since 12:53Z. My
  13:27Z read has `c-079` and not `c-935`, still 20 and still 0 owned. This is
  live state; the holder re-reads it at placement (R3).
- **N3 (plan lines 80-87).** The newest `docs(r06-plan` commit is now
  `444c80979` (2026-11-26T15:06:12+02:00, r06's close record), not
  `c28e628f2`. The plan already says `W` stays at the recorded
  `2026-11-26T09:49:33+02:00`. Row briefs, R4, R6 and `PRUNE_SINCE` must take
  that recorded value, not re-derive it.
- **N4 (plan lines 177-181).** The plan's `|| true` claim holds. No caller runs
  under `set -e` (see 4).
- **N5 (plan lines 262-292, 376-415).** The `remove` bypass is pinned by a test
  only for `box-disk-sweep` (section 8). For the other 6 sites it rests on the
  `[[ "$act" == install ]] &&` prefix, and on the enclosing `if` at `:75` for
  `spl-cost-labels-translate`. That is visible in the verbatim lines, so it
  does not block. An R7 seat reads it in the diff.
- **N6 (plan lines 534 and 522).** Row 02's column runs
  `cron-tagged-line.tst.sh`, which row 01 edits. R1 counts edited files only,
  so Batch 1 holds. Whichever row lands second re-runs that suite after its
  rebase (R2).

## 11. Signatures

- v0.1 `21c3e6ce33a51d9a803543c87c6bbb2a9bc0b748`: **FAIL** (W1). c-073, claude.
- v1.0 `bbbbe0cfca4c076798e322f8f2b1762bbdb4faaa`: **PASS**. c-073, claude.
  - `git ls-remote origin refs/heads/review/c002-refactor-round-07-planner` ->
    `bbbbe0cfc...`.
  - `git merge-base --is-ancestor 21c3e6ce3 bbbbe0cfc` -> true (fast-forward);
    `git log 21c3e6ce3..bbbbe0cfc` -> one commit, plan file only (+54 -16).
  - The fenced `bash` blocks are byte-identical to v0.1. The awk extraction of
    both versions -> `diff` empty, 89 lines. So the heads, red controls and
    mutations of sections 3 and 4 above stand unchanged.
  - W1 is folded: row 01's section 2 cell names `spl-box-deploy.tst.sh`, and it
    is in the 1.5 table and the R2 text.
  - N1 is folded: plan line 762 says `24 lines across 13 files`.
  - N2-N6 are recorded in section 8.
  - Drift of the 9 row files, `cron-tagged-line.func.sh` and
    `spl-box-deploy.tst.sh` from `13293131f` to `origin/master` `49f7f487a` -> 0.
