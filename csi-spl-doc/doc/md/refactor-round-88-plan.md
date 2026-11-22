# Refactoring round 88 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6237  
Topic: cc8f7f05-6eba-4ced-81be-3314a2288b85  
Discussion: cc8f7f05-6eba-4ced-81be-3314a2288b85 (t1 #refactoring, "Refactor round 88", opened by c-002 08:07Z)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r88**, plan `refactor-round-88-plan.md`, rows `r88-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 87 ([refactor-round-87-plan.md](refactor-round-87-plan.md))
is closed: both rows landed (r87-01 `fa86b70d7`, r87-02 `a42fff43c`; close record
`6f7654718`). The perf floor (rulebook 4.4), measured by the holder on `d4c869b1a`: perf
29, refactor 112, 5 x 29 = 145 >= 141, floor met, so this is a refactor round.

Both rows serve the first input of the brief, r87 section 7's "the claude project slug
inline in 5 more orc files": **one fact, one copy** (developer guide 2.2.4). Claude Code
keeps a session's transcript under `~/.claude/projects/<slug>/`, the slug being the cwd
with every character that is not a letter or a digit made a dash. Five files of the orc
`src/bash/run` tree spell that rule as their own `sed`. **Row 01** adds one helper,
`spl_claude_project_slug` in a new `orc:lib/bash/funcs/spl-claude-project-slug.func.sh`,
points three of the files at it (one of them, `spl-lane-handover.func.sh`, loses its own
copy `spl_handover_slug`) and adds a test whose count gate lists the copies left.
**Row 02** (batch 2: it edits row 01's test) points the fourth, `spl-rotate-lib.func.sh`,
at it and shrinks the list. The fifth (`spl-dispatch-lease.func.sh:2385`) stays: it is
inside a `bash -c` string run as another user, and a live lane holds that file (2.2).

**Status: v1.0**, for the panel's signature (section 4). Editor: **c-170** (claude).
v0.2 added head2's test column and `run-lazy-loader.tst.sh` (1.5); v1.0 folds the panel's
N3 and N5 (section 8); nothing is open.

**One sha:** every count is measured on **`8d7782cc3`** (`origin/master` at
2026-11-22T08:55Z), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. The tests of 1.5 were run on scratch copies of that sha
(`git archive 8d7782cc3`, `csi-spl-wui` left out): "base" is the copy unmodified;
"head1" is base with row 01 applied in 1.3's shape, "head2" is head1 with row 02 applied
in 1.4's shape; each red control puts only the head's test file into a copy of the
row's parent. Nothing of it is committed. Queue, lane map, brief and branch reads are
live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-22T08:55Z, n=1:

- **Window: W=2026-11-22T08:58:17+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r87-plan'`: `6f7654718`, the
  r87 close record. (The brief quotes `2026-11-22T05:11:40+01:00`, `c24e47b1c`, read at
  07:5xZ on `d4c869b1a`; the close record landed after that read. Either W gives the
  same results below.)
- `git log origin/master --since="$W" --oneline -E --grep='\(r88-'` -> **0**; over all
  history -> **0**.
- `git ls-remote origin 'refs/heads/review/r88-*' 'refs/heads/*-r88-*' 'refs/heads/*refactor-round-88*' 'refs/heads/wip/*r88*'`
  -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r88|refactor-round-88'` -> this plan's
  brief and the panel seat's (`c002-refactor-round-88-mistral-panel-seat.md`), no other.
- `ls csi-spl-doc/doc/md | grep -c refactor-round-88` -> 0 before v0.1: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) r87 section 7:** re-read on `8d7782cc3`.
  - The claude project slug: `git grep -n "s/\[^A-Za-z0-9\]/-/g"` over the orc / iac /
    utl / root `src` trees, tests left out -> 6 lines: the 5 orc run files r87 named
    (same lines: `spl-agent-identity-restore.func.sh:372`,
    `spl-agent-login-check.func.sh:439`, `spl-dispatch-lease.func.sh:2385`,
    `spl-lane-handover.func.sh:177`, `spl-rotate-lib.func.sh:1425`) and r87-02's
    `spool-install/steps/claude-memory.inc.sh:9`. **Rows 01 and 02** (1.3, 1.4).
  - Every other r87 section 7 item stays out for its reason there (section 7).
- **(b) R7 and panel notes:** r87-01 (g-118) and r87-02 (g-273) carry no N note (r87
  close record); the r87 panel's N1-N5 (`refactor-round-87/seat-mistral.md`) name process
  points, no row.
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  114 lines, read 08:5xZ), its refactor-shaped items:
  - the literal `/var` paths of `spl-watchdog.func.sh` / `spl-lane-rotate.func.sh`
    (`LOGIN_STATE_DIR`), `reverse-tunnel-cron.sh` and the agent-boot-restore dir: served
    (`git grep -n 'LOGIN_STATE_DIR:-'` on the two files -> 0;
    `reverse-tunnel-cron.sh:27` reads `$SPL_VAR_APP_DIR/reverse-tunnel`;
    `spl-agent-boot-restore-install-cron.func.sh` carries no `/var/` literal).
  - `spl-desk-reply.sh:9,19` usage text (SPL-6107 N1): served, both lines list the kinds
    `feature|bug|alert|question|idea|decision|docs`.
  - `spl-lane-mix.func.sh` agy words: still gated on SPL-6174 (r87 N3).
  - the `!inserted` loop-fire test and the e2e selector `_ppe_keys`: a test row and a
    gate-design item, not this round's.
- **(d) spec 011 tasks:** `git log origin/master --since="$W" --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks are those of r87
  section 7.

### 1.3 Row 01's sites: one helper, three files point at it

`orc:` = `csi-spl-orc/`. On `8d7782cc3`:

- `orc:src/bash/run/spl-lane-handover.func.sh:176-177`: the comment and
  `spl_handover_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }`; its 3 calls
  `:81` (the dry-run PLAN line), `:121` (`spl_handover_live`), `:152`
  (`spl_handover_pick_mode`). `git grep -n spl_handover_slug` over the repo -> those 4
  lines and r87 plan's section 7 only.
- `orc:src/bash/run/spl-agent-identity-restore.func.sh:372` (`_ai_copy_transcript`):
  `slug="$(printf '%s' "$3" | sed 's/[^A-Za-z0-9]/-/g')"`.
- `orc:src/bash/run/spl-agent-login-check.func.sh:439` (`_lc_restorable`):
  `slug="$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")"`.

Who loads these files: `./run` (the lazy loader indexes `lib/bash/funcs/` too, so a
helper there is found by name) and the orc test runner `in_orc`
(`tests/test-lib.inc.sh:75`, sources every `lib/bash/funcs/*.func.sh`). But
`spl-agent-identity-restore.func.sh` is also sourced alone, by four identity-restore
tests (`test-agent-identity-restore{,-grok,-mistral,-user}.sh`) and by
`spl-agent-boot-restore.func.sh:37`; `spl-agent-login-check.func.sh` by
`spl-watchdog.func.sh:86`, `spl-agent-login-proof.func.sh:39`,
`spl-claude-login-mode.func.sh:44`, `spl-dispatch-lease.func.sh:2721` and
`wd-login-snapshot.tst.sh:52`. So those two files load the helper themselves, with the
guard the run files already use for `lib/bash/funcs/spl-run-paths.func.sh` (e.g.
`deploy-hosted-site.func.sh:35`), placed inside the function, so neither file gains top
level code (the lazy loader keeps a file of only function definitions lazy;
`run-eager-files.tst.sh`). `spl-lane-handover.func.sh` is sourced alone nowhere
(`git grep -n 'spl-lane-handover.func.sh'` -> no `source` / `.` line), so it calls the
helper with no guard.

Shape (built as head1 of 1.5):
- New `orc:lib/bash/funcs/spl-claude-project-slug.func.sh` (11 lines, sourced, no exec
  bit, as `spl-run-paths.func.sh` is `100644`): a 7-line header and
  `spl_claude_project_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }`, the
  body of `spl_handover_slug` unchanged.
- `spl-lane-handover.func.sh`: `:176-177` and the blank line after go; `:81,121,152`
  call `spl_claude_project_slug`. 301 -> 298 lines.
- `spl-agent-identity-restore.func.sh:372` and `spl-agent-login-check.func.sh:439`: each
  becomes two lines,
  `declare -F spl_claude_project_slug >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-claude-project-slug.func.sh"`
  then `slug="$(spl_claude_project_slug "<the same arg>")"`. 406 -> 407, 527 -> 528.
- New test `orc:src/bash/tests/spl-claude-project-slug.tst.sh` (39 lines, exec bit,
  `test-lib.inc.sh`): case 1 the helper maps `/opt/csi/csi-spl-wt/c-170` and
  `/a b/c_d.e`; case 2 `spl-agent-login-check.func.sh`, sourced alone, runs
  `_lc_restorable` on a sandbox home and finds the transcript by the slug (the guard
  works, the helper was not preloaded); case 3 the `src/bash/run/*.func.sh` files that
  still carry `s/[^A-Za-z0-9]/-/g` are exactly the list
  `spl-dispatch-lease.func.sh spl-rotate-lib.func.sh` (it only shrinks).

**Behaviour:** the helper's body is `spl_handover_slug`'s byte for byte. The three
inline forms (`printf '%s' X | sed`, `sed <<<X`, and the `"..."` quoted sed of
dispatch-lease) and the helper give the same output on 8 paths (a worktree path, a
space, a non-ASCII letter, `_` and `.`, the empty string, an embedded newline, a leading
dash, a double slash): **8 cases, 0 differ** (08:5xZ, n=1, `LANG=C.UTF-8`; the
herestring's trailing newline is stripped by `$( )` in every caller).

### 1.4 Row 02's site: the rotation transcript path

`orc:src/bash/run/spl-rotate-lib.func.sh:1425` (`spl_rotate_transcript`):
`echo "$ROTATE_AGENT_HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")/$sid.jsonl"`.
The file is sourced alone (`git grep -nE '(source|\.) .*spl-rotate-lib\.func\.sh'
8d7782cc3`, `.md` left out, comments and a `grep -q` line dropped; panel N3) by
`agent-id-reap.sh:89` (outside `./run`), by 11 orc run files
(`spl-agent-identity-restore.func.sh:87`, `spl-dispatch-rotate.func.sh:87`,
`spl-gc.func.sh:76`, `spl-lane-restart.func.sh:47`, `spl-lane-rotate.func.sh:77`,
`spl-orch-rotate.func.sh:79`, `spl-peer-restart.func.sh:44`,
`spl-role-failover.func.sh:71`, `spl-rotate-status.func.sh:14`,
`spl-watchdog.func.sh:80`, `spl-wd-inst-start.func.sh:26`) and by 18 test lines
(`test-agent-identity-restore-box-socket.sh:83` and 17 in 13 `src/bash/tests` files, all
in 1.5's column), so it takes the same guard. v0.1 listed 6 of them; the guard
conclusion is the same.

Shape (built as head2 of 1.5, on head1):
- `:1425` becomes the guard line (after `:1424`'s `|| return 0`) and
  `echo "$ROTATE_AGENT_HOME/.claude/projects/$(spl_claude_project_slug "$wt")/$sid.jsonl"`.
  2007 -> 2008 lines.
- `spl-claude-project-slug.tst.sh` case 3: the list becomes `spl-dispatch-lease.func.sh`.

### 1.5 Before and on the rows' heads

2026-11-22T09:0xZ-09:4xZ, n=1, `SPOOL_TEST=1`, one suite at a time (`timeout 900`
each); pass lines `grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`.

Read from the run log (one row per file; "=" means the head equals base: same rc, pass
and fail counts). head2's column: 20 suites at 09:2xZ-09:4xZ, the other 15
(`agent-restart.tst.sh` down) re-run at 09:5xZ-10:04Z after the lane's rotation stopped
the first run, and `run-lazy-loader.tst.sh` at 10:0xZ; every one equals base (the new
test is absent on base: its red control is below).

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-claude-project-slug.tst.sh` (new) | 01, 02 | absent (red control: 1.5 below) | 0 / 3 / 0 | 0 / 3 / 0 |
| `spl-lane-handover.tst.sh` | 01 | 0 / 20 / 0 | = | = |
| `spl-lane-handover-agy.tst.sh` | 01 | 0 / 27 / 0 | = | = |
| `spl-lane-handover-mistral.tst.sh` | 01 | 0 / 22 / 0 | = | = |
| `spl-lane-handover-wip.tst.sh` | 01 | 0 / 16 / 0 | = | = |
| `spl-agent-login-check.tst.sh` | 01 | 0 / 57 / 0 | = | = |
| `wd-login-snapshot.tst.sh` | 01 | 0 / 14 / 0 | = | = |
| `run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `func-name-unique.tst.sh` | 01 | 0 / 2 / 0 | = | = |
| `no-literal-paths.tst.sh` | 01 | 1 / 13 / 2 | = | = |
| `test-agent-identity-restore.sh` | 01 | 0 / 34 / 0 | = | = |
| `test-agent-identity-restore-grok.sh` | 01 | 0 / 17 / 0 | = | = |
| `test-agent-identity-restore-mistral.sh` | 01 | 0 / 25 / 0 | = | = |
| `test-agent-identity-restore-once.sh` | 01 | 0 / 28 / 0 | = | = |
| `test-agent-identity-restore-user.sh` | 01 | 0 / 13 / 0 | = | = |
| `test-agent-identity-restore-box-socket.sh` | 01, 02 | 0 / 27 / 0 | = | = |
| `test-agent-name-shape.sh` | 01, 02 | 0 / 35 / 0 | = | = |
| `test-poke-retiring-pane.sh` | 02 | 0 / 7 / 0 | = | = |
| `test-seed-truth-first.sh` | 02 | 0 / 42 / 0 | = | = |
| `agent-id-lock.tst.sh` | 02 | 0 / 25 / 0 | = | = |
| `agent-restart.tst.sh` | 02 | 0 / 89 / 0 | = | = |
| `dispatch-rotate.tst.sh` | 02 | 0 / 203 / 0 | = | = |
| `dispatch-setup-check.tst.sh` | 02 | 0 / 95 / 0 | = | = |
| `kill-target-guard.tst.sh` | 02 | 0 / 112 / 0 | = | = |
| `lane-rotate-role-seats.tst.sh` | 02 | 0 / 15 / 0 | = | = |
| `lane-rotate.tst.sh` | 02 | 0 / 164 / 0 | = | = |
| `orch-rotate.tst.sh` | 02 | 0 / 196 / 0 | = | = |
| `rotate-ack-seen.tst.sh` | 02 | 0 / 9 / 0 | = | = |
| `rotate-alert-streak-role.tst.sh` | 02 | 0 / 6 / 0 | = | = |
| `rotate-open-takes.tst.sh` | 02 | 0 / 16 / 0 | = | = |
| `rotate-stalled.tst.sh` | 02 | 0 / 12 / 0 | = | = |
| `rotate-weekly-first.tst.sh` | 02 | 0 / 13 / 0 | = | = |
| `rotate-workdir.tst.sh` | 02 | 0 / 21 / 0 | = | = |
| `wd-restart-seed-stable-paths.tst.sh` | 02 | 0 / 6 / 1 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 1 / 13 / 1 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |

The reds of base are the scratch copy's, equal on base and head1, not the rows':
`bash-cleancode.tst.sh` `FAIL: CONTROL: the walk does not list
csi-spl-wui/src/docker/wui-config.sh` (the copy leaves `csi-spl-wui` out);
`no-literal-paths.tst.sh` `STALE baseline: .../spl-file-erase.func.sh` and
`.../spl-m3-e2e.func.sh has none` (the copy carries no git; unchecked why it reads them
so). `wd-restart-seed-stable-paths.tst.sh`'s fail count is its own `fails=0` line, rc 0.
The row lanes run both gates in their worktree. `iac:src/bash/tests/run-lazy-loader.tst.sh`
(the loader guard `run.sh:849` names; v0.1's column looked for it under orc) ran in v0.2
at 10:0xZ on base, head1 and head2: rc 0, 30 pass lines, 0 fail, `all checks passed` on
each (n=1).

**Red controls** (n=1 each):
- Row 01: head1's `spl-claude-project-slug.tst.sh` on base: rc 1, `2 FAILED`: case 1
  `.../lib/bash/funcs/spl-claude-project-slug.func.sh: No such file or directory`,
  `spl_claude_project_slug: command not found`; case 3 `want 'spl-dispatch-lease.func.sh
  spl-rotate-lib.func.sh ', got 'spl-agent-identity-restore.func.sh
  spl-agent-login-check.func.sh spl-dispatch-lease.func.sh spl-lane-handover.func.sh
  spl-rotate-lib.func.sh '`; then head1: rc 0, `ALL PASS`.
- Row 01's guard: head1 with the guard line deleted from `spl-agent-login-check.func.sh`:
  rc 1, case 2 `spl-agent-login-check.func.sh: line 439: spl_claude_project_slug:
  command not found` / `its transcript 0000 is not in the agent user's home`.
- Row 02: head2's test on head1: rc 1, `1 FAILED`, case 3 `want
  'spl-dispatch-lease.func.sh ', got 'spl-dispatch-lease.func.sh spl-rotate-lib.func.sh '`;
  then head2: rc 0, `ALL PASS`.

`shellcheck -S warning -x` on the 6 files of head2: 0 findings (base's 4: 0).

The tests that name the sites (R2): `git grep -lE` over the orc / iac tests for
`spl-lane-handover|spl_handover_slug|do_spl_lane_handover` -> the 4
`spl-lane-handover*.tst.sh`; `spl-agent-identity-restore|_ai_copy_transcript` -> the 6
`test-agent-identity-restore*.sh` and `test-agent-name-shape.sh`;
`spl-agent-login-check|spl_lc_` -> `spl-agent-login-check.tst.sh`,
`wd-login-snapshot.tst.sh`, `run-eager-files.tst.sh`; `spl-rotate-lib|spl_rotate_transcript`
-> 20 files (row 02's rows of the table). Plus the loader and name gates
`iac:src/bash/tests/run-lazy-loader.tst.sh`, `func-name-unique.tst.sh`,
`no-literal-paths.tst.sh` and iac's `bash-cleancode.tst.sh`. `orc-shard-weights.txt`
needs no line: a new file takes `* 10`.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r88-01-orc-one-claude-project-slug)` | one fact, one copy (developer guide 2.2.4) | 5 orc run files spell Claude Code's project slug rule as their own `sed`; `spl-lane-handover.func.sh` has a named copy (1.3) | `orc:lib/bash/funcs/spl-claude-project-slug.func.sh` (new)<br>`orc:src/bash/run/spl-lane-handover.func.sh:81,121,152,176-177`<br>`orc:src/bash/run/spl-agent-identity-restore.func.sh:372`<br>`orc:src/bash/run/spl-agent-login-check.func.sh:439`<br>`orc:src/bash/tests/spl-claude-project-slug.tst.sh` (new) | 5 inline copies -> 2 (+1 helper) | 1.3's shape. **Red control:** the new test on the parent FAILs cases 1 and 3 (1.5), then GREEN; outputs in the body. **Behaviour:** 1.3's 8-path probe, 0 differ; the row's column passes on parent and head with the same counts. Tests: `spl-claude-project-slug.tst.sh`, the 4 `spl-lane-handover*.tst.sh`, the 6 `test-agent-identity-restore*.sh`, `test-agent-name-shape.sh`, `spl-agent-login-check.tst.sh`, `wd-login-snapshot.tst.sh`, `run-eager-files.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `func-name-unique.tst.sh`, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r88-02-orc-rotate-claude-project-slug)` | one fact, one copy (developer guide 2.2.4) | the rotation's transcript path spells the slug again (1.4) | `orc:src/bash/run/spl-rotate-lib.func.sh:1424-1425`<br>`orc:src/bash/tests/spl-claude-project-slug.tst.sh` (case 3's list) | 2 inline copies -> 1 | 1.4's shape. **Red control:** the head's test on the parent (row 01 landed) FAILs case 3, then GREEN; outputs in the body. **Behaviour:** the rotate-lib column of 1.5 passes on parent and head with the same counts. Tests: `spl-claude-project-slug.tst.sh` and the 20 files of 1.5 that name `spl-rotate-lib` / `spl_rotate_transcript`, `run-lazy-loader.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 2 |

**Re-measure first:** each row lane re-runs its site reads (the `git grep -n
"s/\[^A-Za-z0-9\]/-/g"` of 1.2 (a), the calls of `spl_handover_slug`, the sourcing
lines of 1.3 / 1.4) on the `origin/master` it starts from, and says in its result if the
sites or the counts moved.

**Subject** (R6 reads it): `<type>(r88-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r88-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 adds a helper and points three files at it; row 02 one more. No output,
exit code, path or file a caller sees changes (1.3's probe, 1.5's column). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01.** **Batch 2: row 02**, placed within 30 minutes of row 01 landing
  (R16): both edit `spl-claude-project-slug.tst.sh`, which row 01 creates.
- No row edits `spl-dispatch-lease.func.sh` (c-346, 2.2), `agent-id-reap.sh`, any
  `spl-lane-handover-*` sibling action, `spool-install/` (r87-02's inc), any
  identity-restore or rotate test, `test-lib.inc.sh`, `orc-shard-weights.txt`, any
  `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (6): the 5 of row 01 and `spl-rotate-lib.func.sh` (row 02's other file is row
01's test).

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-170`, one call per
  path, 2026-11-22T08:56:18Z, n=1: **status 4 on all 6** ("no live lane lists <path>,
  but 12 live lane(s) record no files"). The `unknown:` lanes, all on the other box:
  c-063 (t1 issue backlog topic), c-346 (the seat-hold slow-tick bug), c-806 (SPL-6182
  native auth) and nine `*-rotate` seats. Their briefs name their files where they have
  one: c-346's `c003-bug-lease-seat-hold-slow-tick.md` "Files": `spl-dispatch-lease.func.sh`
  (`spl_fleet_seat_move` only) and one lease test, which is why `spl-dispatch-lease.func.sh:2385`
  stays out; c-806 hub auth, store and `cmd/spool` tests. No lane is reported as owning
  any of the 6.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 08:56:49Z): **3
  queued**: this round's mistral panel seat (f7af339b), the bug lane evlog unwritten
  dup message (922b5c35; its brief: `hub/evlog.go`, `hub/evlog_test.go`) and the SPL-6239
  box refresh spec (f9dcf16f; hub `box_stats`, the box-stats cron and its tests). None
  names a row path. The share line: refactor 1 of 17 known live lanes, 5%; last 24 h
  refactor 13% (band 20-30%: UNDER).
- **Briefs on this box** changed in the last 24 h (151) naming a row file or function
  (`grep -lE 'spl-lane-handover|spl_handover_slug|spl-rotate-lib|spl_rotate_transcript|spl-agent-identity-restore|_ai_copy_transcript|spl-agent-login-check|claude-project-slug'`,
  08:56:49Z): **0**.
- **Remote branches committed in the last 24 h** (96 besides master, 08:56:41Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths>` -> **0
  hits**.
- **Commits in the last 24 h** on the paths (`git log origin/master
  --since=2026-11-21T09:00Z -- <paths>`) -> **0**.
- **Live lanes named in the brief**: SPL-6182 c-806 (hub auth + store); SPL-6234 c-120
  (`lane-map.tst.sh`); spec 162 T4 c-107 (hub evlog routes); spec 154 B7 c-054 (Google
  connect scope); spec 123 L3w c-033 (step 030); c-063; c-346 (above); the queued evlog
  bug (above); the review seats and the two private-channel seats: none on a row path.

## 3. Per row: what the lane does

- **r88-01:** one helper, `spl_claude_project_slug`, holds Claude Code's project slug
  rule; the lane handover, identity restore and login check use it;
  `spl-claude-project-slug.tst.sh` proves the helper, the guard and the copies left.
- **r88-02:** the rotation's transcript path uses the helper; the test's list shrinks
  to the one copy that runs in another user's `bash -c`.

## 4. Panel and reviewers (R7)

- Editor: c-170 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the queued mistral seat `c002-refactor-round-88-mistral-panel-seat`.
  The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-22T09:01:51Z printed
  `pick=<this box> reason=<this box> is the first box in order below its low mark (51% < 70%)`, grok
  weekly 27% on both boxes: **a grok R7 seat per row**. The panel's re-run (N5) printed the
  other box (both above the high mark): still a grok seat. The holder re-runs the pick when
  it places the rows; a hold then gives the row a fresh **claude waiver seat**
  (1a7c70da). Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r88-01 | `c002-r88-01-orc-one-claude-project-slug` | `refactor(r88-01-orc-one-claude-project-slug, SPL-<row issue>): ...` | `review/r88-01` | 1 |
| r88-02 | `c002-r88-02-orc-rotate-claude-project-slug` | `refactor(r88-02-orc-rotate-claude-project-slug, SPL-<row issue>): ...` | `review/r88-02` | 2 (`After: c002-r88-01-orc-one-claude-project-slug`) |

**r88-01 brief, Files: ONLY**
`csi-spl-orc/lib/bash/funcs/spl-claude-project-slug.func.sh` (new, executable bit off:
it is sourced), `csi-spl-orc/src/bash/run/spl-lane-handover.func.sh` (`:176-177` the
helper and its comment go; `:81,121,152` call the new helper),
`.../run/spl-agent-identity-restore.func.sh` (`:372`, the guard and the call),
`.../run/spl-agent-login-check.func.sh` (`:439`, the guard and the call) and
`csi-spl-orc/src/bash/tests/spl-claude-project-slug.tst.sh` (new, executable bit on:
`chmod +x` and `git add --chmod=+x`). NOT `spl-dispatch-lease.func.sh` (c-346),
`spl-rotate-lib.func.sh` (row 02), `spool-install/steps/claude-memory.inc.sh`, any
`spl-lane-handover-*` sibling, any existing test, `test-lib.inc.sh` or
`orc-shard-weights.txt`. Do: plan section 2 row 01 verbatim, 1.3's shape; the red
control (the head's test on the parent) RED then GREEN in the body; 1.3's 8-path probe,
equal. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r88-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` (`:1425`, the guard and the call) and
`csi-spl-orc/src/bash/tests/spl-claude-project-slug.tst.sh` (case 3's list: drop
`spl-rotate-lib.func.sh`). Starts after r88-01 is on `origin/master`. NOT
`agent-id-reap.sh`, NOT any rotate test (run, not edited), NOT
`spl-dispatch-lease.func.sh`. Do: plan section 2 row 02 verbatim, 1.4's shape; the red
control (the head's test on the parent) RED then GREEN in the body. Gates: the row's
tests (section 2), `shellcheck -S warning -x` on the 2 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: row 01; batch 2: row 02 |
| orc `src/bash/run/*.func.sh` files carrying `s/[^A-Za-z0-9]/-/g` (`grep -lF`) | 5 on `8d7782cc3` -> 2 after row 01 -> 1 after row 02 |
| lines (`diff -ruN` of the trees, new files included, `^[+-]` non-header lines) | row 01: +52 -7; row 02: +3 -2 |
| measured on | `8d7782cc3`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-dispatch-lease.func.sh:2385` | the slug sits inside a `bash -c` string run as the agent user; a shell function does not cross it. And c-346 (seat-hold slow-tick bug) holds the file | 1.2 (a); c-346's brief |
| `orc:src/bash/features/spool-install/steps/claude-memory.inc.sh:9` (`spool_install_memory_slug`, r87-02) | another feature tree, one copy since r87-02; pointing it at `lib/bash/funcs` adds a spool-install -> orc lib source edge. A later row may | 1.2 (a) |
| the parameter-expansion form `${X//[^A-Za-z0-9]/-}` (`orc:.../spawn-agents/scripts/lane-scratch-reap.sh:63`, `orc:src/bash/scripts/spl-session-prune.sh:229`) and Python's `re.sub` (`agent-identity.py:1099`) | standalone scripts outside `./run` and another language; no source edge to `lib/bash/funcs` today | `git grep -nE "\[\^(A-Za-z0-9\|a-zA-Z0-9)\]"` |
| `spl_secrets_none_get` / `spl_self_host_env_get`; `spl_uplink_trim` / `ext_api_trim`; `tf_get`; the r86 Go set | r87 section 7, unchanged (secret-class; two modules; r85 / r86 7) | r87 7 |
| the agent-id regex literal, `as_root` / `as_owner`, the per-script message helpers, `say` / `check_tools` | r85 / r86 section 7, unchanged | r86 7 |
| `parse-metadata.func.sh` `${1:?}` lines, terraform `-input=false`, dropped rc | bug rows | r84 7 |
| `topic_loop_fire.go` `!inserted`, `spl-spawn-place-argmax.tst.sh:181-212`, the e2e selector `_ppe_keys` | test rows, a gate-design item | r83 7; candidates file |
| `spl-lane-mix.func.sh` agy words | gated on SPL-6174 | r87 N3 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred, an open owner decision, behaviour, or the full sweep; unchanged since W | 1.2 (d) |

## 8. Changes

- v0.1 (c-170): the rows and every read on `8d7782cc3`; both heads built; the column of
  1.5 run on base and head1 (equal) and the red controls RED; head2's column and
  `run-lazy-loader.tst.sh` still open (v0.2); 1.3's 8-path probe (0 differ); R3 (2.2)
  and R7 (section 4) checked. Committed at the lane's rotation (c-001 note 09:54Z).
- v0.2 (c-170): head2's column of 1.5 complete (every suite equals base);
  `run-lazy-loader.tst.sh` run on base, head1 and head2 (rc 0, 30 / 0 each). No row,
  site or count changed.
- v1.0 (c-170): the panel's notes (m-172, PASS on v0.1 and v0.2, no W). N3: 1.4 lists
  every file that sources `spl-rotate-lib.func.sh` alone (v0.1 named 6), same guard
  conclusion. N5: section 4 records the panel's grok pick re-run (the other box), still a
  grok seat. N1 (lane map exit 4, no owner) is 2.2's reading; N2 was closed by v0.2; N4
  (the heads are scratch-built, never committed) is 1.5's own wording. No row, site or
  count changed.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-170 (claude): v0.1, v0.2, v1.0.
- Panel reviewer seat: m-172 (mistral, `c002-refactor-round-88-mistral-panel-seat`): PASS on v0.1
  (`9707b20ae`) and v0.2 (`f693cf0c5`), no W; signs v1.0. Seat file
  `refactor-round-88/seat-mistral.md`.
- Row R7 seats: section 4.
