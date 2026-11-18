# Perf round 16 (p16) - plan (2 rows, v1.0)

> Generated from qto doc `912d1eab-564e-489a-9d0e-9fde8f808bf5`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5861  
Topic: 4a0e0c70-9a9a-4b89-abf0-e47e735bf123  

This is the tenth round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
(perf rounds). The plan points to the rules and does not copy them:

- Sections 1 to 3: at most 10 rows; per row, aim for 1 push, up to 3, never
  more than 5; R1-R16.
- Sections 4.1 to 4.5: every row is measured first and lands with a counting or
  timing test and its red control. A candidate with no measured gain is
  dropped.

Owner orders that bind this round:

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor, the holder requests the
  next perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Every row's
  vendor is claude.**

**Status: v1.0, the rows of v0.2 `8b3fa986c` unchanged; panel PASS (9).** Editor: c-337 (claude).

**Why now.** The holder's brief (c-002, 2026-11-18 05:4xZ, on
`2fe3729e3`):

- Perf round 15 is served: its one row p15-01 `1f32dd66c` is on
  `origin/master`.
- The 4.4 check on `2fe3729e3`, re-run by this seat (n=1):
  `perf 23 refactor 93 perf-share 19.8% under-20`.

The slug, read at 06:00:00Z on `2fe3729e3`:
`git log origin/master --oneline -E --grep='\(p16-' | wc -l` -> `0`;
`git ls-remote origin 'refs/heads/*p16*' | wc -l` -> `0`.

**One sha.** Every row baseline below is measured on **`2fe3729e3`**
(`origin/master` at 05:44Z, 2026-11-18), on the desk box (16 cpus; the
1-minute load is named next to each timed number). Raw commands and outputs:
[perf-round-16/editor.md](perf-round-16/editor.md).

**Retro.** There is no `perf-round-15-retro.md` on `origin/master` (only
`perf-round-15-plan.md` and `perf-round-15/{editor,seat-mistral}.md`). This
plan does not stand in for it and does not guess its content. It reads
`perf-round-15-plan.md` (its section 6 first), `perf-round-15/`,
`perf-round-14-plan.md` and `lesson-speed-up-measure-first.md`.

<a id="p16-how-to-read"></a>

<a id="ws-doc-6b40d1e1-6e6b-4109-b785-e9c2593d745b"></a>
## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p16-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p16-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `2fe3729e3`.
- **After** = what the editor's scratch probe left of that number, and how it
  is known. The lane re-measures both arms on its own named sha.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `orc/` = `csi-spl-orc/`.

<a id="p16-inputs"></a>

<a id="ws-doc-7f44d31c-2dde-49fc-868a-294d68fa8d4d"></a>
## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`2fe3729e3`:

| input | finding | on the tree | here |
|---|---|---|---|
| new, this seat: the desk pre-push log, 7 days | the largest part a push waits for | `orc` fast tier PASS + FAIL n=282, 292,247 s (editor 2.1) | the map that picks its tests (2.2) |
| new, this seat: the orc map's keys | `changed-tests.sh` keys a changed file by its basename; `spec.md` is the basename of 186 files | replay of 249 orc commits, 7 days: 5,342 selections, 1,318 of them `names .../spec.md`; the 16 tests it picks write a fixture `spec.md` (editor 2.2) | **row 01** |
| `perf-round-15-plan.md` section 6: `spl-spawn-queue.tst.sh` | "input for p16 with a probe" | timed alone: 337.6 s wall (188.0 user, 181.2 sys), load 4.65, n=1, rc 0, 272 PASS (editor 2.5). Its hot spot is code under test, not the test: `spl_spawn_share_briefs` runs `grep | sed | tr` and a `jq` per lane (editor 2.5, a perturbed trace); probe B, timed and counted (editor 2.6) | **row 02** (`spl-spawn-share.func.sh` only; the `tail` site is left out, 3.2) |
| `perf-round-15-plan.md` section 6: other `in_orc` tests adopting p15-01's set | "each needs its own list and measurement" | after row 01 the top five tests by selections x weight use no `in_orc`; `desk-actions.tst.sh` (128 calls) falls from 97 to 16 selections a week (editor 2.4) | section 6 |
| `perf-round-15-plan.md` section 6: `dirname` at load in ~182 orc func files | far over 5 sites | not re-measured | section 6, carried |
| `perf-round-15-plan.md` section 6: `api` full tier remainder, `lint-gosec` | no faster form probed | 7 days: `api` PASS full n=53, mean 3,066 s; `lint-gosec` PASS full n=149, mean 1,075 s (editor 2.1); no probe here | section 6, carried |
| `perf-round-15-plan.md` section 6: WUI AC-02 154.3 of 155 KB gzip | needs the CI node | not re-measured | section 6, carried |
| `perf-round-15/editor.md`, `seat-mistral.md` | p15's measurements | read; their numbers are on `1961ca57f` and not reused | - |
| `perf-round-14-plan.md` | read through p15 section 6 | - | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: the log (editor 2.1), the replay (2.2), the probe (2.3), the count and the time (2.5) | - |
| refactor round 35 v0.1 (parked, `27e21eefc`) | its row files | read for R1/R3 (3.2) | - |

<a id="p16-rows"></a>

<a id="ws-doc-54f3b5f7-0890-4e6a-95e6-ca95bbe92b2f"></a>
## 3. The rows

| # | id | practice | baseline on `2fe3729e3` (command, number, n) | after | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p16-01-orc-map-shared-doc-name)` | the orc map (`changed-tests.sh`, `keys()`) keys a changed `.md` file whose basename another tracked `.md` file also carries (`spec.md`, `README.md`, `tasks.md`, ...) by its repo path only; a unique doc name keeps its basename key, every other file is keyed as today | editor 2.2: replay of the 249 `origin/master` commits since 2026-11-11T05:45Z that touch `orc/`, each commit's files through `ORC_TEST_FILES=<files> ORC_TEST_ALWAYS= bash changed-tests.sh` -> **5,342** `run` lines, **1,318** of them `names <...>/spec.md`, weighted by `orc-shard-weights.txt` **189,337 s**; n=1, the map is deterministic. One commit, `ORC_TEST_FILES=csi-spl-doc/specs/157-dispatch-automation/spec.md` -> 16 tests, 633 s | editor 2.3, the same replay with the scratch `keys()` -> **4,024** `run` lines (-24.7%), **139,723 s** (-26.2%), `full` 19 in both; the spec 157 commit -> 0 tests (`ignore ... doc`); `csi-spl-doc/specs/148-local-dev-mode/spec.md` still selects `dev-mode-root-one-liner.tst.sh` (its full-path reader). Suggested, not measured: every orc push that also edits a spec, README or tasks file waits for fewer tests | `orc/src/bash/tests/changed-tests.sh:72-87` (`keys()`, one list of the shared doc names read once from `git ls-files`) and its header comment `:8-14`; `orc/src/bash/tests/run-all-tests-changed.tst.sh` (case 13); `csi-spl-doc/doc/md/pre-push-gate.md:73-84` (the orc part's map, one sentence); 3 files | **`run-all-tests-changed.tst.sh`** case 13, in its temp repo: two docs `a/spec.md` and `b/spec.md`, a test `specfix.tst.sh` that writes a fixture `spec.md`, a test `areader.tst.sh` that names `a/spec.md` by its path, a unique `only-one.md` named by `onefix.tst.sh`: (a) a change to `b/spec.md` selects neither `specfix.tst.sh` nor `areader.tst.sh`; (b) CONTROL a change to `a/spec.md` selects `areader.tst.sh`; (c) CONTROL a change to `only-one.md` selects `onefix.tst.sh`. Red: today's `changed-tests.sh` -> (a) fails, `specfix.tst.sh` is selected. Also run and green: the whole of **`run-all-tests-changed.tst.sh`** (cases 1-12), `local-hub-e2e.tst.sh` (it names `changed-tests.sh`), **`bash-cleancode.tst.sh`**; the lane re-runs the replay on its own sha and puts both counts in the commit body | either fleet box | claude / simple_coding | 1 |
| 02 | `perf(p16-02-orc-spawn-share-briefs-one-pass)` | `spl_spawn_share_briefs` reads the `Class:` line of every lane's brief with one `grep -m1 -oiHE ... <every brief>` and builds the map with one `jq`, in place of `grep \| sed \| tr` and a `jq` per lane; same map | editor 2.6, the function alone, 41 lanes on the box (40 briefs, 1 missing) and 1 on another box, logging `PATH` stubs: **164 execs** per call (41 each of `grep`, `jq`, `sed`, `tr`); n=1, deterministic. Timed, 20 calls: **9.6, 10.9, 9.7 s** (n=3, load 24-26). Whole test `spl-spawn-queue.tst.sh`: **337.6, 375.7, 337.4 s** wall, user + sys **369.2, 369.8, 366.3 s** (n=3, load 4.7 / 14.5 / 6.5 at start), 272 PASS each (editor 2.6) | editor 2.6: **3 execs** per call (1 `grep`, 2 `jq`), 20 calls **0.36, 0.27, 0.22 s** (same n and load); the same map on the fixture, edge cases included (`cmp` of `jq -S` output). Whole test: **283.6, 265.6 s** wall, user + sys **296.7, 288.7 s** (n=2, load 13.2 / 13.2), 272 PASS each: CPU mean 368.4 -> 292.7 s (**-20.5%**), wall mean 350.2 -> 274.6 s (-21.6%) | `orc/src/bash/run/spl-spawn-share.func.sh:189-197` (`spl_spawn_share_briefs`); `orc/src/bash/tests/spl-spawn-share.tst.sh` (case 14); 2 files | **`spl-spawn-share.tst.sh`** case 14: a fixture of 30 lanes on the box (briefs with `Class: BUG`, a second `Class:` line, `Class: ci.`, `class: Refactor`, `Class: chore`, an empty brief, a missing brief) and 1 lane on another box; logging `PATH` stubs for `grep`, `jq`, `sed`, `tr`: (a) one call execs at most 3 of them; (b) CONTROL the map equals the expected JSON; (c) CONTROL no lane -> `{}`. Red: today's function -> (a) fails, about 4 execs per lane (the lane puts the exact count in the commit body). Also run and green: the whole of **`spl-spawn-share.tst.sh`** (cases 1-13), **`spl-spawn-queue.tst.sh`** (272 PASS on `2fe3729e3`), **`bash-cleancode.tst.sh`**; the lane re-times the whole `spl-spawn-queue.tst.sh`, alternated, n=2 per arm, and puts both arms in the commit body | either fleet box | claude / simple_coding | 1 |

Every row is claude: rulebook R14 (an established vendor) and the owner's
10-17 rule (no mistral coding or testing).

<a id="p16-batches"></a>

<a id="ws-doc-d81f2dcf-0ada-4f75-8ece-e100d29724bc"></a>
### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01 and 02, in parallel; no file in common.
  - Row 01: `changed-tests.sh`, `run-all-tests-changed.tst.sh`,
    `pre-push-gate.md`.
  - Row 02: `spl-spawn-share.func.sh`, `spl-spawn-share.tst.sh`.
- No row file is a file of an unlanded round row or of the parked r35 v0.1
  (3.2).

<a id="p16-r3"></a>

<a id="ws-doc-5fb7b757-ebee-42ae-b66d-281bbcf91b83"></a>
### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-18, each with its time (editor 3):

- **Lane map, every machine** (05:56:58Z, one call): `lane-map.sh --check
  <changed-tests.sh, run-all-tests-changed.tst.sh, spl-spawn-queue.tst.sh,
  this plan, its seat file> --agent c-337` -> exit 4: `0` lines `owned by`,
  `13` lines `unknown:`, all lanes on the second box that record no files
  (two blog drafts, seats and rotations, an ops lane, a box CPU bug). 
  Exit 4 is not free: the R3 check before each spawn re-reads the map and
  asks any lane still unknown.
- **Spawn queue** (05:45:27Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`) -> `1 queued, 0 placing`: the bug round 15 planner
  (ask 1b6bcd45). Holder c-002, msg 4097ad50: its planner c-339 has no
  rows yet, and the holder sent it these candidate files so its plan stays
  off them.
- **Bug round 15 v0.1** (c-339, `8ce0de287`; holder c-002 msg fab96dbe,
  06:0xZ): its 3 rows are clear of every p16 file per c-339; row b15-03
  edits the 4 byte-identical `run.sh` files and `run-log.tst.sh`, which no
  p16 row touches (confirmed to the holder).
- **Parked refactor round 35 v0.1** (`27e21eefc` on
  `review/c002-refactor-round-35-planner`): its files (editor 3) include
  `orc-shard-weights.txt` and `run-eager-files.tst.sh`, none of a p16 row;
  p16 rows leave `orc-shard-weights.txt` alone.
- **v0.2 re-read (row 02), 06:41:05Z to 06:44:04Z**, `origin/master`
  `f529b3091` (no commit since `2fe3729e3` touches a row 02 file:
  `git log --oneline 2fe3729e3..origin/master -- '*spl-spawn-share*'` -> 0):
  - Lane map, `--check spl-spawn-share.func.sh,spl-spawn-place.func.sh,spl-spawn-queue.tst.sh,changed-tests.sh --agent c-337`
    (06:41:05Z) -> exit 4, `0` owned, 12 lanes `unknown:`. The one live lane
    seen running `spl-spawn-queue.tst.sh`, the b15-02 lane, only runs it; its
    brief's files are `spl-spawn-group-put.func.sh`, `spl-spawn-group.tst.sh`
    and spec 135.
  - Spawn queue (06:44:02Z) -> `2 queued, 0 placing`: this round's mistral
    panel seat (ask a4390135) and bug round 15 row 03 (`run.sh` copies,
    `run-log.tst.sh`).
  - Bug round 15 v1.0 is on `origin/master` (`f529b3091`, SPL-5862): its
    rows 01 (`spl-lane-rotate.func.sh`, `lane-rotate.tst.sh`), 02 (above)
    and 03 (above) touch no p16 file, and its section 3 lists the p16
    candidate files as off limits.
  - **Parked refactor round 35 v0.1 row 04 edits `spl-spawn-place.func.sh`**
    (`:206,672`). So row 02 leaves that file: probe B's `| tail -1` site
    (`spl-spawn-place.func.sh:1417`) goes to section 6, and row 02 is
    `spl-spawn-share.func.sh` and its test only. The whole-test timing of row
    02 in editor 2.6 is of that share-only change (arm R).
- **Unlanded round rows**: bug round 14 is served (b14-01 `ce765392c`,
  b14-02 `0a5a8fbb3`); p15-01 `1f32dd66c` is on `origin/master`.

<a id="p16-per-row"></a>

<a id="ws-doc-91d14207-827c-4681-ad80-ea030f757b41"></a>
## 4. Per row: what the lane does

- **01**:
  - The shared names are read once per run of the map (`git ls-files --
    '*.md'`, basenames that occur more than once), not per changed file.
  - A shared doc name keys only by its repo path. A test that reads such a
    doc through a variable path (`"$DIR/spec.md"`) is no longer selected by
    it: the lane lists every (commit, test) pair the replay drops and checks
    with `grep -n` that each test only writes a fixture of that name, and
    puts the count in the commit body. CI and the default mode still run the
    whole suite, so the map only decides what runs before the push.
  - Unique doc names, code files and the `full` fallback do not change:
    the replay's `full` count stays 19.
- **02**:
  - One `jq` lists the box's lane ids (as today), one `grep -m1 -oiHE` reads
    the `Class:` line of all their briefs (`-m1` counts per file), one `jq -R
    -s` turns `<path>:<class>` lines into the map. A missing or empty brief,
    a lane with no `Class:` line and a class outside `ci|refactor|bug|feature`
    give no key, as today; the class is lower-cased, as today.
  - No lane on the box -> `{}` without a `grep`. The output has no trailing
    newline, as today (`jq -j` or `printf '%s'`).
  - `spl-spawn-place.func.sh` is not touched (3.2).


<a id="p16-panel"></a>

<a id="ws-doc-53283b86-cc86-463b-a440-5d9fe528f0f5"></a>
## 5. Panel and reviewers (R7)

Read on 2026-11-18 05:58:23Z (editor 4):

- `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=hold`, grok weekly
  99% on both boxes.
- `BOX_PICK_KIND=agy` -> `pick=<second box>` (46% < 70%); `mistral`,
  `claude` -> `pick=<this box>` (37% < 70%).
- `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder: `c-002` (05:58Z; c-003 06:16Z to 06:20Z, c-003 msgs 4351d224, 9fa1a341; `LEASE_CMD=show` at 06:20:35Z -> `c-002`; c-003 again from 06:46Z, c-003 msg 4f022e60, `LEASE_CMD=show` at 06:47:08Z -> `c-003`; c-002 again from 06:50Z, c-003 msg da50a133, `LEASE_CMD=show` at 06:50:37 -> `c-002`).

- **Plan panel (rulebook 3.2)**: editor c-337 (claude) and **one mistral
  seat** (ask a4390135, queued at 06:44:02Z), as in p12 to p15. The holder
  placed an agy seat (ask e5289f63) and a mistral seat on v0.1, then dropped
  the agy seat: its seat is on its usage limit until 11-24 (holder c-002,
  msg 367a834d; c-001 msg 3d8282c0). The seat signs only a sha this editor
  names, sent to it and the holder (c-002 since 06:50Z).
- **Row reviewers (2.7.2)**: the row authors are claude. Code R7 is the
  holder's pick at placement (grok when it picks; otherwise the waiver seat
  the holder names), never a plan seat. A row never pushes without its R7
  PASS.

<a id="p16-left-out"></a>

<a id="ws-doc-0af7bdca-909c-45fc-9848-d7ab88229650"></a>
## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| `spl_spawn_place_brief`'s `\| tail -1` (`orc/src/bash/run/spl-spawn-place.func.sh:1417`) -> `${c##*$'\n'}` | **not a row in p16 (R1)**: parked refactor round 35 row 04 edits the same file; a later perf round may take it once r35 is served or dropped | the perturbed trace of editor 2.5: `tail` 2,716 times on `:1417` in one run of `spl-spawn-queue.tst.sh` (direction only); one `tail` exec is about 1-2 ms on this box (not timed alone) |
| other `in_orc` tests adopting p15-01's set | **dropped for p16**: after row 01 the five heaviest selected tests use no `in_orc` | editor 2.4: probe replay top five by selections x weight (`wd-situations` 38 x 228, `dispatch-rotate` 45 x 190, `fleet-lease` 27 x 308, `spl-spawn-queue` 32 x 246, `spl-lane-mix` 23 x 324), `in_orc` count 0 in each; `desk-actions.tst.sh` (128 calls) 97 -> 16 selections |
| `all.env.yaml` keys (450 selections) | **not a row**: 9 of 249 commits touched it, and the tests it selects read the real cnf | editor 2.2 |
| the `dirname` calls at load in ~182 orc func files | carried: far over 5 sites | p15 editor 2.4 (not re-measured) |
| `api` full tier remainder, `lint-gosec` | carried: no faster form probed | 7 days: `api` PASS full n=53, mean 3,066 s; `lint-gosec` PASS full n=149, mean 1,075 s (editor 2.1) |
| WUI AC-02 initial download 154.3 of 155 KB gzip | carried: needs a probe on the CI node | p13 section 2, n=1 |
| CI shard rebalance; per-case wait audit; `commit-links`' prd key; `iac-cross`; p5/p6 inputs | carried from p14/p15 section 6 | not re-measured here (no key, no lab) |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p16-counts"></a>

<a id="ws-doc-31982755-5468-41ab-bfb2-e2a2b5e0ba65"></a>
## 7. Counts

- Rows: 2 in v1.0 (rulebook 1.1: at most 10).
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p16-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p16-' --format=%B | grep -c '^review: '` must reach the row count.

<a id="p16-changes"></a>

<a id="ws-doc-76062ddf-9352-453d-8c35-2cc6cc5a9421"></a>
## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 15. From then on the Qto doc is the primary copy.

- v0.1 (c-337, 2026-11-18 06:3xZ): first draft on `2fe3729e3`.
- v0.2 (c-337, 2026-11-18 06:5xZ): row 02 (probe B, share part only;
  counted and timed in editor 2.6); the `tail` site to section 6 (R1 with
  parked r35 row 04); the panel is the mistral seat alone (5).
- v1.0 (c-337, 2026-11-18 07:2xZ): the rows of v0.2 unchanged, after the
  mistral seat's PASS on `8b3fa986c` (9). Holder: c-002 (c-003 held the
  lease 07:15Z to 07:19Z, c-003 msgs 80abf68b, ba7c7410).

<a id="p16-consensus"></a>

<a id="ws-doc-d944c432-7b88-415a-9bb4-bb606827f29c"></a>
## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-337 (editor) | claude | v0.1, v0.2; v1.0 | author; **signs** v1.0 (the rows of `8b3fa986c`, unchanged) |
| m-638 (mistral seat, ask a4390135) | mistral | v0.2 `8b3fa986c` (v0.1 `90e21bfad` also PASS) | **PASS**, W none, N1..N6 (seat `356216b66` on `review/c002-perf-round-16-mistral-seat`, msg 40b3c8fc); signs the landed v1.0 sha |

The seat's notes, for the row lanes:

- N1: its weighted sums for row 01 are ~4,100 s higher in both arms
  (193,437 -> 143,083 s, summing `orc-shard-weights.txt` with its `*`
  default) than editor 2.3 (189,337 -> 139,723 s); the run-line counts match
  exactly (5,342 -> 4,024), -26.0% against -26.2%. The lane states which sum
  it uses.
- N6: on its own box row 02's whole-test gain is smaller: user + sys
  -3.8% to -12.7% (n=2 per arm) against -20.5% here; the exec count
  (162 -> 3 on its fixture) and the identical map reproduce. The row's
  claim is the exec count; the whole-test time is box- and load-bound, and
  the lane re-times both arms on its own sha.

