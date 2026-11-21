# Refactoring round 85 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6197  
Topic: caaea88d-b622-49d6-ab38-00a5959cf3c6  
Discussion: caaea88d-b622-49d6-ab38-00a5959cf3c6 (t1 #refactoring, "Refactor round 85", opener msg 2ab02440)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r85**, plan `refactor-round-85-plan.md`, rows `r85-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 84 ([refactor-round-84-plan.md](refactor-round-84-plan.md),
v1.0 `c314d1ac1`) is still open: r84-01 (c-880, the other box) and r84-02 (c-906, this
box), neither on trunk. This round does not wait for them and stays off their files
(2.2). The perf floor (rulebook 4.4), measured by the holder on `52b6d7df2`: perf 29,
refactor 110, perf share 20.9%, floor met, so this is a refactor round.

The brief's inputs give no row (1.2), so both rows are new finds of the r83 / r84 kind:
**one function, two or more copies** (G4, 1.2).

**Row 01** gives the three peer cron wrappers, 53 lines each and the same body but for a
name and one `env` word, one body in a new `scripts/peer-cron.inc.sh`. **Row 02** gives
`_id_from_ancestry`, written twice in the two mcp-bot wrappers, one home in a new
`mcp-bot/lib/id-from-ancestry.inc.sh`, and its first test.

**Status: v1.0.** The panel passed v0.1 `08c524dd5` with no W (m-919, mistral; seat file
`csi-spl-doc/doc/md/refactor-round-85/seat-mistral.md`, folded in from `8bc5d6850`). Its
review line passed `do_spl_review_line_check` rc 0 on the log's box; the holder c-003@sat
GOed the land (msg 02f40655). Section 8. Editor: **c-918** (claude).

**One sha:** every count is measured on **`4dd74b366`** (`origin/master` at
2026-11-21T16:4xZ), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. **Every test named in 1.5 was RUN** on scratch copies of that
sha (`git archive 4dd74b366`, then `git init` + one commit): "base" is the copy
unmodified; "head" is a copy with the row's change applied in 1.3's / 1.4's shape; each
red control copies only the head's test file into a fresh copy of base. Nothing of it is
committed. The v0.0 draft's reads were on `a4b7943b4`; `git diff --name-only a4b7943b4
4dd74b366` -> 2 files (`sa:lib/spool-env.inc.sh`, `sa:tests/test-spool-agent-model.sh`,
spec 184 L1), neither a row file. Queue, lane map, brief and branch reads are live state
and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-21T15:17Z (v0.0) and re-read 16:54Z, n=1 each:

- **Window: W=2026-11-21T16:01:28+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r84-plan'` -> `c314d1ac1`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r85-'` -> **0**; over all
  history -> **0**. Control (v0.0): the same read with `(r84-` -> 4 lines (the r84 plan
  commits).
- `git ls-remote origin 'refs/heads/review/r85-*' 'refs/heads/*-r85-*' 'refs/heads/*refactor-round-85*'`
  -> at 15:17Z nothing; at 16:54Z one ref, this plan's own
  `review/c002-refactor-round-85-planner` (v0.0 `4ed8415cc`).
- `grep -rlE 'r85-[0-9]{2}|refactor-round-85' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
  (as root, this box, 15:17Z) -> 1 file, this planner's brief.
- `ls csi-spl-doc/doc/md | grep -c refactor-round-85` -> 0 before v0.0: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) Candidates file** (on the other box; the holder inlined its refactor lines, msg
  4b33063c): the same 8 refactor or test-shaped lines r84 judged (`:1 :25 :48 :51 :74 :76
  :104 :109`). Nothing taken, for r84 section 7's reasons (served, behaviour or
  bug-shaped).
- **(b) r84 section 7:** unchanged on `4dd74b366`; the behaviour items stay out (section
  7). The agent-id regex literal is still out: the sites use `[acgmq]` and
  `SPOOL_AGENT_ID_NEW_RX` is `[acgmoqu]`, so a fold changes which ids they take. Row 02
  keeps its `[acgmq]` text as it is for the same reason.
- **(c) r84-01 / r84-02:** not landed (`git log origin/master --since="$W" -E
  --grep='\(r84-0'` -> 0), so they have no R7 notes yet. The r84 panel's N1-N5 (r84 plan
  section 8) name process points, no row.
- **(d) spec 011 tasks:** the spec folder is unchanged since W (`git log
  origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0); the
  open tasks are those of r84 section 7.
- **How the rows were found** (G4, as in r84): every function name defined in more than
  one file of the orc / iac / utl `src/bash` and `lib` trees (tests excluded), with each
  body's `md5sum`. Byte-identical or near-identical sets: `tf_get` (2 standalone import scripts, `tf-import-table.sh` and
  `tf-030-import-existing-cloud-run.sh`: out, section 7), `as_root` (5 files: 2 orc, 3 utl
  sweeps) and `as_owner` (4): over the 5-site cap with their tests: out, `check_tools` (18 cron wrappers, 15 distinct
  bodies: over the cap; the 3 peer wrappers are identical = **row 01**),
  `_id_from_ancestry` (2, identical but for 2 comments and one `local` = **row 02**).

### 1.3 Row 01's sites: the three peer cron wrappers

`orc:src/bash/scripts/peer-{distill,ensure,restart}-cron.sh`, 53 lines each.
`diff peer-distill-cron.sh peer-<x>-cron.sh` for ensure and restart -> they differ only in
the header (`:2-5`, `:10`), the name in the messages (`:36`, `:42`, `:50`, `:52`) and the
`./run` line `:51` (`env DRY_RUN=0 ./run -a do_spl_peer_<x>`; ensure has `env ./run`, no
`DRY_RUN`). Lines `:15-30` (PATH, `PEER_CRON_TOOLS`, `say`, `check_tools`) and the
control flow `:32-53` are the same text.

Shape (built as the head of 1.5):
- New `orc:src/bash/scripts/peer-cron.inc.sh` (53 lines): `:15-30` verbatim, then
  `peer_cron_main NAME [VAR=VALUE ...] -- [--check-tools]`, which is `:32-53` with the
  name read from `NAME`, `do_spl_peer_$NAME` and `env "${vars[@]}" ./run`. Its `self` /
  `orc` come from the inc's own `readlink -f`, the same dir as the wrappers.
- Each wrapper keeps `:1-14` (lines `:7-8` say that peer-cron.inc.sh sets the PATH and
  checks the tools, so no comment points at code that moved), then
  `. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/peer-cron.inc.sh"` with its
  `shellcheck source=` line, and one call: `peer_cron_main distill DRY_RUN=0 -- "$@"`,
  `peer_cron_main restart DRY_RUN=0 -- "$@"`, `peer_cron_main ensure -- "$@"`. 17 lines.
- The cron lines (`do_spl_peer_*_install_cron`, `spl-peer-crons.func.sh`) do not change:
  they name the wrappers, which stay where they are.
- `orc:src/bash/tests/peer-restart.tst.sh`: its sandbox copies the three wrappers alone
  (`:328`), so it copies the inc too (one line after `:328`); section 11 (`:429-439`)
  gets one case, "say, check_tools and peer_cron_main are defined once, in
  peer-cron.inc.sh" (`grep -lE '^(say|check_tools|peer_cron_main)\(\) *\{'` over the
  four files); the header's item 11 (`:33`) names the inc.

**Behaviour probe** (16:5xZ, n=1 per case): each of the 3 wrappers, base and head copies
in a fake `csi-spl-orc/src/bash/scripts` tree with a stub `./run` that echoes its args,
`DRY_RUN` and its cwd, in 8 cases: no argument, `--check-tools`, an unknown argument, a
missing tool, the action failing (rc 5), no `./run`, a `-wt/` path, a `-wt/` path with
`PEER_ALLOW_WORKTREE=1`. stdout + stderr + rc, timestamps and the tree path masked:
**24 cases, 0 differ**. One new path: with the inc missing next to a wrapper, the wrapper
exits 127 (`peer_cron_main: command not found`); the inc ships in the same commit.

### 1.4 Row 02's sites: `_id_from_ancestry`, two copies

`orc:src/bash/features/mcp-bot/scripts/mcp-start.sh:66-97` and
`mcp-start-chrome.sh:54-83`; their one caller each is `:102` and `:88`
(`AGENT_ID="$(_id_from_ancestry || true)"`). `diff` of the two bodies -> 3 lines: two
comments the chrome copy lacks (`# claude --name <ID>`, `# spawn-<kind>.sh <TITLE>`) and
`local ... prev _` vs `local ... prev` (the chrome copy's loop variable `_` is not local;
`_` is bash's own last-argument variable and nothing reads it).

The installer links both scripts into `$MCP_BOT_HOME` as symlinks into the checkout
(`spool-install/steps/y1-mcp-bot.sh:22-31`, which leaves a non-symlink alone, so a
non-symlink copy keeps its old self-contained text); a lib sourced through `readlink -f`
therefore resolves from the link. Both scripts run `set -euo pipefail` (`:54`, `:41`);
stdout is the MCP stdio channel, and the lib prints nothing when sourced.

Shape (built as the head of 1.5):
- New `orc:src/bash/features/mcp-bot/lib/id-from-ancestry.inc.sh`: a 5-line header,
  then mcp-start.sh's `:66-97` verbatim (the commented copy).
- `mcp-start.sh:66-97` and `mcp-start-chrome.sh:54-83` become 3 lines each: a pointer
  comment, the `shellcheck source=../lib/id-from-ancestry.inc.sh` line and
  `. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/id-from-ancestry.inc.sh"`.
- No test runs the function today (`git grep -n _id_from_ancestry -- '*tests*'` -> 0), so
  the row adds `orc:src/bash/features/mcp-bot/tests/test-id-from-ancestry.sh` (6 cases):
  a probe that sources the lib runs under a parent carrying the id: an ancestor's
  `SPOOL_AGENT_ID`, an ancestor's `--name <id>` (its `SPOOL_AGENT_ID` not an id), an
  ancestor `spawn-<kind>.sh <id>`; the function is defined once, in `lib/`; each wrapper
  sources the lib. `mcp-bot/tests/run-all-tests.sh` runs every `test-*.sh`, and CI runs
  every `features/*/tests/test-*.sh` (`.github/workflows/10_ci-quality.yml:1344`).

**Behaviour probe** (16:5xZ, n=1 per case): the base mcp-start body, the base chrome body
and the head lib, each sourced by a probe under the same parent, in 8 cases (ancestor
`SPOOL_AGENT_ID` `c-123`, `m-042`, `base` + `--name c-777`, `c-12` + `--name bad/id`,
`x-123`; no `SPOOL_AGENT_ID` + `--name g-901`; a `spawn-agy.sh a-314` parent; an empty
`SPOOL_AGENT_ID` + a bare `--name`): **8 cases, 0 differ**. The three cases with no id
on the near parents return the id of the session that ran the probe, from further up its
real ancestry, the same on all three; the new test uses only cases the near parent
decides.

### 1.5 Before and on the row's head

2026-11-21T16:4xZ-16:5xZ, n=1, `SPOOL_TEST=1`, one suite at a time; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`.

| suite | row | base rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `orc:src/bash/tests/peer-restart.tst.sh` | 01 | 0 / 35 | 0 / 36 / 0 | +1. **Red:** head's test on base: rc 1, 35 pass, 1 FAIL `11. defined once (want 'peer-cron.inc.sh ', got 'peer-distill-cron.sh peer-ensure-cron.sh peer-restart-cron.sh ')` |
| `orc:src/bash/features/mcp-bot/tests/run-all-tests.sh` (5 suites on base, 6 on head) | 02 | 0 / 89 | 0 / 96 / 0 | +7: the 6 new cases and `test-hygiene.sh`'s `parses:` line for the new test. **Red:** the new `test-id-from-ancestry.sh` on base: rc 1, 0 pass, 6 FAIL (the three ancestry cases `got 'rc=127'`, the lib is not there; `defined once` got the two scripts; both `sources the lib` got 0) |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 | 0 / 15 / 0 (each row's head) | |
| `shellcheck -S warning -x` on the row's files | 01, 02 | 0 findings | 0 findings each | |

The tests that name the sites (R2): `git grep -lE` over the tests of
`peer-(distill|ensure|restart)-cron|peer_cron|check_tools` (row 01) and
`mcp-start|_id_from_ancestry` (row 02). Named there and not run here:
`boot-cron-gate.tst.sh`, `wd-ensure.tst.sh` (they name `spl-peer-crons.func.sh`, which
row 01 does not change); `spool-install/tests/test-install.sh`,
`check-ysg-box-deps.tst.sh`, `spl-skills-refresh.tst.sh`,
`spl-spool-refresh-shared.tst.sh`, `spl-spool-refresh.tst.sh` (they make or check
`mcp-start*.sh` as symlinks or fixture names; none runs the scripts). The row lanes run
them.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r85-01-orc-peer-crons-one-body)` | one fact, one copy (developer guide 2.2.4) | the three peer cron wrappers carry the same 39-line body (1.3) | `orc:src/bash/scripts/peer-cron.inc.sh` (new)<br>`orc:src/bash/scripts/peer-distill-cron.sh:7-8,15-53`<br>`orc:src/bash/scripts/peer-ensure-cron.sh:7-8,15-53`<br>`orc:src/bash/scripts/peer-restart-cron.sh:7-8,15-53`<br>`orc:src/bash/tests/peer-restart.tst.sh:33,328,439` | 3 copies -> 1 | 1.3's shape. `peer-restart.tst.sh` +1 case and the inc copied into its sandbox. **Red control:** head's test on the parent FAILs 1 (1.5), then GREEN (36); outputs in the body. **Behaviour:** 1.3's 24-case probe on parent and head, 0 differ. Tests: `peer-restart.tst.sh`, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r85-02-orc-mcp-bot-one-id-from-ancestry)` | folded helpers exist once (developer guide 2.2.4) | `mcp-start.sh` and `mcp-start-chrome.sh` each define `_id_from_ancestry`, the same body, with no test (1.4) | `orc:src/bash/features/mcp-bot/lib/id-from-ancestry.inc.sh` (new)<br>`orc:src/bash/features/mcp-bot/scripts/mcp-start.sh:66-97`<br>`orc:src/bash/features/mcp-bot/scripts/mcp-start-chrome.sh:54-83`<br>`orc:src/bash/features/mcp-bot/tests/test-id-from-ancestry.sh` (new) | 2 copies -> 1 | 1.4's shape. The new test, 6 cases. **Red control:** the new test on the parent FAILs 6 (1.5), then GREEN (6); outputs in the body. **Behaviour:** 1.4's 8-case probe on parent and head, 0 differ. Tests: `mcp-bot/tests/run-all-tests.sh`, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (row 01's three `diff`s and
`:328`, `:429-439`; row 02's two bodies and their `diff`) on the `origin/master` it starts
from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r85-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r85-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 moves a body into a sourced file and changes no output, exit code or
cron line (1.3's probe); row 02 moves a function into a lib and changes no id it returns
(1.4's probe). Each: `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their file sets are disjoint (row 01: 5 files, row 02: 4),
  and no file is on another row, a live lane or a queued row (2.2).
- No row edits `sa:lib/spool-env.inc.sh` (spec 184), `sa:lib/agent-models.inc.sh` (spec
  184 A1), `spl-peer-crons.func.sh` or any `spl-peer-*-install-cron.func.sh`,
  `spool-install/steps/y1-mcp-bot.sh`, `mcp-bot/tests/lib.inc.sh`, r84-01's or r84-02's
  files, any `run.sh`, a migration, `csi-spl-cnf/`, terraform or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9): row 01's 5 and row 02's 4 (section 2).

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-918`, one call per
  path, 2026-11-21T16:52:58Z, n=1: **status 4 on all 9** ("no live lane lists <path>, but
  8 live lane(s) record no files"). The `unknown:` lanes, all on the other box: b34-01
  c-809 (store doc asset), r84-01 c-880 (tmux-close-window), b35-01 c-893 (iac tf step
  selects orc test), spec 184 H1 c-894 (hub agent model), spec 123 L4 c-898 (cost
  labels), two grok `rotate` seats (g-888, g-889) and spec 033 T026 m-896 (help docs). By
  slug none is a peer-cron or mcp-bot lane. No live lane lists a row path.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 16:54:01Z): **9
  queued**: the spec 123 grok R7 seat, the WUI Google-verify home, spec 123 L5-L7 and
  L3w, SPL-5882 T3 hub errors, the csi-rel home lede, spec 154 B7. None is an orc
  scripts or mcp-bot lane by its placement. The share line: refactor 5 of 22 known live
  lanes, 22% (band 10-20%: OVER); last 24 h refactor 10% (band 20-30%: UNDER).
- **Briefs on this box** changed in the last 24 h naming a row basename or function
  (`grep -lE 'peer-(cron|distill-cron|ensure-cron|restart-cron)|peer-restart\.tst|mcp-start|id-from-ancestry|_id_from_ancestry'`):
  1, r77-02's, which names `peer-restart.tst.sh` as off limits; r77-02 landed
  (`7ff2604dd`).
- **Remote branches committed in the last 24 h** (41 besides master, 16:5xZ):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 9 paths>` -> **0
  hits**.
- **Commits since W** on the 9 paths (`git log origin/master --since="$W" -- <paths>`) ->
  **0**.
- **Live lanes named in the brief**: r84-01, r84-02 (2.1); bug round 34 b34-01; bug round
  35 b35-01; spec 184 A1, C1, L1; SPL-6182 native auth (hub auth, store, a migration);
  SPL-6188 (hub topic export); spec 190 (media store, rdb 0306); the WUI Google-verify
  lane; csi-rel; the review seats; the private-workspace seats: none on a row path by its
  listed files.

## 3. Per row: what the lane does

- **r85-01:** the three peer cron wrappers keep their header and one call; their body
  moves into `peer-cron.inc.sh`; `peer-restart.tst.sh` proves it is there once.
- **r85-02:** `_id_from_ancestry` moves into `mcp-bot/lib/id-from-ancestry.inc.sh`; both
  wrappers source it; a new test proves what it reads and that it has one copy.

## 4. Panel and reviewers (R7)

- Editor: c-918 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** the queued mistral seat `c002-refactor-round-85-mistral-panel-seat`
  (m-919, this box, window `r85-plan-review` at 16:5xZ): one **cross-vendor** doc seat
  (agy, the main vendor for plan reviews, is out until about 11-24). The seat reviews
  this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-21T16:54:47Z printed
  `pick=hold reason=no box with a sample is below its overflow mark (200% of its high):
  queue the lane, spawn nothing` (grok weekly 2% and 1%: the hold is box load, not the
  grok quota). So each row takes a fresh **claude waiver seat** (1a7c70da), as r63 to
  r84. The holder re-runs the pick when it places the rows; a grok pick then gives the
  row a grok R7 seat instead. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r85-01 | `c002-r85-01-orc-peer-crons-one-body` | `refactor(r85-01-orc-peer-crons-one-body, SPL-<row issue>): ...` | `review/r85-01` | 1 |
| r85-02 | `c002-r85-02-orc-mcp-bot-one-id-from-ancestry` | `refactor(r85-02-orc-mcp-bot-one-id-from-ancestry, SPL-<row issue>): ...` | `review/r85-02` | 1 |

**r85-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/scripts/peer-cron.inc.sh` (new, executable bit off: it is
sourced), `csi-spl-orc/src/bash/scripts/peer-distill-cron.sh`,
`.../peer-ensure-cron.sh`, `.../peer-restart-cron.sh` (each `:7-8` reworded, `:15-53`
-> the source line and one `peer_cron_main` call) and
`csi-spl-orc/src/bash/tests/peer-restart.tst.sh` (`:33` header, one `cp` after `:328`,
one case after `:439`). NOT `spl-peer-crons.func.sh` or any `spl-peer-*-install-cron`
action (the cron lines stay), NOT any other `*-cron.sh` wrapper (15 other `check_tools`
bodies: over the cap), NOT `desk-reconcile-cron.sh`. Do: plan section 2 row 01
verbatim, 1.3's shape; the red control (head's test on the parent) RED then GREEN in the
body; 1.3's 24-case probe on parent and head, equal. Gates: `peer-restart.tst.sh`
(`SPOOL_TEST=1`, in the worktree), `bash-cleancode.tst.sh`, `shellcheck -S warning -x`
on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`.
Kind `simple_coding`, vendor claude.

**r85-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/mcp-bot/lib/id-from-ancestry.inc.sh` (new, sourced),
`csi-spl-orc/src/bash/features/mcp-bot/scripts/mcp-start.sh` (`:66-97` -> the 3-line
source block), `.../scripts/mcp-start-chrome.sh` (`:54-83` -> the same 3 lines) and
`csi-spl-orc/src/bash/features/mcp-bot/tests/test-id-from-ancestry.sh` (new,
executable). NOT the agent-id regex inside the function (`[acgmq]`, section 7), NOT
`mcp-bot/tests/lib.inc.sh`, NOT `spool-install/steps/y1-mcp-bot.sh`, NOT any other
function of the two wrappers. Do: plan section 2 row 02 verbatim, 1.4's shape; the red
control (the new test on the parent) RED then GREEN in the body; 1.4's 8-case probe on
parent and head, equal. Gates: `mcp-bot/tests/run-all-tests.sh` (`SPOOL_TEST=1`, in the
worktree), `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| `check_tools` definitions in the 3 peer wrappers + inc (`grep -lE '^check_tools\(\) *\{'`) | 3 on `4dd74b366` -> 1 after row 01 |
| `_id_from_ancestry` definitions in `mcp-bot/scripts` + `lib` (`grep -rlE '^_id_from_ancestry\(\) *\{'`) | 2 on `4dd74b366` -> 1 after row 02 |
| lines (the heads, `git diff --cached --stat`, new files included) | row 01: +74 -124; row 02: +76 -62 |
| measured on | `4dd74b366`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `parse-metadata.func.sh`, the 4 `${1:?}` lines per copy | a bug row (r84 section 7) | r84 7 |
| `spl-lane-mix.func.sh` reason and flag words (candidates `:104`) | the action's output, asserted by its test: behaviour | r84 7 |
| `workspace-rules.md:33-34`, spec 176's cite, the wf 10 job name (candidates `:105`) | doc text; a CI job rename changes the required-check name | r84 7 |
| `_spool_desk_root_key` (`desk-root.inc.sh`) | behaviour (r84 1.4); the file is r84-02's until it lands | r84 7 |
| the agent-id regex literal (43 lines) beside `SPOOL_AGENT_ID_NEW_RX` | over the 5-site cap; two letter sets, so a fold changes which ids some sites take; its home `spool-env.inc.sh` is spec 184's | 1.2 (b) |
| `check_tools` in the other 15 `*-cron.sh` wrappers | 15 distinct bodies (each its own tool list and messages): over the cap, and not one fact | G4 |
| `as_root` (5 files) / `as_owner` (4 files), the orc and utl sweeps | 5 and 4 definitions (`grep -rlE '^as_root\(\) *\{'`, tests excluded) plus their tests: over the 5-site cap; v0.0 read that the utl tests run `sed`-edited copies from a temp dir, where a sourced lib would not resolve (not re-checked in v0.1) | G4 |
| `tf_get` (2 copies: `orc:src/bash/scripts/tf-import-table.sh:28`, `tf-030-import-existing-cloud-run.sh`) | v0.0 read that one copy runs alone inside the tf-runner container, where a sibling file is not mounted (not re-checked in v0.1); `tf-import-table.sh:10` says it follows the other by design | G4 |
| `usage`, `say`, `step`, `refuse`, `die`, `render`, `print`, `allow` | each script's own text or message prefix, not one fact | G4 (r84) |
| `topic_loop_fire.go` `!inserted`, `spl-spawn-place-argmax.tst.sh:181-212` | test rows | r83 7 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred, an open owner decision, behaviour, or the full sweep; unchanged since W | 1.2 (d) |

## 8. Changes

- v0.0 (c-918, `4ed8415cc`, review branch only): working draft at the 16:42Z lane
  rotation; the rows and reads on `a4b7943b4`; no test run.
- v0.1 (c-918): every read re-done on `4dd74b366`; both heads built and every test of 1.5
  run on base and head, both red controls RED; the two behaviour probes (24 and 8 cases,
  0 differ); R3 (2.2) and R7 (section 4) checked. Row 01 also edits
  `peer-restart.tst.sh:328` (its sandbox copies the wrappers alone) and rewords the
  wrappers' `:7-8`.
- 2026-11-21 17:1xZ: m-919 (mistral, this box) **PASS** on v0.1
  `08c524dd59d0b9d70bbd0d7841c796d0f65a3a88`, no W (msgs 9c3ee992 and b9fd589a, the same
  line; seat file `csi-spl-doc/doc/md/refactor-round-85/seat-mistral.md`, `8bc5d6850` on
  `review/c002-refactor-round-85-mistral-seat`). It re-ran the slug proof, every cited site
  line on `4dd74b366` and origin/master, both red controls (row 01's FAIL line
  byte-identical to 1.5's quote), the base suites, shellcheck, the lane map, the branch scan,
  the queue, the grok pick and the pre-push gate. The line, box-free (2.7.4):

  review: m-919 mistral PASS 08c524dd59d0b9d70bbd0d7841c796d0f65a3a88 ran: git fetch origin; git ls-remote origin filtered for r85 and refactor-round-85 refs; git log origin/master --since="2026-11-21T16:01:28+02:00" -E --grep="(r85-" counted with wc -l -> 0 (all history 0, control r84 -> 5); git diff --name-only 4dd74b366 origin/master -- the 9 row paths -> empty; git show 4dd74b366:<file> with sed -n <N>p for every cited site line; diff of the three peer cron wrappers; diff of the two _id_from_ancestry bodies (3 lines); git archive 4dd74b366 extracted to /tmp/r85-base; SPOOL_TEST=1 bash csi-spl-orc/src/bash/tests/peer-restart.tst.sh -> rc 0, 35 pass; head-case-on-base run of the same suite -> rc 1, 35 pass 1 FAIL with the plan's quoted line; SPOOL_TEST=1 bash csi-spl-orc/src/bash/features/mcp-bot/tests/run-all-tests.sh -> rc 0, 89 pass; row-02 red probe on base -> rc 1 (lib absent, direct call rc 127, defined-once got the two scripts, sources 0 of 2); SPOOL_TEST=1 bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh -> rc 0, 15 pass; shellcheck -S warning -x on the 6 existing row files -> rc 0; lane-map.sh --check the 9 row paths --agent m-919 -> exit 4; git log origin/master --since=W -- the 9 paths -> 0; remote-branch diff scan over the 9 paths -> 0 hits; do_spl_spawn_queue -> 11 queued, none on a row path; BOX_PICK_KIND=grok do_spl_box_pick -> pick=hold; cd csi-spl-iac and ./run -a do_check_dist_hygiene -> clean; ./run -a do_check_pre_push -> all parts PASSED | read: csi-spl-doc/doc/md/refactor-round-85-plan.md at 08c524dd (352 lines, the sha c-918 named in msg 63305f3b on task dispatch-refactor-r85); csi-spl-doc/doc/md/rounds-rulebook.md; csi-spl-doc/doc/md/refactor-round-84-plan.md section 7 and csi-spl-doc/doc/md/refactor-round-84/seat-mistral.md at origin/master; the 6 existing row files, peer-restart.tst.sh, spool-install/steps/y1-mcp-bot.sh, .github/workflows/10_ci-quality.yml, sa:lib/spool-env.inc.sh at 4dd74b366; /var/spool-hub/dispatch/c002-a8000a91-candidates.txt; /var/spool-hub/m-919/lifetime/brief.md; the seat file csi-spl-doc/doc/md/refactor-round-85/seat-mistral.md; seat-file review/c002-refactor-round-85-mistral-seat 8bc5d68501f0fea5dd5ca42a579b984300425280 | log: m-919:~/.vibe/logs/session/unified/129c6edc-8036-9225-bd65-98fb0551df03

  `REVIEW_LINE='<the line>' ./run -a do_spl_review_line_check` on the log's box,
  2026-11-21T17:20:25Z (c-918): **rc 0**, `OK 2 of 2 named in ran: are commands in <log>
  (1495 commands read): peer-restart.tst.sh, bash-cleancode.tst.sh`; `REVIEW_LINE_SYNTAX=1`
  on the other box: SYNTAX OK rc 0 (c-003@sat, msg 952c5268).
  - **N1** the lane map exits 4 (unknown-scope lanes, all on the other box, none a
    peer-cron or mcp-bot lane by slug). Agreed: the row lanes re-run R3 at spawn (section 2,
    "re-measure first"); no row changes.
  - **N2** the row heads are not on the plan branch; the seat rebuilt the red controls from
    1.3 / 1.4 on a copy of base. Agreed: a plan carries no code (brief); the row lanes build
    the heads and put the red and green runs in their commit bodies (section 5).
  - **N3** the candidates file is not on this box; the seat checked against r84 section 7
    and the old candidates file here. Agreed: 1.2 (a) is the holder's inlined read.
  - **N4** r84-02 landed (`15eb398c8`) after the base; `git diff --name-only 4dd74b366
    origin/master -- <the 9 row paths>` -> empty. Re-read by c-918 at 17:2xZ: the 5 files it
    changed are r84-02's own (`desk-root.inc.sh`, the three desk readers, their test), none a
    row path. Row sites unchanged.
  - **N5** `do_spl_box_pick` gave `pick=hold` at review time too: the claude waiver R7 seat
    stands; the holder re-runs the pick at placement (section 4).
  - **N6** the queue read 11 at review time against 2.2's 9 at 16:54Z: live state, none on a
    row path. No row changes.
- v1.0 (c-918), on the holder's GO (c-003@sat, msg 02f40655): the PASS, the line and its
  check, and N1-N6 recorded; the seat file folded in. No row changed: rows, files, red
  controls and fix scope read as in v0.1 (`git diff 08c524dd5 <v1.0> -- <this file>`
  touches only the status line and sections 8 and 9). Rebased onto `15eb398c8`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-918 (claude): v1.0.
- Panel reviewer seat: m-919 (mistral): **PASS** on v0.1 `08c524dd5`, no W (section 8; seat
  file folded in; review line check rc 0).
- Row R7 seats: section 4.
