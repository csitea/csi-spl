# Refactoring round 86 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6209  
Topic: a5843661-2703-4a69-99bc-1a64af3136bf  
Discussion: a5843661-2703-4a69-99bc-1a64af3136bf (t1 #refactoring, "Refactor round 86", opener msg 3d5ac13b)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r86**, plan `refactor-round-86-plan.md`, rows `r86-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 85 ([refactor-round-85-plan.md](refactor-round-85-plan.md))
is closed: both rows landed (r85-01 `662d8559d`, r85-02 `76a14993e`; close record
`6a68f6938`). The perf floor (rulebook 4.4), measured by the holder on `662d8559d`: perf
29, refactor 113, 5 x 29 = 145 >= 142, floor met, so this is a refactor round.

The brief's inputs give no row (1.2), so both rows are new finds of the r83 to r85 kind:
**one function, two or more copies** (developer guide 2.2.4).

**Row 01** gives the orchestrator and dispatcher rotation cron wrappers, which carry the
same PATH block, `say`, `check_tools` and checkout gate, one copy in a new
`scripts/rotate-cron.inc.sh` (the r85-01 shape). **Row 02** makes `hubclient.ParseDropAfter`,
the same body as `hubclient.ParseMinutes`, a one-line call into it, and adds a `folded`
entry to the Go clean code gate that keeps the parse in one file.

**Status: v1.0.** The panel passed v0.1 `8dc0ce940` with no W (m-035, mistral; seat file
`csi-spl-doc/doc/md/refactor-round-86/seat-mistral.md`, folded in from `354c87a1e`). Its
re-issued review line passed `do_spl_review_line_check` rc 0 on the log's box; the holder
c-002 GOed the land (msg eba2bada). Section 8. Editor: **c-028** (claude).

**One sha:** every count is measured on **`f074057b5`** (`origin/master` at
2026-11-21T19:4xZ), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. **Every test named in 1.5 was RUN** on scratch copies of that
sha (`git archive f074057b5`, then `git init` + one commit): "base" is the copy
unmodified; "head" is a copy with the row's change applied in 1.3's / 1.4's shape; each
red control puts only the head's test file into a copy of base. Nothing of it is
committed. Queue, lane map, brief and branch reads are live state and carry their own
time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-21T19:41Z, n=1:

- **Window: W=2026-11-21T18:21:36+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r85-plan'` as it read when this
  round opened (18:36Z): `d519dd8e5`, r85 plan v1.0. The r85 close record `6a68f6938`
  (2026-11-21T20:26:13+01:00) landed after the round opened, so W stays as read at open
  (5.3: "the planner reads W once, when its round opens"). Both dates give the same
  results below.
- `git log origin/master --since="$W" --oneline -E --grep='\(r86-'` -> **0**; over all
  history -> **0**.
- `git ls-remote origin 'refs/heads/review/r86-*' 'refs/heads/*-r86-*' 'refs/heads/*refactor-round-86*' 'refs/heads/wip/*r86*'`
  -> nothing.
- `grep -rlE 'r86-[0-9]{2}|refactor-round-86' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
  (as root, this box) -> 1 file, this planner's brief. The mistral panel seat is queued, not
  yet placed (2.2).
- `ls csi-spl-doc/doc/md | grep -c refactor-round-86` -> 0 before v0.1: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) Candidates file** (on the other box; the holder inlined its refactor-shaped lines,
  msg a726c92c, 19:42Z, not re-measured by it): `:1 :2 :25 :26 :29 :48 :74 :76 :83 :94
  :104 :105`. Re-measured on `f074057b5`:
  - `:1` the `LOGIN_STATE_DIR` default and the `spl-lane-rotate.func.sh` `/var` literal:
    served (`spl-watchdog.func.sh:72` reads `spl_claude_login_state_dir`;
    `git grep -n '/var/' -- csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh` -> 0).
  - `:25` the reverse-tunnel state dir: served (`reverse-tunnel-cron.sh:27` reads
    `$SPL_VAR_APP_DIR/reverse-tunnel`).
  - `:48` the agent-boot-restore dir: served (writer
    `spl-agent-boot-restore-install-cron.func.sh:60` and reader `spl-watchdog.func.sh:541`
    both call `spl_var_app_subdir`).
  - `:2` terraform `-input=false`, `${1:?}`, dropped rc: behaviour, bug rows.
  - `:26` `installation-and-configuration-guide.md:594` names the reverse-tunnel state dir
    as a literal: doc text of a Qto export (the guide is edited in Qto, not in git): left
    out (section 7).
  - `:29`, `:105` the wording of a workflow comment and a CI job name: a job rename changes
    the required-check name (r84 section 7).
  - `:74` `topic_loop_fire.go !inserted`, `:94` `spl-spawn-place-argmax.tst.sh:181-212`:
    test rows (r83 section 7), unchanged.
  - `:76` `spl-desk-reply.sh:9,19` usage lists 12 kinds: spec 033's lane (T026 m-896,
    help docs kinds) is live on the kinds; left to it.
  - `:83` `ws-docs-head.mjs` synthetic click: a WUI e2e test-hardening row, not a
    refactor (a real pointer changes what the test proves).
  - `:104` `spl-lane-mix.func.sh` "agy has the final word" words: the action's output,
    asserted by its test: behaviour (r84 section 7).
- **(b) r85 section 7:** unchanged on `f074057b5`; each item stays out for its reason
  there. `check_tools` in the other `*-cron.sh` wrappers is re-judged in 1.3: only the two
  rotation wrappers share one tool-list variable and one gate.
- **(c) r85 R7 notes:** r85-01 N1 (g-953, one blank line) and r85-02 (g-989, the
  dubious-ownership note) name no row. The r85 panel's N1-N6 name process points, no row.
- **(d) spec 011 tasks:** `git log origin/master --since="$W" --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks are those of r85
  section 7.
- **How the rows were found** (G4, as r84 and r85): every Bash function name defined in
  more than one file of the orc / iac / utl `src/bash` and `lib` trees, tests excluded,
  each body's `md5sum`; the per-module `run.sh`, `lib/bash/funcs` and `print-help` copies
  are byte-identical by design (developer guide 2.4.2) and left out. Then the same over
  the hub's Go (`func` bodies of 5+ lines, `_test.go` excluded, signature + body hashed).
  Bash: `check_tools` (16 files, one identical pair: `orch-rotate-cron.sh` and
  `dispatch-rotate-cron.sh` = **row 01**), `tf_get` (r85 section 7). Go, the same body and
  signature in one package: `ParseMinutes` / `ParseDropAfter` (`hubclient`) = **row 02**;
  the rest: section 7.

### 1.3 Row 01's sites: the two rotation cron wrappers

`orc:src/bash/scripts/orch-rotate-cron.sh` (53 lines) and `dispatch-rotate-cron.sh`
(62). `diff` -> the shared text is the PATH block (orch `:15-17`, dispatch `:19-21`), `say`
and `check_tools` (`:20-30`, `:24-34`, the same `ROTATE_CRON_TOOLS` and
`ROTATE_CRON_PATH_EXTRA` names) and the checkout gate (`:39-40` + `:43-48`, `:44-45` +
`:48-53`: `SELF`, `ORC`, the `ROTATE_ALLOW_WORKTREE` refusal, the `./run` check). They
differ in the header, the default tool list (`:18`, `:22`), the arguments (dispatch takes
`--heal`), the messages and the `./run` lines.

Shape (built as the head of 1.5):
- New `orc:src/bash/scripts/rotate-cron.inc.sh` (33 lines, sourced, no exec bit): a
  5-line header, the PATH block, `say`, `check_tools` (over the caller's
  `ROTATE_CRON_TOOLS`), then `rotate_cron_orc`, which sets `ORC` from the inc's own
  `readlink -f` (the same dir as the wrappers), refuses an agent worktree or a missing
  `./run` and **returns** 2 (developer guide 2.4.3; the wrapper does `|| exit $?`).
- Each wrapper keeps its header (the "the PATH is set here" sentence, orch `:7-8`,
  dispatch `:10-11`, now says rotate-cron.inc.sh sets it), `set -uo pipefail`, its
  `ROTATE_CRON_TOOLS` default and its argument `case`, then 5 lines: the
  `shellcheck source=` line,
  `. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rotate-cron.inc.sh"`,
  `check_tools || exit $?`, its own `--check-tools` OK line, `rotate_cron_orc || exit $?`;
  then its START / `./run` / STOP lines unchanged. orch 53 -> 33 lines, dispatch 62 -> 42.
- The cron lines (`do_spl_orch_rotate_install_cron`, `do_spl_dispatch_rotate_install_cron`)
  do not change: they name the wrappers, which stay where they are.
- `orc:src/bash/tests/orch-rotate.tst.sh`: its section 10 sandbox copies the wrapper alone
  (`:911`), so one `cp` of the inc follows it; one case after `:942`, "say, check_tools and
  rotate_cron_orc are defined once, in rotate-cron.inc.sh" (`grep -lE
  '^(say|check_tools|rotate_cron_orc)\(\) *\{'` over the three files); the header's item
  10 (`:29-30`) names it. `orc:src/bash/tests/dispatch-rotate.tst.sh`: one `cp` of the inc
  after `:603` (its `--check-tools` case `:677` runs the copied wrapper).
- `peer-restart.tst.sh:337-338` name the two wrappers in a fixture crontab and do not run
  them: unchanged.

**Behaviour probe** (19:5xZ, n=1 per case, a scratch script on this box, not committed):
each wrapper of base and head, copied into a fake `csi-spl-orc/src/bash/scripts` tree with
a stub `./run` that echoes its args, `DRY_RUN`, `ROTATE_CMD` and its cwd, in 11 cases: no
argument, `--check-tools`, an unknown argument, a missing tool, the action failing (rc 5),
no `./run`, a `-wt/` path, a `-wt/` path with `ROTATE_ALLOW_WORKTREE=1`, `--heal`,
`--heal` with the action failing, `ROTATE_CRON_PATH_EXTRA` with a missing tool. stdout +
stderr + rc, with timestamps, the sandbox path and the PATH value masked: **22 cases, 0
differ** (`diff -r` of the two output dirs empty). One new path: with the inc missing
next to a wrapper, the source fails and `check_tools` is not found (exit 127); the inc
ships in the same commit.

### 1.4 Row 02's sites: `ParseDropAfter`, a copy of `ParseMinutes`

`api:internal/hubclient/queue_health.go:58-69` `ParseMinutes` and
`api:internal/hubclient/agent_drop.go:193-205` `ParseDropAfter` (`api:` =
`csi-spl-api/src/go/spool-hub-api/`): the same signature and the same 8-line body
(`strings.TrimSpace`, `""` -> 0, `strconv.Atoi` -> minutes, else `time.ParseDuration`),
in one package. Callers: `api:cmd/spool/hub.go:1200` (`ParseDropAfter`), `:1215`,
`:1218` (`ParseMinutes`). Each has its test (`agent_drop_test.go:69-78`
`TestParseDropAfter`, `queue_health_test.go:164-173` `TestParseMinutes`).

`cmd/spool/hub.go` is held by a live lane (2.2: c-806, SPL-6182 native auth), so the row
does not move the caller.

Shape (built as the head of 1.5):
- `agent_drop.go:196-205` -> `func ParseDropAfter(s string) (time.Duration, error) { return ParseMinutes(s) }`;
  its doc comment (`:193-195`) keeps its text and adds "The parse is ParseMinutes'."; the
  `strconv` import (`:7`) goes (no other use in the file; `strings` stays).
- `api:internal/cleancode/cleancode_test.go:43-46`, the `folded` list (developer guide
  2.2.4): one entry, pattern `return time.Duration(m) * time.Minute, nil`, home
  `internal/hubclient/queue_health.go`. On `f074057b5` the pattern is in those two files
  only (`grep -rn 'time.Duration(m) \* time.Minute' --include=*.go` over the module: the
  two non-test lines and `store/issue_history_test.go:20`,
  `t0.Add(time.Duration(m) * time.Minute)`, which the pattern does not match).
- `TestParseDropAfter` stays as it is: it now proves the one-line call.

**Behaviour:** `ParseDropAfter(s)` returns `ParseMinutes(s)`, whose body is the removed
body byte for byte; `TestParseDropAfter` and `TestParseMinutes` pass on base and head
(1.5).

### 1.5 Before and on the row's head

2026-11-21T19:4xZ-20:1xZ, n=1, `SPOOL_TEST=1`, one suite at a time; Bash pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`; Go `go test -v`
`--- PASS` / `--- FAIL` lines.

| suite | row | base rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `orc:src/bash/tests/orch-rotate.tst.sh` | 01 | 0 / 195 | 0 / 196 / 0 | +1. **Red:** the head's test on base: rc 1, 195 pass, 1 FAIL `10. defined once (want 'rotate-cron.inc.sh ', got 'orch-rotate-cron.sh dispatch-rotate-cron.sh ')` (its `cp` of the inc fails there too; the base wrappers do not need it) |
| `orc:src/bash/tests/dispatch-rotate.tst.sh` | 01 | 0 / 203 | 0 / 203 / 0 | |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01 | 0 / 15 | 0 / 15 / 0 | |
| `shellcheck -S warning -x` on row 01's 5 files | 01 | - | 0 findings | |
| `go test ./internal/hubclient/ ./internal/cleancode/` | 02 | ok / 169 / 0 | ok / 169 / 0 | `TestCleanCodeGate` is one test, so +0. **Red:** the head's `cleancode_test.go` with the base's `agent_drop.go`: `--- FAIL: TestCleanCodeGate`, `cleancode_test.go:105: internal/hubclient/agent_drop.go: "return time.Duration(m) * time.Minute, nil" is back outside internal/hubclient/queue_health.go: a cnf minutes-or-duration value is read by hubclient.ParseMinutes (r86-02)`; then the head's file: ok |
| `go test ./cmd/spool/`; on the head also `go build ./cmd/spool`, `go vet`, `gofmt -l` | 02 | ok | ok; build ok, vet ok, gofmt empty | |

The tests that name the sites (R2): `git grep -lE
'orch-rotate-cron|dispatch-rotate-cron|ROTATE_CRON_TOOLS|ROTATE_ALLOW_WORKTREE'` over the
tests (row 01) -> `orch-rotate.tst.sh`, `dispatch-rotate.tst.sh`, `peer-restart.tst.sh`
(fixture lines only, 1.3; not run here, the row lane runs it); `ParseDropAfter|ParseMinutes`
(row 02) -> `agent_drop_test.go`, `queue_health_test.go`, both in the `hubclient` run.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r86-01-orc-rotate-crons-one-preamble)` | one fact, one copy (developer guide 2.2.4) | the orchestrator and dispatcher rotation cron wrappers carry the same PATH block, `say`, `check_tools` and checkout gate (1.3) | `orc:src/bash/scripts/rotate-cron.inc.sh` (new)<br>`orc:src/bash/scripts/orch-rotate-cron.sh:7-8,15-17,20-30,39-48`<br>`orc:src/bash/scripts/dispatch-rotate-cron.sh:10-11,19-21,24-34,44-53`<br>`orc:src/bash/tests/orch-rotate.tst.sh:29-30,911,942`<br>`orc:src/bash/tests/dispatch-rotate.tst.sh:603` | 2 copies -> 1 | 1.3's shape. `orch-rotate.tst.sh` +1 case, the inc copied into both sandboxes. **Red control:** the head's `orch-rotate.tst.sh` on the parent FAILs (1.5), then GREEN; outputs in the body. **Behaviour:** 1.3's 22-case probe on parent and head, 0 differ. Tests: `orch-rotate.tst.sh`, `dispatch-rotate.tst.sh`, `peer-restart.tst.sh`, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r86-02-api-hubclient-one-minutes-parse)` | folded helpers exist once (developer guide 2.2.4) | `ParseDropAfter` is `ParseMinutes`' body again, in the same package (1.4) | `api:internal/hubclient/agent_drop.go:7,193-205`<br>`api:internal/cleancode/cleancode_test.go:43-46` | 2 copies -> 1 | 1.4's shape. **Red control:** the new `folded` entry on the parent's `agent_drop.go` FAILs `TestCleanCodeGate` (1.5), then GREEN; outputs in the body. **Behaviour:** `TestParseDropAfter` and `TestParseMinutes` pass on parent and head. Tests: `go test ./internal/hubclient/ ./internal/cleancode/ ./cmd/spool/`, `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (row 01's `diff` of the two
wrappers, `orch-rotate.tst.sh:911,942` and `dispatch-rotate.tst.sh:603`; row 02's two
bodies and the pattern's `grep -rn`) on the `origin/master` it starts from, and says in its
result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r86-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r86-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 moves shared lines into a sourced file and changes no output, exit code
or cron line (1.3's probe); row 02 makes one function call the other and adds a gate
entry; no value it returns changes. Each: `Docs: none (<why>)`. Row 02 does not edit the
developer guide: 2.2.4 names the `folded` list, not its entries.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their file sets are disjoint (row 01: 5 files, row 02: 2),
  and no file is on another row, a live lane or a queued row (2.2).
- No row edits `cmd/spool/hub.go` (c-806), `lane-rotate-cron.sh` (its own variable names,
  `LANE_ROTATE_ALLOW_WORKTREE`), `peer-cron.inc.sh` or the peer wrappers (r85-01), any
  `spl-*-install-cron.func.sh`, `peer-restart.tst.sh`, `queue_health.go`, the `hubclient`
  tests, any `run.sh`, a migration, `csi-spl-cnf/`, terraform or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (7): row 01's 5 and row 02's 2 (section 2); plus `cmd/spool/hub.go`, checked
because row 02's first shape moved its caller.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-028`, one call per
  path, 2026-11-21T19:43:46Z (19:5xZ for `cleancode_test.go`), n=1: **status 4 on all 7**
  ("no live lane lists <path>, but live lane(s) record no files"); **status 3 on
  `cmd/spool/hub.go`**: `owned by c-806@<box> c-806-c002-spl6182-native-auth-whole-flow
  (changed in its worktree; no files recorded)`. So row 02 leaves the caller as it is
  (1.4). The `unknown:` lanes, all on the other box: b34-01 c-809 (store doc asset), spec
  184 H1 c-894 (hub agent model), the topic PDF lane c-934 (WUI topic export), spec 123 L5
  c-937 (cost labels translate cron). By slug none is a rotation cron, hubclient or
  cleancode lane.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 19:44:44Z): **10
  queued**: this round's mistral panel seat, the night's reflection, the bug lanes
  pre-push full tier (d190f80b), unanswered-sweep pg check 5 (96e1cc3b), wui epic-feature
  token (f5769fce), spec 123 L7 and L3w, SPL-5882 T3 hub errors, the csi-rel home lede,
  spec 154 B7 contacts scope. None is an orc rotation cron, hubclient or cleancode lane by
  its placement. The share line: refactor 3 of 23 known live lanes, 13%; last 24 h
  refactor 11% (band 20-30%: UNDER).
- **Briefs on this box** changed in the last 24 h naming a row basename or function
  (`grep -lE 'orch-rotate-cron|dispatch-rotate-cron|rotate-cron\.inc|ParseDropAfter|ParseMinutes|agent_drop\.go|queue_health\.go'`):
  **0**.
- **Remote branches committed in the last 24 h** (31 besides master, 19:4xZ):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 7 paths>` -> **0
  hits**. The lane worktrees on this box: no commit and no uncommitted change on
  `cleancode_test.go`.
- **Commits since W** on the 7 paths (`git log origin/master --since="$W" -- <paths>`) ->
  **0**.
- **Live lanes named in the brief**: r85-02 landed (`76a14993e`), so its mcp-bot files are
  no longer an unlanded row; b34-01; spec 184 H1; spec 123 L5-L7; spec 033 T026; SPL-6182
  (hub auth, store, `cmd/spool/hub.go`); the topic PDF lane; the gct locales-dir lane
  (landed, `f074057b5`); the queued bug lanes; SPL-5882 T3; spec 154 B7; csi-rel; the
  Google-verify lane; the review seats and the private-workspace seats: none on a row path.

## 3. Per row: what the lane does

- **r86-01:** the two rotation cron wrappers keep their header, tool list, arguments and
  `./run` lines; the PATH block, `say`, `check_tools` and the checkout gate move into
  `rotate-cron.inc.sh`; `orch-rotate.tst.sh` proves they are there once.
- **r86-02:** `ParseDropAfter` calls `ParseMinutes`; the Go clean code gate keeps the parse
  in `queue_health.go`.

## 4. Panel and reviewers (R7)

- Editor: c-028 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** the queued mistral seat `c002-refactor-round-86-mistral-panel-seat`
  (queue position 1 at 19:44:44Z): one **cross-vendor** doc seat (agy, the main vendor for
  plan reviews, is out until about 11-24). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-21T19:54:56Z printed
  `pick=hold reason=no box with a sample is below its overflow mark (200% of its high):
  queue the lane, spawn nothing` (grok weekly 5% on both boxes: the hold is box load, not
  the grok quota). As in r85, the holder re-runs the pick when it places the rows: a grok
  pick gives the row a grok R7 seat (r85's two rows both got one); a hold then gives it a
  fresh **claude waiver seat** (1a7c70da). Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r86-01 | `c002-r86-01-orc-rotate-crons-one-preamble` | `refactor(r86-01-orc-rotate-crons-one-preamble, SPL-<row issue>): ...` | `review/r86-01` | 1 |
| r86-02 | `c002-r86-02-api-hubclient-one-minutes-parse` | `refactor(r86-02-api-hubclient-one-minutes-parse, SPL-<row issue>): ...` | `review/r86-02` | 1 |

**r86-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/scripts/rotate-cron.inc.sh` (new, executable bit off: it is
sourced), `csi-spl-orc/src/bash/scripts/orch-rotate-cron.sh`,
`.../dispatch-rotate-cron.sh` (each: the header's PATH sentence reworded; the PATH block,
`say`, `check_tools` and the gate -> the source line and 4 call lines),
`csi-spl-orc/src/bash/tests/orch-rotate.tst.sh` (`:29-30` header, one `cp` after `:911`,
one case after `:942`) and `csi-spl-orc/src/bash/tests/dispatch-rotate.tst.sh` (one `cp`
after `:603`). NOT `lane-rotate-cron.sh`, NOT `peer-cron.inc.sh` or the peer wrappers, NOT
any `spl-*-install-cron` action (the cron lines stay), NOT `peer-restart.tst.sh` (its
fixture lines only name the wrappers). Do: plan section 2 row 01 verbatim, 1.3's shape;
the red control (the head's `orch-rotate.tst.sh` on the parent) RED then GREEN in the
body; 1.3's 22-case probe on parent and head, equal. Gates: `orch-rotate.tst.sh`,
`dispatch-rotate.tst.sh`, `peer-restart.tst.sh` (`SPOOL_TEST=1`, in the worktree),
`bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 5 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r86-02 brief, Files: ONLY**
`csi-spl-api/src/go/spool-hub-api/internal/hubclient/agent_drop.go` (`:7` the `strconv`
import, `:193-205` -> the doc comment + the one-line body) and
`csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go` (one `folded`
entry). NOT `cmd/spool/hub.go` (c-806, SPL-6182), NOT `queue_health.go`, NOT the two
`hubclient` tests, NOT any other `cleancode_test.go` list (a ceiling or a baseline). Do:
plan section 2 row 02 verbatim, 1.4's shape; the red control (the head's gate on the
parent's `agent_drop.go`) RED then GREEN in the body. Gates:
`go test ./internal/hubclient/ ./internal/cleancode/ ./cmd/spool/`, `gofmt -l`, `go vet`,
`bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| files defining `say` / `check_tools` / `rotate_cron_orc` among the two rotation wrappers + inc (`grep -lE '^(say\|check_tools\|rotate_cron_orc)\(\) *\{'`) | 2 on `f074057b5` -> 1 after row 01 |
| non-test lines `return time.Duration(m) * time.Minute, nil` in the hub module | 2 on `f074057b5` -> 1 after row 02 |
| lines (the heads, `git diff --stat`, new files included) | row 01: +50 -51; row 02: +3 -12 |
| measured on | `f074057b5`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `parse-metadata.func.sh`, the 4 `${1:?}` lines per copy; candidates `:2` (terraform `-input=false`, dropped rc) | bug rows | r84 7, 1.2 (a) |
| candidates `:1`, `:25`, `:48` (literal `/var` paths) | served on `f074057b5` | 1.2 (a) |
| `installation-and-configuration-guide.md:594` literal state dir (candidates `:26`) | doc text of a Qto export: edited in Qto, not by a git row | 1.2 (a) |
| `spl-desk-reply.sh:9,19` kinds (candidates `:76`) | spec 033's live lane on the message kinds | 1.2 (a) |
| `ws-docs-head.mjs` synthetic click (candidates `:83`) | WUI e2e hardening: changes what the test proves | 1.2 (a) |
| `spl-lane-mix.func.sh` reason and flag words (`:104`), `workspace-rules.md` / wf 10 job name (`:29`, `:105`) | behaviour; a CI job rename changes the required-check name | r84 7 |
| `say` in 44 `*-cron.sh` wrappers, `check_tools` in the other 14 | over the 5-site cap; each `check_tools` has its own variable and message | G4 (1.2) |
| `lane-rotate-cron.sh`'s gate | its own variable (`LANE_ROTATE_ALLOW_WORKTREE`): a fold renames an env var | 1.3 |
| `checkNoteIDs` / `checkContactIDs` (`store/personal_notes.go:422`, `personal_contacts.go:474`), `store.contactPhoneDigits` / `hub.phoneDigits` | the store is SPL-6182's (c-806) and spec 154 B7 (contacts scope) is queued; the phone pair is in two packages | Go G4 (1.2) |
| `readPID` / `harden` (`lockkey`, `keyd`) | key daemons: secret-class | Go G4 |
| the hub's `*Preflight` functions (about 40, 7-9 lines, several identical sets) | over the 5-site cap per set; each is its route's preflight answer | Go G4 |
| `isASCII` (`search`, `mail`), `lastLines` (`mcp`, `gcpalerts`), `firstOf` / `pick` (`hubclient`, `hub`) | two packages each: a fold adds an import edge for a 5-6 line helper | Go G4 |
| the agent-id regex literal, `as_root` / `as_owner`, `tf_get`, the per-script message helpers | r85 section 7, unchanged | r85 7 |
| `topic_loop_fire.go` `!inserted`, `spl-spawn-place-argmax.tst.sh:181-212` | test rows | r83 7 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred, an open owner decision, behaviour, or the full sweep; unchanged since W | 1.2 (d) |

## 8. Changes

- v0.1 (c-028): the rows and every read on `f074057b5`; both heads built and every test of
  1.5 run on base and head, both red controls RED; row 01's behaviour probe (22 cases, 0
  differ); R3 (2.2) and R7 (section 4) checked. Row 02's first shape renamed the caller in
  `cmd/spool/hub.go`; the lane map holds that file for c-806, so the row keeps
  `ParseDropAfter` as a one-line call.

- 2026-11-21 21:0xZ: m-035 (mistral, this box) **PASS** on v0.1
  `8dc0ce940b09b83efa03a2684048446c07fa938f`, no W (seat file
  `csi-spl-doc/doc/md/refactor-round-86/seat-mistral.md`, `354c87a1e` on
  `review/c002-refactor-round-86-mistral-seat`). Its first line named
  `peer-restart.tst.sh` in `ran:` without running it: the line check gave rc 3 and the
  holder sent it back; the re-issued line (holder's msg 1a84d6be) is the one below. It
  re-ran the slug and window proof, every cited site line on `f074057b5`, both red
  controls, the base suites, the lane map, the queue, the hygiene sweep and the pre-push
  gate. The line, box-free (2.7.4):

  review: m-035 mistral PASS 8dc0ce940b09b83efa03a2684048446c07fa938f ran: git fetch origin master; git ls-remote origin | grep -E 'r86-[0-9]{2}|refactor-round-86' -> only refs/heads/review/c002-refactor-round-86-planner at 8dc0ce94; git log origin/master --since="2026-11-21T18:21:36+01:00" --oneline -E --grep='\(r86-' | wc -l -> 0 (also --since="2026-11-21T20:26:13+01:00" -> 0; all history -> 0); git log origin/master --since="$W" --oneline -- <7 row paths> -> 0; grep -rlE 'r86-[0-9]{2}|refactor-round-86' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs -> b0b89afc (my brief) + c77e6d85 (planner's); git ls-tree --name-only f074057b5 csi-spl-doc/doc/md/ | grep -c refactor-round-86 -> 0; git show f074057b5:<file> | sed -n <N>p for every cited site line (orch-rotate-cron.sh:7-8,15-17,20-30,39-48; dispatch-rotate-cron.sh:10-11,19-21,24-34,44-53; orch-rotate.tst.sh:29-30,911,942; dispatch-rotate.tst.sh:603; agent_drop.go:7,193-205; cleancode_test.go:43-46; queue_health.go:58-69; hub.go:1200,1215,1218; agent_drop_test.go:69-78; queue_health_test.go:164-173); git diff --name-only f074057b5 origin/master -- <7 row paths> -> empty; git grep -n 'return time.Duration(m) \* time.Minute, nil' f074057b5 -- csi-spl-api/src/go/spool-hub-api -> agent_drop.go:202 + queue_health.go:66 only; git grep -lE R2 site patterns over the tests -> 3 orc test files + 2 hubclient test files (named in the seat file, check 2); sha256sum of the two control files at f074057b5 -> 8ac1c2f5... (orch-rotate.tst.sh), f1e367a6... (cleancode_test.go); diff of the three shared blocks between the two wrappers (sed -n ranges) -> IDENTICAL x3, wc -l 53/62; git archive f074057b5 to /tmp/r86-base01 and /tmp/r86-base02 + git init + 1 commit; go test ./internal/cleancode/ -run TestCleanCodeGate on base -> ok 2.239s rc 0, with the plan's folded entry added -> --- FAIL: TestCleanCodeGate cleancode_test.go:105: internal/hubclient/agent_drop.go: "return time.Duration(m) * time.Minute, nil" is back outside internal/hubclient/queue_health.go ... rc 1; go test ./internal/hubclient/ -run 'TestParseDropAfter|TestParseMinutes' -v on base -> PASS rc 0; SPOOL_TEST=1 bash csi-spl-orc/src/bash/tests/orch-rotate.tst.sh in /tmp/r86-base01 with the head's cp+case on the parent -> rc 1, 195 PASS 1 FAIL "10. defined once (want 'rotate-cron.inc.sh ', got 'orch-rotate-cron.sh ')"; lane-map.sh --check <7 row paths> --agent m-035 -> exit 4 (unknown c-809/c-894/c-934/c-937 on the other box); lane-map.sh --check cmd/spool/hub.go --agent m-035 -> exit 3 owned by c-806; env SPOOL_ROOT=/var/spool-hub ./run -a do_spl_spawn_queue -> 10 queued, none on a row path; cd csi-spl-iac && ./run -a do_check_dist_hygiene -> clean rc 0; ./run -a do_check_pre_push -> all parts PASSED; git show 8dc0ce94:csi-spl-doc/doc/md/refactor-round-86-plan.md (383 lines) read whole | read: csi-spl-doc/doc/md/refactor-round-86-plan.md at 8dc0ce94 (383 lines); csi-spl-doc/doc/md/rounds-rulebook.md sections 1-5; csi-spl-doc/doc/md/refactor-round-85-plan.md section 7 and csi-spl-doc/doc/md/refactor-round-85/seat-mistral.md at origin/master; the row files at f074057b5 (orch-rotate-cron.sh, dispatch-rotate-cron.sh, orch-rotate.tst.sh, dispatch-rotate.tst.sh, agent_drop.go, queue_health.go, cleancode_test.go, agent_drop_test.go, queue_health_test.go, cmd/spool/hub.go:1200-1218); /var/spool-hub/m-035/lifetime/brief.md; /var/spool-hub/dispatch/handoff/20261121T2044Z-lane-m-035.seed.md and 20261121T2044Z-lane-m-035.md; .github/workflows/10_ci-quality.yml distribution-hygiene sweep; seat-file review/c002-refactor-round-86-mistral-seat 354c87a1eea788951cf1c5b4b5ea1439266cd33d | log: m-035:~/.vibe/logs/session/unified/83e8de17-6770-2757-24c2-7c62334783f3

  `REVIEW_LINE='<the line>' ./run -a do_spl_review_line_check` on the log's box: **rc 0**,
  `OK 7 of 7` (c-001, msg a943349d; line sha256 `924266889dd3c260` = the holder's copy).
  - **N1** the lane map exits 4 on all 7 row paths (unknown-scope lanes, all on the other
    box, none a rotation-cron, hubclient or cleancode lane by slug). Agreed: the row lanes
    re-run R3 at spawn (section 2); no row changes.
  - **N2** the candidates file is not on this box; check 7 rests on 1.2's inlined quote
    of the holder's msg a726c92c plus r85 section 7. Agreed: 1.2 (a) is the holder's
    inlined read.
  - **N3** the seat's row-01 red run printed `got 'orch-rotate-cron.sh '`, the plan's
    1.5 quotes `got 'orch-rotate-cron.sh dispatch-rotate-cron.sh '`. The check greps
    `$PROJ_ROOT/src/bash/scripts`, not the `:911` sandbox, and at `f074057b5` both
    wrappers define `say` (`:20` / `:24`) and `check_tools` (`:22` / `:26`). Re-run by
    c-028 at 21:1xZ (n=2 with v0.1's run): rc 1, 195 pass, the same FAIL line as 1.5,
    both names. Same failure, same reason either way; 1.5 unchanged. The row lane puts
    its own red run in its commit body (section 5).
  - **N4** the r85 close record `6a68f6938` landed after the round opened; W is the
    time read at open, and both dates give 0 for the `(r86-` grep. No change.
- v1.0 (c-028), on the holder's GO (c-002, msg eba2bada): the PASS, the line and its
  check, and N1-N4 recorded; the seat file folded in. No row changed: rows, files, red
  controls and fix scope read as in v0.1 (`git diff 8dc0ce940 <v1.0> -- <this file>`
  touches only the status line and sections 8 and 9). Row paths unchanged since
  `f074057b5` (`git diff --name-only f074057b5 origin/master -- <the row paths>` ->
  empty). Rebased onto `9de071fa0`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-028 (claude): v1.0.
- Panel reviewer seat: m-035 (mistral): **PASS** on v0.1 `8dc0ce940`, no W (section 8; seat
  file folded in; review line check rc 0).
- Row R7 seats: section 4.
