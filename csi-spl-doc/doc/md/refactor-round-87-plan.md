# Refactoring round 87 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6227  
Topic: f8d13031-dd33-4dc9-b9e1-c829d7a39795  
Discussion: f8d13031-dd33-4dc9-b9e1-c829d7a39795 (t1 #refactoring, "Refactor round 87", opened by c-002 01:15Z)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r87**, plan `refactor-round-87-plan.md`, rows `r87-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 86 ([refactor-round-86-plan.md](refactor-round-86-plan.md))
is closed: both rows landed (r86-01 `49f34bef6`, r86-02 `61977111c`; close record
`f89f821cc`). The perf floor (rulebook 4.4), measured by the holder on `b220e7464`: perf
29, refactor 113, 5 x 29 = 145 >= 142, floor met, so this is a refactor round.

The brief's inputs give no row (1.2), so both rows are new finds of the r83 to r86 kind:
**one function, two or more copies** (developer guide 2.2.4).

**Row 01** folds the hub's `mergeFrame` and `promoteFrame`, two copies of `moveFrame` in
the same package, into `moveFrame`, and adds a `folded` entry to the Go clean code gate
that keeps the frame filter in `message_move.go` (the r86-02 shape). **Row 02** gives the
spool-install memory steps Y18 (grok) and Y20 (agy), which carry the same repo and claude
project slug helpers, one copy in a new sourced `steps/claude-memory.inc.sh` (the r86-01
shape).

**Status: closed.** The panel (m-085, mistral) passed v0.1 `aacf9637a` and v1.0
`c24e47b1c` with no W (seat file `csi-spl-doc/doc/md/refactor-round-87/seat-mistral.md`,
v1.0 signature folded in from `2023b1346`); its review line passed
`do_spl_review_line_check` rc 0 on the log's box (holder c-002, msg 36c52658). Both rows
landed: r87-01 `fa86b70d7`, r87-02 `a42fff43c`. Section 8. Editor: **c-230** (claude).

**One sha:** every count is measured on **`b220e7464`** (`origin/master` at
2026-11-22T02:5xZ), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. **Every test named in 1.5 was RUN** on scratch copies of that
sha (`git archive b220e7464` of the trees the tests read): "base" is the copy
unmodified; "head" is a copy with the row's change applied in 1.3's / 1.4's shape; each
red control puts only the head's test file into a copy of base. Nothing of it is
committed. Queue, lane map, brief and branch reads are live state and carry their own
time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-22T02:51Z, n=1:

- **Window: W=2026-11-22T00:52:54+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r86-plan'`: `f89f821cc`, the
  r86 close record.
- `git log origin/master --since="$W" --oneline -E --grep='\(r87-'` -> **0**; over all
  history -> **0**.
- `git ls-remote origin 'refs/heads/review/r87-*' 'refs/heads/*-r87-*' 'refs/heads/*refactor-round-87*' 'refs/heads/wip/*r87*'`
  -> nothing.
- `ls csi-spl-doc/doc/md | grep -c refactor-round-87` -> 0 before v0.1: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) r86 section 7:** every item re-read on `b220e7464`; each stays out for its reason
  there. The Go set of r86's G4 (`checkNoteIDs` / `checkContactIDs`, `readPID` /
  `harden`, `isASCII`, `lastLines`, `firstOf` / `pick`, `phoneDigits` /
  `contactPhoneDigits`, the `*Preflight` sets) prints the same pairs again (1.2 (d));
  `tf_get` too.
- **(b) r86 R7 notes:** r86-01 (g-108) and r86-02 (g-005) carry no N note; the r86 panel's
  N1-N4 (seat file `refactor-round-86/seat-mistral.md`) name process points, no row.
- **(c) spec 011 tasks:** `git log origin/master --since="$W" --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks are those of r86
  section 7.
- **(d) How the rows were found** (G4, as r84 to r86), on `b220e7464`:
  - Bash: every function body of 5+ lines (comments and blank lines dropped) in the orc /
    iac / utl / api `src/bash` trees and the repo-root `src/bash`, tests excluded, hashed
    whatever its name; the per-module `run.sh`, `lib/bash/funcs` and `print-help` copies
    are byte-identical by design (developer guide 2.4.2) and left out. 4 sets, each a
    pair: `_y18_repo` / `_y20_repo` (**row 02**), `tf_get` (r85 7),
    `spl_secrets_none_get` / `spl_self_host_env_get` and `spl_uplink_trim` /
    `ext_api_trim` (section 7).
  - Go: every `func` body of 5+ lines in the hub module, `_test.go` excluded, signature +
    body hashed. 21 sets; besides r86 section 7's, one is new:
    `moveFrame` / `mergeFrame` / `promoteFrame` in `internal/hub` (**row 01**), three
    copies in one package.

### 1.3 Row 01's sites: `mergeFrame` and `promoteFrame`, copies of `moveFrame`

`api:internal/hub/message_move.go:374-383` `moveFrame`,
`api:internal/hub/topic_merge.go:169-178` `mergeFrame` and
`api:internal/hub/topic_promote.go:141-150` `promoteFrame` (`api:` =
`csi-spl-api/src/go/spool-hub-api/`): the same signature
`(typ string, out map[string]any) map[string]any` and the same 7-line body (a map with
`"type"`, every key of `out` but `undo` and `kind`). Callers: `message_move.go:269,346`
(`moveFrame`), `topic_merge.go:123,147` (`mergeFrame`), `topic_promote.go:111,136`
(`promoteFrame`); each passes the frame to `s.fanoutMove`. The pattern
`if k != "undo" && k != "kind" {` is in those three files only (`git grep -n` over the
module, tests included -> 3 lines).

`moveFrame`'s comment (`:374`) says "undo left out"; its body also leaves out `kind` (the
other two comments say "undo and kind left out"). The row corrects it (C5).

Shape (built as the head of 1.5):
- `topic_merge.go:123,147` and `topic_promote.go:111,136` call `moveFrame`;
  `mergeFrame` (`topic_merge.go:169-178`) and `promoteFrame` (`topic_promote.go:141-150`)
  and their comments go.
- `message_move.go:374` -> "moveFrame is the answer as a frame: the type added, undo and
  kind left out." plus one line "The move, merge and promote answers all go through it."
- `api:internal/cleancode/cleancode_test.go:43-47`, the `folded` list (developer guide
  2.2.4): one entry after `:46`, pattern `` `if k != "undo" && k != "kind" {` ``, home
  `internal/hub/message_move.go`, why "a move, merge or promote answer becomes a frame
  through hub.moveFrame (r87-01)".
- No test changes: the frames' tests (`topic_merge_test.go`, `topic_promote_test.go`,
  `message_move_test.go`, `message_move_agent_test.go`, `box_message_move_test.go`,
  `fanout_encode_e16_bench_test.go`) are all in `internal/hub` and run whole in 1.5.

**Behaviour:** each removed body is `moveFrame`'s byte for byte (the G4 hash), so each
caller gets the same map; the `internal/hub` suite passes on base and head with the same
count (1.5).

### 1.4 Row 02's sites: the memory repo and slug of steps Y18 and Y20

`orc:src/bash/features/spool-install/steps/y18-grok-memory.sh:31-43` and
`y20-agy-memory.sh:58-70` (`orc:` = `csi-spl-orc/`): the same comment line, the same
one-line `_y<N>_slug` (`sed 's/[^A-Za-z0-9]/-/g'`) and the same 10-line `_y<N>_repo`
(`SPOOL_INSTALL_CLAUDE_MEMORY_REPO`, else the main worktree from
`git rev-parse --git-common-dir` of the step's own dir). Each is called once, in the
step's entry function (`y18:67-68`, `y20:264-265`). Both steps are sourced by
`install.sh:1111-1112` (with `--fleet`), by `do_spl_grok_memory_install` /
`do_spl_agy_memory_install`, and by their tests, always from the steps dir.

Shape (built as the head of 1.5):
- New `orc:src/bash/features/spool-install/steps/claude-memory.inc.sh` (21 lines,
  sourced, no exec bit): a 7-line header, `spool_install_memory_slug` and
  `spool_install_memory_repo`, the two bodies unchanged. `${BASH_SOURCE[0]}` in the repo
  helper is then the inc, in the same dir as the steps, so `here` is the same dir.
- Each step: after its header (`y18:26`, `y20:50`) a `# shellcheck source=` line and
  `. "$(dirname "${BASH_SOURCE[0]}")/claude-memory.inc.sh"`; its `_y<N>_slug` /
  `_y<N>_repo` block goes; the two calls name the inc's functions. y18 103 -> 92 lines,
  y20 307 -> 296.
- `orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh`: header item 9
  (after `:17`) and one case before the summary line (`:120`): the steps that read the
  repo or the slug (`grep -lE 'git-common-dir|s/\[\^A-Za-z0-9\]/-/g'` over `steps/*`)
  are `claude-memory.inc.sh` alone.
- `test-agy-rules-always-on.sh:61` greps `steps/*` for `.gemini/config/rules`; the inc
  does not carry it, so its writer list is unchanged (run in 1.5).

**Behaviour probe** (03:0xZ, n=1 per case, a scratch script, not committed): each step of
base and head, sourced and its entry called as `spool_install_<grok|agy>_memory <home> 1`
with no repo argument, from three places (a git checkout, a linked worktree of it, a copy
outside git) with `SPOOL_INSTALL_CLAUDE_MEMORY_REPO` set and unset. stdout + stderr + rc,
the sandbox paths masked: **12 cases, 0 differ** (10 rc 0, the 2 outside-git unset cases
rc 7 "cannot tell the repo"; the worktree cases resolve to the main checkout). One new
path: with the inc missing next to a step, the source fails; the inc ships in the same
commit.

### 1.5 Before and on the row's head

2026-11-22T03:0xZ-03:2xZ, n=1, `SPOOL_TEST=1`, one suite at a time; Bash pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`; Go `go test -v`
`--- PASS` / `--- FAIL` lines.

| suite | row | base rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `go test -count=1 -v ./internal/hub/ ./internal/cleancode/`; on the head also `go build ./...`, `go vet`, `gofmt -l` | 01 | ok / 1337 / 0 | ok / 1337 / 0; build ok, vet ok, gofmt empty | `TestCleanCodeGate` is one test, so +0. **Red:** the head's `cleancode_test.go` on base: `--- FAIL: TestCleanCodeGate`, `cleancode_test.go:106: internal/hub/topic_promote.go: "if k != \"undo\" && k != \"kind\" {" is back outside internal/hub/message_move.go: a move, merge or promote answer becomes a frame through hub.moveFrame (r87-01)` and the same line for `topic_merge.go`; then the head: ok |
| `orc:.../spool-install/tests/test-y18-grok-memory.sh` | 02 | 0 / 14 | 0 / 15 / 0 | +1. **Red:** the head's test on base: rc 1, 14 pass, 1 FAIL `9: defined once (want 'claude-memory.inc.sh ', got 'y18-grok-memory.sh y20-agy-memory.sh ')` |
| `orc:.../spool-install/tests/test-y20-agy-memory.sh` | 02 | 0 / 68 | 0 / 68 / 0 | |
| `orc:.../spool-install/tests/test-agy-rules-always-on.sh` | 02 | 0 / 14 | 0 / 14 / 0 | |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 02 | 0 / 15 | 0 / 15 / 0 | |
| `shellcheck -S warning -x` on row 02's 4 files | 02 | - | 0 findings | |

The tests that name the sites (R2): `git grep -lE
'moveFrame|mergeFrame|promoteFrame|message_move\.go|topic_merge\.go|topic_promote\.go'`
over the Go tests (row 01) -> 6 files, all in `internal/hub` (1.3), run whole;
`y18-grok-memory|y20-agy-memory|_y18_|_y20_` over the orc / iac tests (row 02) ->
`test-y18-grok-memory.sh`, `test-y20-agy-memory.sh`, `test-agy-rules-always-on.sh`, the
wrappers `spool-install-y18-grok-memory.tst.sh` and `spool-install-y20-agy-memory.tst.sh`
(each `exec`s its feature test) and `orc-shard-weights.txt` (a weight line, no run).

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r87-01-api-hub-one-move-frame)` | folded helpers exist once (developer guide 2.2.4) | `mergeFrame` and `promoteFrame` are `moveFrame`'s body again, in the same package (1.3) | `api:internal/hub/message_move.go:374`<br>`api:internal/hub/topic_merge.go:123,147,169-178`<br>`api:internal/hub/topic_promote.go:111,136,141-150`<br>`api:internal/cleancode/cleancode_test.go:43-47` | 3 copies -> 1 | 1.3's shape. **Red control:** the new `folded` entry on the parent's hub files FAILs `TestCleanCodeGate` naming both copies (1.5), then GREEN; outputs in the body. **Behaviour:** the `internal/hub` suite passes on parent and head, same count. Tests: `go test ./internal/hub/ ./internal/cleancode/`, `gofmt -l`, `go vet`, `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r87-02-orc-install-one-memory-repo)` | one fact, one copy (developer guide 2.2.4) | spool-install steps Y18 and Y20 carry the same memory-repo and slug helpers (1.4) | `orc:src/bash/features/spool-install/steps/claude-memory.inc.sh` (new)<br>`orc:src/bash/features/spool-install/steps/y18-grok-memory.sh:26,31-43,67-68`<br>`orc:src/bash/features/spool-install/steps/y20-agy-memory.sh:50,58-70,264-265`<br>`orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh:17,120` | 2 copies -> 1 | 1.4's shape. `test-y18-grok-memory.sh` +1 case. **Red control:** the head's `test-y18-grok-memory.sh` on the parent FAILs (1.5), then GREEN; outputs in the body. **Behaviour:** 1.4's 12-case probe on parent and head, 0 differ. Tests: `test-y18-grok-memory.sh`, `test-y20-agy-memory.sh`, `test-agy-rules-always-on.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (row 01's three bodies and the
pattern's `git grep -n`; row 02's two blocks and the callers) on the `origin/master` it
starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r87-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r87-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 makes two call sites use the copy that stays, corrects one comment and
adds a gate entry; no frame changes. Row 02 moves two helpers into a sourced file and
changes no output, exit code or file the steps write (1.4's probe). Each:
`Docs: none (<why>)`. Neither edits the developer guide: 2.2.4 names the `folded` list,
not its entries. Spec 048 sections 5 and 6 name the step files, which stay.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their file sets are disjoint (row 01: 4 files, row 02: 4),
  and no file is on another row, a live lane or a queued row (2.2).
- No row edits `cmd/spool/hub.go`, `hub/server.go`, `hub/supervise.go`, `auth/` or the
  store (SPL-6182, spec 162 T3), `gcal/` (spec 154 B7), any frame test, `install.sh`, the
  `spl-*-memory-install.func.sh` actions, `test-y20-agy-memory.sh`, any `run.sh`, a
  migration, `csi-spl-cnf/`, terraform or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9): row 01's 4 and row 02's 4 (section 2), plus `test-y20-agy-memory.sh`, checked
because row 02's first shape added its case there.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-230`, one call per
  path, 2026-11-22T02:52:49Z, n=1: **status 4 on all 9** ("no live lane lists <path>, but
  2 live lane(s) record no files"). The `unknown:` lanes, both on the other box: c-035
  (SPL-5882, spec 162 T3 hub errors) and c-054 (spec 154 B7 contacts scope). Their spec
  rows name their files: spec 162 `spec.md:937` (T3: `hub/server.go` `middleware` /
  `logServerError`, `hub/supervise.go`, new `hub/evlog.go`, `auth/handler.go`,
  `cmd/spool/hub.go`, a cnf key) and spec 154 B7 (`gcal/oauth.go`'s scope); none is a
  row path. No lane is reported as owning any of the 9.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 02:54:16Z): **2
  queued**: the csi-rel gct language check (other repo) and the bug round 37 planner
  (SPL-6228). Bug round 37 plans in parallel: **its planner gets this plan's 8 row
  paths from the holder before either plan is pushed** (section 4). The share line:
  refactor 1 of 16 known live lanes, 6%; last 24 h refactor 12% (band 20-30%: UNDER).
- **Briefs on this box** changed in the last 24 h (89) naming a row basename or function
  (`grep -lE 'message_move\.go|topic_merge\.go|topic_promote\.go|moveFrame|mergeFrame|promoteFrame|y18-grok-memory|y20-agy-memory|claude-memory\.inc|_y18_repo|_y20_repo|test-y18|test-y20'`,
  03:10:36Z): **0**.
- **Remote branches committed in the last 24 h** (31 besides master, 02:5xZ):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the paths>` -> **0
  hits**. The 316 lane worktrees on this box: no commit past `origin/master` and no
  uncommitted change on a row path (03:1xZ).
- **Commits since W** on the paths (`git log origin/master --since="$W" -- <paths>`) ->
  **0**.
- **Live lanes named in the brief**: SPL-6182 native auth c-806 (hub auth + store);
  spec 184 H1 c-894 (hub agent-model tables, routes; it records files, none a row path);
  SPL-5882 T3 c-035; spec 154 B7 c-054; spec 123 L3w c-033 (Cloud Translation settings,
  landed `6048633fd`); the t1 issue-backlog topic c-063; csi-rel lanes (other repo); bug
  round 37 (above): none on a row path.

## 3. Per row: what the lane does

- **r87-01:** the merge and promote answers become frames through `moveFrame`; the two
  copies go; `moveFrame`'s comment says what it leaves out; the Go clean code gate keeps
  the frame filter in `message_move.go`.
- **r87-02:** steps Y18 and Y20 source `claude-memory.inc.sh` for the memory repo and its
  slug; `test-y18-grok-memory.sh` proves they are read there once.

## 4. Panel and reviewers (R7)

- Editor: c-230 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2). `ENV=prd ./run -a
  do_spl_hub_agent_kinds` at 2026-11-22T03:10Z: `off [qwen], paused []` (grok on).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 03:10:02Z printed `pick=hold
  reason=no box with a sample is below its overflow mark (200% of its high): queue the
  lane, spawn nothing` (both boxes at 230% / 324% of cores; grok weekly 20% on both: the
  hold is box load, not the grok quota). As in r85 and r86, the holder re-runs the pick
  when it places the rows: a grok pick gives the row a grok R7 seat; a hold then gives it
  a fresh **claude waiver seat** (1a7c70da). Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).
- **Bug round 37** (SPL-6228) plans beside this round: the holder hands its planner the
  row paths of section 2 so the two rounds stay disjoint (R1 across rounds, R3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r87-01 | `c002-r87-01-api-hub-one-move-frame` | `refactor(r87-01-api-hub-one-move-frame, SPL-<row issue>): ...` | `review/r87-01` | 1 |
| r87-02 | `c002-r87-02-orc-install-one-memory-repo` | `refactor(r87-02-orc-install-one-memory-repo, SPL-<row issue>): ...` | `review/r87-02` | 1 |

**r87-01 brief, Files: ONLY**
`csi-spl-api/src/go/spool-hub-api/internal/hub/message_move.go` (`:374` the comment),
`.../internal/hub/topic_merge.go` (`:123,147` the calls, `:169-178` `mergeFrame` and its
comment go), `.../internal/hub/topic_promote.go` (`:111,136` the calls, `:141-150`
`promoteFrame` and its comment go) and
`csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go` (one `folded`
entry). NOT `cmd/spool/hub.go`, `hub/server.go`, `hub/supervise.go`, `auth/` or the store
(SPL-6182, spec 162 T3), NOT any `internal/hub` test, NOT any other `cleancode_test.go`
list (a ceiling or a baseline). Do: plan section 2 row 01 verbatim, 1.3's shape; the red
control (the head's gate on the parent's hub files) RED then GREEN in the body. Gates:
`go test ./internal/hub/ ./internal/cleancode/`, `gofmt -l`, `go vet`,
`bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r87-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spool-install/steps/claude-memory.inc.sh` (new,
executable bit off: it is sourced), `.../steps/y18-grok-memory.sh` and
`.../steps/y20-agy-memory.sh` (each: the source line after its header; the slug and repo
block goes; the two calls name the inc's functions) and
`csi-spl-orc/src/bash/features/spool-install/tests/test-y18-grok-memory.sh` (header item
9, one case before the summary line). NOT `install.sh`, NOT the
`spl-grok-memory-install` / `spl-agy-memory-install` actions, NOT `test-y20-agy-memory.sh`
or `test-agy-rules-always-on.sh` (run, not edited), NOT the other claude project slug
sites of `csi-spl-orc/src/bash/run/` (section 7). Do: plan section 2 row 02 verbatim,
1.4's shape; the red control (the head's `test-y18-grok-memory.sh` on the parent) RED then
GREEN in the body; 1.4's 12-case probe on parent and head, equal. Gates:
`test-y18-grok-memory.sh`, `test-y20-agy-memory.sh`, `test-agy-rules-always-on.sh`
(`SPOOL_TEST=1`, in the worktree), `bash-cleancode.tst.sh`, `shellcheck -S warning -x`
on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| files in the hub module carrying `if k != "undo" && k != "kind" {` (`git grep -l`) | 3 on `b220e7464` -> 1 after row 01 |
| files under `spool-install/steps/` reading the memory repo or slug (`grep -lE 'git-common-dir\|s/\[\^A-Za-z0-9\]/-/g'`) | 2 on `b220e7464` -> 1 after row 02 |
| lines (the heads, `diff -ruN` of base and head, new files included) | row 01: +7 -27; row 02: +38 -32 |
| measured on | `b220e7464`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl_secrets_none_get` (`orc:src/bash/run/spl-secrets-check.func.sh:256`) / `spl_self_host_env_get` (`spl-self-host-up.func.sh:56`), the same dotenv read | secret-class: both read the self-host secrets file (DB and S3 passwords); the brief keeps secret-class sites out | G4 (1.2 (d)) |
| `spl_uplink_trim` (`orc:.../spl-uplink-probe.func.sh:184`) / `ext_api_trim` (`utl:.../external-api-health.func.sh:142`) | two modules: a fold adds an orc -> utl source edge for a 9-line helper | G4 |
| the claude project slug inline in 5 more orc files (`spl-agent-identity-restore.func.sh:372`, `spl-agent-login-check.func.sh:439`, `spl-dispatch-lease.func.sh:2385`, `spl-lane-handover.func.sh:177`, `spl-rotate-lib.func.sh:1425`) | over the 5-site cap with row 02's; each but `spl_handover_slug` is one `sed` inside a larger line, not a function copy; a later row can point them at one helper | `git grep -n "s/\[^A-Za-z0-9\]/-/g"` |
| `tf_get`; the r86 Go set (`checkNoteIDs` / `checkContactIDs`, `readPID` / `harden`, the `*Preflight` sets, `isASCII`, `lastLines`, `firstOf` / `pick`, `phoneDigits` / `contactPhoneDigits`) | r85 / r86 section 7, unchanged on `b220e7464` | G4 |
| the agent-id regex literal, `as_root` / `as_owner`, the per-script message helpers, `say` / `check_tools` in the other cron wrappers | r85 / r86 section 7, unchanged | r86 7 |
| `parse-metadata.func.sh` `${1:?}` lines, terraform `-input=false`, dropped rc | bug rows | r84 7 |
| `topic_loop_fire.go` `!inserted`, `spl-spawn-place-argmax.tst.sh:181-212` | test rows | r83 7 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred, an open owner decision, behaviour, or the full sweep; unchanged since W | 1.2 (c) |

## 8. Changes

- v0.1 (c-230): the rows and every read on `b220e7464`; both heads built and every test of
  1.5 run on base and head, both red controls RED; row 02's behaviour probe (12 cases, 0
  differ); R3 (2.2) and R7 (section 4) checked.

- 2026-11-22 04:0xZ: m-085 (mistral, the other box) **PASS** on v0.1
  `aacf9637a1305c79544c195fb2044454f2946c24`, no W (seat file
  `csi-spl-doc/doc/md/refactor-round-87/seat-mistral.md`, `11b7f922b` on
  `review/c002-refactor-round-87-mistral-seat`, msg 9c725daf). It re-ran the slug and
  window proof, every cited site line on `b220e7464`, both red controls (failure output
  byte-identical to 1.5), the base and head suites, shellcheck on row 02's files, the
  lane map, the queue, the perf floor, the hygiene sweep and the pre-push gate. The line,
  box-free (2.7.4; the box and the home prefix dropped):

  review: m-085 mistral PASS aacf9637a1305c79544c195fb2044454f2946c24 ran: git ls-remote origin refs/heads/review/c002-refactor-round-87-planner ; git log origin/master -1 --format=%cI -E --grep="^docs\(r86-plan" ; git log origin/master --since="$W" --oneline -E --grep="\(r87-" | wc -l ; git ls-remote origin | grep -E "r87-[0-9]{2}|refactor-round-87" ; ls /var/spool-hub/dispatch/briefs | grep -E "r87-[0-9]{2}|refactor-round-87" ; git diff --name-only b220e7464 origin/master -- <9 row paths> ; git show b220e7464:<file> | sed -n <N>p on every cited site ; git grep -n "if k != \"undo\" && k != \"kind\" {" b220e7464 -- csi-spl-api ; git grep -lE "git-common-dir|s/\[\^A-Za-z0-9\]/-/g" b220e7464 -- steps/ ; go test ./internal/cleancode/ -run TestCleanCodeGate -count=1 on scratch copies (base ok rc 0; base+head-test FAIL rc 1, cleancode_test.go:106 names topic_merge.go and topic_promote.go) ; go test -count=1 -v ./internal/hub/ ./internal/cleancode/ on base and head (1337 PASS 0 FAIL rc 0 both) ; go build ./... ; go vet ; gofmt -l ; SPOOL_TEST=1 bash test-y18-grok-memory.sh (base 14/0 rc 0; base+head-test rc 1 FAIL case 9 got "y18-grok-memory.sh y20-agy-memory.sh "; head 15/0 rc 0) ; SPOOL_TEST=1 bash test-y20-agy-memory.sh (68/0) ; SPOOL_TEST=1 bash test-agy-rules-always-on.sh (14/0) ; SPOOL_TEST=1 bash bash-cleancode.tst.sh (15/0) ; shellcheck -S warning -x on the 4 row-02 files (0 findings) ; lane-map.sh --check <9 row paths> --agent m-085 (exit 4, no owner) ; do_spl_spawn_queue (0 queued) ; do_check_dist_hygiene (clean rc 0) ; do_check_pre_push (all PASSED) ; perf-floor command on b220e7464 (perf 29 refactor 113 floor-met) | read: csi-spl-doc/doc/md/refactor-round-87-plan.md @aacf9637 ; csi-spl-doc/doc/md/rounds-rulebook.md ; csi-spl-doc/doc/md/refactor-round-86-plan.md and refactor-round-86/seat-mistral.md @origin/master ; /var/spool-hub/dispatch/c002-next-round-candidates.md ; /var/spool-hub/dispatch/briefs/c002-refactor-round-87-mistral-panel-seat.md ; CLAUDE.md ; csi-spl-doc/doc/md/developer-guide.md ; csi-spl-doc/doc/help/how-to-post.md ; the 9 row files @b220e7464 (message_move.go, topic_merge.go, topic_promote.go, cleancode_test.go, y18-grok-memory.sh, y20-agy-memory.sh, test-y18-grok-memory.sh, test-y20-agy-memory.sh, install.sh) ; spl-watchdog.func.sh, spl-lane-rotate.func.sh, reverse-tunnel-cron.sh, spl-agent-boot-restore-install-cron.func.sh, spl-desk-reply.sh, spl-lane-mix.func.sh @b220e7464 ; seat-file review/c002-refactor-round-87-mistral-seat 11b7f922bfd115045746bf6f4695c454a1cf43bc | log: m-085:~/.vibe/logs/session/unified/7c057b5b-0ab0-7e74-6157-4ec72d9dd450

  `REVIEW_LINE='<the line>' ./run -a do_spl_review_line_check` on the log's box: **rc 0**,
  7 of 7 (holder c-002, 04:1xZ, msg 36c52658); on this box `REVIEW_LINE_SYNTAX=1`: rc 0,
  `SYNTAX OK` (c-230, line 2644 bytes, sha256 `98161e66c1906a44`).
  - **N1** the lane map exits 4 on all 9 row paths, 11 unknown-scope lanes at review time
    (all on the other box), none owning a row path. Agreed: the row lanes re-run R3 at
    spawn (section 2); no row changes.
  - **N2** the planner brief is not in the seat box's `dispatch/briefs` (the planner runs
    on the other box). No change: 2.2's brief read is this box's.
  - **N3** `spl-lane-mix.func.sh` still carries the stale agy words on `b220e7464`
    (`:46`, `:136`, `:138`, `:392`, `:401`); SPL-6174's head `473495da4` is not on master,
    so that input stays gated on SPL-6174 and is accounted through r86 section 7 (the
    `:104` reason words row), not a new section 7 row. Agreed; no change.
  - **N4** the seat built the head control files per 1.3 / 1.4 (sha256 base
    `cleancode_test.go` `f19e114c`, base `test-y18` `63db74ec`, head `cleancode_test.go`
    `a6f4ee94`, head `test-y18` `23636a4f`); failure outputs byte-identical to 1.5. No
    change.
  - **N5** 2.2 recorded 2 unknown lanes at 02:52Z, the seat 11 at review time: the same
    result class (exit 4, no owner of a row path). No change.
- v1.0 (c-230), on the holder's instruction (c-002, msg 36c52658): the PASS, the line and
  its check, and N1-N5 recorded; the seat file folded in. No row changed: rows, files,
  red controls and fix scope read as in v0.1 (`git diff aacf9637a <v1.0> -- <this file>`
  touches only the status line and sections 8 and 9). Row paths unchanged since
  `b220e7464` (`git diff --name-only b220e7464 origin/master -- <the 9 row paths>` ->
  empty, 04:2xZ). Rebased onto `e46621014`.

- 2026-11-22 04:1xZ: m-085 **PASS** on v1.0 `c24e47b1c4974c7f1dcf8f18b1e9de417b2d6202`,
  no W; N1-N5 stand. It checked the v1.0 branch head, that `git diff aacf9637a c24e47b1c
  -- <this file>` touches only the status line and sections 8 and 9, that the folded seat
  file equals `11b7f922b`'s, and that the row paths are unchanged since `b220e7464`. Its
  v1.0 signature (`2023b1346`, which was not on `origin/master`) is folded into the seat
  file by this close record. The holder c-002 confirmed the v0.1 line check, gave the GO
  (msg 118f1356) and v1.0 landed as `c24e47b1c`.

- Round closed (c-230), no version bump: the 2 rows landed, r87-01 `fa86b70d7`
  (SPL-6229, committed 2026-11-22T07:30:50Z; R7 g-118 grok PASS on `ea2bf74e2`, no W;
  holder GO msgs 24b05a0a, 7fff17bc) and r87-02 `a42fff43c` (SPL-6230, committed
  04:55:05Z; R7 g-273 grok PASS on `8f7d74390`, no W). r87-02 ACCEPTED by the holder
  c-002 (msg 76440ff4, 05:11:40Z: c-104 and g-273 ACCEPTED); r87-01's ACCEPTED was not in
  this box's spool when this record was written (its row seat c-101 runs on the other
  box). **R7 vendor:** both seats are grok, the holder's pick at placement (section 4).
  `git patch-id --stable` of each landed commit equals its reviewed head's (r87-01
  `4a6ba6166658`, r87-02 `6ddc0492d53c`). `merge-base --is-ancestor` rc 0 for both on
  `d4c869b1a`. CI on `a42fff43c`: 10 quality gate, 15, 25, 26, 64, 67 **success**. On
  `fa86b70d7`: 10 quality gate, 15, 21, 25, 26, 40, 50, 61, 62, 64 **success**; 20 (hub
  build + deploy, 44998641108) still `in_progress` at 07:58Z, so its deploy is not
  recorded here.
  On `d4c869b1a` (n=1 each, `SPOOL_TEST=1`, in the worktree, 1.5's line counts): `go test
  -count=1 -v ./internal/hub/ ./internal/cleancode/` ok, 1505 `--- PASS` (1350 top-level),
  0 `--- FAIL`, `TestCleanCodeGate` PASS (1.5 read 1337 on `b220e7464`; r87-01's body
  read 1500 on its parent and head: the growth is tests landed by other lanes, not a
  row change); `test-y18-grok-memory.sh` rc 0, 13 pass, 0 fail, "2 grok checks not run"
  (no grok on the measuring user here; g-273 read 15/15, 0 not run, on its box);
  `test-y20-agy-memory.sh` rc 0, 68 pass; `test-agy-rules-always-on.sh` rc 0, 14 pass;
  `bash-cleancode.tst.sh` rc 0, 15 pass; 0 fail lines each. No plan miss.
  - r87-01 and r87-02: no N note in either R7 line. Notes only; none asks a change.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-230 (claude): v0.1, v1.0.
- Panel reviewer seat: m-085 (mistral): **PASS** on v0.1 `aacf9637a` and on v1.0
  `c24e47b1c`, no W (section 8; seat file folded in, v1.0 signature `2023b1346`).
- Row R7 seats: section 4; both grok (section 8, round closed).
- Closed: both rows landed (r87-01 `fa86b70d7`, R7 g-118 PASS; r87-02 `a42fff43c`,
  R7 g-273 PASS). This close record carries `Closes: SPL-6227`.
