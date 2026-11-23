# Refactoring round 93 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6317  
Topic: 8f7f1485-3be7-4176-9c32-c3aaa9e00722  
Discussion: 8f7f1485-3be7-4176-9c32-c3aaa9e00722 (t1 #refactoring, "Refactor round 93", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r93**, plan `refactor-round-93-plan.md`, rows `r93-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 92 ([refactor-round-92-plan.md](refactor-round-92-plan.md))
is served: both rows landed (r92-01 `903427b6b`, r92-02 `151d1f868`), and its close
record `a7b5ae564` (this planner's first commit, `Closes: SPL-6306`) landed at
15:28:27Z. The perf floor (rulebook 4.4), measured by the holder c-003 on `151d1f868`:
perf 29, refactor 105, 21.6%, floor met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91 and
r92, found by a fresh scan (1.2 (e)) that no earlier plan lists: a function body that
exists twice under two names loses its second copy, and its caller calls the first,
`send_*` of `spool-caller.inc.sh` (the spool-send caller library, SPL-3654 /
SPL-5136), which neither row edits.
**Row 01:** `lane-map.sh` keeps `lane_is_role_seat`, byte-identical to
`send_role_seat` but for the name; the copy goes and the script sources
`spool-caller.inc.sh` beside the `spool-env.inc.sh` it already sources.
**Row 02:** the channel move's caller check (`channel-move.inc.sh`, spec 167 D1) keeps
`cm_chain`, byte-identical to `send_caller_chain` but for the name; the copy goes and
the lib loads `spool-caller.inc.sh` behind a `declare -F` guard, as it loads
`channel-rules.inc.sh`. The rows share no file: both are batch 1.

**Status: v0.1, for the panel.** Rows run by night (rulebook 1.4). Editor: **c-707**
(claude).

**One sha:** every count is measured on **`a7b5ae564`** (`origin/master` at
2026-11-23T15:28:34Z, the r92 close record), n=1 per command unless stated. Reads are
on `a7b5ae564` with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of that sha (not committed, removed after v1.0): "base" unmodified, "head1"
= base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's
shape; each red and guard control (1.5) ran in a worktree of its own. Queue, lane map,
brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-23T15:28:34Z, n=1, after this planner's r92 close record landed (fresh fetch):

- **Window: W=2026-11-23T17:27:53+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r92-plan'`: `a7b5ae564`
  (`docs(r92-plan, SPL-6306): refactor round 92 closed: ...`), the close record, read
  once at the start as 5.3 says. Before it landed the newest was `c831ad397` (plan
  v1.0, 2026-11-23T15:14:47+02:00).
- `git log origin/master --since="$W" --oneline -E --grep='\(r93-'` -> **0**; over all
  history -> **0**.
- `git ls-remote origin 'refs/heads/review/r93-*' 'refs/heads/*-r93-*' 'refs/heads/*refactor-round-93*' 'refs/heads/wip/*r93*'`
  -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r93|refactor-round-93'` -> this plan's
  brief and the panel seat's (`c002-refactor-round-93-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-93`
  -> 0: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) r92 section 7:** every item re-read on `a7b5ae564`. The `spl-lane-mix.func.sh`
  agy words (r91 panel N4) are **served**: `5077a62cd` (SPL-6308, 2026-11-23T13:18Z)
  rewrote them, `git grep -nE 'needs_agy_review|waits for an agy review|agy has the final word' a7b5ae564 -- ':!*.md'`
  -> 0. Every other item: `git diff --stat 7024772b1 a7b5ae564 -- <its 22 run files>`
  -> only `spl-lane-mix.func.sh` (that commit), so each stays out for its reason there
  (section 7).
- **(b) R7 and panel notes:** r92-01's R7 line (g-184, body of `903427b6b`) and
  r92-02's (g-215, body of `151d1f868`) carry notes only: the author brief absent on the
  reviewer's box (g-184 N1, g-215 N2: the rows ran on the other box) and the landed
  files' sha256 differing from 1.4's head2 in wording only (g-215 N1). The r92 panel's
  N1-N5 (m-650, plan v1.0 `c831ad397`) are process notes. No row in either; all folded
  in the r92 close record (`a7b5ae564`, section 8).
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  115 lines, read 15:3xZ): its refactor-shaped items re-measured on `a7b5ae564`:
  the reverse-tunnel cron literal (`reverse-tunnel-cron.sh:27` now reads
  `$SPL_VAR_APP_DIR`), the wf 10 disk comment (`10_ci-quality.yml:440-446` now says
  "about 96 MB"), the uplink probe comment (`spl-uplink-probe.func.sh:14-15` now names
  the config-fault exit), `spl-desk-reply.sh` kinds (r81-01, r83-01): served. The
  `spl-lane-mix.func.sh` agy words: (a). `i18n-lang-review-exempt.json:2` `_doc`
  (names only `Lang-review: a-NNN`, the gate also takes `gct`, added 14:2xZ): a doc
  line in a WUI data file, section 7. The rest are bug-, test- or feature-shaped.
- **(d) spec 011 tasks:** `git log origin/master --since=2026-11-23T08:56:59+02:00 --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks (T001-T008
  deferred by the owner, T018-T021, T023, T027, T034) are each wider than one row.
- **(e) A fresh scan for byte-identical function bodies** over the tracked `*.sh` of
  `csi-spl-orc/src/bash`, `csi-spl-orc/lib`, `csi-spl-iac/src/bash`,
  `csi-spl-utl/src/bash` and `src/bash`, tests and copies of `run.sh` and
  `print-help.func.sh` left out (one framework, r86 7): each `name() {` ... `}` body
  whitespace-trimmed, its own name masked, hashed and grouped; groups with a body of 2+
  lines or one line of 40+ characters. Unlike r89..r92's scans, this one reads the
  `features/` libs and scripts too. Groups of 2+ lines: **14**; of them 11 are in r91
  section 7 (their reasons hold), and 3 are listed in no refactor plan
  (`grep -lE '<names>' csi-spl-doc/doc/md/refactor-round-*-plan.md` -> none):
  - `cm_chain` / `send_caller_chain` (9 lines): **row 02** (1.4).
  - `lane_is_role_seat` / `send_role_seat` (3 lines): **row 01** (1.3).
  - `_gscv_get` / `_sgw_get` (iac, 3 lines): the third candidate, section 7.
  - The 1-line groups the scan also printed: section 7.

### 1.3 Row 01's site: lane-map's own role-seat check goes

`sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`. On `a7b5ae564`:

- `sa:scripts/lane-map.sh:74-85`: the 4-line comment (`:74-77`), `lane_is_role_seat`
  (`:78-81`, body `:79-80`), its one call at `:82` (`done` for a role seat is a no-op,
  `:83-84`). The script already sources `sa:lib/spool-env.inc.sh` at `:38`, by
  `$_here` = the real dir of the script (`readlink -f`, `:36`).
- `sa:lib/spool-caller.inc.sh:8-12`: the comment and `send_role_seat` (`:9`), body
  `:10-11`. `lane-map.sh:79-80` and `spool-caller.inc.sh:10-11` are **byte-identical**
  (`diff <(sed -n 9,12p caller) <(sed -n 78,81p lane-map | sed s/lane_is_role_seat/send_role_seat/)`
  -> no hunk, n=1). `send_role_seat` is also called by `spool-send.sh:172,176,236` and
  `spl-sender-audit.func.sh:125`. `lane_is_role_seat` came first (`8a957cfa8`
  2026-10-03, "role seats no-op `lane-map.sh done`"); `send_role_seat` was written
  in `spool-send.sh` the same morning (`06243116f`) and moved to the lib in
  `bf414adef` (SPL-5136): the lib is the shared home, so the script's copy goes.
- `spool-caller.inc.sh`'s top-level code is one line (`:6`, `_spool_caller_dir`); it
  defines `send_role_seat`, `send_caller_chain`, `send_caller_env_id`,
  `send_caller_pane_id`, `send_caller_id`, `send_chain_caller`; it needs
  `spool-env.inc.sh` first (its header), which `lane-map.sh:38` already gives. No name
  it defines is defined or used in `lane-map.sh`
  (`grep -nE '_spool_caller_dir|send_(role_seat|caller_|chain_caller)'` -> 0).
- `git grep -nE 'lane_is_role_seat|send_role_seat' a7b5ae564 -- ':!*.md'` -> the 2
  definitions and the 5 calls above. The test that proves the no-op:
  `csi-spl-orc/src/bash/tests/lane-map.tst.sh` case 9 (`:404-421`): `done --agent`
  c-001, c-002, c-003 (`spl_is_role_seat`) and c-412 (a `lease.conf` id) exit 0 with
  the INFO line and never call the action; the control c-077 calls it.
- Who runs `lane-map.sh`: every lane (the seed's lane map), its test, and the spawn /
  retire scripts and their tests, some through a symlink in a temp dir
  (`test-agent-id-retire-worktree.sh:128`): `readlink -f` (`:36`) resolves it to the
  real `scripts/`, so `$_here/../lib/` is found as `spool-env.inc.sh` is today.

Shape (built as head1 of 1.5):
- `lane-map.sh:76-82` become 5 lines: the comment's last 2 lines say the ids are
  `send_role_seat` of `spool-caller.inc.sh`, their one copy; a
  `# shellcheck source=../lib/spool-caller.inc.sh` line; `. "$_here/../lib/spool-caller.inc.sh"`;
  the `if` calls `send_role_seat "$_lane_agent"`. `:74-75` and `:83-85` unchanged.
  129 -> 127 lines.
- `csi-spl-orc/src/bash/tests/lane-map.tst.sh` gains (case 9's header, 3 lines for 1;
  one check after the c-077 control, 3 lines): `lane-map.sh` holds no
  `LEASE_(MASTER|FAILOVER|ORCH)` line and its `if` calls `send_role_seat "$_lane_agent"`.
  1014 -> 1019.
- head1's files, sha256 (12 chars): script `5c2c13430d28`, test `dc48225937c8`.

**Behaviour:** the function the `if` now calls has the deleted body byte for byte, with
the same argument; case 9's five role-seat and control checks pass on base and head1
with the same counts (1.5). The source line runs one assignment at top level.

### 1.4 Row 02's site: the channel move's own chain walk goes

On `a7b5ae564`:

- `sa:lib/channel-move.inc.sh:139-150`: the 1-line comment, `cm_chain` (`:140-149`,
  body `:141-148`) and a blank; its one call at `:232` in `cm_caller_check` (the D1
  caller check). The lib loads its sibling `channel-rules.inc.sh` at `:61-63`
  (`CM_LIB_DIR`, a `declare -F cr_map` guard).
- `sa:lib/spool-caller.inc.sh:14-24`: the same 1-line comment and `send_caller_chain`
  (`:15`), body `:16-23`. `channel-move.inc.sh:139-149` with `cm_chain` read as
  `send_caller_chain` is **byte-identical** to `spool-caller.inc.sh:14-24`
  (`diff <(sed -n 14,24p caller) <(sed -n 139,149p move | sed s/cm_chain/send_caller_chain/)`
  -> no hunk, n=1). `send_caller_chain` was written for the from-guard of
  `spool-send.sh` (`d45898ce8`, 2026-10-27, SPL-3654) and moved to the lib in
  `bf414adef`; `cm_chain` came with the channel move B1 (`eec2fe646`, 2026-11-05,
  SPL-4845). The lib is the shared home, so the move's copy goes.
- `git grep -nE '\bcm_chain\b|send_caller_chain' a7b5ae564 -- ':!*.md'` -> the 2
  definitions, the 2 calls (`channel-move.inc.sh:232`, `spool-caller.inc.sh:62`) and a
  comment in `csi-spl-api/.../internal/action/sender_audit.go:95` that names
  `send_caller_chain` (unchanged).
- Who loads `channel-move.inc.sh`: `cm_action_load` of
  `csi-spl-orc/src/bash/run/spl-channel-move.func.sh:58-67` (after `spool-env.inc.sh`)
  and of `spl-channel-manifest-add.func.sh:46`, and `channel-move-plan.tst.sh`, which
  sources it alone (`:268`, `live()`, `bash -c '. "$0"; ...'`). The guarded load goes
  beside the `channel-rules.inc.sh` one, at the lib's top level.
- Hardening (spec 167 D1, c-715 W1-W5), read on `a7b5ae564`: outside `SPOOL_TEST` the
  action refuses a caller that exports any function (`spl-channel-move.func.sh:33-42`,
  `BASH_FUNC_`), so no exported `send_caller_chain` can pass the `declare -F` guard;
  and runs its body under `env -i` with the fixed `CM_SAFE_PATH` (`:45-56`), so the
  load's `readlink` / `dirname` (`spool-caller.inc.sh:6`) run from that PATH, as the
  lib's own `dirname` at `:61` does. The body walks `/proc` with the same `cat` and
  `awk` as before.

Shape (built as head2 of 1.5):
- After `channel-move.inc.sh:63` 3 lines: a comment (the caller's pid chain is
  `send_caller_chain` of `spool-caller.inc.sh`, its one copy), a
  `# shellcheck source=spool-caller.inc.sh` line and
  `declare -F send_caller_chain >/dev/null || . "$CM_LIB_DIR/spool-caller.inc.sh"`.
  `:139-150` go. `:232` calls `send_caller_chain "$root" "$(cm_start_pid)"`. 445 -> 436
  lines.
- `csi-spl-orc/src/bash/tests/channel-move-plan.tst.sh` gains (header 2 lines; one
  block of 7 lines before "unknown and unbuilt commands"): the lib defines no
  `cm_chain()` and its caller check calls `send_caller_chain "$root"`; and the lib
  sourced alone (`env -i`, the test's PATH) defines `send_caller_chain` (the guarded
  load). 373 -> 382.
- head2's files, sha256 (12 chars): lib `706f1d0807e7`, test `23f523a502af`.

**Behaviour:** the function the caller check now calls has the deleted body byte for
byte, with the same arguments; the D1 cases (C14, C21, C23) and the W1-W5 hardening
cases pass on base and head2 with the same counts (1.5).

### 1.5 Before and on the rows' heads

2026-11-23T15:32:12Z-15:38:06Z (the column, base and both heads at once) and
15:35:17Z-15:36:26Z (controls), n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900` each; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'` (a suite's own
`FAILED <n>` summary counts as one). "=" means the head equals base: same rc, pass and
fail counts.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/lane-map.tst.sh` | 01 | 0 / 148 / 0 | 0 / 149 / 0 (9b adds 1) | = |
| `orc:src/bash/tests/lane-map-dead-role-seat.tst.sh` | 01 | 0 / 17 / 0 | = | = |
| `orc:src/bash/tests/lane-map-run-tees.tst.sh` | 01 | 0 / 6 / 0 | = | = |
| `sa:tests/test-agent-id-reap-lane-close.sh` | 01 | 0 / 125 / 0 | = | = |
| `sa:tests/test-agent-id-retire-worktree.sh` (runs `lane-map.sh` through a symlink) | 01 | 0 / 31 / 0 | = | = |
| `sa:tests/test-spawn-lane-review-row.sh` | 01 | 0 / 23 / 0 | = | = |
| `sa:tests/test-spawn-seed-size.sh` | 01 | 0 / 168 / 0 | = | = |
| `orc:src/bash/tests/desk-user-hops.tst.sh` | 01 | 0 / 217 / 0 | = | = |
| `sa:tests/test-spool-send-from-guard.sh` (the keeper's users) | 01, 02 | 0 / 28 / 0 | = | = |
| `orc:src/bash/tests/sender-audit.tst.sh` (the keeper's users) | 01, 02 | 0 / 35 / 0 | = | = |
| `orc:src/bash/tests/channel-move-plan.tst.sh` | 02 | 0 / 67 / 0 | = | 0 / 69 / 0 (the block adds 2) |
| `orc:src/bash/tests/spl-channel-move-rehearsal-seed.tst.sh` | 02 | 0 / 51 / 0 | = | = |
| `sa:tests/test-channel-workspace-move-box.sh` | 02 | 0 / 24 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |

Each head also ran the other row's suites: equal to base. `shellcheck -S warning -x` on
the 4 row files, base and each head: rc 0, no findings (n=1 each).

**Red controls** (n=1 each, each in its own worktree of `a7b5ae564`):
- Row 01: head1's `lane-map.tst.sh` on base: rc 1, 1 fail,
  `FAIL: 9b. lane-map.sh keeps its own role-seat check, or no call of send_role_seat: 76:# The ids: ... 78:lane_is_role_seat() {  # ID ...`;
  head1: rc 0, 0 fail.
- Row 01's guard: head1 with the source line deleted: rc 1, 4 fail, the role-seat
  checks of case 9, e.g.
  `FAIL: role seat c-001 (rc=0): .../lane-map.sh: line 79: send_role_seat: command not found / RUN -a do_spl_lane_put state=done agent=c-001`
  (also c-002, c-003, c-412): without the load a role seat's `done` reaches the action.
- Row 02: head2's `channel-move-plan.tst.sh` on base: rc 1, 2 fail (`FAILED 2`),
  `FAIL: one copy: channel-move.inc.sh keeps its own pid-chain walk, or no call of send_caller_chain: 140:cm_chain() {  # ROOT PID`
  and `FAIL: one copy load: `; head2: rc 0, 0 fail.
- Row 02's guard: head2 with the `declare -F` line deleted: rc 1, 28 fail
  (`FAILED 28`: C1 19, C14 4, C23 1, W4 1, W5 1, N3 1, the load check 1), e.g.
  `FAIL: C14 (a): rc 3 .../channel-move.inc.sh: line 222: send_caller_chain: command not found`.

The tests that name the sites (R2): `git grep -lE` over the orc and iac tests for
`scripts/lane-map\.sh|"lane-map\.sh"|lane-map\.sh"|lane_is_role_seat|send_role_seat|spool-caller`
-> `lane-map.tst.sh`, `lane-map-run-tees.tst.sh`, `test-agent-id-reap-lane-close.sh`,
`test-spawn-lane-review-row.sh`, `test-spawn-seed-size.sh`, `desk-user-hops.tst.sh`;
added: `lane-map-dead-role-seat.tst.sh` and `test-agent-id-retire-worktree.sh` (they run
the script), and the keeper's two suites. For
`channel-move\.inc|cm_caller_check|cm_chain|do_spl_channel_move\b|spl-channel-move\.func|send_caller_chain|spool-caller`
-> `channel-move-plan.tst.sh`; added: `spl-channel-move-rehearsal-seed.tst.sh` and
`test-channel-workspace-move-box.sh` (the channel move family) and the keeper's suites.
`orc-shard-weights.txt` names `lane-map.tst.sh` and `channel-move-plan.tst.sh` (no line
needed: no new file). Plus the loader, path and name gates of the table.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r93-01-orc-lane-map-role-seat)` | one fact, one copy (developer guide 2.2.4) | `lane-map.sh` keeps a byte-identical copy of `send_role_seat` of `spool-caller.inc.sh` (1.3) | `sa:scripts/lane-map.sh:76-82`<br>`orc:src/bash/tests/lane-map.tst.sh` (case 9 header, 1 check) | definitions of the role-seat check body 2 -> 1 | 1.3's shape. **Red control:** the head's test on the parent FAILs 9b (1.5), then GREEN; the guard control (the source line deleted: the role-seat checks of case 9 fail); outputs in the body. **Behaviour:** the column passes on parent and head with the same counts but the new check. Tests: `orc:.../lane-map.tst.sh`, `lane-map-dead-role-seat.tst.sh`, `lane-map-run-tees.tst.sh`, `sa:tests/test-agent-id-reap-lane-close.sh`, `test-agent-id-retire-worktree.sh`, `test-spawn-lane-review-row.sh`, `test-spawn-seed-size.sh`, `desk-user-hops.tst.sh`, `test-spool-send-from-guard.sh`, `sender-audit.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r93-02-orc-channel-move-caller-chain)` | one fact, one copy (developer guide 2.2.4) | the channel move's caller check keeps a byte-identical copy of `send_caller_chain` of `spool-caller.inc.sh` (1.4) | `sa:lib/channel-move.inc.sh:61-63,139-150,232`<br>`orc:src/bash/tests/channel-move-plan.tst.sh` (header, 1 block) | definitions of the pid-chain walk body 2 -> 1 | 1.4's shape. **Red control:** the head's test on the parent FAILs the one-copy check (1.5), then GREEN; the guard control (the `declare -F` line deleted: 28 checks fail, C14 among them); outputs in the body. **Behaviour:** the column passes on parent and head with the same counts but the new checks. Tests: `orc:.../channel-move-plan.tst.sh` (whole: D1 and W1-W5), `spl-channel-move-rehearsal-seed.tst.sh`, `sa:tests/test-channel-workspace-move-box.sh`, `test-spool-send-from-guard.sh`, `sender-audit.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body comparison, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r93-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r93-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a copy and points its caller at the other; no output, exit
code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: the lane map
  script and its test; row 02: the channel move lib and its test).
- No row edits `sa:lib/spool-caller.inc.sh` (the keeper both load), `sa:lib/spool-env.inc.sh`,
  `sa:lib/channel-rules.inc.sh`, `sa:scripts/spool-send.sh`,
  `orc:src/bash/run/spl-sender-audit.func.sh`, `orc:src/bash/run/spl-channel-move.func.sh`,
  `orc:src/bash/run/spl-channel-manifest-add.func.sh`, `sender_audit.go`, any other
  test, `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform,
  `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (5): `sa:scripts/lane-map.sh`, `orc:src/bash/tests/lane-map.tst.sh`,
`sa:lib/channel-move.inc.sh`, `orc:src/bash/tests/channel-move-plan.tst.sh`, and the
keeper `sa:lib/spool-caller.inc.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-707`, one call per
  path, n=1, 2026-11-23T15:32:17Z-15:32:30Z: **exit 4 on all 5** ("no live lane lists
  <path>, but 11 live lane(s) record no files"). The `unknown:` lanes, all on the other
  box: the private-channel seats c-029, c-041, c-146, c-187, c-924, c-927 (`*-rotate`),
  the seat c-086, the reviewer g-133 (SPL-6301), b41-01 c-170 (SPL-6310, landed
  `366bc7dca`: `spl-box-update.func.sh`, `check-deploy-lag` and their tests, none of
  the 5), SPL-6316 c-214 (`c002-s154-contacts-one-place`, WUI Settings) and this
  round's panel seat m-234. No lane is reported as owning any of the 5; none of those
  scopes is a spawn-agents lib or script.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 15:33:40Z): 0
  queued, 1 placing: `c002-spl5985-rust-run-path-step` (feature, SPL-5985, the `./run`
  path step); its brief names `run.sh` and no row path.
- **Briefs on this box** changed in the last 24 h (107) naming a row function or file
  (`grep -lE 'lane_is_role_seat|send_role_seat|spool-caller|channel-move\.inc|cm_chain|send_caller_chain|channel-move-plan|lane-map\.tst'`,
  15:3xZ): **0**. (`lane-map.sh` itself is named by every brief's seed text, as the R3
  tool, not as a file to edit.)
- **Remote branches committed in the last 24 h** (11 besides master after
  `fetch --prune`, 15:32Z): `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 5 paths>`
  -> **0 hits**.
- **Commits in the last 24 h** on those 5 paths (`git log origin/master --since=2026-11-22T15:30Z`)
  -> **0**.
- **Live lanes and rows named in the brief:** SPL-6301 c-626 (costs vendor share,
  landed) and g-133; b41-01 c-170 (SPL-6310) and b41-02 c-673 (SPL-6314, api gcal
  RRULE WKST) with reviewers g-693 / g-696; SPL-6316 c-214 and g-702; blog g-125; the
  private-channel seats; the seat c-086: none on a row path (the lane map, the queue and
  the branch read above).

## 3. Per row: what the lane does

- **r93-01:** `lane-map.sh done` for a role seat stays a no-op through
  `send_role_seat` of `spool-caller.inc.sh`, the one copy, sourced beside
  `spool-env.inc.sh`. Check 9b of `lane-map.tst.sh` proves the copy is gone; case 9's
  role-seat checks (c-001..c-003, the `lease.conf` id c-412) and its control prove the
  source line loads it.
- **r93-02:** the channel move's caller check walks the caller's pid chain through
  `send_caller_chain` of `spool-caller.inc.sh`, the one copy, loaded behind a
  `declare -F` guard beside `channel-rules.inc.sh`. The new block of
  `channel-move-plan.tst.sh` proves the copy is gone and the lib sourced alone defines
  it; the D1 cases prove the check still reads the caller.

## 4. Panel and reviewers (R7)

- Editor: c-707 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the queued mistral seat `c002-refactor-round-93-mistral-panel-seat`
  (live as m-234 at 15:32Z, lane map). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-23T15:34:14Z printed
  `pick=<box> reason=<box> is the first box in order below its high mark (89% < 90%), every box is at or above its low mark`,
  grok weekly 68% on both boxes: **a grok R7 seat per row**. The rows run by night
  (rulebook 1.4); the holder re-runs the pick when it places them, and a hold then gives
  the row a **claude waiver seat**, as r90..r92's section 4 say. Not a mistral code R7.
- Row 02's reviewer runs `channel-move-plan.tst.sh` whole: its W1-W5 cases are the
  hardening the guarded load must keep (1.4).
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r93-01 | `c002-r93-01-orc-lane-map-role-seat` | `refactor(r93-01-orc-lane-map-role-seat, SPL-<row issue>): ...` | `review/r93-01` | 1 |
| r93-02 | `c002-r93-02-orc-channel-move-caller-chain` | `refactor(r93-02-orc-channel-move-caller-chain, SPL-<row issue>): ...` | `review/r93-02` | 1 |

**r93-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh` (`:76-82`: the
comment's last 2 lines, the function goes, the source line, the call) and
`csi-spl-orc/src/bash/tests/lane-map.tst.sh` (case 9's header and check 9b). NOT
`spool-caller.inc.sh`, `spool-env.inc.sh`, `spool-send.sh` or any other test. Do: plan
section 2 row 01 verbatim, 1.3's shape; the red control (the head's test on the parent)
RED then GREEN in the body; the guard control (the source line deleted) RED. Gates: the
row's tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on
the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r93-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/lib/channel-move.inc.sh` (the guarded load
after `:63`, `:139-150` go, the call at `:232`) and
`csi-spl-orc/src/bash/tests/channel-move-plan.tst.sh` (header and the one-copy block).
NOT `spool-caller.inc.sh`, `channel-rules.inc.sh`, `spl-channel-move.func.sh`,
`spl-channel-manifest-add.func.sh`, `sender_audit.go` or any other test. Do: plan
section 2 row 02 verbatim, 1.4's shape; the red control (the head's test on the parent)
RED then GREEN in the body; the guard control (the `declare -F` line deleted) RED, built
in a worktree, not a temp-dir copy. Gates: the row's tests (section 2), `shellcheck -S
warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| definitions of the role-seat check body (1.3) | 2 on `a7b5ae564` (`send_role_seat`, `lane_is_role_seat`) -> 1 after row 01 |
| definitions of the pid-chain walk body (1.4) | 2 on `a7b5ae564` (`send_caller_chain`, `cm_chain`) -> 1 after row 02 |
| lines (`git diff --numstat` of each head) | row 01: script +5 -7, test +6 -1; row 02: lib +4 -13, test +9 -0 |
| measured on | `a7b5ae564`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `_gscv_get` / `_sgw_get` (`iac:src/bash/run/gh-set-ci-vars.func.sh:36`, `spl-gh-wire.func.sh:92`, 3 lines, byte-identical but the name; each reads one GitHub Actions variable with `gh api repos/<repo>/actions/variables/<name>`) | a third candidate: this round aims at 2 rows (5.1), so it is the next refactor round's first candidate; its load shape and tests are not measured here | 1.2 (e); `sed -n 34,38p` / `90,94p` of the two files |
| `i18n-lang-review-exempt.json:2` `_doc` (names only `Lang-review: a-NNN`; `check-pre-push-lang-review.func.sh:65-66,151` take `gct` first and still an agy line) | a doc string in a WUI data file, not a code copy; one line for a docs or bug row, not this round | `git grep -n 'Lang-review' a7b5ae564 -- csi-spl-wui/i18n/i18n-lang-review-exempt.json` -> 1 line |
| the 1-line groups (the `say` / `refuse` / `as_root` / `*_ms` families of the cron and sweep scripts, `_frd_log` / `_qdd_log`, `is_commit`, `restore_args`, `is_held`, `allow`, the directive selftest `ok` / `no`) | standalone scripts or one-line helpers across modules with no source edge; the families are over the 5-site cap | 1.2 (e) |
| `spl-lane-mix.func.sh` agy words (r91 panel N4, r92 7) | served by `5077a62cd` (SPL-6308) | 1.2 (a) |
| every other r92 section 7 item (`ndf_link` / `ndp_link`, `_lc_deps` / `_spl_box_leave_deps`, `do_db_login_ensure_gcp` / `do_db_login_rotate_gcp`, every r91 section 7 item) | unchanged since r92's base, its reason there | r92 7; 1.2 (a) |

## 8. Changes

- v0.1 (c-707): the rows and every read on `a7b5ae564`; both heads built in scratch
  worktrees; the column of 1.5 run on base and both heads; the red and guard controls
  RED; R3 (2.2) and R7 (section 4) checked.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-707 (claude): v0.1.
- Panel reviewer seat: the mistral seat `c002-refactor-round-93-mistral-panel-seat`.
- Row R7 seats: section 4.
