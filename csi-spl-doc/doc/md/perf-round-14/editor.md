# Perf round 14: editor seat (c-025, claude)

Issue SPL-5795, epic SPL-2402, spec `csi-spl-doc/specs/027-spool-performance`,
round topic `9611738e`; report to the dispatch lease holder on task
`dispatch-perf-r14`. The plan: [perf-round-14-plan.md](../perf-round-14-plan.md).

## 1. Done

- STEP 0: developer guide acked (blob `8b1916cd`), fetched.
- One sha for every baseline: **`f9661ccf0`** (`origin/master` at 13:31Z,
  2026-11-17).
- Rulebook 4.4 on `f9661ccf0` (13:31:41Z), the command verbatim:
  `perf 20 refactor 100 perf-share 16.7% under-20`.
- Slug: `git log origin/master --oneline -E --grep='\(p14-'` -> 0 lines;
  `git ls-tree -r --name-only origin/master | grep -c perf-round-14` -> 0.
- Retro: `git ls-tree -r --name-only origin/master | grep -E 'perf-round-1[23]'`
  -> `perf-round-12-plan.md`, `perf-round-12/editor.md`,
  `perf-round-13-plan.md`, `perf-round-13/editor.md`: there is no
  `perf-round-13-retro.md`. p13-01 `05791365d` and p13-02 `e3388fce3` are on
  `origin/master`.

## 2. Measurements

### 2.1 The desk box pre-push log (the push user's `~/.cache/csi-spl/pre-push.log`)

Window: since p12-01 (`d5f6f6887`, 2026-11-16T23:52Z) to 13:30Z, parts with
a verdict that ran (no SKIP, no cached), split by tier:

```bash
sudo awk -v s="2026-11-16T23:52" '$1>=s && $3=="PART" && $5!~/SKIP|cached/ {gsub(/s$/,"",$6); tier="?"; for(i=7;i<=NF;i++) if($i~/^tier=/) tier=$i; k=$4" "$5" "tier; n[k]++; t[k]+=$6} END{for(k in n) if(t[k]>200) printf "%-45s n=%d sum=%d mean=%d\n",k,n[k],t[k],t[k]/n[k]}' ~/.cache/csi-spl/pre-push.log | sort
```

| part verdict tier | n | sum s | mean s |
|---|---|---|---|
| `api` PASS full | 9 | 29,430 | 3,270 (2,649..3,804) |
| `lint-gosec` PASS full | 15 | 12,890 | 859 |
| `orc` PASS fast | 25 | 9,174 | 366 |
| `wui` PASS fast | 14 | 9,111 | 650 |
| `wui-e2e` PASS fast | 14 | 6,007 | 429 |
| `orc` WARN-pre-existing full | 1 | 5,316 | 5,316 |
| `wui` PASS full | 7 | 4,485 | 640 |
| `wui-e2e` PASS full | 7 | 4,383 | 626 |
| `iac` PASS fast | 8 | 2,963 | 370 |

The parts run one after another, so a part's seconds are the push's own
wait. `lint-gosec` since p13-02 (`e3388fce3`, 12:37Z): n=3 (1,007 s on the
row's own push, 767, 536); the p13 retro's to measure, not this plan's.

### 2.2 The WUI unit runner: serial vs a pool of 4 (row 01)

`csi-spl-wui/src/node/test/run-unit-tests.mjs:70-84` spawns one `node`
per `tests/unit/*.test.mjs`, one after another (`spawnSync`), 524 files. The
`wui` part runs it (`check-pre-push.func.sh:786`), and so does CI wf 10
(`10_ci-quality.yml:605`, step "Unit tests").

Probe (scratch, never committed): a `git clone --shared` of the repo at
`f9661ccf0` in `/var/tmp`, `csi-spl-wui/node_modules` a symlink to a lane's
`node_modules` whose `.pnpm/lock.yaml` equals `f9661ccf0`'s
`pnpm-lock.yaml` (`cmp`), nothing installed. Arm S =
`node src/node/test/run-unit-tests.mjs` (today); arm P4 = the same 524 files,
`ls tests/unit/*.test.mjs | xargs -P 4 -I{} node {}`, per-file wall
recorded. Alternated S, P4, S, P4, run as the push user:

| arm | seconds | 1-min load start / end | result |
|---|---|---|---|
| S | 565.6 | 23.62 / 32.44 | `unit runner: all 524 file(s) passed` |
| P4 | 126.9 | 32.44 / 27.78 | 524 lines `rc=0` |
| S | 546.7 | 27.78 / 20.50 | all 524 passed |
| P4 | 120.3 | 20.50 / 23.87 | 524 lines `rc=0` |

- n=2 per arm: S 546.7..565.6 s, P4 120.3..126.9 s.
- P4's slowest files: `eslint-gate.test.mjs` 30.3 / 31.2 s, then
  `blog-sync` 8.1 / 10.2 s, `e2e-runner-coverage` 7.9 / 8.3 s: the floor of
  a pool is ~31 s.
- Shared state: `grep -lE "writeFileSync\(|rmSync\(" tests/unit/*.test.mjs | xargs grep -L mkdtemp`
  -> 0 files (27 files write, all 27 use `mkdtemp`). A grep cannot prove
  absence of every shared path; the row's lane runs the pool twice green.
- CI wf 10 "Unit tests" step, 5 green master jobs (hosted runner):
  124 s (`f9661ccf0`, job 134074428993), 168, 151, 136, 167 s. Not probed on
  CI.
- A first arm on a wui-only `git archive` failed 3 files that read
  `csi-spl-orc/` (not in the archive): 564.6 s, discarded.

### 2.3 The api part, full tier (row 02's baseline)

Probe: `SPL_API_TEST_TIER=full bash csi-spl-api/src/bash/tests/run-all-tests.sh`
on a `--shared` clone at `f9661ccf0`, each line time-stamped (UTC), start
13:39:59Z, load 25.17. Postgres from the cached docker image (`ok - temp
Postgres up (docker postgres:16-alpine)`). So far:

| section | start | seconds |
|---|---|---|
| toolchain tests + build-stripped + build-warm-mod-cache + cli-cross-build | 13:39:59 | 210 |
| gofmt + go vet | 13:43:29 | 28 |
| `go test -race ./...` (plain, no DSN) | 13:43:57 | 485 |
| coverage, hub-init, hygiene greps, smoke, the groups tests, live-stack | 13:52:02 | 191 |
| hub Postgres gate (`hub-pg.tst.sh`) | 13:55:13 | 1,830 (to `ALL HUB POSTGRES CHECKS PASSED` 14:25:43) |
| pg coverage floors + hub GCS gate | 14:25:45 | 8 (to 14:25:53) |

hub-pg groups: store a 568, b 316, c 156, d 217 s (chain 1,257 s); hub a 551,
b 369, c 384, d 267 s (chain 1,571 s); each "its fresh database" 7..20 s of
it. The two chains run side by side, each chain's groups one after another;
the last group ended 14:22:25, so the package suites took ~1,632 s, the e2e
after them 198 s.

Every section through the GCS gate printed green (`grep -cE 'not ok|FAIL'`
-> 0); the run's final `ALL csi-spl-api TESTS PASSED`, `RC` and `END` lines
are missing: the time-stamping pipe belonged to the old session, which the
14:26Z rotation stopped. Whole run 13:39:59..14:25:53 = 2,754 s, n=1.

### 2.4 hub-pg with every group at once (row 02's after)

Scratch copy `hub-pg-par.tst.sh` in the same clone (`f9661ccf0`): the
`store_groups` and `hub_groups` loops start each group in the background and
wait for all, the `db_lock` flock kept; nothing committed. Run alone,
`setsid`, `AGENT_ID=c-025 bash csi-spl-api/src/bash/tests/hub-pg-par.tst.sh`,
start 14:27:46Z load 21.93, end 14:47:35Z load 29.74, `RC 0`, `grep -cE 'not
ok|FAIL'` -> 0:

| group | seconds (fresh database part) |
|---|---|
| store c | 403 (23) |
| store d | 536 (47) |
| hub c | 722 (46) |
| hub d | 733 (61) |
| hub a | 734 (24) |
| store b | 886 (35) |
| hub b | 851 (75) |
| store a | 922 (12) |

Package suites 14:27:51..14:43:58 = **967 s** (baseline ~1,632 s); the whole
gate **1,189 s** (baseline 1,830 s); n=1 each, the baseline inside the full
run, this arm alone. Every group slowed under the contention; store a's 922 s
is 77% of the 20 min per-group timeout, so the row carries a cap.

A first run on a `git archive` (no `.git`) failed
`build-warm-mod-cache.tst.sh` case 3 (rc 128), discarded.

## 3. R3 reads

- Lane map, every machine, 13:40:11Z: `lane-map.sh --check
  csi-spl-api/src/bash/tests/run-all-tests.sh,csi-spl-api/src/bash/tests/hub-pg.tst.sh,csi-spl-wui/src/node/test/run-unit-tests.mjs,csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-doc/doc/md/perf-round-14-plan.md,csi-spl-doc/doc/md/perf-round-14/editor.md
  --agent c-025` -> exit 4: 0 `owned by`, 13 `unknown:`, all on the second
  box (8 rotation seats; 5 lanes: two blog drafts, a price, cost allocation,
  release projects). None names a test runner.
- Spawn queue, 13:40:18Z (`ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`): `2 queued, 1 placing`: b11-02 (orc review-go) placing,
  two agy i18n reviews (SPL-5706, SPL-5707) waiting.
- Round rows: r59 01..06 all on `origin/master`; r60..r63 0 lines; bug round
  11: b11-01 landed (`d3fd3032d`), b11-02 placing, its files are orc
  review-go (`grep -cE 'run-all-tests.sh|hub-pg|run-unit-tests|check-pre-push.func|pre-push-gate.md' bug-round-11-plan.md`
  -> 0).

## 4. Panel

- 13:40:50Z: grok `pick=hold` (99% on both boxes), agy `pick=nokind` (no CLI;
  agy on the second box at its limit until 2026-11-20T23:04:20Z), mistral `pick=hold` on
  load only; `do_spl_hub_agent_kinds` -> off [qwen], paused [].
- Asked c-002@sat (msg ade5d260, 13:41:47Z); c-002 (31c1b060): ruling
  e895dea6 holds for p14, claude + mistral sign; mistral seat ask 8aaab744.
  c-003@sat (c8cd065b): placed as **m-031@sat**. m-031 (2f837cc1) waits for
  a sha.
- m-031 PASS on v0.2 `ad7621455` (msg 11630893, seat `fff01fa97`), W none,
  N1..N4; holder c-002 GO for v1.0 (ff0f2c32). m-031 PASS on v1.0
  `b603e2db4` (msg 6e4d396d, seat `f4ca76204`): the rows are identical to v0.2.

## 5. State

- Plan v0.1 (row 01) and this file pushed to
  `review/c001-perf-round-14-planner`. The api probe (`run2.log` under the
  push user's `/var/tmp/p14-probe-scripts.*`) still runs.
- 14:5xZ (session after the 14:26Z rotation): the api probe's end read (2.3),
  the parallel arm run (2.4), plan v0.2 with row 02, rebased on `770de68f4`,
  pushed; the sha named to m-031 and the holder.
- 15:2xZ, at the 15:26Z rotation: plan v0.2 = **`ad7621455`** on
  `review/c001-perf-round-14-planner` (a fast-forward of `5929030f0`, a merge
  with `770de68f4`; `git ls-remote` read 15:2xZ). Named to m-031 (msg
  `57ec4e23`, 14:49:59Z) and reported to the holder c-002@sat (result
  `298bd2e1`, 14:50:11Z). No reply from either by 15:2xZ (`spool recv`).
  m-031's seat file on `review/c002-perf-round-14-mistral-seat` (`7ab0c2e50`)
  is its 14:34Z state, verdict PENDING, written before the sha was named.
- Next session: wait for m-031's verdict on `ad7621455` and any send-back;
  fold findings into v0.3 (new sha, named again). This state commit is local
  only, so the reviewed branch head stays `ad7621455`; push it with v0.3 or
  at the round's end. Exit only on a message on `dispatch-perf-r14` whose body
  starts with ACCEPTED.
- 15:2xZ (session after the 15:27Z rotation): the state commit pushed to
  the review branch as `af1daf181` (editor.md only; the plan file is 0 diff
  lines from `ad7621455`), named to m-031 (f60968eb).
- 15:3xZ: plan **v1.0 landed on master as `b603e2db4`** (`do_spl_push_master`,
  1 try; `git-fetch-fresh.sh --landed` rc 0), N1 and N3 folded, rows
  unchanged; the sha sent to c-002 (result, 15:38:05Z). m-031 PASS on it
  (section 4).
- Qto import (rulebook 4.5): c-025 holds no seat in the sat t1 prd desk
  (`DOCTREE_ARGS=list ./run -a do_spl_desk_doctree` -> "c-025 has no seat in
  the sat desk of t1"), so c-001 ran it (as the box's t1 desk user, `DESK_AGENT=c-001`), as in
  p13: qto doc **`558a5ba8-ff00-4a7c-941e-987d4c3d0e29`** (11 sections,
  workspace system), md export and `qto-docs.tsv` row landed as **`8d47ed465`**
  (c-001 msg 3b52f777). From now on the Qto doc is the plan's primary copy.
- Next: the holder queues the rows; this seat waits for ACCEPTED on
  `dispatch-perf-r14`.
- Scratch to remove after the round (push user's): `/var/tmp/p14-api-probe.*`,
  `/var/tmp/p14-api-clone.*`, `/var/tmp/p14-wui-probe.*`,
  `/var/tmp/p14-wui-clone.*`, `/var/tmp/p14-probe-scripts.*` (also `pg-arm.sh`,
  `pg.P.1.log`).
