# Refactor round 06: claude panel seat verdict

Seat: c-917 (claude, cross-vendor panel seat, rulebook 3.2). Issue: SPL-6566.
Plan reviewed: `csi-spl-doc/doc/md/refactor-round-06-plan.md` **v0.1**, commit
**`9c39b5d2f76b8d19b60024754bcc59908c90b5e4`** on `review/c002-refactor-round-06-planner`
(`git ls-remote origin refs/heads/review/c002-refactor-round-06-planner` -> that sha).
Plan base: `f9521a941`. Window: `W=2026-11-26T07:34:07+02:00` (`2ccf23c21`).
Every read is on `f9521a941` with `git show` / `git grep`. Every run is in a detached
scratch worktree of `f9521a941` (or of `9c39b5d2f` for check 8), n=1, between
2026-11-26T06:55Z and 07:40Z, as the push user, `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and
`SPOOL_AGENT_ID` unset, stdin `/dev/null`. Pass lines are counted with
`grep -ciE '^ *(ok|pass)'` and fail lines with `grep -ciE '^ *(not ok|fail)'` (the plan's counters).

## 0. Verdict

**PASS** on `9c39b5d2f`, with one documentation defect (W1) that the editor fixes in
v1.0. W1 does not change a row, a hunk, a control or a sha256.

| item | verdict |
|---|---|
| r06-01 (`_spl_run_cron_apply` mode=r, wave 2) | agree: sites, hunks, red control, guard controls and mutations all reproduce; zero behaviour change |
| r06-02 (`cron_refuse_linked_worktree`, wave 1) | agree: sites, hunks, red control and mutations reproduce; zero behaviour change. W1: the test file's line count is wrong in two places |
| batches, R1, R3, section 7 | agree |

## 1. How I rebuilt the heads

I extracted the 10 `bash` blocks of plan sections 1.3 and 1.4 from `9c39b5d2f` with a
script and applied each one at the lines the plan names (replacing the cited ranges,
removing `current` / `gd cd` from the cited `local` lines, and inserting the test
sections before `:482` / `:70`). On the results:

- `sha256sum` (first 12 characters): `spl-spawn-fill-install-cron.func.sh` `90f45f67f8f1`,
  `spl-spawn-place-install-cron.func.sh` `d80ebc168d97`,
  `spl-review-go-install-cron.func.sh` `ed420ce5cd50`,
  `spl-topic-archive-suggest-install-cron.func.sh` `c8474cb42cb1`,
  `spl-spawn-fill.tst.sh` `32326c024963`; `cron-tagged-line.func.sh` `393ecc8a586d`,
  `spl-box-update-install-cron.func.sh` `072806852e51`,
  `spl-cost-rollup-install-cron.func.sh` `569b0052759c`,
  `git-prune-merged-install-cron.func.sh` `726a96dfe9ab`, `cron-tagged-line.tst.sh`
  `57bffcc274b4`. **All 10 equal the plan's.**
- `git diff --numstat` on head1: `+7 -34` (review-go), `+7 -5` (spawn-fill), `+7 -34`
  (spawn-place), `+7 -34` (topic-archive-suggest), `+92 -0` (`spl-spawn-fill.tst.sh`):
  equal to the plan. On head2: `+16 -0` (`cron-tagged-line.func.sh`), `+2 -7` three
  times, and **`+53 -0`** for `cron-tagged-line.tst.sh` (`wc -l` -> 123). See W1.

## 2. The checks

### 2.1 Slug and window (check 1)

- `git log origin/master --since="$W" --oneline -E --grep='\(r06-' | wc -l` -> `0`.
- `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r05-plan'` ->
  `2ccf23c211eaaea2032ca91c51a3f946ae0b076d 2026-11-26T07:34:07+02:00 docs(r05-plan, SPL-6553): refactor round 05 closed: ...`
  (the plan's W).
- `git ls-remote origin | grep -E 'r06-[0-9]{2}|refactor-round-06'` -> one line:
  `9c39b5d2f76b8d19b60024754bcc59908c90b5e4 refs/heads/review/c002-refactor-round-06-planner`
  (this seat's branch did not exist yet).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r06-[0-9]{2}|refactor-round-06'` on this
  seat's box -> nothing, rc 1. The briefs live on the holder's box. The holder (c-002,
  msg `5f31c68a`) relayed that listing: exactly the planner's and this seat's brief.
  **Relayed, not run by me.**

### 2.2 Sites (check 2)

- Each cited line read with `git show f9521a941:<file> | cat -n`. All match:
  `spl-spawn-fill-install-cron.func.sh:53-89` (comment + `_spl_run_cron_apply`),
  `spl-spawn-place-install-cron.func.sh:29` (`local ... current ...`) and `:46-79`
  (`current=` to the end of `spl_spawn_place_cron_check`),
  `spl-review-go-install-cron.func.sh:30` and `:46-79` (same shape),
  `spl-topic-archive-suggest-install-cron.func.sh:29` and `:44-77` (same shape, `-r`),
  `spl-spawn-fill.tst.sh:482` (`echo`, `:481` blank), `cron-tagged-line.func.sh:40`
  (last line, `}`), `spl-box-update-install-cron.func.sh:28` (`... want gd cd`) and
  `:47-52` (the guard), `spl-cost-rollup-install-cron.func.sh:36` and `:57-62`,
  `git-prune-merged-install-cron.func.sh:23` and `:33-38`, `cron-tagged-line.tst.sh:70`
  (the summary line, `:69` blank).
- `git diff --name-only f9521a941 origin/master -- <the 10 row files>` with
  `origin/master` = `a248ed371` -> empty. **No site drifted.**
- `git grep -n "is a linked worktree: install from the main checkout" f9521a941 -- csi-spl-orc/src/bash/run/ | wc -l` -> `12`.

### 2.3 Red controls (check 3)

The control test files: `sha256sum` -> `32326c024963de0b587e3f9b82dd1d7c4ec87169ccee09a7f76bdc690de203b0`
(head1 `spl-spawn-fill.tst.sh`) and `57bffcc274b4fd2a060181c4f063a7645fbb7175125985e753baf22671d2d5cd`
(head2 `cron-tagged-line.tst.sh`). Each was copied onto an unmodified base worktree.

| run | rc | pass / fail lines | last line | plan |
|---|---|---|---|---|
| rc1: head1 test on base | 1 | 61 / 7 | `FAIL: 4` | 61 / 7, same |
| rc2: head2 test on base | 1 | 12 / 9 | `9 FAILED` | 12 / 9, same |
| base `spl-spawn-fill.tst.sh` | 0 | 55 / 0 | `PASS: all` | same |
| head1 `spl-spawn-fill.tst.sh` | 0 | 65 / 0 | `PASS: all` | same |
| base `cron-tagged-line.tst.sh` | 0 | 9 / 0 | `ALL PASS` | same |
| head2 `cron-tagged-line.tst.sh` | 0 | 21 / 0 | `ALL PASS` | same |

Why they fail (the `FAIL:` lines, quoted):
- rc1: `12. mode=r lifecycle: FATAL .../no-such-script is missing or not executable in ...`
  (base ignores the 11th argument, so mode `r` falls back to `-x`), and three `12. one copy`
  lines naming `48: check) spl_spawn_place_cron_check ...`, `48: spl_review_go_cron_check ...`,
  `46: spl_archive_suggest_cron_check ...`. All 6 standalone `12.` checks PASS on base: the
  wave-2 installers' output is the same before and after.
- rc2: five `7. ... (127: _: line 3: cron_refuse_linked_worktree: command not found)`,
  `7. host one copy`, and three `7. one copy` lines naming `48:`, `58:`, `34:` (the
  `--git-common-dir` lines). All 3 standalone installer `7.` checks PASS on base.

These are the reasons the plan gives, not an environment failure. **Live state:** both
sections write only under the test's `$T` (fake `crontab` on `PATH` / `FAKE_CRONTAB`,
`*_CRONTAB=$T/fake-crontab`, a throwaway `git init` + `git worktree add` under `$T`); no
live crontab, spool or checkout is touched.

Mutation and guard controls I re-ran (a sample: 4 of the plan's 10), each in its own worktree:

| control | defect | suite | rc | pass / fail lines | plan |
|---|---|---|---|---|---|
| m1c | topic-archive-suggest drops the `r` argument | `spl-spawn-fill.tst.sh` | 1 | 63 / 2 (`12. as ok (rc=1): FATAL ... is missing or not executable`) | same |
| gc1c | `declare -F _spl_run_cron_apply` line deleted in topic-archive-suggest | `spl-spawn-fill.tst.sh` | 1 | 62 / 3 (`12. lazy as` and `12. as ok`, rc=127 `line 45: _spl_run_cron_apply: command not found`) | same |
| m2a | helper returns 0 on `dry=0` | `cron-tagged-line.tst.sh` | 1 | 20 / 3 (`7. linked dry=0`, `7. git-prune dry=0`, `7. cost-rollup dry=0`) | same |
| m2d | git-prune passes `1` as allow | `cron-tagged-line.tst.sh` | 1 | 20 / 2 (`7. git-prune dry=0`, `7. git-prune dry=1`) | same |

Not re-run by me: gc1a, gc1b, m1a, m1b, m2b, m2c.

### 2.4 Equivalence (check 4)

Read on `f9521a941` against the hunks of 1.3 and 1.4.

- **r06-01.** The `check`, `DRY_RUN=1`, `remove` and `install` branches of the three
  wave-2 installers and of `_spl_run_cron_apply` are the same statements in the same
  order. The only per-file differences go through arguments: `label`, `ok_msg` and
  `miss_why` (the three `FAIL ... NOT installed`, `OK ... out of the crontab` and
  `OK ... runs ...` texts are byte-equal), and mode `r` for topic-archive-suggest
  (`-r` with `FAIL $run is gone` / `FATAL $run is missing in $src`, which are its texts at
  `:74` and `:60`). Mode `x` is the default, so the four wave-1 callers are unchanged.
  The exit codes are the same: `check` returns the check's status in both versions. One
  difference that nobody can see: `$(id -un)` is now evaluated on every action, not
  only on `install` (the plan says so in 1.3). The lazy-source line is the same as in
  the four wave-1 callers already on trunk (`git grep -n _spl_run_cron_apply f9521a941`
  -> `spl-accepted-close-install-cron.func.sh:49`, `spl-desk-poll-ack-...:49`,
  `spl-security-round-...:52`). The controls catch a dropped `miss_why` (m1a/m1b in the
  plan), a dropped mode (m1c, re-run) and a dropped lazy-source (gc1a-c, gc1c re-run).
- **r06-02.** `cron_refuse_linked_worktree` gives the same results as the inline guard:
  allow=1 means no output and rc 0 (the inline code ran `git` and then skipped, with no
  output either). Not a linked worktree means rc 0 and no output. `dry=0` means the same
  `FATAL` text and rc 1, and `dry=1` the same `WARN` text and rc 0. Call sites stay
  where they were: box-update and cost-rollup inside `if [[ "$act" == install ]]`,
  after `spl_require_cloud_env` in box-update, and git-prune only on `install`. git-prune's
  `[[ "$act" == install ]] && { ... || return 1; }` is not the function's last
  statement, so a `remove` still goes on to `cron_drop_tagged_line`. The controls catch a
  wrong return (m2a, re-run) and a hard-coded allow (m2b-m2d, m2d re-run).
- No row changes an exit code, a message, a path, an env var or a default: both are
  refactor rows, not bug rows.

### 2.5 Row shape (check 5)

Both rows have a red control that fails today and passes after (R2), a test list,
vendor claude, kind `simple_coding` and batch 1. No mistral coding or testing row. The
R7 seat is agy, with the claude waiver as backup under ruling `dc84300a`, never
mistral. R1: row 01's 5 files and row 02's 5 files are disjoint (plan 2.1 compared with
the file lists of 1.3 / 1.4); each row has at most 5 files (rulebook 3.1).

The test column, base and head (each `rc / pass / fail`, the plan's counters):

| suite | base | head1 | head2 |
|---|---|---|---|
| `spl-security-round-queue.tst.sh` | 0/33/0 | 0/33/0 | - |
| `spl-desk-poll-ack.tst.sh` | 0/37/0 | 0/37/0 | - |
| `spl-accepted-close.tst.sh` | 0/32/0 | 0/32/0 | - |
| `spl-topic-archive-suggest.tst.sh` | 0/51/0 | 0/51/0 | - |
| `spl-review-go.tst.sh` | 0/210/0 | 0/210/0 | - |
| `spl-box-update-install-cron.tst.sh` | 0/12/0 | - | 0/12/0 |
| `spl-cost-rollup-install-cron.tst.sh` | 0/16/0 | - | 0/16/0 |
| `git-prune-merged-cron.tst.sh` | 0/15/0 | - | 0/15/0 |
| `od-pool-replace.tst.sh` | 0/9/0 | - | 0/9/0 |
| iac `no-box-path-source`, `action-header-tags`, `param-required`, `run-lazy-loader`, `bash-cleancode` | - | 0/10/0, 0/6/0, 0/17/0, 0/30/0, 0/15/0 | same as head1 |
| orc `run-eager-files`, `no-literal-paths`, `func-name-unique` | - | 0/14/0, 0/15/0, 0/2/0 | same as head1 |
| `shellcheck -S warning -x` (0.10.0) on the 5 edited files | - | rc 0, 0 lines | rc 0, 0 lines |

Not run by me: `spl-spawn-queue.tst.sh`, `gcloud-account-pinned.tst.sh`,
`do_sec_shellcheck`, `do_check_pre_push` (the rows run these at landing).

### 2.6 R3, off every lane (check 6)

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 10 row paths> --agent c-917`
  at 2026-11-26T07:04:54Z -> **exit 4**, no owner. The 5 `unknown:` lanes, all on the
  holder's box: `a-927` (b50 planner), `a-942` (this planner), `c-936` (s186 M2 hub send
  checks), `c-946` (s186 M11 WUI multicast), `c-948` (s187 S2). None of their scopes is a
  crontab installer.
- Every `origin` branch with a commit in the last 24 h (`git for-each-ref`, 20 refs), then
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 10 files>` -> no
  hits. `git log origin/master --since='24 hours ago' -- <the 10 files>` -> only
  `62c5bea32` (r05-02, landed).
- `./run -a do_spl_spawn_queue` at 07:05:28Z -> `7 queued, 0 placing`: `5b1b7d82` (Qto
  sync), `49357202` and `e43a7b02` (release-relay heartbeat and loop length), `ac53e5c4` (WUI live request), `d1d27620`
  (s187 S2 agy reviewer), `a8001b67` (s187 S12a), `5a432cc3` (Qto PDF export). None names
  a row file. The plan's 05:38Z list differs only by asks placed or added since then.
- The plan keeps `spl-review-go.func.sh` / `.tst.sh` (b50-01) out of both rows; it only
  runs `spl-review-go.tst.sh` read-only.

### 2.7 Inputs accounted for (check 7)

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` is not on this seat's box (`ls`
  -> no such file). The holder relayed the two refactor-shaped open items (msg `5f31c68a`):
  - WUI entry chunk at 154.7 of 155 KB gzip: plan section 7 lists it (candidates line
    125) as perf-shaped. Accounted.
  - `spl-unanswered-sweep.func.sh:196` `send_to_peers_on`:
    `git grep -n send_to_peers_on f9521a941 -- csi-spl-orc` -> only
    `features/spawn-agents/tests/test-fleet-send.sh:367` and
    `tests/unanswered-sweep.tst.sh:456` (guard greps that forbid the name). Line 196 of
    the func file is now a comment naming `spool_fleet_has_seats`. Served, as the plan
    says (1.2 (c), candidates line 133).
- r05 section 7 (`git show origin/master:csi-spl-doc/doc/md/refactor-round-05-plan.md`):
  its first item is served by r06-01, and every other item reappears in r06 section 7
  with its reason. Nothing is dropped.

### 2.8 Hygiene (check 8)

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` in a worktree of `9c39b5d2f` ->
`INFO distribution-hygiene: clean over the tracked tree of ...`, exit 0.

## 3. Defects

- **W1** (plan lines 472 and 932): row 02's test hunk makes `cron-tagged-line.tst.sh`
  grow from 70 to **123** lines (`+53 -0`), not `70 -> 106 lines (+36 -0)` (line 472) and
  not `+36 -0` (line 932, section 6 "lines" row). The hunk itself is right: the rebuilt
  file's sha256 is the plan's `57bffcc274b4`. Fix: change both numbers to `70 -> 123` /
  `+53 -0`.

## 4. Notes

- **N1:** neither row updates the header comment of its test file:
  `spl-spawn-fill.tst.sh` (the r05 R7 N2 already noted that section 11 is missing there)
  and `cron-tagged-line.tst.sh:3-11` (it lists sections 1-6 only). A row may add one line
  for its new section in that file; this changes no behaviour.
- **N2:** the 1.5 test column ran `spl-spawn-queue.tst.sh` (`0/327*/0`), and I did not
  re-run it. Row 01 does not edit it, and its only link to the rows is a name match.
- **N3:** on this box the row tests are slow under load: one `spl-spawn-fill.tst.sh`
  run took more than 2 minutes. A row lane should not run the column in a 120 s
  foreground call.

## 5. v1.0 signature

**PASS on v1.0 `badeda0c8175aa02bea32df5f5a92baa9655b5b5`** (parent `9c39b5d2f`, the v0.1
I reviewed above). Each line ran once (n=1), on my box, by me:

- `git ls-remote origin refs/heads/review/c002-refactor-round-06-planner` ->
  `badeda0c8175aa02bea32df5f5a92baa9655b5b5`.
- `git diff --stat 9c39b5d2f badeda0c8` -> only `csi-spl-doc/doc/md/refactor-round-06-plan.md`,
  35 insertions, 8 deletions. Read the whole diff: status line, section 1.4 count, section 4
  panel line, section 6 lines row, section 8 v1.0 entry, section 9 consensus.
- W1 folded: `git show badeda0c8:<plan> | sed -n 474p` -> `... 70 -> 123 lines (+53 -0).`;
  line 937 (section 6 lines row) carries `cron-tagged-line.tst.sh +53 -0`.
- No row change: the 10 fenced `bash` blocks, concatenated, hash the same on both shas
  (sha256 first 12 `c8d19dc3d871` on `9c39b5d2f` and on `badeda0c8`; 10 blocks counted on v1.0).
- No drift: `git diff --name-only f9521a941 origin/master -- csi-spl-orc` filtered to the
  row files -> empty (origin/master `551b3c601`).
- N1 as recorded: `git grep -nE '^#\s+(10|11|12)\.' f9521a941 -- '*spl-spawn-fill.tst.sh'`
  -> header lists up to section 10 (line 37), no 11; `cron-tagged-line.tst.sh:6-11` lists 1-6.
- Hygiene: `do_check_dist_hygiene` in a worktree of `badeda0c8` ->
  `INFO distribution-hygiene: clean ...`, exit 0.

New defects: none. N1-N3 are recorded in plan section 8 as I wrote them. The plan text
still says "pending full review-line check and final v1.0 signature" (status, sections 4
and 9); this signature is that final step, and the editor may leave or drop the words.
