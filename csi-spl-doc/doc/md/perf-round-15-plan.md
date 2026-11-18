# Perf round 15 (p15) - plan (1 row, v1.0)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5835  
Topic: 99becb6c-4a5a-462c-adb3-f781b0204b18  

This is the ninth round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
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

**Status: v1.0, signed** (claude c-454 author, mistral m-245 PASS on `e4c176fb4`). Editor: c-454 (claude).

**Why now.** The holder's request (c-003@sat, 476a073a, 2026-11-17 22:2xZ;
ruling c-001 237a4e95):

- Perf round 14 is served: p14-01 `70eef695e`, p14-02 `f62d610cb` are on
  `origin/master`.
- The 4.4 check on `f96f597b1` (the brief, n=1) printed
  `perf 22 refactor 102 perf-share 17.7% under-20`.

The slug, read at 23:47Z on `1961ca57f`:

- `git log origin/master --oneline -E --grep='\(p1[45]-'` -> the two p14 rows
  and the p14 plan commits; no `p15-` line.

**One sha.** Every row baseline below is measured on **`1961ca57f`**
(`origin/master` at 23:47Z, 2026-11-17), on the desk box (16 cpus; the
1-minute load is named next to each number, it ran 11..70 during this seat).
Raw commands and outputs: [perf-round-15/editor.md](perf-round-15/editor.md).

**Retro.** There is no `perf-round-14-retro.md` on `origin/master` (only
`perf-round-14-plan.md` and `perf-round-14/editor.md`). This plan does not
stand in for it and does not guess its content. It reads
`perf-round-14-plan.md` (its section 6 first), `perf-round-14/editor.md`,
`perf-round-13-plan.md` and `lesson-speed-up-measure-first.md`.

<a id="p15-how-to-read"></a>

## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p15-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p15-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `1961ca57f`.
- **After** = what the change leaves of that number, and how it is known.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `orc/` = `csi-spl-orc/`.
- **Where the rows come from.** The desk box pre-push log, 7 days (editor
  2.1): the parts' own seconds, ranked by their sum. `orc` PASS on the fast
  tier is the largest (n=240, 71,230 s). The fast tier runs the orc tests that
  name a touched file; a replay of the last 7 days' orc commits through
  `changed-tests.sh` (editor 2.2) ranks which tests it runs most.

<a id="p15-inputs"></a>

## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`1961ca57f`:

| input | finding | on the tree | here |
|---|---|---|---|
| new, this seat: the fast-tier `orc` part | the largest summed part of the desk pre-push log, 7 days | `orc` PASS fast n=240, 71,230 s, mean 296 s; FAIL fast n=23, 53,289 s (editor 2.1). Replay (editor 2.2): `spl-spawn-queue.tst.sh` selected by 104 of 226 commits, `spl-lane-issue.tst.sh` by 99 | the two top tests timed and traced (editor 2.3, 2.4) |
| new, this seat: `in_orc` in `test-lib.inc.sh` | each call sources all 712 orc func files in a fresh bash | one full source: 46 execve (39 `dirname`), 931..2,080 ms wall, n=10, load 60 (editor 2.4). `spl-lane-issue.tst.sh`: 14,379 successful execve, 6,396 of them `dirname` (n=1 trace) | **row 01** |
| new, this seat: `spl-spawn-queue.tst.sh` | the top fast-tier test by selections x weight (104 x 246 s) | 228.8 s wall, load 15.5, n=1; 66,106 execve, `jq` 12,738 (n=1 trace). It does not use `in_orc`; its `jq` calls are spread over 161 lines of the test and its hub stub | section 6 |
| `perf-round-14-plan.md` section 6: `api` full tier remainder (`go test -race ./...` 485 s, build tests 210 s, n=1) | carried | not re-probed: no faster form to time | section 6, carried |
| `perf-round-14-plan.md` section 6: the `orc` fast-tier part (n=25, mean 366 s) | "no single piece stands out" | re-read here over 7 days and replayed per test (editor 2.1, 2.2): the piece is the `in_orc` source | row 01 |
| `perf-round-14-plan.md` section 6: WUI AC-02 154.3 of 155 KB gzip | headroom under a ceiling | not re-measured: needs a `nuxt generate` on the CI node version | section 6, carried |
| `perf-round-14-plan.md` section 6: `lint-gosec` after p13-02 | the p13 retro measures it | 7 days: `lint-gosec` PASS full n=91, 59,539 s, mean 654 s (editor 2.1); no probe of a faster form here | section 6, carried |
| `perf-round-14/editor.md` | p14's measurements | read; its numbers are on `f9661ccf0` and not reused | - |
| `perf-round-13-plan.md` | read through p14 section 6 | - | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: the log first (editor 2.1), the replay (2.2), the trace and count (2.4), then the probe (2.5) | - |

<a id="p15-rows"></a>

## 3. The rows

| # | id | practice | baseline on `1961ca57f` (command, number, n) | after | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p15-01-in-orc-run-set)` | `in_orc` sources every `lib/bash/funcs/*.func.sh` and, when the test sets `IN_ORC_RUN="<run file stems>"`, only those `src/bash/run/<stem>.func.sh` files; unset, it sources all as today, so the 266 other `in_orc` tests do not change. `spl-lane-issue.tst.sh` sets it once, to the 8 run files whose functions its code under test calls | editor 2.4, `strace -f -e trace=execve bash spl-lane-issue.tst.sh` on a clone of `1961ca57f` -> **14,379** successful execve, `dirname` **6,396**, n=1, rc 0, 174 PASS. Wall: `time bash spl-lane-issue.tst.sh` -> **142.0 s** (82.9 user, 60.3 sys), load 11.0, n=1 | editor 2.5, the same run with the scratch `in_orc` and `IN_ORC_RUN` = the 8 files -> **8,917** successful execve, `dirname` **1,181**, n=1, rc 0, 174 PASS, 0 FAIL. CPU (user + sys), alternated S, L, S, L, n=2 per arm (editor 2.5): today **203.4 and 232.0 s**, with the set **48.2 and 50.3 s**, each L arm under a higher load than the S arm before it; 174 PASS in all four. Suggested: the fast tier runs this test on ~99 of 226 orc commits a week | `orc/src/bash/tests/test-lib.inc.sh:62-72` (`in_orc` and its comment); `orc/src/bash/tests/spl-lane-issue.tst.sh:20` (one `IN_ORC_RUN=...` line after the `source`); a new `orc/src/bash/tests/in-orc-run-set.tst.sh`; `orc/src/bash/tests/orc-shard-weights.txt` (its weight line, if the lane gives one); 4 files | the new **`in-orc-run-set.tst.sh`**: a `dirname` stub that logs each call put first on `PATH` (as `in_orc`'s own stubs are); asserts (a) with `IN_ORC_RUN=spl-lane-issue`, `declare -F do_spl_lane_issue` is set and a function of another run file (e.g. `do_spl_spawn_queue`) is not; (b) unset, both are set; (c) the stub's call count per `in_orc` is smaller with the set than without. Red: today's `test-lib.inc.sh` -> (a) fails, `do_spl_spawn_queue` is defined. Also run and green: **`spl-lane-issue.tst.sh`** (174 PASS, its seconds before and after, n>=2 each, alternated, load at start), `orc-jobs-derivation.tst.sh`, **`bash-cleancode.tst.sh`**, and every orc test that sources `test-lib.inc.sh` and calls `in_orc` once in full (`git grep -l in_orc -- csi-spl-orc/src/bash/tests`), unchanged because it leaves `IN_ORC_RUN` unset | either fleet box | claude / simple_coding | 1 |

Every row is claude: rulebook R14 (an established vendor) and the owner's
10-17 rule (no mistral coding or testing).

<a id="p15-batches"></a>

### 3.1 Batches and disjoint files (R1)

- **Batch 1**: row 01. Files: `test-lib.inc.sh`, `spl-lane-issue.tst.sh`,
  `in-orc-run-set.tst.sh` (new), `orc-shard-weights.txt`.
- No row file is a file of an unlanded round row (3.2).

<a id="p15-r3"></a>

### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-18, each with its time (editor 3):

- **Lane map, every machine** (00:49:45Z, one call): `lane-map.sh --check
  <test-lib.inc.sh, spl-lane-issue.tst.sh, in-orc-run-set.tst.sh, this plan,
  its seat file> --agent c-454` -> exit 4: `0` lines `owned by`, `7` lines
  `unknown:`, all lanes on the second box that record no files (c-044 s143 b6
  api/orc sync, c-137 nuxt4 migration, c-176 invitee label, c-197 and c-762
  rotation seats, c-233 a box-update bug, m-235 the bug round 13 mistral
  panel seat). Exit 4 is not free: the R3 check before the spawn re-reads the
  map and asks any lane still unknown.
- **Spawn queue** (00:49:54Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`) -> `2 queued, 0 placing`: the SPL-5830 agy language
  review and SPL-5836 W1 (kind picker keys). None names an orc test file.
- **Parked refactor round 35 v0.1** (`27e21eefc` on
  `review/c002-refactor-round-35-planner`): its rows write orc `run/` files
  and `no-literal-paths.baseline`; `git show 27e21eefc:csi-spl-doc/doc/md/refactor-round-35-plan.md
  | grep -cE 'test-lib.inc.sh|spl-lane-issue'` -> 0.
- **Unlanded round rows**: refactor round 34 (r60) is served (all 6 rows on
  `origin/master`, the brief); the p14 rows are on `origin/master`.

<a id="p15-per-row"></a>

## 4. Per row: what the lane does

- **01**:
  - The set is opt-in. Unset or empty `IN_ORC_RUN` = today's loop, byte for
    byte in effect, so no other test moves.
  - A stem with no `src/bash/run/<stem>.func.sh` fails loudly (`in_orc`
    prints the stem and returns non-zero), never skipped: a typo must not turn
    into a test that passes on a missing function.
  - The 8 stems the editor's probe used: `spl-desk-live-proof spl-desk-reply
    spl-desk-up spl-done-claim-check spl-issue-update spl-lane-issue-applied
    spl-lane-issue spl-spawn-share`. The lane re-derives the list from the
    functions `spl-lane-issue.func.sh` calls and says how in the commit body.
    `spl-lane-issue.func.sh`'s three `declare -F <f> || source <file>` guards
    (`:254`, `:642`, `:693`) already source their file when the function is
    missing, so the narrower set does not take a branch away.
  - The lane re-times `spl-lane-issue.tst.sh` on one named sha, today's and
    with the set, n>=2 each, alternated, the load at start, user and sys
    seconds as well as wall, and puts it in the commit body. On this box
    the wall seconds swing with the load (editor 2.5); the execve count does
    not, so the commit body carries both.
  - Other `in_orc` tests adopt the set in later rows, each with its own
    measurement; this row changes only `spl-lane-issue.tst.sh`.

<a id="p15-panel"></a>

## 5. Panel and reviewers (R7)

Read on 2026-11-18 00:49:54Z (editor 4):

- `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=hold`, grok weekly
  99% on both boxes.
- `BOX_PICK_KIND=agy`, `mistral`, `claude` -> `pick=hold`, each on box load
  only ("no box with a sample is below its overflow mark").
- `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder: `c-003@sat`.

- **Plan panel (rulebook 3.2)**: editor c-454 (claude) and one **mistral**
  seat, under owner ruling e895dea6 (claude + mistral sign, no agy), as for
  p13 and p14. Holder c-002@sat (msg 169c9d51, correcting 24474737):
  agy is not at a quota (an agy review ran at ~00:05Z); `BOX_PICK_KIND=agy
  do_spl_box_pick` -> `pick=hold`, no box below its overflow mark (346% on
  one), so agy cannot place now; grok holds. Seat: ask 6eaf2fde, placed as **m-245@sat** (c-002 msg 7aa321bc),
  seat file `perf-round-15/seat-mistral.md`, branch
  `review/c002-perf-round-15-mistral-seat`. The seat signs only a sha this
  editor names.
- **Row reviewers (2.7.2)**: the row's author is claude. Code R7 is the
  holder's pick at placement (grok when it picks; otherwise the waiver seat
  the holder names), never the plan seat. A row never pushes without its R7
  PASS.

<a id="p15-left-out"></a>

## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| `spl-spawn-queue.tst.sh` (selected by 104 commits in 7 days, CI weight 246 s) | **not a row yet**: the `jq` cost is spread over 161 lines of the test and its hub stub; no single change to probe in this seat | 228.8 s wall (160.8 user, 80.0 sys), load 15.5, n=1, rc 0, 272 PASS; 66,106 execve (56,626 successful): `jq` 12,738, `grep` 8,080, `sed` 7,380, `dirname` 5,238, n=1 trace (editor 2.3, 2.4). Input for p16 with a probe |
| other `in_orc` tests adopting row 01's set | **not this round**: each needs its own list and measurement | 266 orc tests use `in_orc` (`git grep -l in_orc -- csi-spl-orc/src/bash/tests`) |
| the `dirname` calls at load in the 182 orc func files (`$(dirname "${BASH_SOURCE...}")`) | **not a row**: a parameter expansion in place of the fork would touch ~182 files, far over 5 sites; row 01 avoids most of them for its test | one full source: 39 `dirname` of 46 execve (editor 2.4) |
| `api` full tier remainder: `go test -race ./...`, the build tests | carried from p14: no faster form probed | p14 editor 2.3, n=1: 485 s and 210 s |
| `lint-gosec` | **not here**: no faster form probed | 7 days: PASS full n=91, mean 654 s (editor 2.1) |
| WUI AC-02 initial download 154.3 of 155 KB gzip | carried: needs a probe on the CI node | p13 section 2, n=1 |
| CI shard rebalance; per-case wait audit; `commit-links`' prd key; `iac-cross`; p5/p6 inputs | carried from p14 section 6 | not re-measured here (no key, no lab) |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p15-counts"></a>

## 7. Counts

- Rows: 1 in v1.0, unchanged from v0.1 (rulebook 1.1: at most 10).
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p15-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p15-' --format=%B | grep -c '^review: '` must reach the row count.

<a id="p15-changes"></a>

## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 14. From then on the Qto doc is the primary copy.

- v0.1 (c-454, 2026-11-18 00:5xZ, `1c82cbccc`): first draft on `1961ca57f`,
  row 01.
- v0.2 (c-454, 2026-11-18 01:0xZ): row 01's after column carries the CPU
  series, n=2 per arm (editor 2.5); section 5 names the seat m-245; rows
  unchanged.
- v0.2.1 (c-454, 2026-11-18 01:1xZ): section 5 drops the agy quota line
  (holder c-002 msg 169c9d51: agy holds on box load, not a quota); rows
  unchanged.
- v1.0 (c-454, 2026-11-18 01:2xZ): mistral m-245 PASS on v0.2.1 `e4c176fb4`
  (msg 91c1bc58, seat `26f9fddda`), W none; rows unchanged. Noted, nothing to
  fold into a row: N1, `git grep -l in_orc` prints 267, which counts
  `test-lib.inc.sh` itself, so "266 tests" stands. N2..N4, the seat re-ran the
  baseline arm on a clone of `1961ca57f` with logging `PATH` stubs (no
  strace on its box), n=3: `dirname` **6,396** each, 174 PASS, rc 0; `sed`
  1,255, `tail` 585, `id` 412 match, `grep` 1,153 against 1,148; wall 219.4,
  219.4, 276.3 s at load 29.6, 12.6, 18.3. N5, the seat's lane map read 15
  `unknown:` lanes on the second box, exit 4: the R3 re-read before the spawn
  stands. N6, the dispatch lease holder is now c-002@sat (read 01:27Z). N7, the
  after arm is this editor's probe, not re-run by the seat; the row lane
  re-times both arms (section 4). Only the status, the counts line, this line
  and section 9 change.

<a id="p15-consensus"></a>

## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-454 (editor) | claude | v0.1, v0.2, v0.2.1; v1.0 | author; **signs** v1.0 (the rows of `e4c176fb4`, unchanged) |
| m-245 (mistral seat, ask 6eaf2fde) | mistral | v0.2.1 `e4c176fb4` | **PASS**, W none, N1..N7 (seat `26f9fddda`, msg 91c1bc58) |
