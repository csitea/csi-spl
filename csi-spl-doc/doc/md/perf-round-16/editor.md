# Perf round 16: editor seat (c-337, claude)

Issue SPL-5861, epic SPL-2402, spec `csi-spl-doc/specs/027-spool-performance`,
round topic `4a0e0c70`; report to the dispatch lease holder on task
`dispatch-perf-r16`. The plan: [perf-round-16-plan.md](../perf-round-16-plan.md).

## 1. Done

- STEP 0: developer guide acked (blob `8b1916cd`), fetched.
- One sha for every baseline: **`2fe3729e3`** (`origin/master` at 05:44Z,
  2026-11-18), on the desk box (16 cpus; the 1-minute load is named next to
  each timed number).
- Slug, 06:00:00Z: `git log origin/master --oneline -E --grep='\(p16-' | wc -l`
  -> `0`; `git ls-remote origin 'refs/heads/*p16*' | wc -l` -> `0`; no
  `perf-round-16*` path under `csi-spl-doc/doc/md`.
- Floor, the rulebook 4.4 command on `2fe3729e3`, n=1:
  `perf 23 refactor 93 perf-share 19.8% under-20`.
- Retro: `perf-round-15-retro.md` is not on the tree (`ls` -> No such file).
  This seat does not invent its content.

## 2. Measurements

### 2.1 The desk box pre-push log, 7 days

The push user's `~/.cache/csi-spl/pre-push.log`, `PART` lines since
2026-11-11T05:45Z with a verdict that ran (no SKIP, no cached, no
PASS-tree), summed per part, verdict and tier (top 8):

| part verdict tier | n | sum s | mean s |
|---|---|---|---|
| `orc` FAIL full | 19 | 243,834 | 12,833 |
| `api` PASS full | 53 | 162,514 | 3,066 |
| `lint-gosec` PASS full | 149 | 160,213 | 1,075 |
| `orc` PASS fast | 237 | 152,208 | 642 |
| `orc` FAIL fast | 45 | 140,039 | 3,111 |
| `api` FAIL full | 27 | 125,623 | 4,652 |
| `orc` WARN-pre-existing full | 13 | 113,838 | 8,756 |
| `wui` PASS fast | 150 | 112,398 | 749 |

`orc` on the fast tier (PASS + FAIL, n=282, 292,247 s) is again the largest
part a push waits for on every orc commit. It runs the orc tests the map
(`csi-spl-orc/src/bash/tests/changed-tests.sh`) selects.

### 2.2 Which orc tests the fast tier runs, and why (replay of the map)

Every `origin/master` commit since 2026-11-11T05:45Z touching `csi-spl-orc/`
(249 commits), its own file list fed to the map on `2fe3729e3`:
`ORC_TEST_FILES=<files> ORC_TEST_ALWAYS= bash changed-tests.sh` (n=1, the map
is deterministic). Result: **5,342** `run` lines, **19** `full`. Weighted by
`orc-shard-weights.txt` (CI wall seconds per test): **189,337 s**.

The reason column (`names <file>`), by the basename of the file (top 5):

| basename | selections |
|---|---|
| `spec.md` | **1,318** |
| `test-lib.inc.sh` | 747 |
| `all.env.yaml` | 450 |
| `spl-dispatch-lease.func.sh` | 352 |
| `spl-rotate-lib.func.sh` | 214 |

`spec.md` is the basename of 186 tracked files
(`git ls-files | grep -c '/spec.md$'`). The map keys a changed file by its
basename, so a commit that edits any `csi-spl-doc/specs/<NNN>/spec.md`
selects the 16 orc tests that write a fixture `spec.md`
(`spl-spawn-queue.tst.sh`, `spl-lane-issue.tst.sh`, `desk-actions.tst.sh`,
`lane-map.tst.sh`, ...). `grep -n 'spec\.md'` on each: 15 write or name a
fixture path under the test's temp dir; one, `dev-mode-root-one-liner.tst.sh`,
reads the real `csi-spl-doc/specs/148-local-dev-mode/spec.md` by its full
repo path. One such commit,
`ORC_TEST_FILES=csi-spl-doc/specs/157-dispatch-automation/spec.md`: 16
tests, weight 633 s.

`all.env.yaml`: 9 of the 249 commits touched it; the tests it selects read
the real cnf (`grep -c 'csi-spl-cnf/csi-spl/all'` >= 1 in most). Not a
candidate.

### 2.3 Probe A: a shared doc name keys by its repo path

Scratch clone of `2fe3729e3`, never committed: in `keys()`, a `.md` file
whose basename more than one tracked `.md` file carries keys by its repo path
only; a unique doc name keeps its basename key. The same replay:

| arm | run lines | `full` | weighted CI s |
|---|---|---|---|
| today | 5,342 | 19 | 189,337 |
| probe | **4,024** | 19 | **139,723** |

-1,318 selections (24.7%), -49,614 weighted s (26.2%) over 7 days, n=1
(deterministic). Lost selections by basename: `spec.md` 1,261, `README.md` 39,
`tasks.md` 14, `how-to-post.md` 3, `SKILL.md` 1. A first form (every `.md`
by its path) also lost unique names (`SPEC-spool-fleet-roles.md` 22,
`unified-fs.md` 4, `developer-guide.md` 2): rejected.

Checks on the probe: `ORC_TEST_FILES=csi-spl-doc/specs/148-local-dev-mode/spec.md`
-> `run dev-mode-root-one-liner.tst.sh` (the full-path reader is still
selected); the spec 157 commit above -> 0 tests, `ignore ... doc`;
`bash run-all-tests-changed.tst.sh` -> `0 failed`.

### 2.4 After probe A, which tests weigh most

The probe replay, selections x CI weight, top 5:

| test | selected | weight s | uses `in_orc` |
|---|---|---|---|
| `wd-situations.tst.sh` | 38 | 228 | no |
| `dispatch-rotate.tst.sh` | 45 | 190 | no |
| `fleet-lease.tst.sh` | 27 | 308 | no |
| `spl-spawn-queue.tst.sh` | 32 | 246 | no |
| `spl-lane-mix.tst.sh` | 23 | 324 | no |

`desk-actions.tst.sh` (128 `in_orc` calls) falls from 97 to 16 selections:
the p15 carry "other `in_orc` tests adopt the set" weighs little once the
`spec.md` keys go.

### 2.5 `spl-spawn-queue.tst.sh`

Timed alone on a `git clone --shared` of `2fe3729e3`, bash `time`
(`TIMEFORMAT="%R %U %S"`): **337.6 s wall, 188.0 user, 181.2 sys**, load
4.65 at start, n=1, rc 0, 272 PASS, 0 FAIL (05:46:07Z; the map replay of 2.2
ran beside it for its first ~60 s).

Where the cost is: a `bash -x` run with `PS4='+${BASH_SOURCE##*/}:${LINENO}: '`
and `SHELLOPTS` exported, counted by `source:line`. **Perturbed**: the trace
lines went into captured output, so the run ended 73 PASS / 199 FAIL; its
counts show the direction only. Top external calls by site:

| site | call | count |
|---|---|---|
| `spl-spawn-share.func.sh:193` (`spl_spawn_share_briefs`, per lane) | `grep`, `sed`, `tr` | 4,383 each |
| `spl-spawn-place.func.sh:1417` (`spl_spawn_place_brief`, `\| tail -1`) | `tail` | 2,716 |
| `spl-spawn-place.func.sh:249` | `jq` | 542 |
| 6 sourced files' load lines (`dirname "${BASH_SOURCE[0]}"`) | `dirname` | 628 each |

One `jq` call on this box: 3.9 ms wall (200 calls 0.78 s, n=3, load 7);
one `dirname` 1.7 ms (n=2).

Probe B (scratch clone `clone-q`, never committed):
`spl_spawn_share_briefs` reads the `Class:` line of every lane's brief with
ONE `grep -m1 -oiHE ... <files>` and builds the map with ONE `jq`, in place
of `grep | sed | tr` and a `jq` per lane; `spl_spawn_place_brief` takes the
last line with `${c##*$'\n'}` in place of `| tail -1`. Same output on a
fixture of 5 briefs (Refactor, a second Class line, none, missing, `ci.`),
both arms: `{"c-101@<box>":"refactor","c-102@<box>":"bug","g-105@<box>":"ci"}`, and
`{}` for no lane; the probe adds a trailing newline (the lane prints with
`jq -j`).

The count and the time of probe B are in 2.6 (v0.2). Before that (v0.1): A count with logging
`PATH` stubs (jq grep sed tr tail dirname date awk cat) did not finish: the
stubbed run of today's arm wrote no test output in 30 min (stopped 06:3xZ by
its task id; a `cat` stub in a polling loop is the likely cause, unchecked).
Next: time S and P alternated, n=2 each, no stubs; count with stubs on the
6 commands only (no `cat`, `date`, `awk`).

### 2.6 Probe B, counted and timed (v0.2)

**The function alone.** `spl_spawn_share_briefs` extracted with `awk` from
`spl-spawn-share.func.sh` of each arm and called in one shell:
`SPOOL_ROOT=<fixture>`, `ASKS_BOX=bx`, a lanes JSON of 41 lanes on `bx`
(`c-101..c-140` with a brief each, `c-999` with none) and 1 on another box.
The briefs: `Class:` refactor / feature / ci / bug in turn, then 6 edge
cases (`Class: BUG` then a second `Class: refactor`; `Class: ci.`;
`Class:feature x`; `class: Refactor`; `Class: chore`; an empty file).
Arm S = `2fe3729e3`; arm R = `2fe3729e3` + the share half of probe B (the
`spl-spawn-share.func.sh` hunk only, no `spl-spawn-place.func.sh` change).

| what | S (`2fe3729e3`) | R (probe B, share only) |
|---|---|---|
| execs per call, logging `PATH` stubs for `jq grep sed tr` (n=1, deterministic) | **164**: 41 `grep`, 41 `jq`, 41 `sed`, 41 `tr` | **3**: 1 `grep`, 2 `jq` |
| 20 calls, wall s, n=3 alternated, load 25.6 / 24.3 / 25.1 | 9.57, 10.86, 9.68 | 0.36, 0.27, 0.22 |
| map (`jq -S` of both outputs, `cmp`) | same | same |

The edge cases map the same in both arms: `bug`, `ci`, `feature`,
`refactor`, and no key for `chore`, the empty brief and the missing brief.

**The whole test**, `spl-spawn-queue.tst.sh`, timed alone with `timeit.sh`
(bash `time`, `TIMEFORMAT="%R %U %S"`, one run at a time, on `git clone
--shared` copies of `2fe3729e3`). It ran beside other lanes' work on a busy
box, so the load is named per run and the CPU column (user + sys) is the
fairer number:

| run | start (UTC) | arm | load at start | wall s | user s | sys s | user + sys s | result |
|---|---|---|---|---|---|---|---|---|
| S1 | 05:46:07Z | S | 4.65 | 337.6 | 188.0 | 181.2 | 369.2 | 272 PASS, rc 0 |
| P1 | 06:33:43Z | P (both halves, not row 02) | 7.68 | 299.8 | 170.0 | 137.7 | 307.7 | 272 PASS, rc 0 |
| S2 | 06:38:43Z | S | 14.53 | 375.7 | 193.5 | 176.3 | 369.8 | 272 PASS, rc 0 |
| R1 | 06:45:01Z | R | 13.23 | 283.6 | 165.5 | 131.2 | 296.7 | 272 PASS, rc 0 |
| S3 | 06:49:45Z | S | 6.47 | 337.4 | 188.6 | 177.6 | 366.3 | 272 PASS, rc 0 |
| R2 | 06:55:22Z | R | 13.17 | 265.6 | 160.9 | 127.9 | 288.7 | 272 PASS, rc 0 |

S (n=3): user + sys mean **368.4 s**, wall mean 350.2 s. R (n=2): user + sys
mean **292.7 s** (-20.5%), wall mean 274.6 s (-21.6%), with R run at the
higher load. The ranges do not overlap (S 366.3..369.8, R 288.7..296.7 CPU).
n is small: this shows the direction and the size, not a tight figure; the
lane re-times on its own sha.

**R1.** The `| tail -1` half of probe B (`spl-spawn-place.func.sh:1417`) is
not in row 02: parked refactor round 35 row 04 edits that file (plan 3.2).
Run P1 in the table (05:46Z..06:33Z series) had both halves.

## 3. R3 reads

- Lane map, every machine, 05:56:58Z: `lane-map.sh --check
  <changed-tests.sh, run-all-tests-changed.tst.sh, spl-spawn-queue.tst.sh,
  the plan, this file> --agent c-337` -> exit 4: 0 `owned by`, 13
  `unknown:`, all on the second box (blog drafts c-054, c-714; seats and
  rotations c-060, c-390, c-468, c-469, c-528, c-545, c-570, c-596, c-669,
  c-924, c-927).
- Spawn queue, 05:45:27Z (`ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`): `1 queued, 0 placing`, the bug round 15 planner
  (ask 1b6bcd45, SPL-5862).
- Bug round 15: holder c-002, msg 4097ad50 (05:5xZ): its planner c-339
  has no rows yet; the holder told it this round's candidate files.
- Bug round 15 v0.1 (c-339, `8ce0de287`), holder msg fab96dbe: b15-03 edits
  the 4 `run.sh` files and `run-log.tst.sh`; c-339 says its 3 rows are clear
  of the 6 p16 candidate files. Confirmed to the holder: no p16 row touches
  a `run.sh` or `run-log.tst.sh`.
- Bug round 14: both rows on `origin/master` (`git log origin/master
  --oneline -E --grep='\(b14-'` -> b14-01 `ce765392c`, b14-02 `0a5a8fbb3`).
- Parked r35 v0.1 (`27e21eefc`): its files are `box-crons.manifest`,
  `no-literal-paths.baseline`, `orc-shard-weights.txt`,
  `spl-uplink-probe.func.sh`, `spl-reflection-gather.func.sh`,
  `prune-docker-images-install-cron.func.sh`, `box-crons-desk-reach.py` and
  the tests `boot-cron-gate`, `desk-install-service-*`, `install-box-crons`,
  `m3-e2e-none`, `no-literal-paths`, `run-eager-files`, `spl-run-paths`,
  `spl-token-burn-collect`, `test-seed-truth-first`. No p16 row file is
  among them; p16 rows leave `orc-shard-weights.txt` alone.

## 4. Panel (read 05:58:23Z)

- `do_spl_box_pick`: grok `pick=hold` (weekly 99% on both boxes); agy
  `pick=<second box>` (46% < 70%); mistral and claude `pick=<this box>`.
- `ENV=prd do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder: `c-002` (05:58Z; c-003 06:16Z to 06:20Z, c-003 msgs 4351d224, 9fa1a341; `LEASE_CMD=show` at 06:20:35Z -> `c-002`; c-003 again from 06:46Z, c-003 msg 4f022e60, `LEASE_CMD=show` at 06:47:08Z -> `c-003`; c-002 again from 06:50Z, c-003 msg da50a133, `LEASE_CMD=show` at 06:50:37 -> `c-002`).
- Seats are asked once the plan has a sha.

## 5. State (v0.2, 06:5xZ)

- v0.1 (`90e21bfad`) went to the holder (c-002) at 06:32Z; the holder placed
  an agy and a mistral seat, then dropped the agy seat (on its usage limit
  until 11-24; holder msg 367a834d). The panel is the mistral seat alone
  (ask a4390135, queued at 06:44:02Z).
- v0.2 adds row 02 (2.6) and is pushed to `review/c002-perf-round-16-planner`;
  its sha goes to the mistral seat and the holder (c-002 since 06:50Z) only.
- v0.2 `8b3fa986c`: mistral seat m-638 PASS (msg 40b3c8fc, W none, N1..N6;
  seat `356216b66`). v1.0 = the rows of v0.2 unchanged, landed on
  `master` by this seat; the seat signs the landed v1.0 sha, then the holder
  queues p16-01 and p16-02.

## 6. Close (09:5xZ)

- v1.0 `330bfc390` landed; quality gate 44258982546 and 44261383265
  success on it.
- Rows on `origin/master` (`git log origin/master --oneline -E
  --grep='\(p16-'` -> 2 lines): p16-01 `48b44328b`, p16-02 `0905076cc`.
  Per the holder: p16-01 ACCEPTED by c-002@sat; p16-02 and this seat
  ACCEPTED by c-003@sat (msg 37ccafd4, 08:48:45Z; quality gate 44265733431
  success on `e563bf623`, which contains `0905076cc`).
- The Qto import (4.5) is not done by this seat: the lane has no desk seat,
  so `do_spl_doctree_import_md` refused it; the DRY_RUN=0 command went to the
  orchestrator. The dry run on this tree listed 11 sections.
- `perf-round-16-retro.md` is the next round's input, not written here.
