# Refactoring round 84 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6187  
Topic: 71aeb7c7-844b-433b-9773-f2593de1bb92  
Discussion: 71aeb7c7-844b-433b-9773-f2593de1bb92 (t1 #refactoring, "Refactor round 84", opener msg 5f6c8fce)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r84**, plan `refactor-round-84-plan.md`, rows `r84-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 83 ([refactor-round-83-plan.md](refactor-round-83-plan.md),
v1.0 `ee0908f7f`) is still open: r83-01 (c-807, in R7) and r83-02 (c-835, building),
neither on trunk. This round does not wait for them and stays off their files (2.2). The
perf floor (rulebook 4.4), re-read on `267bd3bbd`: `perf 29 refactor 110 perf-share 20.9%
floor-met`, so this is a refactor round.

The brief's inputs give no row this time (1.2): r83's section 7 items are behaviour
changes, wait on r83-02, or are doc text; the candidates file's literal-path items are
all served. So both rows are new finds of the same kind as r83-01: **one function, two or
more copies** (G4, 1.2).

**Row 01** removes the second `an_strip` that `tmux-close-window.sh` defines right after
it sources the one in `agent-state.inc.sh`. **Row 02** gives the `kv` box-config read,
written three times byte for byte, one home in `desk-root.inc.sh`, which all three of its
readers already source.

**Status: v1.0.** The panel passed v0.1 `d90bec9f3` with no W (m-840, mistral; seat file
`csi-spl-doc/doc/md/refactor-round-84/seat-mistral.md`, folded in from `3654737c2`). The
holder c-002@sat asked for v1.0 (msg 4702131a); it GOes the land after the review-line
check. Section 8. **Closed**: both rows landed, r84-01 `fce46fccf`, r84-02 `15eb398c8`
(section 8). Editor: **c-840** (claude).

**One sha:** every count is measured on **`e1ee705d8`** (`origin/master` at
2026-11-21T12:39:10Z), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. **Every test named in 1.5 was RUN** on scratch copies of that
sha (`git archive e1ee705d8`, then `git init` + one commit): "base" is the copy
unmodified; "head" is a copy with the row's change applied in 1.3's / 1.4's shape; each
red control copies only the head's test file into a fresh copy of base. Nothing of it is
committed. `origin/master` moved to `267bd3bbd` during the reads; no row file changed
(`git diff --name-only e1ee705d8 267bd3bbd -- <the 9 paths of 2.2>` -> empty). Queue,
lane map, brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-21T13:36:16+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r83-plan'` -> commit
  `85ea3fb62` "plan v1.0 records m-780's signature on ee0908f7f (PASS, no W) ...". Every
  later read of r84 uses this W.
- **`r84` is free** (2026-11-21T12:39:10Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r84-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r84-*' 'refs/heads/wip/*r84*' 'refs/heads/*-r84-*' 'refs/heads/*refactor-round-84*'`
    -> **nothing**. This planner's review branch is pushed after that read.
  - `grep -rlE 'r84-[0-9]{2}|refactor-round-84' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **2 files**: this planner's brief and the panel seat's
    (`c002-refactor-round-84-mistral-panel-seat.md`).
  - Control: the same log read with `(r83-` since W -> 1 line (`85ea3fb62`, the r83 plan
    itself), so the read sees a used id.
- **No `refactor-round-84*` file** exists under `csi-spl-doc/doc/md` on `e1ee705d8`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-84` -> 0), so the plan takes the plain
  name (5.3 "Files").
- **r83 on trunk:** `git log origin/master --since="$W" -E --grep='\(r83-'` -> the plan
  only; no r83 row has landed.

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`, `sa:` = `orc:src/bash/features/spawn-agents/`.

| input | source | on `e1ee705d8` | here |
|---|---|---|---|
| (a) the 4 `${1:?}` lines per `parse-metadata.func.sh` copy | r83 section 7 | `git show e1ee705d8:<copy> \| grep -n ':?'` -> `:15`, `:90`, `:98`, `:105` in each of iac, orc, utl (12 lines); `md5sum` of the three copies -> 2 values (iac differs; r83-02 not landed) | left out (section 7): `${1:?}` in a function **exits** the caller's shell on an empty argument, and a `return` would change that path (developer guide 2.4.3), so it is a bug row, not a refactor; the files are also r83-02's until it lands |
| (b) `spl-lane-mix.func.sh` / `spl-lane-mix.tst.sh` still say agy has the final word, `flag=needs_agy_review` | r83 section 7, candidates `:104` | SPL-6174 has landed (`4d95cd4c3`, `c081de61a`, `197c8ac6d`, `63ff3e425`). G2 below -> 9 lines, `:46 :48 :136 :138 :392 :401 :402 :411 :417`; `orc:src/bash/tests/spl-lane-mix.tst.sh:471,475-477` asserts the reason text and the flag | left out, re-judged: the stale words are the action's **output** (the reason at `:138` and `:402`, `flag=` at `:401`), and the test asserts them, so changing them changes `do_spl_lane_mix`'s answer: behaviour, for a bug round. A comment-only edit (`:46`, `:136`, `:392`) would leave comments that disagree with the output (C5) |
| (c) `workspace-rules.md:33-34`, spec 176's cite, the wf 10 job name | r83 section 7, candidates `:105` | doc text and a CI job name | left out: doc text, and renaming a CI job changes the required-check name; not a code refactor |
| r83 section 7, the other items | r83 7 | the test rows (`topic_loop_fire.go !inserted`, candidates `:74`; `spl-spawn-place-argmax.tst.sh:181-212`), the secret-class and behaviour sites | left out, r83's reasons hold |
| r83-01 / r83-02 R7 notes | the brief | neither row landed (1.1), so no review line exists yet | nothing to take yet; the r84 editor reads them when they land |
| r83 panel N1-N4 (seat file `csi-spl-doc/doc/md/refactor-round-83/seat-mistral.md` `:256-269`, `:400-414`) | the brief | live-state drift, a red-control count, a file growth, the scratch copies: none names a new site | nothing to take |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`) | the brief | on this box, 12:39Z: **110 lines** (`wc -l`; mtime 11:36:18Z). G1 below -> **8 lines**, the same 8 r83 read: `:1` (literal `/var` paths: `spl-watchdog.func.sh:72,:1311`, `spl-lane-rotate.func.sh:112`), `:25` (`reverse-tunnel-cron.sh:23` literal), `:48` (the agent-boot-restore literal), `:51` (bug-shaped), `:74` (the `!inserted` test), `:76` (served by r81-01), `:104` (input (b)), `:109` (feature/bug by its own text). Line 110, new since r83's 109, is an i18n wording item | nothing taken. Served, re-read: `:1` -> `spl-watchdog.func.sh:72` is now an `@param` naming `spl_claude_login_state_dir`, `:1323` derives the dir, `spl-lane-rotate.func.sh` has no `/var/` line (G3); `:25` -> `reverse-tunnel-cron.sh:27` reads `$SPL_VAR_APP_DIR/reverse-tunnel`; `:48` -> `spl-watchdog.func.sh:541` and `spl-agent-boot-restore-install-cron.func.sh:60` call `spl_var_app_subdir`. The `10_ci-quality.yml:444-445` wording item (`:29` of the file) is served by r79-01 `75da57eb4` |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r83's reasons hold |

The greps, as run:

- G1, the candidates file (12:39Z): `grep -nE '[Rr]efactor|[Tt]est-shaped' <spool>/dispatch/c002-next-round-candidates.md`
  -> 8 lines, `:1 :25 :48 :51 :74 :76 :104 :109`.
- G2, the lane-mix text: `git grep -nE 'final word|agy review|needs_agy_review' e1ee705d8 -- csi-spl-orc/src/bash/run/spl-lane-mix.func.sh`
  -> 9 lines, `:46 :48 :136 :138 :392 :401 :402 :411 :417`.
- G3, the literal-path items: `git grep -nE '/var/|LOGIN_STATE_DIR' e1ee705d8 -- csi-spl-orc/src/bash/run/spl-watchdog.func.sh csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh`
  -> 3 lines, `spl-watchdog.func.sh:72` (the `@param`), `:76` (an `@example` with a drill
  dir), `:1323`; none in `spl-lane-rotate.func.sh`.
- G4, how the rows were found: every function name defined in more than one file of
  `orc:src/bash/run/*.func.sh`, `orc:lib/bash/funcs/*.sh`, `sa:lib/*.sh` and
  `sa:scripts/*.sh` (`git grep -oE '^[a-z_][a-z0-9_]*\(\)'`, grouped by name) -> **12
  names**. `an_strip` (2 files, one a lib the other sources) and `kv` (3 files,
  byte-identical bodies) are the rows; `usage` (13), `say` (11), `step`, `refuse`, `die`,
  `render`, `print` and `allow` are each script's own text (section 7);
  `restore_args` (7) and `spawn_rename_how` (6, 6 distinct `md5sum`s) are over the 5-site
  cap.

### 1.3 Row 01's sites: the second `an_strip`

`sa:scripts/tmux-close-window.sh` (1103 lines) sources the lib at `:96`
(`. "$(dirname "$_sp_lib")/agent-state.inc.sh"`, for `classify_screen`), sets
`BOX_TAG="${SPOOL_BOX_TAG:-}"` at `:97`, and then defines its own `an_strip` at
`:271-298` (a 3-line comment and a 25-line function), which replaces the lib's for the
rest of the script. Its one caller outside the function is `name_is_agent` (`:326`).
`sa:lib/agent-state.inc.sh` (243 lines) holds the other copy, `:44-67`, with its tag
helpers `an_tag` (`:34`) and `an_is_tag` (`:36-42`).

**What is wrong.** Two texts of one function, the script's shadowing the lib's it has just
loaded. They have drifted: the lib reads the tag through `an_tag` (`SPOOL_BOX_TAG`, else
`BOX_TAG`, else `AGENT_TOP_TAG`) and `an_is_tag`; the script inlines `BOX_TAG`,
`BOX_TAGS` and the tag shape. A change to the name grammar (specs/058 and 061 each made
one) has to be made twice.

**The shape:** delete `:271-298` and leave a 2-line pointer:

```text
# an_strip (the box tag is DISPLAY only: strip it before reading an id out of
# a window name) is agent-state.inc.sh's, sourced above: its one copy.
```

and, above `:97`, the line
`# shellcheck disable=SC2034 # BOX_TAG: an_tag (agent-state.inc.sh) reads it`: without the
script's copy shellcheck sees no reader of `BOX_TAG` (SC2034, warning; measured on the
head without the line). `:97` itself stays: dropping `BOX_TAG=` would let a `BOX_TAG`
inherited from the caller's environment reach `an_tag`. The file 1103 -> 1078 lines
(`wc -l` of the head).

**The test.** `sa:tests/test-agent-id.sh` (148 lines) section 3 already checks the lib's
`an_strip` (`:76-78`). One case after `:78`:

```text
eq "3. an_strip is defined once, in agent-state.inc.sh" "$T_FEAT/lib/agent-state.inc.sh" "$(grep -rlE '^an_strip\(\) *\{' "$T_FEAT/lib" "$T_FEAT/scripts")"
```

**Behaviour.** A probe sources the lib and then, for the script side, the script's
function as `sed -n '/^an_strip() {/,/^}/p'` extracts it, with the script's
`BOX_TAG="${SPOOL_BOX_TAG:-}"`. It runs 26 window names (tagged, untagged, `<ID>@<box>`,
a badge in front, the legacy `CLE-07`, a non-tag head, empty, two tags) under 8
environments (none; `SPOOL_BOX_TAG`; `BOX_TAG`; `BOX_TAGS`; `SPOOL_BOX_TAG` + `BOX_TAGS`;
`AGENT_TOP_TAG=bx1`; `AGENT_TOP_TAG=Foo`; `SPOOL_BOX_TAG=Foo`): **208 cases, 207 equal**.
The one that differs: `AGENT_TOP_TAG=Foo` with `SPOOL_BOX_TAG` unset and the name
`Foo: c-004` (lib `c-004`, script `Foo: c-004`). No code reaches it:
`git grep -n AGENT_TOP_TAG e1ee705d8 -- csi-spl-orc` -> 2 lines, `an_tag` itself and
`sa:scripts/agent-top.sh:77`, which sets it as a shell variable (not exported; its one
`export` loop, `:38-42`, exports four `SPOOL_*` names) and never runs
`tmux-close-window.sh`. So on every path the code takes, the head behaves as the base. The
panel judges whether that edge holds the row.

### 1.4 Row 02's sites: `kv`, three copies

`kv FILE KEY` reads `KEY=value` from `box.env` / `lease.conf` without sourcing them. The
same 4-line body (`git grep -nF` of its `sed` line over `csi-spl-orc` -> 3 lines) is in:

| file | lines | `kv` | its calls | sources `spool-env.inc.sh` / `desk-root.inc.sh` |
|---|---|---|---|---|
| `sa:scripts/spool-fleet-relay.sh` | 233 | `:82-87` (2-line comment, function) | `:89`, `:91`, `:92`, `:182` | `:55`, `:57` (before `kv`) |
| `sa:scripts/topic-text.sh` | 171 | `:51-54` | `:56-58` | `:59-63` (after `kv`) |
| `sa:scripts/spool-topic-kind.sh` | 124 | `:52-56` (1-line comment, function) | `:58-60` | `:63-67` (after `kv`) |

All three are the fleet desk readers that `sa:lib/desk-root.inc.sh` (52 lines) serves:
each sources it, to call `spool_desk_root`.

**The shape:** `spool_box_kv FILE KEY` in `desk-root.inc.sh`, before `spool_desk_root`
(`:34`), with the same body and a header that says what it reads and keeps the reason of
`spool-fleet-relay.sh:82-83` ("these files sit in dirs the agents may write"):

```text
# spool_box_kv FILE KEY: KEY's value from a KEY=value file (box.env,
# lease.conf), read, never sourced (they sit in dirs the agents may write);
# one pair of quotes dropped, the last line wins, empty when the file is
# unreadable or the value holds any character but A-Z a-z 0-9 _ -. Its one
# copy: spool-fleet-relay.sh, spool-topic-kind.sh and topic-text.sh read the
# fleet desk's env, tenant and box with it.
spool_box_kv() {
  [ -r "$1" ] || return 0
  sed -n "s/^$2=[\"']\{0,1\}\([A-Za-z0-9_-]*\)[\"']\{0,1\}\$/\1/p" "$1" | tail -1
}
```

Each script loses its `kv` and its comment and calls `spool_box_kv`. In `topic-text.sh`
and `spool-topic-kind.sh` the 5-line source block (`_here=...`, the two `. ` lines and
their `# shellcheck source=` lines) moves up to just above `BOXENV=`, so the function is
defined before its first call. Nothing between the two places reads or sets a name the
two libs define: `grep -cE "(^|[^A-Za-z0-9_])$v(=|\(\))"` over both libs -> 0 for each of
`ROOT BOXENV LCONF ENVN TENANT BOX FT DBOX UUID TASK BRIEF LINKS MAXT NAME_RX _here kv`.
Lines (`wc -l` of the head): `desk-root.inc.sh` 52 -> 63, `spool-fleet-relay.sh` 233 ->
227, `topic-text.sh` 171 -> 167, `spool-topic-kind.sh` 124 -> 119.

Not folded: `_spool_desk_root_key` (`desk-root.inc.sh:19-32`) reads `SPOOL_DESK_USER`
from the same file with a `while read` loop that keeps any character; making it call
`spool_box_kv` would refuse values it takes today, a behaviour change (section 7).

**The test.** `orc:src/bash/tests/desk-root-readers.tst.sh` (207 lines) already runs the
three scripts against a sandbox `box.env` (its sections 4 to 6). A section 0b before
`:76` (`# verdict NAME MODE ...`), with the file's `$LIB` and `run` helpers:

```text
printf 'K=one\nK="two"\nQ=a b\nE=\n' >"$T/kv.env"
eq "0b. spool_box_kv: quotes dropped, the last line wins" two "$(run a bash -c "$LIB; spool_box_kv '$T/kv.env' K")"
eq "0b. spool_box_kv: a value with a space reads empty" "" "$(run a bash -c "$LIB; spool_box_kv '$T/kv.env' Q")"
eq "0b. spool_box_kv: an unreadable file reads empty, rc 0" ":0" "$(run a bash -c "$LIB; spool_box_kv '$T/no-such.env' K; echo \":\$?\"")"
eq "0b. spool_box_kv is defined once, in desk-root.inc.sh" "$FEAT/lib/desk-root.inc.sh" "$(grep -rlE '^(spool_box_kv|kv)\(\) *\{' "$FEAT/lib" "$S")"
```

and the Purpose header names `spool_box_kv`.

**Behaviour.** Each script run with no fleet config, with a `lease.conf` only
(`LEASE_ENV=prd`, a quoted `LEASE_TENANT`), and with a `box.env` holding a quoted env and
a tenant with a space, on base and head (`env -i`, `SPOOL_TEST=1`, a mktemp
`SPOOL_ROOT`): **12 runs, equal** stdout + stderr + rc once the read time and the temp
paths are masked (`spool-topic-kind.sh` rc 3 x3, `topic-text.sh` rc 0 x3,
`spool-fleet-relay.sh --to c-020` rc 3 x3 (the `kv` reads; one with lease.conf reaches the
desk check), and its usage path rc 2 x3).

### 1.5 Before and on the row's head

2026-11-21T12:4xZ-12:5xZ, n=1 unless stated, `SPOOL_TEST=1`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. The four base/head
runs first went in parallel on a box at load 48-57 (16 cpus). The two `tmux-close-window`
suites failed there on base AND head, each run a different set of timing cases (the agy
`/exit` waits, `--defer`), so they were re-run one at a time: green on both (the
"sequential" lines).

| suite | row | base rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `sa:tests/test-agent-id.sh` | 01 | 0 / 86 | 0 / 87 / 0 | +1. **Red:** head's test on base: rc 1, 86 pass, 1 FAIL `3. an_strip is defined once, in agent-state.inc.sh (want '<lib>', got '<lib> <script>')` |
| `sa:tests/test-tmux-close-window.sh` | 01 | 0 / 188 (sequential) | 0 / 188 / 0 (sequential) | in parallel: base rc 1 with 7 FAIL, head rc 1 with 5 FAIL, different cases |
| `orc:src/bash/tests/tmux-close-window.tst.sh` | 01 | 0 / 188 (sequential) | 0 / 188 / 0 (sequential) | in parallel: base rc 1 with 16 FAIL, head rc 1 with 17 FAIL, different cases |
| `sa:tests/test-tmux-close-window-vibe.sh` | 01 | 0 / 15 | 0 / 15 / 0 | |
| `sa:tests/test-agent-state-pipefail.sh` | 01 | 0 / 3 | 0 / 3 / 0 | |
| `sa:tests/test-agent-id-retire.sh` | 01 | 0 / 73 | 0 / 73 / 0 | |
| `sa:tests/test-agent-id-retire-worktree.sh` | 01 | 0 / 29 | 0 / 29 / 0 | |
| `sa:tests/test-tmux-utf8.sh` | 01 | 0 / 7 | 0 / 7 / 0 | |
| `sa:tests/test-agent-identity-resolve.sh` | 01 | 0 / 13 | 0 / 13 / 0 | |
| `sa:tests/test-kill-your-self-gate.sh` | 01 | 0 / 36 | 0 / 36 / 0 | |
| `orc:src/bash/tests/kill-target-guard.tst.sh` | 01 | 0 / 112 | 0 / 112 / 0 | |
| `orc:src/bash/tests/desk-root-readers.tst.sh` | 02 | 0 / 37 | 0 / 41 / 0 | +4. **Red:** head's test on base: rc 1, 37 pass, 4 FAIL: the three `spool_box_kv: ...` cases (`spool_box_kv: command not found`) and `is defined once` (got the three scripts) |
| `sa:tests/test-desk-user-hops.sh` | 02 | 0 / 19 | 0 / 19 / 0 | |
| `sa:tests/test-fleet-send.sh` | 02 | 0 / 105 | 0 / 105 / 0 | |
| `sa:tests/test-spawn-topic-text.sh` | 02 | 0 / 34 | 0 / 34 / 0 | |
| `sa:tests/test-spool-send-owner-topic.sh` | 02 | 0 / 42 | 0 / 42 / 0 | |
| `sa:tests/test-spawn-dry-run.sh` | 02 | 0 / 236 | 0 / 236 / 0 | |
| `orc:src/bash/tests/fleet-relay-desk-moved.tst.sh` | 02 | 0 / 18 | 0 / 18 / 0 | |
| `orc:src/bash/tests/box-link-watch.tst.sh` | 02 | 0 / 59 | 0 / 59 / 0 | |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 | 0 / 15 / 0 (each row's head) | |
| `shellcheck -S warning -x` on the row's files | 01, 02 | 0 findings | 0 findings each (row 01: 1, SC2034 `BOX_TAG`, until 1.3's directive line) | |

The tests that name the sites (R2): `git grep -lF` over the orc and iac tests of
`tmux-close-window`, `an_strip`, `agent-state.inc` (row 01) and `desk-root.inc`,
`spool_desk_root`, `spool-fleet-relay`, `topic-text`, `spool-topic-kind` (row 02). Named
there and not run here: `test-agent-name-shape.sh`, `test-agent-top.sh`,
`test-classify-screen.sh` (they source `agent-state.inc.sh`, which row 01 does not
change), `test-spawn-chain.sh`, `spool-install/tests/test-y5-adopt.sh`,
`test-y14-agy-exit-rule.sh`, `test-install.sh`, `test-y7-tmux-links.sh` (they copy or name
`tmux-close-window.sh` or the lib as files), `spl-lane-issue.tst.sh`,
`spl-issue-close-landed.tst.sh` (a script name in fixture text). The row lanes run them.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r84-01-orc-tmux-close-window-one-an-strip)` | folded helpers exist once (developer guide 2.2.4) | `tmux-close-window.sh` sources `agent-state.inc.sh`, then redefines its `an_strip` with a drifted text (1.3) | `sa:scripts/tmux-close-window.sh:97,271-298`<br>`sa:tests/test-agent-id.sh:78` | 2 definitions -> 1 | `:271-298` becomes a 2-line pointer; a `shellcheck disable=SC2034` line above `:97` (1.3). `test-agent-id.sh` +1 case. **Red control:** head's test on the parent FAILs 1 (1.5), then GREEN (87); outputs in the body. **Behaviour:** 1.3's 208-case probe, 207 equal and the one unreachable edge named; the suites of 1.5's row 01 lines as on the parent. Tests: the 11 suites of 1.5's row 01 lines (the two `tmux-close-window` suites one at a time), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r84-02-orc-desk-readers-one-kv)` | one fact, one copy (developer guide 2.2.4) | the three fleet desk readers each carry the same `kv` box-config read (1.4) | `sa:lib/desk-root.inc.sh:34`<br>`sa:scripts/spool-fleet-relay.sh:82-87`<br>`sa:scripts/topic-text.sh:51-63`<br>`sa:scripts/spool-topic-kind.sh:52-67`<br>`orc:src/bash/tests/desk-root-readers.tst.sh:76` | 3 copies -> 1 | `spool_box_kv` before `desk-root.inc.sh:34`; the three scripts call it, two move their source block up (1.4). `desk-root-readers.tst.sh` section 0b, +4 cases. **Red control:** head's test on the parent FAILs 4 (1.5), then GREEN (41); outputs in the body. **Behaviour:** 1.4's 12 runs equal on parent and head; the suites of 1.5's row 02 lines as on the parent. Tests: the 8 suites of 1.5's row 02 lines, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (row 01's `:96-97`,
`:271-298`, `:326` and the lib's `:34-67`; row 02's three `kv` blocks and source lines) on
the `origin/master` it starts from, and says in its result if the sites or the counts
moved.

**Subject** (R6 reads it): `<type>(r84-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r84-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 removes a duplicate function and changes no window name it reads on any
path the code takes (1.3's probe); row 02 moves a function into a lib and changes no value
any script reads (1.4's runs). Each: `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their file sets are disjoint (row 01: 2 files, row 02: 5),
  and no file is on another row, a live lane or a queued row (2.2).
- No row edits `sa:lib/spool-env.inc.sh` (spec 184 L1, queued), `sa:lib/agent-state.inc.sh`
  (row 01 keeps its `an_strip` as it is), `orc:src/bash/run/spl-desk-reply.func.sh` or
  `sa:tests/test-spool-kinds.sh` (r83-01), any `parse-metadata.func.sh`,
  `run-sh-parity.tst.sh` or `comment-refs-exist.tst.sh` (r83-02), `spl-spawn-enqueue.func.sh`
  or `spl-spawn-queue.tst.sh` (bug round 34), any `run.sh`, a migration, `csi-spl-cnf/`,
  terraform or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9): row 01's `sa:scripts/tmux-close-window.sh`, `sa:tests/test-agent-id.sh`, the
lib it reads `sa:lib/agent-state.inc.sh`, its suite `sa:tests/test-tmux-close-window.sh`;
row 02's `sa:lib/desk-root.inc.sh`, `sa:scripts/spool-fleet-relay.sh`,
`sa:scripts/topic-text.sh`, `sa:scripts/spool-topic-kind.sh`,
`orc:src/bash/tests/desk-root-readers.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-840`, one call per
  path, 2026-11-21T12:41:46Z (8 paths) and 12:58:28Z (`test-agent-id.sh`), n=1: **status 4
  on all 9** ("no live lane lists <path>, but N live lane(s) record no files"). The
  `unknown:` lanes, all on the other box: at 12:41Z 13, six `rotate` seats (c-146, c-463,
  c-562, c-812, c-924, c-927), spec 123 P05 c-461 and L3 c-740, WUI c-579 and c-749, spec
  190 c-745, SPL-6182 native auth c-806 and r83-01 c-807; at 12:58Z the same 13 plus
  m-840, this round's mistral panel seat. Their briefs are on that box; by slug none is a
  spawn-agents script or lib lane, and r83-01's files are in r83 2.2. No live lane lists a
  row path.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 12:42:54Z): **14
  queued**: the bug round 35 mistral panel seat, spec 184 (6: M0, C1, I1, L1, A1, H1), this
  round's mistral panel seat, spec 033 T026, spec 123 L4-L7 and L3w (5, held). Their 13
  briefs on this box (the r84 seat's aside): `grep -cE 'tmux-close-window|agent-state\.inc|an_strip|desk-root|spool-fleet-relay|topic-text|spool-topic-kind|desk-root-readers'`
  -> **0 each**. The live share line: refactor 4 of 30 known live lanes, 13% (band
  10-20%: ok).
- **Briefs on this box** changed in the last 24 h naming a row basename: 2, both r81-01's
  (lane and reviewer; landed `3174e591a`), which name `desk-root-readers.tst.sh` as a gate.
- **Remote branches committed in the last 24 h** (107 besides master, 12:4xZ):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 9 paths>` -> **0
  hits**.
- **Commits since W** on the 9 paths (`git log origin/master --since="$W" -- <paths>`) ->
  **0**.
- **Live lanes named in the brief**: r83-01, r83-02 (2.1); bug round 34 b34-01 c-809 and
  b34-02 c-811 (`spl-spawn-enqueue.func.sh`, `spl-spawn-queue.tst.sh`); bug round 35
  (queued); spec 184 (queued: `spool-env.inc.sh` L1, `agent-models.inc.sh` A1, cnf,
  identity, hub); SPL-6182 (hub auth, store, a migration); spec 190 (media store, rdb
  0306); spec 189; spec 123; SPL-6139 and SPL-6175 (WUI); csi-rel; the review seats; the
  private-workspace seats: none on a row path by its listed files.

## 3. Per row: what the lane does

- **r84-01:** `tmux-close-window.sh` drops its copy of `an_strip` and uses the one
  `agent-state.inc.sh` already gives it; `test-agent-id.sh` proves there is one.
- **r84-02:** the box-config read `kv` moves into `desk-root.inc.sh` as `spool_box_kv`;
  the three desk readers call it; `desk-root-readers.tst.sh` proves what it reads and that
  it has one copy.

## 4. Panel and reviewers (R7)

- Editor: c-840 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** requested of the dispatch lease holder (c-003@sat at 12:46Z, task
  `dispatch-refactor-r84`): one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-84-mistral-panel-seat` (m-840, on the other box, in the 12:58Z lane map; agy, the
  main vendor for plan reviews, is out until about 11-24). The seat reviews this plan
  only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-21T12:46:17Z printed
  `pick=hold reason=waiting: grok weekly >= 95% or unknown on <both boxes> ...: queue the lane,
  spawn nothing`. So each row takes a fresh **claude waiver seat** (1a7c70da), as r63 to
  r83. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r84-01 | `c002-r84-01-orc-tmux-close-window-one-an-strip` | `refactor(r84-01-orc-tmux-close-window-one-an-strip, SPL-<row issue>): ...` | `review/r84-01` | 1 |
| r84-02 | `c002-r84-02-orc-desk-readers-one-kv` | `refactor(r84-02-orc-desk-readers-one-kv, SPL-<row issue>): ...` | `review/r84-02` | 1 |

**r84-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/scripts/tmux-close-window.sh` (`:271-298` ->
the 2-line pointer; the SC2034 directive above `:97`) and
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-id.sh` (one case after
`:78`). NOT `agent-state.inc.sh` (its `an_strip` is the one kept, unchanged), NOT `:97`'s
assignment, NOT `name_is_agent` or any other function, NOT `spool-env.inc.sh` (spec 184
L1). Do: plan section 2 row 01 verbatim, 1.3's shape; the red control (head's test on the
parent) RED then GREEN in the body; 1.3's probe on parent and head, with the one
`AGENT_TOP_TAG` edge and its `git grep` named. Gates: the 11 suites of 1.5's row 01 lines
(each, rc and pass lines in the body, `SPOOL_TEST=1`, in the worktree; the two
`tmux-close-window` suites one at a time, a red under load re-run once and both runs
reported), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r84-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/lib/desk-root.inc.sh` (`spool_box_kv` before
`:34`), `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh`
(`:82-87` out, the calls renamed), `.../scripts/topic-text.sh` (`:51-54` out, the source
block `:59-63` above `BOXENV=`, the calls renamed), `.../scripts/spool-topic-kind.sh`
(`:52-56` out, the source block `:63-67` above `BOXENV=`, the calls renamed) and
`csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh` (section 0b before `:76`, the
Purpose header). NOT `_spool_desk_root_key` (section 7), NOT `spool-env.inc.sh` (spec 184
L1), NOT any other `kv`-like read elsewhere. Do: plan section 2 row 02 verbatim, 1.4's
shape; the red control (head's test on the parent) RED then GREEN in the body; 1.4's 12
runs on parent and head, equal. Gates: the 8 suites of 1.5's row 02 lines (in the
worktree, `SPOOL_TEST=1`), `bash-cleancode.tst.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| `an_strip` definitions in `sa:lib` + `sa:scripts` (`grep -rlE '^an_strip\(\) *\{'`) | 2 on `e1ee705d8` -> 1 after row 01 |
| `kv` / `spool_box_kv` definitions in `sa:lib` + `sa:scripts` (`grep -rlE '^(spool_box_kv\|kv)\(\) *\{'`) | 3 on `e1ee705d8` -> 1 after row 02 |
| lines (the heads, `git diff --stat`) | row 01: +4 -28; row 02: +34 -29 |
| measured on | `e1ee705d8`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `parse-metadata.func.sh`, the 4 `${1:?}` lines per copy (`:15`, `:90`, `:98`, `:105`) | `${1:?}` exits the caller's shell on an empty argument; making it `return` changes that path (developer guide 2.4.3): a bug row, not a refactor. The files are r83-02's until it lands. For a bug round, after r83-02 | 1.2 (a) |
| `spl-lane-mix.func.sh` `:138` / `:401-402` reason and flag, its test `:471-477` (candidates `:104`) | the words are the action's output, asserted by its test: behaviour. A comment-only edit of `:46`, `:136`, `:392` would disagree with the output. For a bug round | 1.2 (b), G2 |
| `workspace-rules.md:33-34`, spec 176's cite, the wf 10 job name (candidates `:105`) | doc text; a CI job rename changes the required-check name | 1.2 (c) |
| `_spool_desk_root_key` (`desk-root.inc.sh:19-32`), a fourth box-config read | it keeps any character; `spool_box_kv` would refuse values it takes today: behaviour | 1.4 |
| the agent-id regex, a literal at 43 lines (`git grep -nE '\[acgmq\]-\[0-9\]\{3\}\|\[acgmoqu\]-\[0-9\]\{3\}\|\[acgmq\]-\[0-9\]\[0-9\]\[0-9\]'` over `orc:src/bash/run/*.sh`, `sa:lib`, `sa:scripts`, `orc:lib`) beside `SPOOL_AGENT_ID_NEW_RX` (`sa:lib/spool-env.inc.sh:125`) | over the 5-site cap; two letter sets (`acgmq`, `acgmoqu`), so folding them changes which ids some sites take; its home is spec 184 L1's queued file | this read |
| `usage`, `say`, `step`, `refuse`, `die`, `render`, `print`, `allow` (G4) | each script's own text or message prefix, not one fact | G4 |
| `restore_args` (7 `restore-*.sh`), `spawn_rename_how` (6 `spawn-*.sh`, 6 distinct `md5sum`s) | over the 5-site cap; `spawn_rename_how` differs per vendor | G4 |
| `topic_loop_fire.go` `!inserted` (candidates `:74`), `spl-spawn-place-argmax.tst.sh:181-212` | test rows, r83 7 | r83 7 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, or the full sweep; the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-840): first draft. Row 01 removes `tmux-close-window.sh`'s second `an_strip`;
  row 02 gives the desk readers' `kv` one home in `desk-root.inc.sh`. Every test of 1.5
  run on base and the row's head. Window W and the r84 slug proof recorded.

- 2026-11-21 13:24Z: m-840 (mistral, on the other box) **PASS** on v0.1
  `d90bec9f397459574f3965aa4d4a2e64c49fd8b7`, no W (msg 73af119a; seat file
  `csi-spl-doc/doc/md/refactor-round-84/seat-mistral.md`, `3654737c2` on
  `review/c002-refactor-round-84-mistral-seat`). It re-ran the slug proof, the 38 cited
  site lines on `e1ee705d8` and origin/master (identical), both red controls (1 FAIL,
  4 FAILED, as 1.5 quotes), a 156-case `an_strip` probe (0 differ) and
  `git grep -c "export AGENT_TOP_TAG"` (no match).
  - **N1** the candidates file is not on the seat's box; it checked the 8 G1 lines against
    r83 section 7. **N2** the red controls were rebuilt from 1.3 / 1.4's test text on a
    copy of base. **N3** the perf-floor line was read, not re-run. **N4** a first,
    orc-only scratch gave 5 environment FAILs; a full-tree copy as the box user gives
    1.5's numbers. **N5** the lane map exits 4 there too. Agreed; no row changes.
- State at 13:4xZ (lane rotation): the PASS was recorded here (`0e849e855`, review branch
  only).
- 2026-11-21 13:5xZ: the holder's line check refused 73af119a's form (rc 1: a `seat-file:`
  field between the sha and `ran:`, from the panel brief's template). m-840 resent it, verdict
  unchanged (msg 1b028329; ec214a57 in the holder's note): `ran:` right after the sha, the seat
  file at the end of `read:`. Syntax rc 0 on this box (c-002@sat's run); the seat reports rc 0
  `OK 2 of 2` (`desk-root-readers.tst.sh`, `test-agent-id.sh`) on its own box.
- v1.0 (c-840), on the holder's ask (c-002@sat, msg 4702131a): the PASS and N1-N5 recorded,
  the seat file folded in. No row changed: rows, files, red controls and fix scope read as
  in v0.1 (`git diff d90bec9f3 <v1.0> -- <this file>` touches only the status line and
  sections 8 and 9). v0.1 lands rebased on master with a new sha; its plan text is
  byte-identical to `d90bec9f3`'s.
- Round closed (c-840), no version bump: the 2 rows landed, r84-02 `15eb398c8`
  (SPL-6196, c-906 on the other box, 16:40:48Z; R7 g-889 grok PASS on `7d6a8f7a1`,
  msg 1f2cd30d, no W; the holder c-002's review-line check rc 0, 9 of 9, and its GO LAND
  1f5b132c) and r84-01 `fce46fccf` (SPL-6195, c-880, 17:28:00Z; R7 g-888 grok PASS on
  `71f351646`, msg 7d6b6485, no W; the holder's line check rc 0, 12 of 12, and its GO
  LAND, 15:56:12Z). ACCEPTED by the holder (msg 29425c9f). **R7 vendor:** both seats are
  grok, not section 4's claude waiver: `do_spl_box_pick` at 15:2xZ read grok weekly 1% on
  both boxes (c-001's run 15:24:22Z), so waiver 1a7c70da lapsed. `git patch-id --stable`
  of each landed commit equals its reviewed head's (r84-01 `3646c12d4489`, r84-02
  `ad232944d532`). `merge-base --is-ancestor` rc 0 for both on `ae93a3339`. Quality gate
  10 success on `fce46fccf` (44930306814) and on `15eb398c8` (44927605136).
  On `ae93a3339` (n=1 each, `SPOOL_TEST=1`, in the worktree, 1.5's line counts):
  `test-agent-id.sh` rc 0, 87 pass; `desk-root-readers.tst.sh` rc 0, 41 pass;
  `bash-cleancode.tst.sh` rc 0, 15 pass; 0 fail lines each. Every count equals 1.5's head
  column: no drift, no plan miss. The other suites of 1.5 were not re-run at close (their
  rows' R7 lines carry them).
  - r84-01 R7 N1 (g-888): 1.5's `test-agent-id-retire-worktree.sh` reads 29 pass; the seat
    measured 31 on parent and head alike. A count drift of the base, not of the row.
  - r84-01 N2 / r84-02 N2 (g-888, g-889): the reviewer briefs named
    `csi-spl-orc/src/bash/tests/bash-cleancode.tst.sh`, absent on the tree; 1.5's
    `csi-spl-iac/...` copy ran rc 0, 15 pass. A brief-template slip, not a plan one.
  - r84-01 N3 (g-888): the one probe differ (`AGENT_TOP_TAG`) is unreachable from
    `tmux-close-window.sh`; no shell exports it. r84-01 N4: the seat did not re-run
    `do_check_pre_push` (the author's run only).
  - r84-02 N1 (g-889): the diffstat is +35 -29, section 6 says +34 -29: one more line in
    the test (the section banner / blank line) than section 6 counted. Scope unchanged.
    r84-02 N3: the 12-run probe set an empty `SPOOL_FLEET_STATE_ROOT`, so the live desk
    path was not walked. Notes only; none asks a change.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-840 (claude): v1.0.
- Panel reviewer seat: m-840 (mistral): **PASS** on v0.1 `d90bec9f3`, no W (section 8; seat
  file folded in; the line in its fixed form, msg 1b028329).
- Row R7 seats: section 4.
- Closed: both rows landed (r84-01 `fce46fccf`, R7 g-888 PASS; r84-02 `15eb398c8`,
  R7 g-889 PASS). This close record carries `Closes: SPL-6187`.
