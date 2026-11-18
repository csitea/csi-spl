# Perf round 15: editor seat (c-454, claude)

Issue SPL-5835, epic SPL-2402, spec `csi-spl-doc/specs/027-spool-performance`,
round topic `99becb6c`; report to the dispatch lease holder on task
`dispatch-perf-r15`. The plan, when drafted: `perf-round-15-plan.md`.

## 1. Done

- STEP 0: developer guide acked (blob `8b1916cd`), fetched.
- One sha for every baseline: **`1961ca57f`** (`origin/master` at 23:47Z,
  2026-11-17).
- Slug: `git log origin/master --oneline -E --grep='\(p1[45]-'` -> the two
  p14 rows (`70eef695e`, `f62d610cb`) and the p14 plan commits; no `p15-`.
- Retro: there is no `perf-round-14-retro.md` on the tree (only
  `perf-round-14-plan.md` and `perf-round-14/editor.md`). This seat does not
  invent its content.
- Phase: `do_spl_rhythm_phase` -> `night` (23:5xZ): plan only.

## 2. Measurements

### 2.1 The desk box pre-push log, 7 days

Parts with a verdict that ran (no SKIP, no cached), since 2026-11-11T00:00Z,
the push user's `~/.cache/csi-spl/pre-push.log`, ranked by summed seconds (top):

| part verdict tier | n | sum s | mean s |
|---|---|---|---|
| `orc` PASS fast | 240 | 71,230 | 296 |
| `api` PASS full | 35 | 65,122 | 1,860 |
| `lint-gosec` PASS full | 91 | 59,539 | 654 |
| `orc` FAIL fast | 23 | 53,289 | 2,316 |
| `wui` PASS fast | 134 | 52,466 | 391 |
| `wui-e2e` PASS fast | 95 | 47,880 | 504 |

`orc` on the fast tier is the largest sum: the orc tests that name a touched
file, run 4 at a time (`run-all-tests.sh --changed`).

### 2.2 Which orc tests the fast tier runs most (replay of the map)

Every `origin/master` commit of the last 7 days touching `csi-spl-orc/`
(248 commits) replayed through
`ORC_TEST_FILES=<its files> ORC_TEST_ALWAYS= bash csi-spl-orc/src/bash/tests/changed-tests.sh`:
4,930 `run` lines over 226 commits, 19 `full`. Selections x CI weight
(`orc-shard-weights.txt`), top:

| test | selected by n commits | CI weight s | n x weight |
|---|---|---|---|
| `spl-spawn-queue.tst.sh` | 104 | 246 | 25,584 |
| `spl-lane-issue.tst.sh` | 99 | 130 | 12,870 |
| `dispatch-rotate.tst.sh` | 44 | 190 | 8,360 |
| `fleet-lease.tst.sh` | 27 | 308 | 8,316 |
| `wd-situations.tst.sh` | 36 | 228 | 8,208 |

### 2.3 The two top tests timed on `1961ca57f`

A `git clone --shared` at `1961ca57f` under the push user's `/var/tmp`, run
alone, as the push user:

| test | wall s | user s | sys s | load at start | result |
|---|---|---|---|---|---|
| `spl-spawn-queue.tst.sh` | 228.8 | 160.8 | 80.0 | 15.53 | rc 0, 272 PASS |
| `spl-lane-issue.tst.sh` | 142.0 | 82.9 | 60.3 | 11.01 | rc 0, 174 PASS |

n=1 each. The sys share (35%, 42%) points at process starts.

### 2.4 The trace and the count (lesson rule 2)

`strace -f -e trace=execve` of one run each:

- `spl-lane-issue.tst.sh` (rc 0): 13,425 execve; of the successful ones
  `dirname` **6,396**, `sed` 1,255, `grep` 1,148, `tail` 585, `id` 412.
- `spl-spawn-queue.tst.sh`: the trace was still running at 00:33Z (60,088
  execve so far: `jq` 11,464, `grep` 7,416, `sed` 6,791, `dirname` 4,774).

The `dirname` calls: the test's `in_orc` (`test-lib.inc.sh:64-72`) sources
**every** orc func file per call (712 files: `lib/bash/funcs/*.func.sh` and
`src/bash/run/*.func.sh`); 182 of them run `$(dirname "${BASH_SOURCE...")`
at load. One full source, timed alone: 46 execve (39 `dirname`); wall
931..2,080 ms, n=10 (sorted: 931 1092 1144 1222 1305 1419 1421 1547 2069
2080), 1-minute load 60.4. `spl-lane-issue.tst.sh` calls `in_orc` ~173
times; 266 orc tests use `in_orc`.

### 2.5 Probe: `in_orc` sourcing only the files it needs

Scratch only (the clone's `test-lib.inc.sh`, never committed): with
`IN_ORC_RUN=<run file stems>` set, `in_orc` sources `lib/bash/funcs/*.func.sh`
and only those `src/bash/run/` files; unset, it sources all as today. For
`spl-lane-issue.tst.sh` the list is the 8 run files that define a function
`spl-lane-issue.func.sh` names: `spl-desk-live-proof spl-desk-reply
spl-desk-up spl-done-claim-check spl-issue-update spl-lane-issue-applied
spl-lane-issue spl-spawn-share`.

- **Count** (n=1 per arm, the trace in 2.4 is arm S), counted the same way
  for both (`grep execve <trace> | grep -vc "= -1"`; 2.4's 13,425 was an
  earlier count of arm S by another filter, superseded by this line):

  | arm | execve lines | successful | `dirname` | rc | PASS / FAIL |
  |---|---|---|---|---|---|
  | S (today) | 15,043 | **14,379** | **6,396** | 0 | 174 / 0 |
  | L (the set) | 9,581 | **8,917** | **1,181** | 0 | 174 / 0 |

  `sed` 1,255, `grep` 1,148, `tail` 585, `id` 412 are the same in both arms:
  the gain is the source, nothing else moves.
- **Wall**, alternated L, S, L (started 00:33Z, stopped by the rotation
  before the 2nd S): L 126.4 s (load 52.7), S 364.3 s (load 70.8), L 73.0 s
  (load 63.1). The load swings 45..70, so these wall seconds show the
  direction only.
- **CPU** (user + sys, less load-bound than wall), alternated S, L, S, L,
  started 00:46Z, bash `time` (`TIMEFORMAT="%R %U %S"`), n=2 per arm:

  | arm | load at start | wall s | user s | sys s | user + sys s | PASS / FAIL |
  |---|---|---|---|---|---|---|
  | S | 21.6 | 269.7 | 113.2 | 90.2 | **203.4** | 174 / 0 |
  | L | 40.5 | 63.5 | 29.4 | 18.8 | **48.2** | 174 / 0 |
  | S | 38.9 | 347.4 | 126.2 | 105.8 | **232.0** | 174 / 0 |
  | L | 59.5 | 82.6 | 30.8 | 19.5 | **50.3** | 174 / 0 |

  Each L arm started under a higher load than the S arm before it and still
  used about a quarter of its CPU (48.2 and 50.3 s against 203.4 and 232.0 s).

## 3. R3 reads

- Lane map, every machine, 23:50:40Z: `lane-map.sh --check
  <spl-spawn-queue.tst.sh, spl-lane-issue.tst.sh, run-all-tests.sh,
  changed-tests.sh, check-pre-push.func.sh, the plan, this file> --agent
  c-454` -> exit 4: 0 `owned by`, 6 `unknown:` on sat (c-044 s143 b6
  api/orc sync, c-137 nuxt4 migration, c-176 invitee label, c-194 kind-picker
  keys, c-197 and c-762 rotate). Not free until re-read before each spawn.
- Spawn queue, 23:50:48Z (`ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`): 7 queued, 0 placing (deploy-lag bug, done-claim
  wording bug, two SPL-5707 agy reviews, SPL-5006 W3 grant, spec 169 T13 and
  T15).
- Parked r35 v0.1 (`27e21eefc`): its rows write orc `run/` files
  (`spl-uplink-probe`, login-check callers, box-crons, spawn-place,
  feature state dirs, key-path examples) and `no-literal-paths.baseline`;
  no test-lib or test-runner file.

## 4. Panel (read 23:51Z)

- `do_spl_box_pick`: grok `pick=hold` (weekly 99% on both boxes); agy,
  mistral, claude `pick=<this box>` (weekly unknown, placed anyway).
- `ENV=prd do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder: `c-003@sat` (23:50:29Z).
- Not asked yet: the seats are asked once the plan has a sha.

## 5. State (00:5xZ, the session after the 00:43Z rotation)

- Plan v0.1 `1c82cbccc`; v0.2 adds the CPU series (2.5).
- Panel seat: m-245@sat (mistral, ask 6eaf2fde, holder c-002@sat msg
  7aa321bc, under owner ruling e895dea6).
- R3 and panel re-read at 00:49Z (plan 3.2, 5).
- m-245 PASS on v0.2.1 `e4c176fb4` (msg 91c1bc58), folded into v1.0.
- v1.0 `b06f4ac3b` and the seat files `0fcef8bc8`, `5616e9aee` landed;
  m-245 PASS on v1.0 (msg b297ff22); ACCEPTED by c-002@sat (msg 00b8493e,
  01:37Z); row p15-01 placed as c-261@sat (ask 80615e25).
- Plan imported as qto doc `907ce2f6-d0dd-4eba-8e1d-b0212483b0e5` (11
  sections, `do_spl_doctree_import_md`, ENV=prd TENANT_ID=t1 QTO_FS=repo);
  the md is its export.
- Scratch (push user's): `/var/tmp/p15-orc-clone.AvLl` (clone, logs,
  straces, the probe edit).
