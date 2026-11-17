# Perf round 14 (p14) - plan (draft v0.2)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5795  
Topic: 9611738e-9cc2-42a8-b9c6-960dddbc5a39  

This is the eighth round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
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

**Status: draft v0.2, not signed.** Editor: c-025 (claude).

**Why now.** The holder's request (c-003@sat, 2839cb8c, 2026-11-17 13:2xZ;
brief by c-001@sat):

- Perf round 13 is served: p13-01 `05791365d`, p13-02 `e3388fce3` are on
  `origin/master`.
- The 4.4 check, re-run here at 13:31:41Z on `f9661ccf0`, printed
  `perf 20 refactor 100 perf-share 16.7% under-20`.

The slug, read at 13:31:41Z on `f9661ccf0`:

- `git log origin/master --oneline -E --grep='\(p14-'` -> 0 lines.
- `git ls-tree -r --name-only origin/master | grep -c perf-round-14` -> 0.

**One sha.** Every row baseline below is measured on **`f9661ccf0`**
(`origin/master` at 13:31Z, 2026-11-17), on the desk box (16 cpus, 1-minute
load 17..33 while measuring). Raw commands and outputs:
[perf-round-14/editor.md](perf-round-14/editor.md).

**Retro.** There is no `perf-round-13-retro.md` on `origin/master`
(`git ls-tree -r --name-only origin/master | grep -E 'perf-round-1[23]'` ->
the two plans and the two `editor.md` files only). This plan does not stand in
for it and does not guess its content. It reads `perf-round-13-plan.md` (its
section 6 first), `perf-round-13/editor.md`, `perf-round-12-plan.md`,
`perf-round-5-retro.md` and `lesson-speed-up-measure-first.md`.

<a id="p14-how-to-read"></a>

## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p14-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p14-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `f9661ccf0`.
- **After** = what the change leaves of that number, and how it is known.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `wui/` = `csi-spl-wui/`.
- **Where the rows come from.** The desk box pre-push log since p12-01
  (editor 2.1): the parts' own seconds, ranked by their sum. `api` on the full
  tier is the largest (n=9, 29,430 s); the `wui` part, unit tests then
  typecheck, is next among the parts every WUI push runs (n=21 fast + full,
  13,596 s).

<a id="p14-inputs"></a>

## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`f9661ccf0`:

| input | finding | on the tree | here |
|---|---|---|---|
| `perf-round-13-plan.md` section 6: `api` on the full tier, 2,355..3,419 s per push, "input for round 14" | not probed in p13 (no container) | log since p12-01 (editor 2.1): `api PASS tier=full` n=9, 2,649..3,804 s, mean 3,270 s. Probe on `f9661ccf0` in flight (editor 2.3); the cached `postgres:16-alpine` image serves it, nothing pulled | **row 02** |
| new, this seat: the WUI unit runner | 524 unit files run one `node` at a time (`run-unit-tests.mjs:70-84`) | probe, n=2 per arm (editor 2.2): serial 565.6 and 546.7 s; 4 at a time 126.9 and 120.3 s, all 524 green in each | **row 01** |
| `perf-round-13-plan.md` section 6: WUI AC-02 initial download 154.3 of 155 KB gzip (c-873) | headroom under a ceiling | not re-measured: no trim to probe, and a probe needs a `nuxt generate` on the CI node version | section 6, carried |
| `perf-round-13-plan.md` section 6: CI shard rebalance; per-case wait audit; `commit-links`' prd key; `iac-cross`; a-827's 3 and 5; `fsync=off`; p5 inputs; p6-08/09 | carried | not re-measured here (no key, no lab) except as the api probe touches the test Postgres | section 6, carried |
| `perf-round-13/editor.md` | p13's measurements | read; its numbers are on `9310612f3` and not reused | - |
| `perf-round-12-plan.md`, `perf-round-5-retro.md` | read through p13 section 6 | - | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: the log first (editor 2.1), then the code path, then an alternated probe (editor 2.2) | - |

<a id="p14-rows"></a>

## 3. The rows

| # | id | practice | baseline on `f9661ccf0` (command, number, n) | after | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p14-01-wui-unit-pool)` | the WUI unit runner runs its test files N at a time (a pool of `spawn`, not `spawnSync`), default `min(4, cpus)`, `WUI_UNIT_JOBS=<n>` overrides, `1` = today's serial loop. Each file's output is buffered and printed whole, in the sorted order, with its `──[i/n] file` header, so the log reads as today; the exit code, the failure list and `FAIL_FAST` keep their meaning | editor 2.2, probe on a clone of `f9661ccf0`: `node src/node/test/run-unit-tests.mjs` (today) -> **565.6 s and 546.7 s, n=2**, 524 files green. Pre-push log since p12-01: `wui` PASS fast n=14 mean 650 s, full n=7 mean 640 s (unit + typecheck); CI wf 10 "Unit tests" 124..168 s, n=5 | the same files 4 at a time (`xargs -P 4`) -> **126.9 s and 120.3 s, n=2**, alternated with the serial arm, 524 green each. Suggested: ~420..440 s off every `wui` part run on the desk box; the CI step gains too, not probed there | `wui/src/node/test/run-unit-tests.mjs:1-21` (the header: the pool, `WUI_UNIT_JOBS`), `:68-84` (the loop becomes the pool), `:86-94` (the summary reads the collected results); 3 edit ranges in 1 file | a new **`wui/tests/unit/unit-runner-pool.test.mjs`**: the runner pointed at a temp dir of 4 stub files (`UNIT_DIR` from an env var, a new 4th edit range at `:29`) that each record their start and end time and wait for a file event the next one writes; asserts the peak number of stub files running at once is **4** with `WUI_UNIT_JOBS=4` and **1** with `WUI_UNIT_JOBS=1`, the output is in sorted order with each header, and one failing stub still exits 1 naming it. Red: today's runner -> peak **1** with `WUI_UNIT_JOBS=4`. Also run and green: **`unit-runner-coverage.test.mjs`** (it reads the runner's source), `pnpm run test:unit` twice in full (both green, its seconds in the commit body), `cleancode.test.mjs` | either fleet box | claude / simple_coding | 1 |
| 02 | `perf(p14-02-api-pg-groups-pool)` | `hub-pg.tst.sh` runs the store groups and the hub groups side by side, up to a cap, instead of one after another within each chain. Since SPL-5654 (`543aca847`) every group has its own freshly migrated database, so the one-at-a-time order no longer protects anything; the database setup stays one at a time (the `db_lock` flock, `:215`). One cap over both lists, `HUB_PG_GROUP_JOBS=<n>`; today runs at most 2 at once (one per chain); the lane picks the default from its own timing (below) | editor 2.3, `SPL_API_TEST_TIER=full bash csi-spl-api/src/bash/tests/run-all-tests.sh` on a clone of `f9661ccf0`, n=1: the whole run **2,754 s**, of it the hub Postgres gate **1,830 s** (13:55:13..14:25:43Z), of that the package suites **~1,632 s**: store chain 568+316+156+217 = 1,257 s, hub chain 551+369+384+267 = 1,571 s, side by side. Pre-push log since p12-01: `api` PASS full n=9, mean 3,270 s | editor 2.4, the same gate with every group started at once (a scratch copy `hub-pg-par.tst.sh`, uncapped), n=1, standalone: the package suites **967 s**, the whole gate **1,189 s**, all green, RC 0. Suggested: ~640 s off every full-tier `api` run. Each group got slower under the contention (store a 568 -> 922 s, hub b 369 -> 851 s; the per-group timeout is 20 min), hence the cap. The CI `hub-pg` job (wf 10) runs the same script; not probed there | `csi-spl-api/src/bash/tests/hub-pg.tst.sh:227-238` (`store_groups`), `:239-250` (`hub_groups`): each becomes a pool under one shared cap; `:251-268` (the launch and wait, so the two chains share the cap); `:270` (the "sequential groups" wording); 4 edit ranges in 1 file | a new **`csi-spl-api/src/bash/tests/hub-pg-pool.tst.sh`**, no Postgres: it sources the pool function from `hub-pg.tst.sh` (or a new `hub-pg-pool.inc.sh`, the lane's pick) with `group_db` and `pg_go_test` stubbed to record start and end and to wait for the next stub's start; asserts the peak number of groups running at once is the cap (**3** with `HUB_PG_GROUP_JOBS=3`) and **1** with `HUB_PG_GROUP_JOBS=1`, that every group of both lists runs exactly once, and that one red stub still fails the gate and names its group. Red: today's script -> peak **2** with `HUB_PG_GROUP_JOBS=3`. Also run and green: `hub-pg-groups.tst.sh`, `store-pg-groups.tst.sh`, and `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (the real gate on Postgres) twice | either fleet box | claude / simple_coding | 1 |

Every row is claude: rulebook R14 (an established vendor) and the owner's
10-17 rule (no mistral coding or testing).

<a id="p14-batches"></a>

### 3.1 Batches and disjoint files (R1)

- **Batch 1**: row 01. Files: `run-unit-tests.mjs`,
  `unit-runner-pool.test.mjs` (new), and `unit-runner-coverage.test.mjs` only
  if its source reading needs the new form.
- **Batch 1**: row 02. Files: `csi-spl-api/src/bash/tests/hub-pg.tst.sh`,
  `hub-pg-pool.tst.sh` (new), `hub-pg-pool.inc.sh` (new, if the lane splits the
  pool out), and `csi-spl-api/src/bash/tests/run-all-tests.sh` only to list the
  new test. Rows 01 and 02 share no file: both are batch 1.
- No row file is a file of an unlanded round row (3.2).

<a id="p14-r3"></a>

### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-17, each with its time (editor 3):

- **Lane map, every machine** (13:40:11Z, one call): `lane-map.sh --check
  <run-all-tests.sh, hub-pg.tst.sh, run-unit-tests.mjs, check-pre-push.func.sh,
  pre-push-gate.md, this plan, its seat file> --agent c-025` -> exit 4: `0`
  lines `owned by`, `13` lines `unknown:`, all lanes on the second box that
  record no files (8 rotation seats; 5 lanes whose slugs name two blog drafts,
  a price, cost allocation and release projects). None names a test runner.
  Exit 4 is not free: the R3 check before each spawn re-reads the map and asks
  any lane still unknown.
- **Spawn queue** (13:40:18Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`) -> `2 queued, 1 placing`: b11-02 (orc review-go) and
  two agy i18n reviews (SPL-5706, SPL-5707). None names a WUI test runner.
- **Re-read for v0.2** (14:27:57Z, lane map; 14:28:08Z, queue):
  `lane-map.sh --check <hub-pg.tst.sh, hub-pg-groups.inc.sh,
  hub-pg-groups.tst.sh, store-pg-groups.tst.sh, run-unit-tests.mjs> --agent
  c-025` -> exit 4: `0` owners, `14` `unknown:` on the second box (rotation
  seats, two blog drafts, a price, cost allocation, a tf log mask, and b11-02,
  which has since landed as `770de68f4`). Queue: `3 queued, 0 placing`: an
  invoice-PDF importer, spec 143 row B-6 (sync and box push per repo) and the
  SPL-5707 agy review; none names a test runner.
  `git log --oneline f9661ccf0..origin/master -- csi-spl-api/src/bash/tests/
  csi-spl-wui/src/node/test/run-unit-tests.mjs` -> 0 lines (origin/master
  `770de68f4`).
- **Unlanded round rows** (13:4xZ, on `f9661ccf0`): r59-01..06 all on
  `origin/master`; `git log origin/master --format=%s -E
  --grep='\(<r>-[0-9]{2}-'` -> r60, r61, r62, r63 0 lines. Bug round 11:
  b11-01 landed, b11-02 placing; `bug-round-11-plan.md` names none of the row
  files (`grep -c` -> 0).

<a id="p14-per-row"></a>

## 4. Per row: what the lane does

- **01**:
  - Keep discovery, the filter, `--list` and `FAIL_FAST` as they are. The
    pool starts the next file when one ends; with `FAIL_FAST=1` it starts no
    new file after the first failure and reports the files already running.
  - Print each file's buffered output (stdout and stderr, as `stdio:
    'inherit'` interleaved them today) when its turn in the sorted order
    comes, so a reader sees the same log as the serial run.
  - The default jobs: `min(4, os.availableParallelism())`; the lane states
    whether CI's hosted runner reports 4 and re-times the CI step on its own
    push (the CI "Unit tests" seconds before and after, n>=1 each, named run
    ids).
  - A file that cannot run beside others (a fixed path, `$HOME` state) must
    not exist: the editor's grep found none (editor 2.2), and the lane runs
    `pnpm run test:unit` twice in full with the pool, both green. If one shows
    up, the lane says so and makes that file use `mkdtemp`, or adds a
    `// serial` marker read the way `csi-spl-orc/src/bash/tests/run-all-tests.sh`
    reads `# serial`, and names it in the commit body.
  - The lane re-times the runner on one named sha, serial (`WUI_UNIT_JOBS=1`)
    and pooled, n>=2 each, alternated, load at start, and puts it in the
    commit body.

- **02**:
  - Keep the group lists (`hub-pg-groups.inc.sh`, `store-pg-groups.inc.sh`),
    each group's own database, the `db_lock` around the database setup, the
    per-group `ok`/`FAIL` lines with their seconds, and "a red group does not
    stop the next".
  - One cap over both lists, so the store and hub groups share it. The
    lane times the gate on one named sha with today's script and with
    at least two caps (e.g. 4 and 8), n>=2 each, alternated, load at start,
    and puts it in the commit body; the default is the fastest cap whose
    slowest group stays under half the 20 min `SPOOL_TEST_GO_TIMEOUT`.
  - The editor's probe (editor 2.4) ran uncapped, standalone, n=1: it shows
    the gain exists, not the best cap.
  - The lane names the CI `hub-pg` job's seconds before and after (named run
    ids, n>=1 each) and says whether the hosted runner's cpus change the
    default.

<a id="p14-panel"></a>

## 5. Panel and reviewers (R7)

Read on 2026-11-17 13:40:50Z (editor 4):

- `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=hold`, grok weekly
  99% on both boxes.
- `BOX_PICK_KIND=agy` -> `pick=nokind` (no agy CLI on either box); agy on the
  second box is at its quota limit until 2026-11-20T23:04:20Z (the spawn
  queue's WAIT lines).
- `BOX_PICK_KIND=mistral` -> `pick=hold` on load only; `ENV=prd ./run -a
  do_spl_hub_agent_kinds` -> `off [qwen], paused []`.

So the vendors that can sit now are claude and mistral.

- **Plan panel (rulebook 3.2)**: editor c-025 (claude) and one **mistral**
  seat. I asked the dispatch holder (c-002@sat, msg ade5d260, 13:41:47Z);
  c-002 ruled (msg 31c1b060) that owner ruling e895dea6 (p12 poll 8ede28e3,
  C: claude + mistral sign, no agy; carried to p13 by c-001 cbada223) holds
  for p14 while grok holds on both boxes and agy is at its limit. Seat: ask
  8aaab744, placed as **m-031@sat** (c-003@sat msg c8cd065b), seat file
  `perf-round-14/seat-mistral.md`, branch
  `review/c002-perf-round-14-mistral-seat`. The seat signs only a sha this
  editor names.
- **Row reviewers (2.7.2)**: every row's author is claude. Code R7 while grok
  holds on both boxes is a claude waiver seat
  (`claude:<slug>-claude-waiver-reviewer`, c-001 re-ruling 5fb1bdab), never
  the mistral plan seat (c-001 b71016ad); the holder names it in each row
  brief. It lapses on the first grok pick on either box. A row never pushes
  without its R7 PASS.

<a id="p14-left-out"></a>

## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| `api` full tier, the rest after row 02: plain `go test -race ./...` | **not a row**: one `go test` over every package, already parallel inside Go; no change to probe | editor 2.3, n=1: 485 s of the 2,754 s run |
| `api` full tier: the build tests (`build-stripped`, `build-warm-mod-cache`, `cli-cross-build`) | **not a row**: no probe of a faster form in this round | editor 2.3, n=1: 210 s |
| the `orc` part on the fast tier (n=25, mean 366 s) | **not a row**: no single piece stands out that this seat could time | its always-run pieces on `f9661ccf0`: `bash-cleancode.tst.sh` 1.4 and 1.2 s, `require-cloud-env.tst.sh` 0.2 s, `run-eager-files.tst.sh` 2.2 s (n=2, n=1, n=1); the rest is the changed files, which differ per push |
| WUI AC-02 initial download 154.3 of 155 KB gzip (c-873) | **not a row**: headroom under a ceiling is not a measured wait, and no trim was probed | CI `b4b9c4f1b`, n=1 (p13 section 2). Input for a later round, with a probe on the CI node |
| `lint-gosec` after p13-02 | **not here**: the p13 retro measures its row | since `e3388fce3`: n=3, 1,007 (the row's own push), 767, 536 s |
| rebalancing CI wf 10 shards; per-case wait audit | dropped in p12, not re-measured | p12 editor 2.4 |
| `commit-links`' prd key lookup; `iac-cross`; a-827's 3 and 5; p5 inputs 1 and 3; p6-08/09 | not here: a key, a lab or a built bundle | carried from p13 |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p14-counts"></a>

## 7. Counts

- Rows: 2 in v0.2 (rulebook 1.1: at most 10).
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p14-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p14-' --format=%B | grep -c '^review: '` must reach the row count.

<a id="p14-changes"></a>

## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 13. From then on the Qto doc is the primary copy.

- v0.1 (c-025, 2026-11-17 14:2xZ): first draft on `f9661ccf0`, row 01; the
  api probe in flight.
- v0.2 (c-025, 2026-11-17 14:5xZ): the api probe ended (editor 2.3); row 02,
  the hub-pg groups side by side under a cap, from an uncapped probe arm
  (editor 2.4); R3 re-read at 14:27Z; rebased on `770de68f4`.

<a id="p14-consensus"></a>

## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-025 (editor) | claude | v0.2 | author |
| m-031 (mistral seat, ask 8aaab744) | mistral | - | waits for a named sha |
