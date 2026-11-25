# Refactor round 02 - claude seat review (c-646)

The cross-vendor (claude) panel seat's review of
`csi-spl-doc/doc/md/refactor-round-02-plan.md`, draft **v0.1**,
sha **`16c335852f48c401739b253c5eef5b0f598ac38e`** on
`review/c002-refactor-round-02-planner` (editor a-712@sat, task
`dispatch-refactor-r02`, issue SPL-6526). A seat commits this file and nothing
else (R7.6).

**Verdict on `16c335852`: FAIL** - two defects (W1, W2), both doc-only. The two
rows themselves hold: every red control, guard control and mutation reproduces
with the counts and the failure reason the plan gives, and both rows keep
behaviour. Fix W1 and W2 in v1.0 and this seat signs it.

**How it was measured.** Base `c567245fa` = `git archive c567245fa` into a
scratch dir (not a worktree; see N2). head1 and head2 built on copies of it from
the plan's verbatim blocks and shape lines (1.3, 1.4). Every suite run as
`env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 timeout 600 bash <test> </dev/null`
as the agent user, counts with the plan's greps (`grep -ciE '^ *(ok|pass)'`,
`grep -ciE '^ *(not ok|fail)'`). n=1 per command, 2026-11-25 19:00Z-19:47Z.
The plan file read: `git show 16c335852:csi-spl-doc/doc/md/refactor-round-02-plan.md`,
sha256 `3ba9c9d157c9e343...`, 838 lines.

## 1. Slug and window (rulebook 5.3)

| command | printed |
|---|---|
| `git log origin/master --since='2026-11-25T18:51:33+02:00' --oneline -E --grep='\(r02-' \| wc -l` (origin/master `d5a2422f4`, 19:42Z) | `0` |
| `sudo -u <owner-user> git ls-remote origin \| grep -E 'r02-[0-9]{2}\|refactor-round-02'` | only `16c335852... refs/heads/review/c002-refactor-round-02-planner` (this seat's branch not pushed yet) |
| `ls /var/spool-hub/dispatch/briefs \| grep -E 'r02-[0-9]{2}\|refactor-round-02'` (this box) | empty, rc 1: the planner's and this seat's briefs live on sat; not read |
| `git merge-base --is-ancestor c567245fa origin/master` | rc 0 |

## 2. Sites on base and drift

Each cited line printed with `git show c567245fa:<file> | sed -n <N>p`:

| site | line on `c567245fa` |
|---|---|
| `spl-msg-move.func.sh:50` / `:60` | `local hub d` / `spl_host_spool \|\| return 1` |
| `spl-msg-move.func.sh:70` / `:78` / `:82` | `python3 - "$ENV" ... "$task" "$out" <<'EOF_PY'` / `EOF_PY` / `# _spl_msg_move_why names a hub refusal ...` |
| `spl-topic-move.func.sh:47` / `:57` | `local hub d` / `spl_host_spool \|\| return 1` |
| `spl-topic-move.func.sh:76` / `:84` | `python3 - ... "$channel" "$out" <<'EOF_PY'` / `EOF_PY` |
| `setup-box-stats-cron.func.sh:43` / `:59` / `:93` / `:94` | `local tag src script logdir line ns current ...` / `current="$(spl_desk_cron_line "$tag")"` / `spl_desk_cron_say "$line"` / `}` |
| `check-disk-headroom-install-cron.func.sh:41` / `:57` / `:91` / `:92` | same four lines |
| `setup-go-cache-prune-cron.func.sh:41` / `:57` / `:91` / `:92` | same four lines |
| `spl-msg-move.tst.sh:74`, `spl-topic-move.tst.sh:71` | `echo "fails=$fails"` (both) |
| `box-stats-cron.tst.sh:219` | `echo` |

Drift: `git diff --name-only c567245fa origin/master -- <the 5 .func.sh + 5 .tst.sh>`
(origin/master `d5a2422f4`) -> `0`;
`git log c567245fa..origin/master --name-only --format= -- <the 5 .func.sh>` -> `0` lines.

Duplication claims: `diff <(...box-stats:59-94) <(...disk-headroom:57-92)` and
`<(...go-cache:57-92)` -> 4 changed lines each (the 4 label lines: FAIL missing
line, OK check, OK remove, OK install). Matches 1.4.

## 3. Heads, sha256 and line counts (W1)

`sha256sum <file> | cut -c1-12` and `wc -l` on the built heads:

| file | built | plan says |
|---|---|---|
| `spl-msg-move.func.sh` | `4a442ccdc5ef` 118 | `4a442ccdc5ef` 118 - match |
| `spl-topic-move.func.sh` | `66ee11218bed` 73 | `66ee11218bed` 73 - match |
| `setup-box-stats-cron.func.sh` | `2b1f19013437` 105 | `2b1f19013437` - match |
| `check-disk-headroom-install-cron.func.sh` | `6106f57f2059` 62 | match |
| `setup-go-cache-prune-cron.func.sh` | `7e4e89ea9bd4` 61 | match |
| `spl-msg-move.tst.sh` | `5b907bd5d703` **125** | `78add1dd5cf8` **118** (`+43`) |
| `spl-topic-move.tst.sh` | `1a42b8064d83` **90** | `252ebe52f341` **87** (`+15`) |
| `box-stats-cron.tst.sh` | `c880d0a28021` **275** | `a4821f702627` **270** (`+49`) |

The verbatim test hunks are 49, 17 and 53 lines (`wc -l` of the blocks
extracted from the plan), each followed by the one blank line the plan asks for:
75+50 = 125, 72+18 = 90, 221+54 = 275. All 5 `.func.sh` claims hold; none of the
3 test-file claims does.

## 4. Suites, base and heads

| suite | base rc/pass/fail | head | plan |
|---|---|---|---|
| `spl-msg-move.tst.sh` | 0/19/1 (`fails=0`) | head1 0/26/1 | = |
| `spl-topic-move.tst.sh` | 0/18/1 (`fails=0`) | head1 0/21/1 | = |
| `box-stats-cron.tst.sh` | 0/36/0 | head2 0/44/0 | = |
| `check-disk-headroom.tst.sh` | 0/43/0 | head2 0/43/0 | = |
| `prune-go-build-cache.tst.sh` | 0/58/0 | head2 0/58/0 | = |
| iac `no-box-path-source` / `action-header-tags` / `param-required` / `run-lazy-loader` / `bash-cleancode` | 0/10/0, 0/6/0, 0/17/0, 0/30/0, 0/15/0 | head1, head2: same | = |
| orc `run-eager-files` / `func-name-unique` | 0/14/0, 0/2/0 | head1, head2: same | = |
| orc `no-literal-paths` | 1/13/2 in the archive copy; 0/15/0 after `git init && git add -A && git commit` of that copy | head1, head2: same both ways | = (N2) |

`shellcheck -S warning -x` on head1's 4 files and on head2's 4 files: rc 0, no
output (both). `do_sec_shellcheck`: NOT RUN.

## 5. Red, guard and mutation controls

Each on a copy of base with the files named; last line, rc, and the FAIL lines:

| control | tree | rc/pass/fail | FAIL lines | plan |
|---|---|---|---|---|
| rc1a | base + head1 `spl-msg-move.tst.sh` | 1/19/8, `fails=7` | `prep dry ok`/`prep dry nodesk`/`prep live` rc 1 and `prep nodesk` rc 127 `_spl_desk_move_prep: command not found`; `json obj`/`json str` rc 127 `_spl_desk_move_json: command not found`; `6. msg one copy` | = |
| rc1b | base + head1 `spl-topic-move.tst.sh` | 1/20/2, `fails=1` | `6. topic one copy: own=[53: do_log "OK DRY_RUN nothing was sent. ...` | = |
| gc1 | head1, `declare -F _spl_desk_move_prep` line deleted in `spl-topic-move.func.sh` | 1/20/2, `fails=1` | `6. lazy topic: rc=1 .../spl-topic-move.func.sh: line 49: _spl_desk_move_prep: command not found` | = |
| rc2 | base + head2 `box-stats-cron.tst.sh` | 1/40/4, `box-stats-cron: 4 FAILED` | `4. apply direct: ... _spl_simple_cron_apply: command not found`; `4. box one copy`; `one copy check-disk-headroom-install-cron.func.sh: own=[69: ...`; `one copy setup-go-cache-prune-cron.func.sh: own=[69: ...` | = |
| gc2a | head2, guard deleted in `check-disk-headroom-install-cron.func.sh` | 1/43/1 | `4. lazy dh (rc=127): ... line 58: _spl_simple_cron_apply: command not found` | = |
| gc2b | head2, guard deleted in `setup-go-cache-prune-cron.func.sh` | 1/43/1 | `4. lazy gc (rc=127): ... line 58: _spl_simple_cron_apply: ...` | = |
| m1a | head1, msg passes `channel` for `to_task` | 1/26/2, `fails=1` | `move (rc=0): {... "channel": "e2c3fbad-..."` | = |
| m1b | head1, topic passes `to_task` for `channel` | 1/20/2, `fails=1` | `6. topic json key: {...` | = |
| m2a | head2, box-stats drops the missing-line suffix | 1/43/1 | `4. box miss (rc=1): FAIL the box-stats cron is NOT installed (no line tagged csi-spl:box-stats)` | = |
| m2b | head2, disk-headroom label `box-stats` | 1/43/1 | `4. lazy dh (rc=1): FAIL the box-stats cron is NOT installed (no line tagged csi-spl:disk-headroom): ...` | = |
| m2c | head2, go-cache label `box-stats` | 1/43/1 | `4. lazy gc (rc=1): FAIL the box-stats cron is NOT installed (no line tagged csi-spl:go-cache-prune)` | = |

Each red fails for the plan's reason (helper missing on base, or the one-copy
grep), not for an environment reason. Live state: none touched.
`box-stats-cron.tst.sh:19` says `No real crontab, hub or tmux is touched`; every
call in its section 4 runs with `PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab"`
(`$T=$(mktemp -d)`, `:28`, fake `crontab` at `:175`); the msg/topic suites stub
`spool`, `curl`, `gcloud`, `tmux` (`orc_stub`, msg `:20`, topic `:19`) and
`spl_host_spool`.

## 6. Equivalence (check 4)

- **r02-01.** `_spl_desk_move_prep` runs the base lines `:52-60` / `:49-57` in the
  same order with the same messages; the only text that varied (`message $id to
  topic $task` vs `topic $topic to #$channel`) is passed as `what`. Dry run: same
  three log lines, rc 0 (caller returns on `SPL_MOVE_DRY_DONE`). Missing desk on
  `DRY_RUN=0`: same FATAL, rc 1, before `spl_host_spool`. `_spl_desk_move_json`
  is the same python with the key passed in; `sort_keys=True` keeps the output
  byte-identical. Caught by: rc1a/rc1b/gc1, m1a (section 4 `move` check), m1b
  (new top-level key check).
- **r02-02.** `_spl_simple_cron_apply` is the base `:59-94` body with the 4 label
  lines parameterised; the go-cache call omits `miss_why`, which reproduces its
  base line (no suffix). Same rc on every branch; the dropped `current` in each
  caller's `local` is only used inside the moved block. Caught by: rc2, gc2a,
  gc2b, m2a-m2c.
- Neither row changes an exit code, a message, a path or a default: both are
  refactor rows, not bug rows.

## 7. Rows, batches, vendors (check 5)

Both rows: R2 control red then green (section 5), test lists in section 2,
vendor claude, kind `simple_coding`, batch 1; no mistral row; R7 an agy seat,
claude waiver backup under ruling `dc84300a` only, never mistral (plan section 4).
R1: row 01's 4 files and row 02's 4 files are disjoint (by name).

## 8. R3 (check 6)

- `sudo -u <owner-user> bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 10 paths of 2.2> --agent c-646`
  at 19:44:40Z: **exit 4**, `no live lane lists <the 10 paths>, but 7 live
  lane(s) record no files`: `a-678@sat`, `a-712@sat`, `a-746@sat`, `c-298@sat`,
  `c-718@sat`, `c-722@sat`, `c-737@sat`. No lane owns a row path.
- `do_spl_spawn_queue` at 19:45:14Z: 5 queued, 0 placing; one is a refactor row,
  `6b14cdc6` `claude:c002-refactor-reserve-reads-box-gh-credential` (N4).
- Every `refs/remotes/origin/*` committed in the last 24 h (26 refs):
  `git diff --name-only $(git merge-base c567245fa <ref>) <ref> -- <the 10 paths>` -> 0 hits.

## 9. Inputs accounted for (check 7)

- `/var/spool-hub/dispatch/c002-next-round-candidates.md`: **NOT RUN** - `wc -l`
  -> `No such file or directory` on this box (it lives on the other box).
- r01 plan section 7 (`git show origin/master:csi-spl-doc/doc/md/refactor-round-01-plan.md`,
  10 rows): each is either served here (msg/topic move -> r02-01; the 3 cron
  installers -> r02-02) or carried in r02 section 7. Nothing unaccounted for.

## 10. Hygiene (check 8)

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` (worktree, before this file):
`INFO distribution-hygiene: clean over the tracked tree`, rc 0.

## Defects

- **W1 (plan :190, :195-196, :198-199, :380, :386, :814).** The test-file claims
  do not match the verbatim test hunks the plan asks the rows to paste: built
  exactly as 1.3/1.4 say, the heads are 125 / 90 / 275 lines with sha256
  `5b907bd5d703` / `1a42b8064d83` / `c880d0a28021`, not 118 / 87 / 270 and
  `78add1dd5cf8` / `252ebe52f341` / `a4821f702627`; the numstat `+43` / `+15` /
  `+49` is wrong too. A row lane that checks its head against the plan's sha256
  will find a mismatch it cannot resolve. Fix: re-measure the three test heads
  from the blocks as printed (or print the blocks that produced the claimed
  sha), and correct the numstat in section 6.
- **W2 (plan :689 and :821).** 2.2 says `r01-02` "is still unlanded" and
  section 7 says `c-639` "is live on these two files" and the guard waits "once
  `r01-02` lands". `3582fc44b` (`refactor(r01-02-orc-fleet-load-error, SPL-6530)`)
  was committed 2026-11-25T20:09:45+01:00 = 19:09:45Z, 17 min before v0.1
  (`16c335852`, 21:26:59+02:00 = 19:26:59Z), and is on origin/master
  (`git merge-base --is-ancestor 3582fc44b origin/master` -> rc 0). Fix: state it
  landed, and either restate why the agent-kinds/runner-cpu guard stays out of
  r02 or keep it as the named r03 candidate with the new reason.

## Notes

- **N1.** 1.4 / 2 / 3 / 5 use `:59-93` and `:57-91` (the 35-line body, ending at
  `spl_desk_cron_say "$line"`); the hunk headers (:396, :448, :459) and the row
  table's sites use `:59-94` / `:57-92` (including the closing `}`). Both are
  correct; say which one a row replaces in one place.
- **N2.** `no-literal-paths.tst.sh` is red (2 `STALE baseline` lines) in a
  `git archive` copy with no `.git`, on base too; it passes 0/15/0 in a git tree.
  The plan's "detached worktree" wording is right: a row that builds controls in
  a plain copy will see a false red.
- **N3.** The plan's R3 snapshot (19:03Z, 19 unknown lanes) had `c-718`, `c-722`,
  `c-737` as queued; at 19:44Z they are live and record no files. The holder
  re-reads at placement, as 2.2 says.
- **N4.** Queued refactor row `6b14cdc6` (`c002-refactor-reserve-reads-box-gh-credential`)
  is not in the plan's R3 list; its brief is not on this box, so its files are unread
  here. The holder checks it against the 10 paths at placement.
- **N5.** Measured on base `c567245fa` and origin/master `d5a2422f4`; the plan's
  "zero drift to `1a8c1ce1c`" (:64, :815) still holds to `d5a2422f4` on the 10 paths.
