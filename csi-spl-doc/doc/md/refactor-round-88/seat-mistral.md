# Refactor round 88 — panel seat mistral (m-172@<box>)

Issue: SPL-6237 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-88-mistral-panel-seat.md`.

Review target: `csi-spl-doc/doc/md/refactor-round-88-plan.md` on branch
`review/c002-refactor-round-88-planner` at v0.1
**`9707b20aef107556ce601ea34fe4d6edf09f98cd`**.

- `git ls-remote origin refs/heads/review/c002-refactor-round-88-planner` ->
  `9707b20aef107556ce601ea34fe4d6edf09f98cd` (head == the sha the holder relayed,
  msg f1af5d0c on dispatch-refactor-r88).
- `git show 9707b20ae --stat --format='%H %cI %s'` -> one file,
  `csi-spl-doc/doc/md/refactor-round-88-plan.md` +413, subject
  `docs(r88-plan, SPL-6237): refactor round 88 plan v0.1: one claude project slug helper, 2 rows`.
- The plan's measured base is `8d7782cc3`; `git merge-base --is-ancestor 8d7782cc3
  origin/master` -> rc 0 (base is on trunk; origin/master at review time
  `5258ae91f`, HEAD of this worktree `2513d45d9`).
- Every file:line cited below was checked with `git show <sha>:<file> | sed -n <N>p`.

**Verdict: PASS on v0.1 `9707b20aef107556ce601ea34fe4d6edf09f98cd`. No W defects.**

## 1. Slug r88 unused since the plan's W

- W: `git log origin/master -1 --format='%h %cI' -E --grep='^docs\(r87-plan'` ->
  `6f7654718 2026-11-22T08:58:17+01:00` — the same W the plan records.
- `git log origin/master --since="2026-11-22T08:58:17+01:00" --oneline -E --grep='\(r88-' | wc -l`
  -> **0**; over all history -> **0**.
- `git ls-remote origin | grep -E 'r88-[0-9]{2}|refactor-round-88'` -> only
  `9707b20aef...  refs/heads/review/c002-refactor-round-88-planner` (the planner's;
  this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r88-[0-9]{2}|refactor-round-88'` ->
  exactly `c002-refactor-round-88-planner.md` and
  `c002-refactor-round-88-mistral-panel-seat.md` (the two expected).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-88`
  -> **0** (the plain name is free on trunk).

## 2. Every row site file:line exists on base and on origin/master

Row paths (6): `orc:lib/bash/funcs/spl-claude-project-slug.func.sh` (new),
`orc:src/bash/run/spl-lane-handover.func.sh`,
`orc:src/bash/run/spl-agent-identity-restore.func.sh`,
`orc:src/bash/run/spl-agent-login-check.func.sh`,
`orc:src/bash/tests/spl-claude-project-slug.tst.sh` (new),
`orc:src/bash/run/spl-rotate-lib.func.sh` (`orc:` = `csi-spl-orc/`).

- `git diff --name-only 8d7782cc3 origin/master -- <the 6 paths>` -> **empty**: no drift.
- `git cat-file -e 8d7782cc3:csi-spl-orc/lib/bash/funcs/spl-claude-project-slug.func.sh`
  -> rc 128 "does not exist"; same for `.../tests/spl-claude-project-slug.tst.sh` —
  expected, the rows create them.
- Cited lines read at `8d7782cc3` and re-read at `origin/master`, all **SAME**:
  - `spl-lane-handover.func.sh:81` (PLAN line, calls `spl_handover_slug "$newwt"`),
    `:121` (`spl_handover_on ... "$(spl_handover_slug "$newwt")" ...`), `:152`
    (`slug="$(spl_handover_slug "$wt")"`), `:176` (comment), `:177`
    (`spl_handover_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }`).
  - `spl-agent-identity-restore.func.sh:372`:
    `slug="$(printf '%s' "$3" | sed 's/[^A-Za-z0-9]/-/g')"`.
  - `spl-agent-login-check.func.sh:439`: `slug="$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")"`.
  - `spl-rotate-lib.func.sh:1424` (`[[ "$sid" =~ ^[0-9a-f-]{36}$ && -n "$wt" ]] || return 0`),
    `:1425` (`echo "$ROTATE_AGENT_HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")/$sid.jsonl"`).
- `git grep -n "s/\[^A-Za-z0-9\]/-/g" 8d7782cc3 -- csi-spl-orc/src csi-spl-iac/src csi-spl-utl/src src | grep -v '/tests/'`
  -> exactly **6 lines**: the 5 orc run files above plus
  `spool-install/steps/claude-memory.inc.sh:9` — as the plan's 1.2 (a) says, and the
  same 5 r87 section 7 named (read on origin/master).
- `git grep -n spl_handover_slug 8d7782cc3` -> the 4 lines of
  `spl-lane-handover.func.sh` (:81,:121,:152,:176,:177) and r87 plan section 7 only.
- `wc -l` at base: handover 301, identity-restore 406, login-check 527, rotate-lib
  2007 — as the plan says.
- Alone-sourcing reads at base: `git grep -nE 'source .*spl-lane-handover\.func\.sh|\. .*spl-lane-handover\.func\.sh'`
  -> no line (handover is sourced alone nowhere, as 1.3 says);
  login-check is sourced by `spl-watchdog.func.sh:86`, `spl-agent-login-proof.func.sh:39`,
  `spl-claude-login-mode.func.sh:44`, `spl-dispatch-lease.func.sh:2721`,
  `wd-login-snapshot.tst.sh:52`; identity-restore by `spl-agent-boot-restore.func.sh:37`
  and the identity-restore tests; rotate-lib by `agent-id-reap.sh:89`,
  `spl-agent-identity-restore.func.sh:87`, `spl-dispatch-rotate.func.sh:87`,
  `spl-gc.func.sh:76`, `spl-lane-restart.func.sh:47`, `spl-lane-rotate.func.sh:77`,
  `spl-orch-rotate.func.sh:79`, `test-agent-identity-restore-box-socket.sh:83`.
- The guard pattern cited: `git show 8d7782cc3:.../deploy-hosted-site.func.sh | sed -n '35p'`
  -> `declare -F spl_cnf_path_expand >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-run-paths.func.sh"`
  — the same shape the rows use. `test-lib.inc.sh:75` sources every
  `lib/bash/funcs/*.func.sh`; `run.sh:849` is the lazy-loader guard comment
  `run-lazy-loader.tst.sh` names.

## 3. Red controls, run on the plan's base in scratch copies

Base scratch copy: `git archive 8d7782cc3` (csi-spl-orc tree) into `/tmp/r88-review-I0Vx/csi-spl-orc`;
verified byte-identical to `8d7782cc3` on the 5 checked files (sha256 match:
handover `4ab30ad5...`, identity-restore `d779351e...`, login-check `9129d9e4...`,
rotate-lib `5fb4e2f6...`, test-lib `9e92bb8a...`). Heads built per the plan's
1.3/1.4 shape: head1 = base + row 01, head2 = head1 + row 02, head1-noguard =
head1 with the guard line deleted from login-check. Run-file line counts match the
plan exactly: 301->298 (handover), 406->407 (identity-restore), 527->528
(login-check), 2007->2008 (rotate-lib).

Control files hashed (constructed heads, not committed anywhere):
- head1 `spl-claude-project-slug.tst.sh` sha256
  `ffad3b64a56085a426f1dfe911d580caed6654d1503f8cda85dd2a1b8cfecfb0`
- head2 `spl-claude-project-slug.tst.sh` sha256
  `ce285f7d50cd7242ef298723d3ccfc951ea31599008a39931c8f1fd8c72fdd17`
- head1 helper `spl-claude-project-slug.func.sh` sha256
  `96612792611e34639c482a3ac234c021a27321a67be9195291c26778822b8b1e`

Five runs, n=1 each, `SPOOL_TEST=1`, all in /tmp scratch copies, nothing committed,
no live state touched:

- **Row 01 red** (head1's tst in a copy of base): rc **1**, last lines
  `FAIL: 1. .../lib/bash/funcs/spl-claude-project-slug.func.sh: No such file or directory; spl_claude_project_slug: command not found`,
  `FAIL: 3. want 'spl-dispatch-lease.func.sh spl-rotate-lib.func.sh ' got 'spl-agent-identity-restore.func.sh spl-agent-login-check.func.sh spl-dispatch-lease.func.sh spl-lane-handover.func.sh spl-rotate-lib.func.sh '`,
  `--- spl-claude-project-slug: 1/3 passed, 2 FAILED` — byte-identical to the plan's
  1.5 quote (2 FAILED, cases 1 and 3).
- **Row 01 green** (head1's tst in head1): rc **0**, `3/3 passed, 0 FAILED`, `ALL PASS`.
- **Row 01 guard red** (head1's tst in head1-noguard): rc **1**,
  `FAIL: 2. guard rc=1: .../spl-agent-login-check.func.sh: line 439: spl_claude_project_slug: command not found`
  + `its transcript 00000000-0000-4000-8000-000000000000 is not in the agent user's home`,
  `2/3 passed, 1 FAILED` — matches the plan's guard quote.
- **Row 02 red** (head2's tst in head1): rc **1**,
  `FAIL: 3. want 'spl-dispatch-lease.func.sh ' got 'spl-dispatch-lease.func.sh spl-rotate-lib.func.sh '`,
  `2/3 passed, 1 FAILED` — matches the plan's 1.5 quote.
- **Row 02 green** (head2's tst in head2): rc **0**, `3/3 passed, 0 FAILED`, `ALL PASS`.

All controls fail for the plan's reason (the helper missing / the guard missing /
the copy list not shrunk), not for an environment reason.

## 4. Equivalence of each row

- The helper's body is `spl_handover_slug`'s byte for byte (diff of head1 vs base:
  only the function name differs on the definition line).
- 8-path probe, run now, `LANG=C.UTF-8`: `printf '%s' X | sed`, `sed <<<X`,
  `printf "%s" X | sed "..."` and `spl_claude_project_slug X` over a worktree path,
  `/a b/c_d.e`, a non-ASCII string, `/_._`, the empty string, an embedded newline,
  a leading dash, a double slash -> **8 cases, 0 differ** (matches the plan's 1.3).
- The guards sit inside the functions (the head diff shows the guard line replacing
  :372 / :439 / :1425 inside `_ai_copy_transcript`, `_lc_restorable`,
  `spl_rotate_transcript`), so neither file gains top-level code; the three call
  sites swap only the function name. No row changes an exit code, a message, a path
  or a default.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after
(reproduced in check 3), a test list, box `either`, vendor `claude`, kind
`simple_coding`, batches 1 and 2. Test lists re-grepped at base: handover -> the 4
`spl-lane-handover*.tst.sh`; identity-restore -> the 6 `test-agent-identity-restore*.sh`
+ `test-agent-name-shape.sh`; login-check -> `spl-agent-login-check.tst.sh`,
`wd-login-snapshot.tst.sh`, `run-eager-files.tst.sh`; rotate-lib -> 20+ files (grep
counts 21 incl. `orc-shard-weights.txt`, which takes `* 10` at :12, so needs no
line). `spl_claude_project_slug` has 0 hits at base (name unique).
No mistral coding or testing row (owner 10-17, t1 b61851fb). R7 (plan section 4):
a grok pick or a fresh claude waiver seat, never a mistral code R7 — compliant.
Re-run now: `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=<box>` (both boxes
above the high mark; the plan recorded `pick=<box>` at 09:01:51Z when sat was 51%);
the holder re-runs the pick at placement. R1: each batch holds one row, so no file
is shared within a batch; the new tst is shared across batches, serialised (R1
allows that). 2 rows, within 5.1's aim 2 / at most 3.

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 paths, comma-separated> --agent m-172`
-> **exit 4**: no live lane lists any row path; 10 live lanes record no files, all
on <box>: c-063, c-146, c-286, c-346, c-806, c-812, c-924, c-927, g-079, g-251.
Named lanes: c-806@<box> (SPL-6182) is in the unknown list and its brief names hub
auth/store/`cmd/spool` — no row path; c-346's brief names
`spl-dispatch-lease.func.sh` (left out of the rows, correctly); c-120@<box>
(SPL-6234, `lane-map.tst.sh`), c-107@<box> (spec 162 T4), c-054@<box> (spec 154 B7),
c-033@<box> (spec 123 L3w) record files and none is a row path (exit 4 proves it).
`do_spl_spawn_queue` now -> `0 queued, 0 placing` (the queued evlog dup-message bug
922b5c35 named `hub/evlog.go`, `hub/evlog_test.go` — no row path). Briefs of the
last 24 h (138) naming a row file/function: **0**. Commits in the last 24 h on the
6 paths: **0**. Of the 96 recent remote branches, `git diff --name-only
<merge-base> <b> -- <the 4 existing row files>` -> **0 hits**. No row file is
touched by any live or queued lane.

## 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` read directly (114 lines).
  Refactor-shaped items, re-verified on origin/master: the literal-`/var`
  candidates are served — `git grep -n 'LOGIN_STATE_DIR:-' origin/master --
  spl-watchdog.func.sh spl-lane-rotate.func.sh` -> 0 hits;
  `reverse-tunnel-cron.sh:27` reads `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`;
  no `agent-boot-restore` `/var` literal in the watchdog or the boot-restore cron
  (the only `/var/` there is the `${SPOOL_ROOT:-/var/spool-hub}` default at :134,
  the owner-decided spool-root exception). `spl-desk-reply.sh:9,19` list all the
  kinds `feature|bug|alert|question|idea|decision|docs` (SPL-6107 N1 served). The
  `spl-lane-mix.func.sh` agy words stay gated on SPL-6174:
  `git merge-base --is-ancestor 473495da4 origin/master` -> rc 1 (unlanded), and
  the plan's section 7 accounts them. The `!inserted` loop-fire branch and the
  `_ppe_keys` e2e selector are a test row and a gate-design item, named in the
  plan's section 7. **No refactor-shaped input is neither served nor accounted for.**
- r87 plan section 7 read on origin/master: its claude-slug row names exactly the 5
  sites r88 rows 01/02 serve (plus dispatch-lease, left out with c-346 named).
- Bug-row scan: no row changes an exit code, a message, a path or a default
  (check 4).

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-172`,
rc **0**.

## Defects

None (no W1...).

## Notes

- **N1** the lane map exits 4 on all 6 row paths; the 10 unknown-scope lanes are
  all on <box> (the plan saw 12 at 08:56Z) — same result class, no owner of any row
  path; the row lanes re-run R3 at spawn.
- **N2** head2's 1.5 column and `iac:.../run-lazy-loader.tst.sh` are NOT RUN in v0.1
  (the plan says so in 1.5 and section 8); they go into v0.2 and this seat re-reads
  the delta then.
- **N3** the plan's 1.4 lists 6 alone-sourcers of `spl-rotate-lib.func.sh`; there
  are 8 source lines (also `spl-lane-rotate.func.sh:77`, `spl-orch-rotate.func.sh:79`)
  — the guard conclusion holds regardless.
- **N4** the head control files were constructed per the plan's 1.3/1.4 shape (the
  heads are not committed anywhere); their sha256s are in check 3 and the failure
  outputs are byte-identical to the plan's 1.5 quotes. The constructed helper/test
  files follow the plan's described shape; the run-file line counts match the plan
  exactly (298/407/528/2008).
- **N5** the grok box pick now returns <box> (both boxes above the high mark); the
  plan recorded <box> at 09:01:51Z — either way a grok R7 seat, never mistral.
