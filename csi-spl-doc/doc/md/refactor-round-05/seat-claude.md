# Refactor round 05 - claude panel seat (c-893)

Issue: SPL-6553 · Epic: SPL-2402 · Spec: csi-spl-doc/specs/011-spool-project-refactor

Plan read: `csi-spl-doc/doc/md/refactor-round-05-plan.md` v0.1 on
`review/c002-refactor-round-05-planner`, sha
**`e97c0dcc55aae42f058b608f5f7a7beea06f0a84`** (`git ls-remote origin
refs/heads/review/c002-refactor-round-05-planner` -> that sha, 2026-11-26T03:4xZ; one
commit on `874d1b2f4`, `git show --stat` -> the plan file only, 889 lines). Plan base:
`b42d34d7b9e57704a26e1fde93ebb65e2813389f`.

## Verdict: PASS on e97c0dcc5 (rows sound), with W1 and W2 to fold into v1.0

Both rows are one logical refactor each, keep behaviour, and their controls go RED for
the reason the plan gives and GREEN on the head. I rebuilt every head file from the
plan's verbatim blocks: 7 of 7 sha256s match the plan (one only after the W2 blank
line). Every count in 1.5 that I re-ran matched the plan's number exactly. W1 is a gap
in the inputs accounting (1.2 (c) and section 7). W2 is a mismatch between the prose
and the sha. Both are doc-only fixes and neither changes a row. I sign v1.0 once both
are folded.

## 1. Window and slug (brief check 1)

Run 2026-11-26T03:4xZ after `git-fetch-fresh.sh` (`fetched origin/master`):

- `git log origin/master -3 --format='%H %cI %s' -E --grep='^docs\(r04-plan'` ->
  `874d1b2f4 2026-11-26T05:32:33+02:00` (r04 close record, landed after the plan read W),
  `ea644d377 2026-11-26T04:08:14+02:00` (v1.0 signed), `58ae657aa ...04:08:14+02:00`.
  The plan's `W=2026-11-26T04:08:14+02:00` (from `ea644d377`) was the newest r04-plan
  commit when the round opened. Rulebook 5.3 fixes W at that recorded date, so `874d1b2f4`
  does not move it.
- `git log origin/master --since="2026-11-26T04:08:14+02:00" --oneline -E --grep='\(r05-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r05-[0-9]{2}|refactor-round-05'` ->
  `e97c0dcc5... refs/heads/review/c002-refactor-round-05-planner` only (the planner's;
  this seat's branch is pushed after this file). Rulebook 5.3 form
  `git ls-remote origin 'refs/heads/review/r05-*' 'refs/heads/wip/*r05*' 'refs/heads/*-r05-*' | wc -l` -> `0`.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r05-[0-9]{2}|refactor-round-05'` ->
  `c002-refactor-round-05-claude-panel-seat.md`, `hand-sat-c002-refactor-round-05-planner.md`
  (the two expected; nothing else).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -E 'refactor-round-0?5'` ->
  `refactor-round-5-plan.md`, `refactor-round-5-retro.md`, `refactor-round-5` (no
  `refactor-round-05*`), so no date suffix is needed. r04 set the same precedent
  (`refactor-round-4-plan.md` beside `refactor-round-04-plan.md`).

## 2. Sites on base and on origin/master (brief check 2)

- `git diff --name-only b42d34d7b origin/master -- <13 files>` (the 7 edited, the 3
  sibling suites, `setup-box-stats-cron.func.sh`, `box-stats-cron.tst.sh`,
  `satellite-ansible.tst.sh`) -> empty at origin/master `874d1b2f4`: **no drift**.
- Line counts on base (`git show b42d34d7b:<f> | wc -l`): orch-rotate install 89,
  `orch-rotate.tst.sh` 1255, spawn-fill install 78, security-round install 82, poll-ack
  install 81, accepted-close install 81, `spl-spawn-fill.tst.sh` 390,
  `setup-box-stats-cron.func.sh` 107. All match the plan.
- Row 01 sites, read with `git show b42d34d7b:... | cat -n`: `:40` holds `local tag src
  script logdir line current pre="" trunk=...`; `:54` is `current="$(spl_desk_cron_line
  "$tag")"`; `:88` is the last `spl_desk_cron_say "$line"`; `:89` is `}`.
  `orch-rotate.tst.sh:948` is `# --- 13. spec 061 L6: ...`.
- Row 02 sites: spawn-fill `:30` local with `current`, `:47` `current=...` through `:78`,
  the end of `spl_spawn_fill_cron_check`. security-round `:35`, `:51-82`. poll-ack `:31`,
  `:48-81`. accepted-close `:31`, `:48-81`. `spl-spawn-fill.tst.sh:387` is `echo`. All
  match. Spans are 32/32/34/34 lines, as the plan says.
- Row 01 body diff: `diff` of `spl-orch-rotate-install-cron.func.sh:54-88` against
  `setup-box-stats-cron.func.sh:71-105`, counting `^[-+][^-+]` lines -> **10**, the
  plan's count (local subj, the 4 log lines, trailing say).

## 3. Red controls, run on base in scratch worktrees (brief check 3)

Built with `git worktree add --detach <push-user mktemp>/<name> b42d34d7b`, then the plan's
verbatim blocks applied (1.3 lines 226-230 and 236-265, 1.4 lines 346-424 and 430-523).
Hunk files: `r1_test.txt` sha256 `e7fe4df8f31f...`, `r2_test.txt` sha256 `0bb3c6d15fb1...`.
Each suite ran as the push user, `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID`
unset, stdin `/dev/null`, counted with the plan's `grep -ciE` patterns, n=1.

| control | tree | rc | pass / fail | last line |
|---|---|---|---|---|
| rc1 `orch-rotate.tst.sh` (head test, base code) | rc1 | 1 | 198 / 1 | `orch-rotate: 1 failure(s)` |
| head1 `orch-rotate.tst.sh` | head1 | 0 | 199 / 0 | `orch-rotate: all passed` |
| base `orch-rotate.tst.sh` | base | 0 | 196 / 0 | `orch-rotate: all passed` |
| rc2 `spl-spawn-fill.tst.sh` | rc2 | 1 | 49 / 6 | `FAIL: 5` |
| head2 `spl-spawn-fill.tst.sh` | head2 | 0 | 55 / 0 | `PASS: all` |
| base `spl-spawn-fill.tst.sh` | base | 0 | 44 / 0 | `PASS: all` |
| m1a (omit arg 11 `""`) | m1a | 1 | 199 / 2 | `orch-rotate: 2 failure(s)` |
| m2a (security-round arg 10 `""`) | m2a | 1 | 53 / 2 | `FAIL: 1` |

- rc1 fails only on `FAIL: 10c. r05-01 one copy: own=[66: do_log "OK the orchestrator
  rotation is installed ...`. The lazy-load and lifecycle checks print `PASS` on base.
  So it fails for the plan's reason (the own copy is still there), not for an
  environment reason.
- rc2 fails on `11. helper lifecycle` (`_spl_run_cron_apply: command not found`) and the 4
  one-copy checks (`old=[48: ...`, `own=[52:`, `[50:`, `[50:`). All 6 standalone
  lazy-load and `ok_msg` checks print `PASS` on base. That is the plan's reason.
- m1a: `FAIL the orchestrator rotation cron is NOT installed` and `OK the orchestrator
  rotation cron runs hourly`. m2a: `FAIL: 11. lazy sr (rc=1): FAIL the weekly security
  round is NOT installed (no line tagged csi-spl:security-round)`. The plan's mutation
  counts reproduced. I did not run gc1, gc2a-c, m1b, m2b or m2c (NOT RUN, out of time
  box; they are the same shape as m1a and m2a).
- Live state: both new sections run on `$T=$(mktemp -d)` with `trap 'rm -rf "$T"'`
  (spawn-fill `:49-50`, orch-rotate `:115-116`). A `crontab` stub on `$T/bin` writes
  `$FAKE_CRONTAB` (`:351-356`, `:905-910`). `DESK_CRON_SRC=$SRC=$T/shared`.
  `spl_desk_cron_checkout` calls no git unless `SPL_DESK_CRON_CREATE=1` (read at
  `lib/bash/funcs/spl-desk-cron-checkout.func.sh:16`). No live crontab, checkout or
  spool is touched. See N5 for one inherited-env edge.

## 4. Equivalence (brief check 4)

- **Row 01:** with `noun=""`, `subj` equals `"orchestrator rotation"`, so the 4 log lines
  and the `check` script test (`spl_desk_cron_script` plus `-x`) are byte-identical to
  `:56-88`. The `FATAL ... (is it on trunk yet?)` and `read back ... Got:` lines are
  already the same in the helper (`setup-box-stats-cron.func.sh:100,104`). Exit codes:
  the helper returns at the same points with the same codes. The column agrees: base
  `0/196/0` -> head1 `0/199/0`, which is the 3 new checks. `box-stats-cron.tst.sh`
  `0/54/0` and `satellite-ansible.tst.sh` `0/96/0` are equal on base and head1.
- **Row 02:** the helper is the 4 bodies with `$label`, `$ok_msg` and `$miss_why`
  substituted. The old `check` path `spl_*_cron_check ...; return` returned the status
  of its last `do_log`; the helper returns 0 explicitly after the same `do_log`. That is
  the same unless `do_log` itself fails. Sibling suites, base -> head2:
  `spl-security-round-queue` `0/33/0`=, `spl-desk-poll-ack` `0/37/0`=,
  `spl-accepted-close` `0/32/0`=.
- **Shared gates** (base / head1 / head2, all rc 0 and equal): `run-eager-files` 14,
  `no-literal-paths` 15, `func-name-unique` 2, `no-box-path-source` 10,
  `action-header-tags` 6, `param-required` 17, `run-lazy-loader` 30, `bash-cleancode` 15,
  `gcloud-account-pinned` 48. `shellcheck 0.10.0 -S warning -x` on the 2 head1 files
  -> rc 0, and on the 5 head2 files -> rc 0.
- **Would the controls catch a difference?** A wrong label or miss text: yes (m1a and
  m2a above). A wrong install `ok_msg`: yes (the `ok_msg` checks). The siblings' remove
  line is not asserted directly (N4).

## 5. Row form (brief check 5)

Both rows carry a RED-then-GREEN control (R2), a test list, vendor `claude`, kind
`simple_coding`, batch 1, and an agy R7 seat (claude waiver only under `dc84300a`, never
mistral). There is no mistral row. The rows have 2 and 5 sites, within 3.1's max of 5,
and the round has 2 rows, within 5.1's 1-3. R1: the head numstat sets are disjoint. Row
01 touches `spl-orch-rotate-install-cron.func.sh` and `orch-rotate.tst.sh`; row 02
touches the 4 installers and `spl-spawn-fill.tst.sh`.

## 6. R3 lane map (brief check 6)

`lane-map.sh --check <the 10 paths of plan 2.2> --agent c-893` at 2026-11-26T03:52:38Z ->
**exit 4**. No live lane lists any of the 10 paths. 15 lanes on the other box record no
files: c-029, c-041, c-086, c-146, c-187, c-398, c-407, c-416, c-474, c-535, c-728, c-927,
c-936 (`*-rotate` seats), c-957 (a monthly personnel-cost spec), and c-965 (`rotate-2`).
The plan's 16 included c-823 (b48-01). That row has since landed (`61a325ebc
fix(b48-01-orc-review-go-dedup-author-sha, SPL-6548)`), so the plan's "live b48-01"
wording in 1.2 (a), 2.2 and 7 is stale (N3). The stale wording does not affect any row.
No row file is touched by a lane the plan names.

## 7. Inputs accounted for (brief check 7)

- r04 section 7 (`git show origin/master:csi-spl-doc/doc/md/refactor-round-04-plan.md`,
  lines 1051-1063) against r05: the cron installers become row 01 and section 7. brc/oq,
  the test bug, msg-dedup and wipe, box-restart, peer-crons and the probes, the gcp
  alerts, channel-agent and the catch-all are all carried. Nothing is dropped.
- The candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 142
  lines, 31775 bytes, mtime 2026-11-26 02:10 +0200), `grep -niE
  'refactor|one copy|duplicat|helper|extract|fold'`. The plan's 1.2 (c) names 4
  entries, all served. The rest are covered by "all other items are bug, perf, doc,
  test-hardening, or other-repo" (plan lines 166-167). That claim is not true for the
  entries in W1.
- No row changes an exit code, a message, a path or a default. Both are refactor rows,
  not bug rows.

## 8. Hygiene (brief check 8)

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> rc 0, `INFO distribution-hygiene:
clean over the tracked tree` (run on this seat's worktree, this file included).

## Defects

- **W1 (plan lines 153-167 and 870): refactor-labelled candidates are not named.** The
  candidates file labels these entries refactor-shaped. The plan names none of them
  (`grep -nE 'watchdog|lane-rotate|agent-boot-restore dir|_ppe_keys|lang-review-exempt|headroom|perf-budget' plan.md`
  -> 0 lines). Re-measured on `b42d34d7b`:
  - Candidates line 1 (literal `/var` paths in `spl-watchdog.func.sh:72,:1311` and
    `spl-lane-rotate.func.sh:112`): served. `git grep -nE '/var/'` on both files -> one
    `@example` line only (`spl-watchdog.func.sh:76`, `/var/tmp/wd-drill`).
  - Candidates line 48 (agent-boot-restore dir literal): served. Both the writer
    (`spl-agent-boot-restore-install-cron.func.sh:60`) and the reader
    (`spl-watchdog.func.sh:541`) use `spl_var_app_subdir`.
  - Candidates line 113 (REFACTOR/GATE `_ppe_keys` exact-key selector,
    `check-pre-push-e2e.func.sh:121`): **open**, not served and not accounted for.
  - Candidates line 115 (BUG/REFACTOR `csi-spl-wui/i18n/i18n-lang-review-exempt.json:2`
    `_doc` says `needs a 'Lang-review: a-NNN <msg id>'`, while
    `check-pre-push-lang-review.func.sh:151` requires `Lang-review: gct`): **open**, not
    accounted for.
  - Candidates line 125 (REFACTOR/PERF WUI entry-chunk headroom): **open**, not accounted
    for. It is perf-shaped, so it should be named as handed to a perf round.

  Fix: add these 5 to 1.2 (c) and section 7, each with its disposition (served, gate or
  bug round, perf round). No row changes.
- **W2 (plan lines 324-325, 336 and 856): the prose and the sha disagree.** "Insert
  section 11 ... preceded and followed by one blank line" (base `:386` is already blank)
  gives `spl-spawn-fill.tst.sh` sha256 `1b29f5d84f85` with `+95`. The plan's
  `f340304fde3a` and `+96` reproduce only with one extra blank line before the section
  (two blank lines in a row). That holds back the "byte-for-byte" claim of the plan's
  "One sha" paragraph. Fix: say "two blank lines before" or drop the extra line and
  restate the sha and numstat.

## Notes

- **N1 (plan lines 39, 181 and 649):** `setup-box-stats-cron.func.sh:67-107` cites line
  67, which is the last line of the helper's header comment
  (`#   when unset; pass "" ...`). The comment starts at `:64` and the definition is at
  `:68`. Write `:64-107` or `:68-107`.
- **N2:** the plan's Status line says zero drift up to `0d5e0b252`. I re-checked up to
  `874d1b2f4`: zero drift (section 2).
- **N3:** c-823 / b48-01 is cited as live (1.2 (a), 2.2 and section 7). It landed as
  `61a325ebc`. The `spl-review-go-install-cron` deferral may now be revisited for r06.
- **N4:** row 02's sibling `remove` line (`OK the <label> is out of the crontab`) is not
  asserted for security-round, poll-ack or accepted-close. It is right by construction,
  because the same `$label` is asserted by the check-missing and check-ok lines. An R7
  seat may want one assertion.
- **N5:** section 11's first block runs `env ... bash -c` (inheriting the caller's env)
  and calls `_spl_run_cron_apply install` directly, without `spl_desk_cron_src`. A
  caller env with `SPL_DESK_CRON_CREATE=1` would make it run `git -C
  "$SPL_DESK_CRON_REPO" fetch/worktree add`. That variable is unset on normal runs. An
  `env -u SPL_DESK_CRON_CREATE` would make the block hermetic like 10c.
- **N6:** `$(id -un)` (row 02) and `$(printf '%02d' "$min")` (row 01) are now evaluated
  on every action, not only on install. The output is unchanged.
- **N7:** row 01's lazy source also loads `setup-box-stats-cron.func.sh`'s top level.
  That is guarded sources of `spl-desk-cron-lock`, `spl-desk-install-service` and
  `spl-desk-cron-checkout`, plus the `do_setup_box_stats_cron` definition. This is the
  same pattern r04-02 landed, and nothing in the output changes.

## Review line

review: c-893 claude PASS e97c0dcc55aae42f058b608f5f7a7beea06f0a84 ran: bash csi-spl-orc/src/bash/tests/orch-rotate.tst.sh ; bash csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh ; bash csi-spl-orc/src/bash/tests/spl-security-round-queue.tst.sh ; bash csi-spl-orc/src/bash/tests/spl-desk-poll-ack.tst.sh ; bash csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh ; bash csi-spl-orc/src/bash/tests/box-stats-cron.tst.sh ; bash csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh ; 9 shared gates ; shellcheck -S warning -x ; lane-map.sh --check ; ./run -a do_check_dist_hygiene | read: rc1 1 198/1, head1 0 199/0, rc2 1 49/6, head2 0 55/0, m1a 1, m2a 1, siblings equal, gates equal, shellcheck rc 0, lane-map exit 4, hygiene rc 0 | log: c-893:~/.claude/projects/-opt-csi-csi-spl-wt-c-893/a470bb35-5c79-48a3-82dc-0c1d141dae7f.jsonl

## v1.0 signature: PASS on 78812b3d75ee018ce4497ad5d82af3ac37d39cd8

I read v1.0 at `78812b3d75ee018ce4497ad5d82af3ac37d39cd8`. Running `git ls-remote origin
refs/heads/review/c002-refactor-round-05-planner` prints that sha. It is a fast-forward
on v0.1 `e97c0dcc5`, and `git diff --stat e97c0dcc5 78812b3d7` touches only the plan
(+104 -50).

- **Code unchanged.** I extracted the fenced `bash` blocks of v0.1 and v1.0 (`awk` from
  `^```bash` to `^````) and hashed them. Both give sha256 `fb2591d977ad...`, over 7
  blocks. Every head, red control and mutation result of sections 3 and 4 above
  therefore still holds.
- **W1 folded.** 1.2 (c) and section 7 now name candidates-file lines 1, 25, 48, 76, 104
  and 133 as served, and 113, 115 and 125 as open with a disposition (gate design, a doc
  or bug line, perf). I checked each number with `sed -n` against the candidates file,
  and they match. `_ppe_keys` is at `check-pre-push-e2e.func.sh:121-128` on
  `b42d34d7b`: `sed -n '121p;128p'` prints `_ppe_keys() {` and `}`.
- **W2 folded.** The prose now says one blank line before and after the section. The
  numbers read `390 -> 485`, `+95 -0`, sha256 `1b29f5d84f85`, which is my v0.1
  measurement of that shape.
- **N1-N7 folded.** The helper is cited as `:64-107`, with the definition at `:68-107`.
  N2 zero drift: `git diff --name-only 5dbcaec84 origin/master -- <13 files>` prints
  nothing, and origin/master is `5dbcaec84`. The N3 lane map now reads exit 4, 15
  unknown, 0 owned. N4-N7 are noted in 1.3, 1.4 and 2.2.
- **Window.** `Window: W=2026-11-26T04:08:14+02:00` is unchanged (rulebook 5.3).
- **Hygiene.** a `grep -nwE` for the 4 user and box literals of the hygiene rule (CLAUDE.md section 4) on the v1.0 plan finds 0 lines.
  The `do_check_dist_hygiene` run on this seat's tree is below.

review: c-893 claude PASS 78812b3d75ee018ce4497ad5d82af3ac37d39cd8 ran: none (v1.0 is docs-only; code blocks byte-identical to v0.1, whose tests ran above) ; ./run -a do_check_dist_hygiene | read: refactor-round-05-plan.md v0.1..v1.0 diff, fenced-block sha256 equal, candidates-file lines 1 25 48 76 104 113 115 125 133, check-pre-push-e2e.func.sh:121-128 | log: c-893:~/.claude/projects/-opt-csi-csi-spl-wt-c-893/a470bb35-5c79-48a3-82dc-0c1d141dae7f.jsonl
