# Refactor round 80 — panel seat mistral (m-691@<box>)

Issue: SPL-6148 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-80-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-80-plan.md` on branch
`review/c002-refactor-round-80-planner`, at the v0.1 sha the dispatch holder named
(spool msg 16098859, 2026-11-21T05:36:25Z, task `dispatch-refactor-r80`):
`7329be64194f2eb72715b4b5f9f3f9e606afc2c4`. Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2 the panel signs the
plan sha; 5.1 1 to 3 rows; 5.3 numbering and window). Form:
`csi-spl-doc/doc/md/refactor-round-79-plan.md` (on origin/master). Measured base
`07f34efeb` (the plan's own "One sha"); `origin/master` at my read `cd20128220`.

## Verdict

**PASS** on `7329be64194f2eb72715b4b5f9f3f9e606afc2c4` — plan v0.1, branch
`review/c002-refactor-round-80-planner` (ls-remote = this sha; one commit, parent
`8b7828a6b`, +417 lines, one file; not on master: `git merge-base --is-ancestor
7329be64194f2eb72715b4b5f9f3f9e606afc2c4 origin/master` -> rc 1). 2 rows, both claude
`simple_coding`, batch 1, files disjoint. No W defect. Notes N1-N3 below.

### 1. Slug r80 unused since the plan's `Window: W=`

W = `2026-11-21T06:01:47+01:00`, re-derived by me: `git log origin/master -1 --format='%H
%cI %s' -E --grep='^docs\(r79-plan'` -> `76eaf4ac69a71b9cd82f00db2c4c7dab588f01f5
2026-11-21T06:01:47+01:00 docs(r79-plan, SPL-6126): ...` (matches the plan's 1.1).

- `git log origin/master --since="$W" --oneline -E --grep='\(r80-' | wc -l` -> **0**; the
  same grep over all history (no `--since`) -> **0**. Control: `(r79-` since W -> **1**
  (`76eaf4ac6`), so the read sees a used id.
- `git ls-remote origin | grep -E 'r80-[0-9]{2}|refactor-round-80'` -> one line:
  `7329be64194f2eb72715b4b5f9f3f9e606afc2c4  refs/heads/review/c002-refactor-round-80-planner`
  (the planner's, expected). `git ls-remote origin 'refs/heads/review/r80-*'
  'refs/heads/wip/*r80*' 'refs/heads/*-r80-*'` -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r80-[0-9]{2}|refactor-round-80'` -> exactly
  the 2 expected files (`c002-refactor-round-80-planner.md`,
  `c002-refactor-round-80-mistral-panel-seat.md`); `spawn-remote/briefs` -> none.
- `git ls-tree 07f34efeb --name-only csi-spl-doc/doc/md/ | grep -c refactor-round-80` -> 0,
  so the plain plan name is right (rulebook 5.3 "Files").

### 2. Every site file:line of every row exists on the base sha and on origin/master

27 cited lines checked with `git show <sha>:<file> | sed -n <N>p` on `07f34efeb` and on
`origin/master` (`cd20128220`): 27 of 27 identical, none empty. Row table sites:

- row 01: `csi-spl-orc/src/bash/run/spl-unanswered-sweep-install-cron.func.sh:26,38,50,53,56,57`
  -> e.g. `:57` -> `  logdir="${SWEEP_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/unanswered-sweep}"`;
  `csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline:10` ->
  `1 csi-spl-orc/src/bash/run/spl-unanswered-sweep-install-cron.func.sh`;
  `csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh:270-272` -> `:272` ->
  `[[ -z "$bad" && "$n_sd" -ge 4 ]] && pass "every state dir the actions write ($n_sd paths) ..."`;
  `csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh:280` ->
  `cron SWEEP_CRON_ACTION=check >"$T/o" 2>&1 && fail "10. check passed with no line" || pass "10. check fails while not installed"`.
- row 02: `csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh:57-60,124,125` -> `:58` ->
  `  local dir="${1:?cnf dir}" env="${2:?env}" out="${3:?out}"`;
  `csi-spl-iac/src/bash/tests/cnf-one-key-per-fact.tst.sh:20,81`.
- input sites: `csi-spl-orc/src/bash/scripts/spl-desk-reply.sh:9,19,39,52,239`,
  `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:138`,
  `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh:147-148` — all SAME.

Drift: `git diff --name-only 07f34efeb origin/master -- <the 6 row files>` -> empty (rc 0);
`git log origin/master --since="$W" -- <the 6 row paths> | wc -l` -> 0.
Line counts on base match the plan: installer 102, unanswered-sweep.tst.sh 463,
no-literal-paths-spelled.baseline 16 lines (15 entries + 1 comment), satellite-ansible.tst.sh
535, spl-merged-cnf.func.sh 125, cnf-one-key-per-fact.tst.sh 81.

### 3. Red controls, run on the plan's base in a scratch copy

Scratch: `git archive 07f34efeb` extracted to a `mktemp -d` dir under /tmp; runs as the push
user with `SPOOL_TEST=1` (the guard at `spool-env.inc.sh:371-382` refuses the live spool
root under it); every test writes only under its own mktemp dir; the one worktree copy-in
was restored (`git status` clean after). sha256sums at base (`git show 07f34efeb:<file> |
sha256sum`):

- `a64c16fa017405473fee04fe278b79b677e5305ca9db33c0ab944ffbbbba4576  csi-spl-orc/src/bash/run/spl-unanswered-sweep-install-cron.func.sh`
- `a02f465340f4262a68c53f6b8f48d4e1b7c7b7117123e215ca2bf8e0f17736ca  csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh`
- `3de28e8e19a4c0943e58845758735cd83b77afa6d0854f7ccdd8b71a4593b0f8  csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline`
- `cf62365076e38654b73f210410d4cd7e1f0976d44e5d6b934ef3d16585be7b36  csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh`
- `d54674d20d17f32642914b3cd981af524235bad289d0d100a23d004d419516e6  csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh`
- `ceca5a601ac7c035622fc43144920da64f7872ae51f212dde016ca1bb984d0af  csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh`
- `8c21f1feb9bfe559879738f47e82515409f7ed67e404acf186cf9fc6b4c24c7e  csi-spl-iac/src/bash/tests/cnf-one-key-per-fact.tst.sh`

- **Row 01, control A (the new section-10 case on the parent's site):** scratch + the new
  case inserted after `:280`, site unmodified:
  `SPOOL_TEST=1 bash csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh` -> rc **1**, 70 PASS
  + 1 FAIL, last line `unanswered-sweep: 1 failure(s)`; the FAIL line prints the hand form:
  `+* * * * * ENV=prd SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5 ... >> /var/<org>/<org>-<app>/unanswered-sweep/cron.out 2>&1 # <org>-<app>:unanswered-sweep`.
  Fails for the plan's reason (the default dir is still spelled by hand). With the site in
  1.3's shape (+ the `@param` at `:26`): rc **0**, 71 PASS, last line
  `unanswered-sweep: all passed`, new case
  `PASS: 10. default log dir: derived from SPL_VAR_APP_DIR, nothing written`.
- **Row 01, control B (satellite-ansible floor):** on a pristine base copy rc 0, 96 PASS,
  `n_sd` = 4 paths. On head (site changed) with the old floor `-ge 4`: rc **1**, 94 PASS,
  `FAIL: state dirs outside /var/<org>/<org>-<app>: ` (bad empty, so n_sd 3 < 4), last line
  `FAIL: 1 assertion(s) in satellite-ansible.tst.sh`. With `:272` moved to `-ge 3`: rc 0,
  96 PASS, `3 paths`.
- **Row 01, control C (spelled ratchet):** in this lane's worktree with the site copied in
  and the baseline NOT dropped:
  `SPOOL_TEST=1 bash csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh` -> rc **1**,
  `FAIL: tree: STALE baseline: csi-spl-orc/src/bash/run/spl-unanswered-sweep-install-cron.func.sh has none: drop its line`,
  last line `1 FAILED`. With baseline `:10` dropped: rc 0, `ALL PASS`, 15 PASS. (Both files
  restored from backup after; `git status` clean.)
- **Row 02 (the new section 4 on the parent's lib):** scratch + section 4 inserted before
  `:81`, lib unmodified:
  `SPOOL_TEST=1 bash csi-spl-iac/src/bash/tests/cnf-one-key-per-fact.tst.sh` -> rc **1**,
  9 PASS + 4 FAIL, last line `FAIL: 4 assertion(s) in cnf-one-key-per-fact.tst.sh`; each FAIL
  has `out ''` (no `rc=` line — the caller's shell was exited) and stderr
  `.../spl-merged-cnf.func.sh: line 58: <n>: <word>`. With the lib in 1.4's shape: rc **0**,
  14 PASS, last line `PASS: all`, the four `PASS: 4. do_spl_merged_cnf ...` lines. Direct
  probe `bash -c 'source <lib>; do_spl_merged_cnf "" dev X; echo "rc=$?"'`: on base prints
  `line 58: 1: cnf dir` and no `rc=` line; on head prints the usage line and `rc=1`.

None of the runs touched live state: scratch copies under /tmp, `SPOOL_TEST=1`, tests write
only their own mktemp dirs, and the dry-run case asserts the derived dir is not created.

### 4. Equivalence of each row

- Row 01: read at `:38-102` on base. The hand form and `spl_var_app_subdir logdir
  unanswered-sweep` print the same path on this box's 3 tree kinds, re-measured by me as
  the push user under `env -i PATH=/usr/bin:/bin`: the main checkout, the desk-cron
  checkout and this lane's worktree -> all `/var/<org>/<org>-<app>/unanswered-sweep`,
  **3 of 3 EQUAL**. With `SWEEP_CRON_LOG_DIR` set the new block is skipped
  (`logdir="${SWEEP_CRON_LOG_DIR:-}"` non-empty), so the existing section-10 cases pass
  unchanged (71 PASS on head). Exit codes: the only new rc is `return 1` when derivation
  fails, which cannot happen on this box (spl_run_paths resolves all 3 trees). Same output,
  same paths, same defaults; the controls above catch a difference in the printed crontab
  line, the baseline and the floor.
- Row 02: read at `:57-125` on base. With three non-empty arguments the 1.4 shape assigns
  the same `dir`/`env`/`out`, so behaviour is identical. Callers verified on origin/master:
  18 calls in `csi-spl-iac/src/bash/run` (16 `|| return 1` / `|| { ...; return 1; }`, 2
  `&&`/`if`: `put-github-app-key.func.sh:37`, `rotate-github-app-key.func.sh:27`) plus 4 in
  libs/make (`satellite.func.sh:36`, `lde-cnf.func.sh:67`, `spl-cloud-cnf.func.sh:263`,
  `spl-merged-cnf.func.mk:18`) — all pass non-empty args, so none reaches the changed path.
  The control (section 4, four forms) pins exactly the changed path. See N1.

### 5. Row fields (R2, R7, R1)

Both rows carry a control that fails today and passes after (section 3) and a test list
(row 01: the 4 files of its grep — `git grep -lE
'spl-unanswered-sweep-install-cron|do_spl_unanswered_sweep_install_cron' -- '*tests/*'` ->
4 — plus `satellite-ansible.tst.sh`, `bash-cleancode.tst.sh`, `do_check_pre_push`; row 02:
the 33 test files of its grep — `git grep -lE 'do_spl_merged_cnf|spl-merged-cnf' --
'*tests/*'` -> 33 — plus `bash-cleancode.tst.sh`, `do_check_pre_push`), vendor **claude**,
kind `simple_coding`, batch 1. No mistral coding or testing row. R7:
`BOX_PICK_KIND=grok ./run -a do_spl_box_pick` re-run by me -> `pick=hold ... grok weekly
99% on both boxes`, so each row takes the claude waiver seat (1a7c70da) — a cross-vendor /
waiver reviewer, never mistral. R1: the two batch-1 rows share no file (`comm -12` of the
two file lists -> 0; 6 distinct row paths).

### 6. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 row paths, comma-separated> --agent m-691`
-> **exit 4**, 15 `unknown:` lanes, all on the other box (rotate seats; spec 123 P05/L2;
spec 033 T025-T027; the WUI lanes; c-601; c-602). Per path individually: exit 4 on all 6, no
exit 3 — no live lane lists a row path. The unknown lanes' slugs name no row path; the b31
rows (`spl-spawn-review-notify.func.sh`, `spl-done-claim-check.func.sh` + their tests) and
the spec 123 / 033 / 143 lanes' listed files (terraform, rdb/store, WUI) touch none of the
6. Spawn queue at my read: 14 queued, 0 placing; none names a row path by slug. The holder's
re-check before placing is the one that counts (plan 2.2 says the same).

### 7. Inputs accounted for

Plan section 7 against `/var/spool-hub/dispatch/c002-next-round-candidates.md`
(refactor-shaped items only) and r79 section 7 — every refactor-shaped input is served or
accounted for:

- served, re-verified by me on origin/master: watchdog/rotate `/var/` literals (non-comment
  `git grep -nE '/var/'` -> 0); `reverse-tunnel-cron.sh:27` reads
  `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`; wf10
  `it also covers the downloaded archive` -> 0 hits (r79-01 `75da57eb4`);
  agent-boot-restore `:31` reads `default <SPL_VAR_APP_DIR>/agent-boot-restore
  (spl_run_paths)`; uplink-probe `:14-15` carries the corrected wording; tf-log-mask
  `${1:?}` -> 0 (r78-02 `ba7acd634`).
- accounted in section 7: `spl-desk-reply.sh:9,19` (measured: `task` is not a reply kind —
  `SPOOL_KINDS` lists 13 at `spool-env.inc.sh:138`, the reply action takes 12, not `task`;
  first candidate for r81); the other `${1:?}` lines (re-counted on base: iac lib+run 15
  lines in 7 files, orc lib+run 11 in 4 — matches 1.2; row 02 takes one file, the rest left
  out); `spl-spawn-place-argmax.tst.sh` s9, spec 182 L2, `ws-docs-head.mjs` (test/WUI rows);
  spec 011: 15 open tasks (`grep -cE '^\s*- \[ \]' tasks.md` -> 15), 0 commits since W.
  Nothing refactor-shaped is left unserved and unaccounted.
- Behaviour-change scan: row 01 changes no exit code, message, path or default on this box
  (3 of 3 same dir; the env-set path untouched; only the `@param` doc line). Row 02 changes
  the empty/missing-argument path only — see N1.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean
over the tracked tree`, exit 0.

## Defects

None. No W.

## Notes

- **N1:** row 02 does change an exit behaviour on the empty/missing-argument path: on base
  `${1:?}` exits the caller's shell (no rc), the row returns 1 with a usage line. It is
  confined to a path no caller takes (all 22 call sites pass non-empty args), it is the
  fail-safe developer guide 2.4.3 mandates, it is disclosed in plan 1.4 and pinned by the
  row's own control (section 4); r78-02 set the same precedent. Recorded, not a W.
- **N2:** counting conventions: the plan's "17 lines in 15 files" for the spelled baseline
  is 16 lines total (15 entries + 1 comment) in 15 files on base by my `wc -l` /
  `grep -cE '^[0-9]'`; the delta the row makes (-1 entry, -1 file, `:10`) is exact. Same
  for cnf-one-key-per-fact: my red run counts 9 PASS + 4 FAIL (plan 1.5 says 10 pass before);
  the green run is 14 PASS `PASS: all` as the plan says. No plan change needed.
- **N3:** lane map exit 4 (15 unknown lanes at my read, down from 19 at the plan's 05:22Z
  read) — none on a row path by slug; the holder re-checks before placing.

## State history

- 2026-11-21T05:47Z commit on `review/c002-refactor-round-80-mistral-seat`: full review of
  `7329be64194f2eb72715b4b5f9f3f9e606afc2c4` (checks 1-8 above), verdict PASS, notes N1-N3.
- 2026-11-21T06:14Z rotation note from c-001 (task `lane-rotate-m-691`, msg
  `4d3918ae-2ab4-428e-a72b-657699f5290e`, rotation at 06:28Z UTC): everything green was
  already pushed (`PUSH_CMD=status` -> `PUSHED bc9b18189... landed_rc=0`); this entry is
  the state write. Inbox at my read: only that note. Planner branch still at v0.1
  `7329be64194f2eb72715b4b5f9f3f9e606afc2c4` (ls-remote); no v1.0 named yet. Verdict
  delivered to c-680 (msg `3900b82c`) and c-002 (msg `7ec0125e`) on task
  `dispatch-refactor-r80` in the `review:` line form. Waiting on: a v1.0 sha on
  `review/c002-refactor-round-80-planner` (then re-verify, sign as a second commit in this
  file, re-push, re-report) or a message starting with ACCEPTED (then `/exit-clean`). Lease
  holder at my read: c-002@sat.

Seed STEP 0: read `csi-spl-doc/doc/md/developer-guide.md`, then
`cd csi-spl-orc && sudo -u <push user> env AGENT_ID=m-691 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
-> `ACK m-691 read developer-guide.md blob 8b1916cdc5d75c52cc4b3248babef398acf1366b`.
Read whole this session: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
`csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-5), the plan at `7329be641`,
`csi-spl-doc/doc/md/refactor-round-79-plan.md` (origin/master),
`/var/spool-hub/dispatch/c002-next-round-candidates.md`, both r80 briefs, the r79 seat
file on `review/c002-refactor-round-79-mistral-seat` (form), and the row site files at
`07f34efeb` via `git show`.
