# Refactoring round 85 - plan (2 rows), v0.0 WORKING DRAFT

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6197  
Topic: caaea88d-b622-49d6-ab38-00a5959cf3c6  

**Status: v0.0, working draft at a lane rotation (16:4xZ).** NOT for the panel yet:
the base/head test runs and the red controls of section 1.5 are not run. The next
editor runs them, then pushes v0.1 to `review/c002-refactor-round-85-planner` and sends
its sha to the holder and the panel seat m-919 (mistral, on this box). Editor: c-918
(claude).

**One sha:** every read is on **`a4b7943b4`** (`origin/master`, 2026-11-21T15:10:01Z).

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3), 2026-11-21T15:17:55Z, n=1

- **Window: W=2026-11-21T16:01:28+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r84-plan'` -> `c314d1ac1`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r85-'` -> **0**; over all
  history -> **0**. Control: the same read with `(r84-` -> 4 lines (the r84 plan commits).
- `git ls-remote origin 'refs/heads/review/r85-*' 'refs/heads/wip/*r85*' 'refs/heads/*-r85-*' 'refs/heads/*refactor-round-85*'`
  -> nothing.
- `grep -rlE 'r85-[0-9]{2}|refactor-round-85' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
  (as root, this box) -> 1 file, this planner's brief.
- `ls csi-spl-doc/doc/md | grep -c refactor-round-85` -> 0: the plain name.

### 1.2 The brief's inputs

- **Candidates file** (on the other box; the holder c-003 inlined it, msg 4b33063c):
  110 lines, the same 8 refactor or test-shaped lines r84 judged (`:1 :25 :48 :51 :74 :76
  :104 :109`). Nothing taken, for r84 section 7's reasons (served, behaviour or bug-shaped).
- **r84 section 7:** unchanged; the behaviour items stay out. The agent-id regex literal is
  still out: the sites use `[acgmq]` and `SPOOL_AGENT_ID_NEW_RX` is `[acgmoqu]`, so a fold
  changes which ids they take.
- **r84-01 / r84-02:** not landed (`git log origin/master --since="$W" -E --grep='\(r84-0'`
  -> 0), so they have no R7 notes yet.
- **How the rows were found** (G4, as in r84): every function name defined in more than one
  file of the orc / iac / utl `src/bash` and `lib` trees (tests excluded), with each
  body's `md5sum`. Byte-identical or near-identical sets: `tf_get` (2, but one copy runs
  alone inside the tf-runner container: out), `as_root` / `as_owner` (3 utl sweeps; their
  tests run `sed`-edited copies from a temp dir, where a sourced lib would not resolve,
  so the row passes the 5-site cap: out for now), `check_tools` (18 cron wrappers, 15
  distinct bodies: over the cap; the 3 peer wrappers are identical = **row 01**),
  `_id_from_ancestry` (2, identical but for 2 comments and one `local` = **row 02**).

### 1.3 Row 01: the three peer cron wrappers, one body

`csi-spl-orc/src/bash/scripts/peer-{distill,ensure,restart}-cron.sh`, 53 lines each.
`diff` of distill against each of the others -> they differ only in the header
(`:2-5`, `:10`), the name in the messages (`:36`, `:42`, `:50`, `:52`) and the `./run` line
(`:51`: `env DRY_RUN=0 ./run -a do_spl_peer_<x>`; ensure has `env ./run`, no DRY_RUN).
Shape: `scripts/peer-cron.inc.sh` holds the PATH setup, `PEER_CRON_TOOLS`, `say`,
`check_tools` and one `peer_cron_main NAME ACTION [VAR=VAL...] -- "$@"`; each wrapper
keeps its header and `set -uo pipefail`, sources the inc through
`readlink -f "${BASH_SOURCE[0]}"` and calls it. The cron line (`do_spl_peer_*_install_cron`)
does not change. Test: `orc:src/bash/tests/peer-restart.tst.sh` section 11 (`:427-437`)
already runs all three; add a case that `check_tools` is defined once (in the inc).

### 1.4 Row 02: `_id_from_ancestry`, one home

`csi-spl-orc/src/bash/features/mcp-bot/scripts/mcp-start.sh:66-97` and
`mcp-start-chrome.sh:54-83`; their callers are `:102` and `:88`. The scripts are installed
as symlinks into the checkout (`spool-install/steps/y1-mcp-bot.sh`, which leaves a
non-symlink alone, so a non-symlink copy never runs the new code). A lib sourced through
`readlink -f` therefore resolves. Shape: `mcp-bot/lib/id-from-ancestry.inc.sh` with
mcp-start.sh's text. No test runs the function today
(`grep -n _id_from_ancestry mcp-bot/tests/*` -> 0), so the row adds
`mcp-bot/tests/test-id-from-ancestry.sh`: an ancestor's `SPOOL_AGENT_ID`, an ancestor's
`--name <id>`, neither, and "defined once". CI runs every `features/*/tests/test-*.sh`
(`10_ci-quality.yml:1344`).

### 1.5 Before and on the row's head

NOT RUN yet (rotation). The next editor builds base and head copies of `a4b7943b4`
(`git archive`), runs `peer-restart.tst.sh`, the mcp-bot `run-all-tests.sh`,
`bash-cleancode.tst.sh` and `shellcheck -S warning -x` on base and on each head, and each
red control (the head's test run on base).

## 2. The 2 rows (draft)

| # | practice | sites | test | vendor | kind | batch |
|---|---|---|---|---|---|---|
| 01 `refactor(r85-01-orc-peer-crons-one-body)` | one fact, one copy (developer guide 2.2.4) | `orc:src/bash/scripts/peer-cron.inc.sh` (new), `peer-distill-cron.sh`, `peer-ensure-cron.sh`, `peer-restart-cron.sh`, `orc:src/bash/tests/peer-restart.tst.sh:427-437` | section 11 + "defined once"; red control on base | claude | simple_coding | 1 |
| 02 `refactor(r85-02-orc-mcp-bot-one-id-from-ancestry)` | folded helpers exist once (2.2.4) | `mcp-bot/lib/id-from-ancestry.inc.sh` (new), `mcp-start.sh:66-97`, `mcp-start-chrome.sh:54-83`, `mcp-bot/tests/test-id-from-ancestry.sh` (new) | the new test; red control on base | claude | simple_coding | 1 |

R3 (the lane map and the queue) and R7 (`BOX_PICK_KIND=grok do_spl_box_pick`) are NOT
checked yet.

## 8. Changes

- v0.0 (c-918): working draft at the 16:42Z lane rotation; the rows and reads above; no
  test run yet.
