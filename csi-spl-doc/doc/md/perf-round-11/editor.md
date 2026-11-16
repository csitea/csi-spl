# Perf round 11: editor seat (c-430, claude)

The raw commands and outputs behind [perf-round-11-plan.md](../perf-round-11-plan.md).

## 1. Seat

- Editor (planner): c-430 (claude) on the desk box (16 cpus), issue SPL-5672,
  discussion `8d4ead86`.
- **The row baselines** (2.5, 2.6, 2.7) were measured on **`6fcc711a9`**
  (`origin/master` at 02:4xZ on 2026-11-16), 02:44Z-02:51Z. The 1-minute load is
  printed beside each run: 16.6..25.8 on 16 cpus.
- The screening runs (2.2, 2.3, 2.4) ran on the older `76f65baee` and
  `fed9fb69d`, before a fresh fetch moved `origin/master` on. They pick the
  candidates. They are not baselines.
  `git diff --stat fed9fb69d 6fcc711a9` shows one file,
  `internal/hub/live_ack_test.go`, which no row touches.
- The probe scripts and raw results are in `/var/tmp/c430-probe/` on the desk box:
  `timeone.sh`, `stamp.sh`, `abpair.sh`, `hygab.sh`, `hyg3.sh`, `*.res`, `*.out`,
  `st-*.txt`, `ab-r0*-*`, `hygab-7.txt`, `wetimeouts.log`. Arm A of every probe is a
  tracked-file export (`git archive <sha> csi-spl-orc csi-spl-cnf`). The B arms
  are copies of A with one edit, and that edit was never committed. `hygab.sh`
  runs in this worktree.

## 2. Measurements

### 2.1 Where the time goes: the pre-push log and CI

The desk user's `~/.cache/csi-spl/pre-push.log`, PART lines with SKIP and CACHED
left out. From 2026-11-15T02:15Z to 2026-11-16T02:15Z (24 h, 9,194 PART lines):

| part | n | median | sum |
|---|---|---|---|
| `orc` | 84 | 29 s | 21,802 s |
| `wui` | 78 | 184 s | 16,862 s |
| `api` | 34 | 205 s | 15,820 s |
| `wui-e2e` | 37 | 373 s | 13,251 s |
| `iac` | 48 | 166 s | 12,219 s |
| `orc-features` | 47 | 177 s | 8,334 s |
| `lint-gosec` | 13 | 584 s | 8,229 s |
| `hygiene` | 236 | 5 s | 1,829 s |
| `commit-links` | 236 | 5 s | 1,633 s |
| `lint-trufflehog` | 275 | 3 s | 1,243 s |
| `iac-cross` | 184 | 4 s | 1,035 s |

From 2026-11-15T21:47Z, after p10-01 landed (`70743821c`, 21:46Z):

- `orc`: n=31, median 404 s, sum 17,161 s. One tree ran 6 `WARN-pre-existing`
  orc parts of 1,104..1,951 s.
- `hygiene`: n=77, median 5 s (1..16).
- `commit-links`: n=77, median 5 s.
- `iac-cross`: n=50, median 4 s.
- `lint-trufflehog`: n=86, median 3 s.

The parts of one gate run one after the other: each part's log line starts
after the one before it ends. So a second saved in an always-run part is a
second saved on every push.

CI, workflow 10 run `43788231600` (green, head `c7b51fe45`): the four
`orc: hermetic action tests` shards took 653, 728, 787 and 606 s. Each shard
ends with `--- slowest 10 test files (wall s, cpu s)`. These are the files
whose wall time is far above their CPU, so they wait rather than work:

| file | wall s | cpu s |
|---|---|---|
| `wd-fence.tst.sh` | 177.1 | 23.9 |
| `lane-rotate.tst.sh` | 164.7 | 51.2 |
| `fleet-lease-slow-tick.tst.sh` | 87.6 | 7.8 |
| `lane-map.tst.sh` | 79.3 | 21.4 |
| `wd-self-update.tst.sh` | 61.4 | 16.5 |
| `workspace-doc-node.tst.sh` | 61.3 | 17.6 |
| `wd-multi-daemon.tst.sh` | 59.1 | 13.6 |
| `spl-standby-bench.tst.sh` | 49.5 | 13.5 |

### 2.2 Screening: the waiting orc tests on the desk box (n=1, `76f65baee`)

`timeone.sh` runs one file the way `run-all-tests.sh` runs it (`bash <file>`,
stdin `/dev/null`) and prints wall, CPU (user + sys) and rc. All eight files ran
at once, under a load of 30..44:

| file | wall s | cpu s | rc |
|---|---|---|---|
| `lane-rotate.tst.sh` | 202.2 | 59.5 | 0 |
| `wd-fence.tst.sh` | 176.7 | 26.5 | 0 |
| `wd-self-update.tst.sh` | 112.0 | 20.7 | 0 |
| `workspace-doc-node.tst.sh` | 102.2 | 66.4 | 0 |
| `fleet-lease-slow-tick.tst.sh` | 94.1 | 5.4 | 0 |
| `lane-map.tst.sh` | 88.0 | 26.3 | 0 |
| `spl-standby-bench.tst.sh` | 87.4 | 20.0 | 0 |
| `wd-multi-daemon.tst.sh` | 80.5 | 11.5 | 0 |

`stamp.sh` prints each output line with the seconds since the start, so the
gap before a line is the time that case spent. The largest gaps on the A export
of `fed9fb69d` (n=1):

- `spl-standby-bench.tst.sh`: **31.4 s** before `PASS: CONTROL no vibe on PATH`
  (case 9, which runs right after case 8).
- `wd-multi-daemon.tst.sh`: **38.3 s** before `PASS: 4 control: no judge lock ->
  the S9 note goes twice`.
- `fleet-lease-slow-tick.tst.sh`: 43.5 s and 42.1 s, its two real-clock runs of
  the loop (scaled 1:15 on purpose). This is the test's design, not a row.
- `lane-map.tst.sh`: 15.6 s, the case for a hub that hangs on every try, bound
  by its 15 s budget on purpose. Not a row.
- `dispatch-rotate.tst.sh`: 17.4 s in case 7, which waits out the rotation's
  `ROTATE_ACK_TIMEOUT=15`. The comment at `:477-479` sets it that way for
  loaded boxes. Not a row.
- `lane-rotate.tst.sh`, `wd-fence.tst.sh`, `desk-move.tst.sh`: many gaps of
  5..11 s each, the per-case waits of the code under test. None of them stands
  out.

### 2.3 Dropped: sub-second rotation polls (n=1)

The rotation code polls in whole seconds (`ROTATE_POLL`, which
`spl-rotate-lib.func.sh:104-108` allows only as a whole number of at least 1),
plus fixed `sleep 1` lines. B = A with each `sleep "$ROTATE_POLL"` and
`sleep 1` in `spl-rotate-lib`, `spl-lane-rotate`, `spl-dispatch-rotate`,
`spl-agent-restart`, `spl-lane-restart` and `spl-peer-restart` changed to
`sleep 0.1` (20 lines). All 8 runs went at once, load 36..48:

| file | A wall / cpu | B wall / cpu |
|---|---|---|
| `lane-rotate.tst.sh` | 238.7 / 59.9 rc 0 | 198.2 / 61.7 rc 0 |
| `dispatch-rotate.tst.sh` | 288.4 / 103.9 rc 0 | 294.6 / 107.7 **rc 1** (`FAIL: 30. slow hand-back`) |
| `orch-rotate.tst.sh` | 205.7 / 79.9 rc 0 | 300.0 / 114.3 rc 0 |
| `agent-restart.tst.sh` | 215.8 / 93.6 rc 0 | 215.0 / 94.1 rc 0 |

There is no gain across the four files, and B breaks one case. Dropped.

### 2.4 No row: hidden `wait_event` timeouts (n=1 per file)

C = A with `wait_event` (`csi-spl-orc/src/bash/tests/wait-event.inc.sh`) changed
to append one line to `wetimeouts.log` when its budget runs out. The 20 orc
test files that call `wait_event` ran 6 at a time (load 22..63).
`wetimeouts.log` got **0** lines from the 17 files that ran green. Three files
went rc 1 in the export because they need a git checkout or the test Postgres:
`spl-doc-tree-repair`, `workspace-doc-node` and `workspace-docs-migration`.
Three more runs of `wd-multi-daemon.tst.sh` under C (at once, load 25.4) took
54.4, 54.2 and 54.3 s and logged
`wd-multi-daemon.tst.sh line=126 budget=30 cmd=done_n 2` three times. That is
row 02. No other file wastes a `wait_event` budget.

### 2.5 Row 01: `spl-standby-bench.tst.sh`, the case 8 fixture (n=5)

Case 8 (`:177-183`) starts `sleep 30 | <stub> &` and later kills only the stub
(`kill "$ctl"`). The `sleep 30` lives on, so the next case pays for it. In
`stamp.sh` the 30 s shows as the gap before case 9's PASS line (A 23.2 -> 54.0 s,
B 23.5 -> 24.6 s, n=1).

B1 = A with case 8's stub reading a fifo fed by `sleep 30 &` (`slp=$!`), and
`kill "$ctl" "$slp"` (2 lines changed). `abpair.sh` starts A and B together
on each run (so both see the same load), n=5, load 17.0..25.8:

| run | A wall / cpu, PASS | B wall / cpu, PASS |
|---|---|---|
| 1 | 55.2 / 16.7, 41 | 25.2 / 16.5, 41 |
| 2 | 57.5 / 17.2, 41 | 29.0 / 18.3, 41 |
| 3 | 52.4 / 15.3, 41 | 22.4 / 15.2, 41 |
| 4 | 54.2 / 16.6, 41 | 27.1 / 17.4, 41 |
| 5 | 54.0 / 16.8, 41 | 24.6 / 16.8, 41 |

- A: median **54.2 s** (52.4..57.5).
- B: median **25.2 s** (22.4..29.0), **-54%**, faster than its paired A in 5 of
  5 runs.
- rc 0 and 41 PASS lines in both arms. CPU is the same in both arms: the saving
  is waiting time only.

### 2.6 Row 02: `wd-multi-daemon.tst.sh`, the S9 control's `settle 2` (n=5, n=12)

The S9 control (`:218-222`) ends in `settle 2`, which waits up to 30 s for 2
detached restarts to finish (`done_n`, `settle` at `:125-126`). Only one restart
happens on most runs, so the wait runs out its full 30 s and the case passes
anyway. B3 printed the count when the wait ran out:
`PROBE SETTLE-TIMEOUT done=1 takeovers=takeover c-952 S9|` (n=1).

B2x = A with `settle 2` -> `settle 1` on `:220` only. This is the probe arm, not
the fix (section 4 of the plan). `abpair.sh`, n=5, load 18.9..24.8:

| run | A wall / cpu | B wall / cpu |
|---|---|---|
| 1 | 55.2 / 9.6 | 23.9 / 8.3 |
| 2 | 26.2 / 9.4 | 26.2 / 9.4 |
| 3 | 23.5 / 8.7 | 23.5 / 8.6 |
| 4 | 51.9 / 8.4 | 21.9 / 8.3 |
| 5 | 22.7 / 8.3 | 22.2 / 8.0 |

All runs rc 0 with 31 PASS lines. A's median is 26.2 s and its mean 35.9 s;
B's median is 23.5 s and its mean 23.5 s.

The wait runs out on some runs and not others. Over every arm-A run of this
file (2.2, 2.4 and here), it ran out in **8 of 12** runs (each about 30 s
longer): 80.5, 70.9, 64.1, 53.0, 54.4, 54.2, 54.3, 55.2 and 51.9 s, against
26.8, 26.2, 23.5 and 22.7 s when it did not. CI's 59.1 s in 2.1 matches a run
where it ran out. Expected gain: about 30 s x 8/12 = **~20 s per run**.

### 2.7 Row 03: the hygiene part's two drift checks beside the dist sweep (n=7)

`_pp_part_hygiene` (`csi-spl-iac/src/bash/run/check-pre-push.func.sh:492-508`)
runs `do_check_dist_hygiene`, then `do_check_fleet_rules_drift`, then
`do_check_qto_doc_drift`, one after the other. None of them reads another's
result.

`hyg3.sh`, this worktree at `6fcc711a9`, each piece through `./run`, n=5, load
17.3..18.9:

| run | dist ms | fleet-rules drift ms | qto drift ms |
|---|---|---|---|
| 1 | 2316 | 1703 | 731 |
| 2 | 2288 | 1382 | 515 |
| 3 | 1528 | 1113 | 705 |
| 4 | 1893 | 1046 | 510 |
| 5 | 1512 | 1089 | 688 |

`hygab.sh`: arm A runs the three pieces one after the other, as today. Arm B
starts the two drift checks in the background and runs the dist sweep in the
foreground, then `wait`. The arms alternate (AB on odd runs, BA on even), n=7,
load 16.6..21.8:

| run | A ms | B ms |
|---|---|---|
| 1 | 3813 | 2444 |
| 2 | 3766 | 2512 |
| 3 | 3359 | 1663 |
| 4 | 3391 | 2002 |
| 5 | 3088 | 1717 |
| 6 | 5558 | 1877 |
| 7 | 5129 | 2440 |

- A: median **3,766 ms** (3,088..5,558).
- B: median **2,002 ms** (1,663..2,512), **-47%**. B is below its paired A in
  7 of 7 runs, and the two ranges do not overlap.
- All pieces rc 0 in both arms. The probe times the whole pieces through
  `./run`. The part sources the two drift files in subshells instead.

## 3. Reads for R1 / R3

- Lane map, 02:45:22Z-02:45:25Z, one call:
  `lane-map.sh --check csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh,csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh,csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-iac/src/bash/tests/check-pre-push.tst.sh,csi-spl-doc/doc/md/perf-round-11-plan.md,csi-spl-doc/doc/md/perf-round-11/editor.md --agent c-430`
  -> exit 4: `0` lines `owned by`, `13` lines `unknown:`, all on sat. They are
  c-193, c-197, c-664 and c-762 (rotation seats); g-293, g-367, g-374, g-376,
  g-386 and g-393 (rotation seats); c-326 (`64ca-t10-fewer-rollouts-one-login`);
  c-361 (`bug-live-ack-test-fixed-sleep`, the api Go test changed in
  `6fcc711a9`); and c-396 (`bug-ppf-parts-drops-unreadable-rc`).
- Spawn queue, 02:45:29Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue` -> `19 queued, 1 placing`. None of their briefs is on
  this box (`/var/spool-hub/dispatch/briefs/<slug>.md` is missing for all
  twelve slugs I checked), so I could not read their files from here. Two slugs
  could touch a row file: `c002-64ca-t7-bench-back-one-post` (ask `2f9a191e`;
  "bench" may mean `spl-standby-bench`) and `c002-64ca-t9-cpu-overload-measure`.
- Unlanded round rows, 02:45:45Z, on `6fcc711a9`,
  `git log origin/master --format=%s -E --grep='\(<r>-[0-9]{2}-'`:
  - landed: r57-01..06, r58-01..07, r59-01..05, p10-01..02.
  - not landed: **r58-08** (`bash-cleancode.tst.sh`, a grok reviewer queued,
    ask `520e4d83`) and **r59-06** (the Go and WUI cleancode lists).
  - r60: 0 lines.
- Slug, 02:45:45Z: `git log origin/master --oneline -E --grep='\(p11-'` -> 0;
  `git ls-tree -r --name-only origin/master | grep -c perf-round-11` -> 0;
  `... | grep -cE 'perf-round-(9|10)-retro'` -> 0.
- Agent kinds, 02:45Z: `ENV=prd ./run -a do_spl_hub_agent_kinds` ->
  `off [qwen], paused []`. The action minted a prd access token with the box's
  prd SA key. This seat did not open the key file.
- Dispatch lease, 02:45Z: `LEASE_CMD=show ./run -a do_spl_dispatch_lease` ->
  `c-003@sat`.
- `command -v agy grok` on the desk box -> both found.
