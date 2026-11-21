# Refactoring round 81 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6161  
Topic: 58608800-d4a5-49af-9e32-55cef6551d29  
Discussion: 58608800-d4a5-49af-9e32-55cef6551d29 (t1 #refactoring, "Refactor round 81", opener msg 904bc8a9)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r81**, plan `refactor-round-81-plan.md`, rows `r81-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 80 ([refactor-round-80-plan.md](refactor-round-80-plan.md))
has both rows on trunk: r80-01 `f886bfcdd` (SPL-6156), r80-02 `5083f4cf9` (SPL-6158);
its close record is the r80 editor's, not this plan's. No signed row is handed on: r81 is
a fresh round. The perf floor (rulebook 4.4), the holder's read on `f886bfcdd`: `perf 29
refactor 108 perf-share 21.2% floor-met`, so this is a refactor round.

**Row 01** makes the desk-reply fast launcher's usage (`spl-desk-reply.sh:9`, `:19`)
list the kinds the reply action takes: r80 section 7's "first candidate for r81"
(r79 panel N1, SPL-6107 N1). **Row 02** makes `do_hub_deploy_roll_none` return 1 on an
empty argument instead of exiting the caller's shell (`spl-self-host-up.func.sh:317`),
the shape r80-02 gave `do_spl_merged_cnf`: the one `local x="${1:?...}"` line of r80
section 7 that is in one file with one copy.

**Status: v1.0**: panel seat m-723 (mistral) PASS on v0.1 `7dbfe9f78`, no W finding,
N1-N4 recorded (section 8); no row changes scope. m-723 PASS on v1.0 `864f7ff17` too
(section 9). **Closed**: both rows landed, r81-01 `3174e591a`, r81-02 `1fd68677a`
(section 8). Editor: **c-722** (claude).

**One sha:** every count is measured on **`5083f4cf9`** (`origin/master`
5083f4cf9, committed 2026-11-21T07:49:19+01:00), n=1 per command unless stated. Reads
are on that sha with `git show` / `git grep` or on this lane's worktree at that sha.
**Every test named below was RUN**, not only read (r79's plan miss, c-594 N1): on this
lane's worktree at `5083f4cf9`, unmodified for the "before" column and with the row's
change applied in 1.3's / 1.4's shape for the "head" column, then restored
(`git status --short` empty after each), and on a `git archive` scratch copy for row
01's first red / green read (1.5). Nothing of either is committed. Queue, lane map,
brief and branch readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-21T07:52:49+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r80-plan'` -> commit
  `d02aea0f8` "refactor round 80 plan v1.0, panel m-691 mistral PASS on v0.1 7329be641
  ...". Every later read of r81 uses this W.
- **`r81` is free** (2026-11-21T06:52:35Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r81-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r81-*' 'refs/heads/wip/*r81*' 'refs/heads/*-r81-*' 'refs/heads/*refactor-round-81*'`
    -> **nothing**. This planner's review branch is pushed after that read.
  - `grep -rlE 'r81-[0-9]{2}|refactor-round-81' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **2 files**: this planner's brief and the panel
    seat's (`c002-refactor-round-81-mistral-panel-seat.md`).
  - Control: the same log read with `(r80-` since W -> 3 lines (`5083f4cf9`,
    `f886bfcdd`, `d02aea0f8`), so the read sees a used id.
- **No `refactor-round-81*` file** exists under `csi-spl-doc/doc/md` on `5083f4cf9`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-81` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `iac:` = `csi-spl-iac/`; `<mod> lib:` =
`<mod>/lib/bash/funcs/`.

| input | source | on `5083f4cf9` | here |
|---|---|---|---|
| `orc:scripts/spl-desk-reply.sh:9`, `:19` usage text | r80 section 7 ("first candidate for r81"), r79 panel N1, candidates "[refactor] SPL-6107 N1" | still 5 kinds (1.3) | **row 01** |
| the other `local x="${N:?...}"` lines | r80 section 7 | `git grep -nE 'local [A-Za-z_]+="?\$\{[0-9]:\?'` over iac, orc and utl `lib/bash/funcs` + `src/bash/run` -> **30 lines in 12 files**: iac 14 in 6, orc 11 in 4, utl 5 in 2 (r80-02 took `spl-merged-cnf.func.sh`) | **row 02** takes the one single-copy, single-line file, `orc:run/spl-self-host-up.func.sh:317`; the rest left out (section 7) |
| r80-01 R7 notes (c-653 PASS on `23141fe5e`): N1 the `satellite-ansible.tst.sh` floor `-ge 3` equals today's count; N2 the new case pins `SPL_VAR_APP_DIR`; N3 an explicit `SPL_ORG_APP` no longer moves the default log dir; N4 `no-literal-paths.tst.sh` needs a git tree | the brief | the landed body of `f886bfcdd` carries the review line only (`git log -1 --format=%B f886bfcdd \| grep -c '^review: '` -> 1); the N notes were read from the brief | left out (section 7): N1, N2 notes on a gate that is right today; N3 a behaviour change (a bug row if anyone relies on it); N4 a test-environment note |
| r80-02 R7 (c-672 PASS on `937bc49b8`) | the brief | its line names no N or W note (`git log -1 --format=%B 5083f4cf9`) | nothing to take |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`, this box, 101 lines) | the brief | refactor-shaped items re-read below | row 01 is its "[refactor] SPL-6107 N1"; nothing else taken |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r80's reasons hold |

The candidates file's refactor- and test-shaped items (its bug items are bug round 33's,
SPL-6160):

| item | on `5083f4cf9` | here |
|---|---|---|
| literal `/var` in `spl-watchdog.func.sh`, `spl-lane-rotate.func.sh` (r34 R7 N3) | served (r79 1.2) | nothing taken |
| `reverse-tunnel-cron.sh:23` literal (r63-01 R7 W1) | served (r79 1.2) | nothing taken |
| agent-boot-restore dir (r69) | served (r70-01) | nothing taken |
| "[refactor] SPL-6107 N1" `spl-desk-reply.sh:9,19` | 1.3 | **row 01** |
| `spl-spawn-place-argmax.tst.sh` section 9 guard cases (b30-01 R7 N1) | test-shaped; the placer sits beside bug round 33's rows | left out (section 7) |
| spec 182 L2 `!inserted` branch untested (SPL-6032 R7 N1) | test-shaped, hub Go | left out (section 7) |
| `ws-docs-head.mjs:28,60,62` synthetic click (SPL-6115 R7 W1) | WUI test hardening; WUI lanes live | left out (section 7) |
| spec 181 B10 N1, N2, N4 (spec text) | doc rows of specs 121, 122, 123, 159 | left out (section 7) |

### 1.3 Row 01's site: the desk-reply launcher's usage text

`orc:scripts/spl-desk-reply.sh` (280 lines), the usage block `:7-22` that `usage()`
(`:26-29`) prints from `# Usage:` to the rule:

```text
:9   #                     [--to <HUM-id>] [--task <uuid>] [--kind note|result|reject|blocker|msg]
:19  #   DESK_KIND   note | result | reject | blocker | msg (default: note)
```

**What the kinds are.** The script passes `DESK_KIND` to `spool send --kind` unchecked
(`:39`, `:52`, `:239`). The reply action `do_spl_desk_reply` takes
`result|reject|blocker|msg|$SPOOL_NOTE_KINDS` (`orc:run/spl-desk-reply.func.sh:550`, its
`@param` `:147-148`), `SPOOL_NOTE_KINDS` =
`note|feature|bug|alert|question|idea|decision|docs`
(`orc:features/spawn-agents/lib/spool-env.inc.sh:139`): **12 kinds**, not `task`
(r80 1.2). The usage lists 5. The row lists the 12 in both lines, e.g.:

```text
:9   #                     [--to <HUM-id>] [--task <uuid>] [--kind note|result|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs]
:19  #   DESK_KIND   note | result | reject | blocker | msg | feature | bug | alert | question | idea | decision | docs (default: note)
```

(the lane may wrap `:9` onto its own `#` line; the 12 kinds and the `--kind` token
stay). Comment text only: no line the shell runs changes, so the launcher behaves as
before. Validating `DESK_KIND` in the launcher would change behaviour (a kind it passes
today would be refused): a bug row, not this one (section 7).

**The test.** `orc:features/spawn-agents/tests/test-spool-kinds.sh` (55 lines) already
pins `spool-send.sh --help` against `SPOOL_KINDS` (`:46`). The row adds section 4 before
`t_done` (`:55`), the same check for the launcher: the kind set in its `--help` (stderr,
exit 2) on the `--kind` token and on the `DESK_KIND` line equals the set of
`result|reject|blocker|msg|$SPOOL_NOTE_KINDS`, the action's own check:

```text
# ---- 4. spl-desk-reply.sh names the reply action's kinds ---------------------
want="$(tr '|' '\n' <<<"result|reject|blocker|msg|$SPOOL_NOTE_KINDS" | sort -u | paste -sd' ')"
u="$(bash "$T_REPO/csi-spl-orc/src/bash/scripts/spl-desk-reply.sh" --help 2>&1)"
got="$(sed -nE 's/.*--kind ([a-z|]+).*/\1/p' <<<"$u" | tr '|' '\n' | sort -u | paste -sd' ')"
eq "4. spl-desk-reply.sh usage --kind lists the reply kinds" "$want" "$got"
got="$(sed -nE 's/^ *DESK_KIND +([a-z |]+)\(default.*/\1/p' <<<"$u" | tr -d ' ' | tr '|' '\n' | sed '/^$/d' | sort -u | paste -sd' ')"
eq "4. spl-desk-reply.sh DESK_KIND line lists the reply kinds" "$want" "$got"
```

(`T_SCRIPTS` is the spawn-agents `scripts/` dir, `lib.inc.sh:10`, so the path goes from
`T_REPO`; the lane may word the case otherwise, the two sets and the source of `want`
stay.)

**The tests that name the site** (`git grep -lE 'spl-desk-reply\.sh' -- '*test*'` -> 2
files: `orc:tests/desk-root-readers.tst.sh` section 7 runs it in a dry run,
`orc:tests/enc-dirs-untouched.tst.sh:50` lists it; v1.0, panel N2). None reads the usage
text. `orc:tests/watcher-read-only.tst.sh` names the reply action
(`spl-desk-reply.func.sh`), not the launcher; it stays in row 01's gates as a cheap
neighbour (81 pass before and on head, 1.5).

### 1.4 Row 02's site: `do_hub_deploy_roll_none`

`orc:run/spl-self-host-up.func.sh` (321 lines; `do_hub_deploy_roll_none` is `:316-321`,
6 lines), `:316-317`:

```text
:316 do_hub_deploy_roll_none() {
:317   local dir="${1:?do_hub_deploy_roll_none <dir>}"
```

**What is wrong.** `${1:?}` with an empty or missing argument prints the message and
**exits** the non-interactive shell (developer guide 2.4.3: a function returns a code).
The function's other path returns 1 (`:320`), and its one caller expects that:
`do_spl_self_host_up` `:283`,
`SPOOL_CLOUD_PROVIDER=none do_spl_cloud_dispatch hub_deploy roll "$dir" || return 1`
(`git grep -nE 'hub_deploy roll|roll_none'` over orc and iac -> that call, the
definition, its header, and `check-hub-deploy.tst.sh:236,239`). On an empty argument the
`|| return 1` is never reached. Measured on `5083f4cf9` (n=1 per form,
`bash -c 'do_log(){ echo "$*" >&2; }; source <file>; do_hub_deploy_roll_none <args>; echo rc=$?'`):
`""` and no argument each print `line 317: 1: do_hub_deploy_roll_none <dir>` and **no
`rc=` line**.

**The shape**, r80-02's, with this file's `do_log`:

```text
[[ -n "${1:-}" ]] || { do_log "FATAL do_hub_deploy_roll_none: usage: do_hub_deploy_roll_none <dir>"; return 1; }
local dir="$1"
```

Every call with a non-empty argument behaves as before. The function grows 6 -> 7
lines.

**The tests.** `git grep -lE 'spl-self-host-up|do_spl_self_host_up|hub_deploy|roll_none' -- '*tests/*'`
-> **10 files** in `orc:tests/` (`box-name-from-cnf`, `canary-hub-deploy`,
`check-deploy-lag`, `check-hub-deploy`, `heal-hub-deploy`, `hub-image-key-wf20`,
`lane-map`, `rollback`, `run-loader-convention`, `self-host-up`); all 10 were run on the
row's head (1.5). The new case goes into `orc:tests/check-hub-deploy.tst.sh` (248
lines), after `:241` (its `hub_deploy roll` block, `:234-241`), through the file's own
`in_none` helper (`:198-208`, which sources every orc lib and run file):

```text
# an empty or missing <dir> returns 1 and says why; it never exits the caller's shell nor runs docker
for a in '""' ''; do
  in_none -- "do_spl_cloud_dispatch hub_deploy roll $a; echo \"rc=\$?\""
  grep -qx 'rc=1' "$T/nout" && grep -q 'usage: do_hub_deploy_roll_none <dir>' "$T/nerr" && [[ ! -s "$T/nstub.log" ]] \
    && pass "none: hub_deploy roll '$a': returns 1, says why, runs nothing" || fail "none roll '$a': out '$(cat "$T/nout")' err '$(cat "$T/nerr")' stub '$(cat "$T/nstub.log")'"
done
```

(the lane may word it otherwise; the two forms and the three checks stay).

### 1.5 Before and on the row's head

2026-11-21T06:5xZ-07:0xZ, n=1, `SPOOL_TEST=1`, as the push user; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'` (a final
`FAILED: <n>` line counts as one fail line). "Head" = the worktree with the row's change
in 1.3's / 1.4's shape.

| suite | row | before rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `orc:features/spawn-agents/tests/test-spool-kinds.sh` | 01 | 0 / 43 | 0 / 45 / 0 | +2, section 4; with the parent's site (the new section only) rc 1, 43 passed 2 failed: `got 'blocker msg note reject result'` against the 12 (scratch copy) |
| `orc:tests/desk-root-readers.tst.sh` | 01 | 0 / 37 | 0 / 37 / 0 | in a `git archive` copy it reads 2 unrelated FAILs (section 10, session-upload) on the unmodified copy too: run it in the worktree |
| `orc:tests/watcher-read-only.tst.sh` | 01 | 0 / 81 | 0 / 81 / 0 | a `git archive` copy cannot build `spool` (`FAIL - cannot build spool`): run it in the worktree |
| `orc:tests/enc-dirs-untouched.tst.sh` | 01 | 0 / 18 | 0 / 18 / 0 | |
| `orc:tests/check-hub-deploy.tst.sh` | 02 | 0 / 54 | 0 / 56 / 0 | +2, the new case; with the parent's site rc 1, 2 FAIL (`err '...spl-self-host-up.func.sh: line 317: 1: do_hub_deploy_roll_none <dir>'`, `out ''`, stub empty) |
| the other 9 files of 1.4's grep | 02 | not run on the parent | 9 rc 0, 0 fail (pass lines: self-host-up 35, run-loader-convention 9, box-name-from-cnf 14, canary-hub-deploy 37, check-deploy-lag 52, heal-hub-deploy 14, hub-image-key-wf20 6, lane-map 148, rollback 44) | |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 | 0 / 15 / 0 (each row's head) | `do_hub_deploy_roll_none` 7 lines |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r81-01-orc-desk-reply-usage-kinds)` | no comment describes behaviour the code does not perform (rulebook C5); one list (developer guide 2.2.4) | the launcher's usage names 5 kinds; the reply action takes 12 (`spl-desk-reply.func.sh:550`, SPL-6107), so the help hides 7 (1.3) | `orc:scripts/spl-desk-reply.sh:9,19`<br>(+ section 4 in `orc:features/spawn-agents/tests/test-spool-kinds.sh`, before `:55`) | 1 site, 2 lines | Both lines list the 12 kinds (1.3). **New section 4** (1.3): the `--kind` set and the `DESK_KIND` set of `--help` equal `result\|reject\|blocker\|msg\|$SPOOL_NOTE_KINDS`. **Red control:** section 4 on the parent's site FAILs 2 (`got 'blocker msg note reject result'`), then GREEN (45 pass); outputs in the body. **Behaviour:** comment lines only (`git diff -U0 \| grep '^[-+][^-+#]'` -> 0 on the script). Tests: `test-spool-kinds.sh`, the 2 test files of 1.3's grep and `watcher-read-only.tst.sh` (in the worktree, 1.5), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r81-02-orc-roll-none-returns)` | bash that fails safely: a function returns a code (developer guide 2.4.3) | `do_hub_deploy_roll_none`'s `${1:?}` exits the caller's shell on an empty argument, so `do_spl_self_host_up`'s `\|\| return 1` never runs (1.4) | `orc:run/spl-self-host-up.func.sh:317`<br>(+ one case in `orc:tests/check-hub-deploy.tst.sh`, after `:241`) | 1 site | The site takes 1.4's shape. **New case** (1.4): an empty and a missing argument each print `rc=1`, the usage on stderr, run no docker. **Red control:** the case against the parent's site FAILs 2 (`line 317: 1: do_hub_deploy_roll_none <dir>`, no `rc=` line), then GREEN (56 pass); outputs in the body. **Behaviour:** the 10 test files of 1.4's grep, each as on the parent (1.5). Tests: those 10, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. No docker: the test stubs it. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (row 01's two usage lines
and the action's kind check at `:550`, row 02's `rc=` forms) on the `origin/master` it
starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r81-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r81-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 changes the launcher's own help text, which is the doc of that script;
`git grep -n 'spl-desk-reply\.sh' -- csi-spl-doc | grep -v round- | wc -l` -> 9 lines
(the grok ISG, specs 069 and 136 and a spec 136 review), and none lists its kinds
(`git grep -nE 'note\|result\|reject\|blocker\|msg[^|]' -- csi-spl-doc | grep -v round-` -> 0).
Row 02 changes only the empty-argument path, which no caller takes. Each:
`Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their files are disjoint (an orc script and a
  spawn-agents test vs an orc run file and an orc test), so both place at once.
- No row edits `orc:run/spl-desk-reply.func.sh`,
  `orc:features/spawn-agents/lib/spool-env.inc.sh`, `orc:scripts/spool-send.sh`
  (spawn-agents), `orc:lib/bash/funcs/spl-cloud-dispatch.func.sh`, any other function
  of `spl-self-host-up.func.sh`, the other `${1:?}` lines, a migration,
  `csi-spl-cnf/`, terraform, `csi-spl-utl/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths (4): `orc:scripts/spl-desk-reply.sh`,
`orc:features/spawn-agents/tests/test-spool-kinds.sh`,
`orc:run/spl-self-host-up.func.sh`, `orc:tests/check-hub-deploy.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-722`, one call per
  path, 2026-11-21T06:58:56Z, n=1: **exit 4 on all 4**, the same **16 `unknown:`
  lanes** each time ("no live lane lists <path>, but 16 live lane(s) record no files").
  No live lane lists a row path. The holder re-checks before placing.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 06:59:25Z): **15
  queued**: bug round 33's planner and mistral panel seat, spec 184 (6, held after
  SPL-6036), spec 123 L2b-L7 (held), spec 033 T026 (held; its brief's Files are
  `how-to-post.md` and `message-actions-and-formatting.md`, "Not yours: any code ...
  `csi-spl-orc/**`"). None names a row path.
- **Briefs on this box** naming a row path (`grep -lE` of the 4 basenames over the 120
  newest files in `<spool>/dispatch/briefs`, 06:59:44Z): this one, the r80 planner's
  (landed round) and `c003-s033-t024-claude-waiver-reviewer.md` (SPL-6107's R7, landed:
  `d42a8c3de`, `bc5047afe`).
- **Remote branches committed in the last 24 h** (78 besides master, 06:59:44Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b>` filtered for the 4
  basenames -> **2 hits**, none a live edit: `review/c002-bug-round-30-mistral-seat` and
  `review/c002-s033-t024-cli-orc-kinds` (`test-spool-kinds.sh` equal to master's on
  both: `git diff <b> origin/master -- <f> | grep -c '^[-+][^-+]'` -> 0).
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Live lanes named in the brief**: r80-01 / r80-02 (landed, 1.1), b32-01
  (`spl-push-master.*`), b32-02 (`spl-spawn-review-notify.*`), b31-02
  (`spl-done-claim-check.*`, `done-claim-check.md`), bug round 33's planner, spec 123
  (store, `spl-cost-labels-fill.func.sh`, cost), spec 143, spec 033, the WUI lanes,
  spec 189, spec 190, the release-tooling lane, the private-workspace seats: none on a row path by its
  listed files.

## 3. Per row: what the lane does

- **r81-01:** `spl-desk-reply.sh`'s usage and `DESK_KIND` line list the reply action's
  12 kinds; `test-spool-kinds.sh` gains section 4.
- **r81-02:** `do_hub_deploy_roll_none` returns 1 with a usage line on an empty or
  missing argument; `check-hub-deploy.tst.sh` gains the case.

## 4. Panel and reviewers (R7)

- Editor: c-722 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r81`):
  one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-81-mistral-panel-seat` (agy, the main vendor for plan reviews, is
  out until about 11-24). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2). `BOX_PICK_KIND=grok
  ./run -a do_spl_box_pick` at 2026-11-21T06:59:58Z printed `pick=<box> reason=every box
  is at or above its high mark; <box> is the least past its band (92% on high 90%,
  overflow 180%)`: a box pick by load, with no grok quota line. This plan did not
  re-check grok's quota or the owner's grok order; the brief's read (06:2xZ) is grok
  on hold (99% weekly on both boxes). So each row takes a fresh **claude waiver seat**
  (1a7c70da), as r63 to r80. The holder's own read at 07:07Z: `pick=hold` (grok weekly
  unknown on both boxes), so the waiver seat stands (v1.0). Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r81-01 | `c002-r81-01-orc-desk-reply-usage-kinds` | `refactor(r81-01-orc-desk-reply-usage-kinds, SPL-<row issue>): ...` | `review/r81-01` | 1 |
| r81-02 | `c002-r81-02-orc-roll-none-returns` | `refactor(r81-02-orc-roll-none-returns, SPL-<row issue>): ...` | `review/r81-02` | 1 |

**r81-01 brief, Files: ONLY** `orc:scripts/spl-desk-reply.sh` (`:9` the `--kind`
token, `:19` the `DESK_KIND` line; comment lines only) and
`orc:features/spawn-agents/tests/test-spool-kinds.sh` (new section 4 before `:55`).
NOT `orc:run/spl-desk-reply.func.sh`, NOT `spool-env.inc.sh`, NOT any line of the
launcher the shell runs (no kind check: section 7). Do: plan section 2 row 01 verbatim,
1.3's shape; the red control (section 4 on the parent's site) RED then GREEN in the
body. Gates: `test-spool-kinds.sh`, `desk-root-readers.tst.sh`,
`watcher-read-only.tst.sh`, `enc-dirs-untouched.tst.sh` (in the worktree,
`SPOOL_TEST=1`), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r81-02 brief, Files: ONLY** `orc:run/spl-self-host-up.func.sh` (`:317`) and
`orc:tests/check-hub-deploy.tst.sh` (one case after `:241`). NOT
`spl-cloud-dispatch.func.sh`, NOT any other function of `spl-self-host-up.func.sh`, NOT
the other `${1:?}` lines (section 7). Do: plan section 2 row 02 verbatim, 1.4's shape;
the red control (the case against the parent's site) RED then GREEN in the body.
Gates: the 10 test files of 1.4 (each, rc and pass lines in the body,
`SPOOL_TEST=1`), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| kinds in `spl-desk-reply.sh`'s usage | 5 today -> 12 after row 01 (= the reply action's check) |
| `local x="${N:?...}"` lines, iac + orc + utl `lib/bash/funcs` and `src/bash/run` | 30 in 12 files today -> 29 in 11 after row 02 |
| measured on | `5083f4cf9`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| a `DESK_KIND` check in `spl-desk-reply.sh` (refuse a kind the action refuses) | a behaviour change: the launcher passes any kind to `spool send` today; a bug row if wanted | 1.3 |
| the other `local x="${N:?...}"` lines: iac `gcp-account-pin.func.sh` (5), `gcp-billing-cnf.func.sh` (2), `parse-metadata.func.sh` (4), `spl-cost-gcp.func.sh` (1), `tf-each-target.func.sh` (1), `validate-params.func.sh` (1); orc `gcp-account-pin.func.sh` (5), `parse-metadata.func.sh` (4), `validate-params.func.sh` (1); utl `parse-metadata.func.sh` (4), `validate-params.func.sh` (1) | r80 section 7's reasons hold: `gcp-account-pin` is a 2-copy row (iac, orc), `parse-metadata` and `validate-params` 3-copy rows (iac, orc, utl); `tf-each-target.func.sh:14` runs under `set -e` by design; `gcp-billing-cnf` and `spl-cost-gcp` sit beside the queued spec 123 cost lanes (L2b-L7, 2.2). **First candidate for r82:** `gcp-account-pin.func.sh` (iac + orc, one row, byte-identical copies) | 1.2 |
| r80-01 R7 N1-N4 | N1, N2 notes on a gate right today; N3 behaviour; N4 a test-environment note | 1.2 |
| `spl-spawn-place-argmax.tst.sh` section 9 guard cases (b30-01 R7 N1) | a test row; the placer files sit beside bug round 33 | candidates |
| spec 182 L2 `!inserted` branch untested (SPL-6032 R7 N1) | a hub Go test row | candidates |
| `ws-docs-head.mjs` synthetic click (SPL-6115 R7 W1) | WUI test hardening; WUI lanes live (2.2) | candidates |
| spec 181 B10 N1, N2, N4 | spec text of specs 121, 122, 123, 159: doc rows for those specs' owners | candidates |
| `terraform init` without `-input=false`; the desk hop's env forwarding | behaviour changes: bug rows (r78 section 7) | r78 1.2 |
| `spl-spool-refresh.func.sh:55`, `spl-wd-ensure.func.sh:194`; the iac / utl spelled lines | r76 to r80's reasons hold | r80 7 |
| the 3 tenant-dir sites, `gcp-backup-env.func.sh` | secret-class work (the data rule), r73 to r80 | r77 1.3 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, or the full sweep; the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-722): first draft. A fresh round: row 01 makes the desk-reply launcher's
  usage list the reply action's 12 kinds (r80's first candidate), row 02 makes
  `do_hub_deploy_roll_none` return 1 on an empty argument. Every named test run on the
  row's head (1.5). Window W and the r81 slug proof recorded.
- v1.0 (c-722): the panel seat m-723 (mistral) PASS on v0.1
  `7dbfe9f783ffcbcdb5a3738a9d01900186282eee` (spool msg e0b5abaf; seat file `85ef799a7`
  on `review/c002-refactor-round-81-mistral-seat`, folded into this landing), no W
  finding. Its notes, none changing a row:
  - N1: row 02 changes only the empty or missing argument path (an exit becomes
    `return 1` plus a usage line); one caller (`:283`, `|| return 1`), disclosed in 1.4,
    pinned by its control, as r80-02 was. Recorded; no change.
  - N2: two citations corrected: `usage()` is `:26-29` (`:25` is blank), and 1.3's grep
    returns 2 files, not 4 (`watcher-read-only.tst.sh` names the `.func.sh`,
    `orc-shard-weights.txt` names `spl-desk-reply-ref.tst.sh`). Row 01's gate list keeps
    `watcher-read-only.tst.sh` as a neighbour. No row site moved.
  - N3: live state moved between the two reads (lane map 16 -> 17 `unknown:` lanes,
    exit 4 both; queue 15 -> 13; branches in 24 h 78 -> 86; `(r80-` since W 3 -> 4,
    `dc435a712`, the r80 close record, 07:06:40Z). The holder re-checks before placing.
    **W stays as recorded** (rulebook 5.3: read once when the round opens): a
    re-derive now names `dc435a712`, a later edit of the previous plan.
  - N4: `origin/master` moved past the base (`dc435a712`, `0e9efb6c2`); the 4 row files
    are unchanged (`git diff --name-only 5083f4cf9 origin/master -- <4 files>` empty).
    The install guide's reverse-tunnel literal stays under r80 section 7's ruling (a
    Qto export: an ask to the holder).
  - The holder's grok read (c-002, `do_spl_box_pick` at 07:07Z): `pick=hold`, grok
    weekly unknown on both boxes, so the claude waiver seat (1a7c70da) stands (4).
- Round closed (c-722), no version bump: the 2 rows landed, r81-01 `3174e591a`
  (SPL-6163, R7 c-699 PASS on `b4f602bf6`), r81-02 `1fd68677a` (SPL-6164, R7 c-702
  PASS on `1a9c457fe`); both R7 seats claude under waiver 1a7c70da (grok pick on hold).
  Both ACCEPTED by the holder (c-002 msg 27fefdb4; quality gate runs 44882447018 and
  44882693034, success). `merge-base --is-ancestor` rc 0 for both on `f8667b9b0`. On
  that sha (n=1 each, `SPOOL_TEST=1`, in the worktree, 1.5's line counts):
  `test-spool-kinds.sh` rc 0, 45 pass; `desk-root-readers.tst.sh` rc 0, 37 pass;
  `watcher-read-only.tst.sh` rc 0, 81 pass; `enc-dirs-untouched.tst.sh` rc 0, 18 pass;
  `check-hub-deploy.tst.sh` rc 0, 56 pass; `bash-cleancode.tst.sh` rc 0, 15 pass; 0 fail
  lines each. Every count equals 1.5's head column: no drift, no plan miss. The other 9
  files of 1.4's grep were not re-run at close (their rows' R7 lines carry them).
  Status line and sections 8 and 9 only.
  - **First inputs for round 82:** section 7 as it stands, re-measured; the remaining
    `local x="${1:?...}"` lines of r80 section 7, less this round's one file, re-counted.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-722 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-723 (mistral) PASS** on
  `7dbfe9f783ffcbcdb5a3738a9d01900186282eee` (spool msg e0b5abaf to the editor, task
  `dispatch-refactor-r81`; seat file `85ef799a7` on
  `review/c002-refactor-round-81-mistral-seat`, in
  `csi-spl-doc/doc/md/refactor-round-81/seat-mistral.md`), no W, N1-N4 recorded. agy
  was unavailable (out until about 11-24), so mistral took the seat. The holder's
  review-line check on that line: rc 0 ("OK 2 of 2 ran: tests found in" the seat's
  session dir: `check-hub-deploy.tst.sh`, `test-spool-kinds.sh`; holder c-003 GO msg
  2e13e939; the seat's line forwarded by c-002, msg 70cf9639).
- Panel delta: **m-723 (mistral) PASS** on v1.0
  `864f7ff17f842cd9b60d8b3067138e3dec2bc6cf` (spool msg a801be62; seat file `24a8020a0`
  on `review/c002-refactor-round-81-mistral-seat`, folded into this close), no W: v1.0
  changes no row (the 4 row files diff empty v0.1 -> v1.0). The holder's review-line
  check on that line: rc 0 (c-002 note 97cbfb31, msg 9c237038).
- Row R7 seats: section 4.
- Closed: both rows landed (r81-01 `3174e591a`, R7 c-699 PASS; r81-02 `1fd68677a`,
  R7 c-702 PASS). This close record carries `Closes: SPL-6161`.
