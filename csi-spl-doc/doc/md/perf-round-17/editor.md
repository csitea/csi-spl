# Perf round 17: editor seat (c-705, claude)

Issue SPL-5872, epic SPL-2402, spec `csi-spl-doc/specs/027-spool-performance`,
round topic `f758f973`; report to the dispatch lease holder on task
`dispatch-perf-r17`. The plan: [perf-round-17-plan.md](../perf-round-17-plan.md).

## 1. Done

- STEP 0: developer guide acked (blob `8b1916cd`), fetched.
- One sha for every baseline: **`e5f867463`** (`origin/master` at 09:16Z,
  2026-11-18), on the desk box (16 cpus; the 1-minute load is named next to
  each timed number). `origin/master` moved to `8de44d393` at 09:27Z; its 3
  commits touch no row file (`git diff --stat e5f867463 8de44d393 --
  <row files> csi-spl-cnf` -> empty).
- Slug, 09:27:35Z on `8de44d393`: `git log origin/master --oneline -E
  --grep='\(p17-' | wc -l` -> `0`; `git ls-remote origin 'refs/heads/*p17*'
  | wc -l` -> `0`; no `perf-round-17*` path under `csi-spl-doc/doc/md`.
- Floor, the rulebook 4.4 command on `8de44d393`, n=1:
  `perf 25 refactor 91 perf-share 21.6% floor-met`.
- Retro: `perf-round-16-retro.md` is not on the tree (`git ls-tree
  --name-only origin/master csi-spl-doc/doc/md/ | grep perf-round-16` ->
  the plan and the seat dir only). This seat does not invent its content.

## 2. Measurements

### 2.1 The desk box pre-push log, 7 days

The push user's `~/.cache/csi-spl/pre-push.log`, `PART` lines since
2026-11-11T09:15:00Z (52,646 lines) with a verdict that ran (no `SKIP*`,
no `cached`, no `PASS-tree`), summed per part, verdict and tier (top 8):

| part verdict tier | n | sum s | mean s |
|---|---|---|---|
| `orc` PASS fast | 241 | 72,289 | 299 |
| `api` PASS full | 36 | 67,256 | 1,868 |
| `lint-gosec` PASS full | 95 | 61,365 | 645 |
| `orc` FAIL fast | 23 | 53,289 | 2,316 |
| `wui` PASS fast | 135 | 52,174 | 386 |
| `wui-e2e` PASS fast | 90 | 45,972 | 510 |
| `orc` WARN-pre-existing full | 8 | 44,791 | 5,598 |
| `iac` PASS fast | 94 | 32,600 | 346 |

These sums are about half of p16 editor 2.1's for the same parts (`orc`
PASS fast 152,208 s there). This seat did not find why (a log rotation, or
a different filter); it uses the table only to rank the parts, not as a
baseline of any row.

### 2.2 The orc map after p16-01 (replay)

Every `origin/master` commit since 2026-11-11T09:15:00Z that touches
`csi-spl-orc/` (**257** commits), its own file list fed to the map on
`e5f867463`: `ORC_TEST_FILES=<files> ORC_TEST_ALWAYS= bash
csi-spl-orc/src/bash/tests/changed-tests.sh` (n=1, deterministic; 95 s).
Result: **4,080** `run` lines, 20 `full`, 345 `ignore`; weighted by
`orc-shard-weights.txt` (`*` = 10): **145,200 s**.

The reason column, by the basename of the file (top 6):

| basename | selections | commits |
|---|---|---|
| `test-lib.inc.sh` | 749 | 2 (`1f32dd66c` p15-01, `a95946d3e`) |
| `all.env.yaml` | 450 | 9 |
| `spl-dispatch-lease.func.sh` | 357 | 8 |
| `spl-rotate-lib.func.sh` | 221 | not counted |
| `spl-desk-reply.func.sh` | 212 | not counted |
| `spl-lane-map.func.sh` | 149 | not counted |

`spec.md` is gone from the top (p16-01). The shared test library selects
every test that sources it, as it should. `spl-dispatch-lease.func.sh`: 29
tests name the file itself (`grep -lwF spl-dispatch-lease.func.sh *.tst.sh |
wc -l` -> 29), its largest function key `spl_lease_init` 19: the tests
source it. **No map row for p17.**

Selections x CI weight, top 5: `wd-situations` 38 x 228, `dispatch-rotate`
45 x 190, `spl-spawn-queue` 34 x 246, `fleet-lease` 27 x 308,
`spl-lane-mix` 23 x 324.

### 2.3 Where three of those tests spend (strace)

`strace -f -qq -e trace=execve` of `spl-lane-mix.tst.sh`,
`fleet-lease.tst.sh` and `dispatch-rotate.tst.sh`, run together on
`e5f867463` (from 09:19Z, load 28..62). Successful execs (`) = 0`), top 3,
read while the runs were still going:

| test | ok execs (partial) | top |
|---|---|---|
| `spl-lane-mix` | 4,868 (strace then died: `ptrace(PTRACE_LISTEN) Input/output error`, rc 1 at 61 PASS) | `yq` 1,614, `dirname` 899, `jq` 650 |
| `fleet-lease` | 9,604 | `rm` 2,276, `grep` 1,461, `date` 974 |
| `dispatch-rotate` | 7,750 | `grep` 1,191, `bash` 668, `date` 618 |

`fleet-lease` and `dispatch-rotate` spread over many sites; no single site
stands out in these counts, and this seat did not trace them by line. Not a
row (plan section 6). `spl-lane-mix`'s `yq` argv (first 32 bytes, strace's
cut): `.env.box.agent_split_by_kind.<kind>.<v>` and
`.env.box.agent_split.{auth_marker,window,tolerance,mistral_*}`: all from
`spl-lane-mix.func.sh` (2.4).

### 2.4 One `do_spl_lane_mix` pick: 12-13 `yq` execs

`onepick.sh <orc root> <stub dir>` (scratch, not committed): the test's
fixture (its cnf transform, a home with the four CLIs, one registry row),
then one pick in a clean `env -i` shell that sources what the test's
`mix()` sources (`lib/bash/funcs/*.func.sh`, `spl-lane-mix*.func.sh`,
`spl-lane-map.func.sh`). Logging `PATH` stubs for `yq`, `dirname`, `jq`, on
`e5f867463`, n=1 each (deterministic):

| `LANE_MIX_KIND` | `yq` per pick |
|---|---|
| `simple_coding` | **13** (and 4 `dirname`, 0 `jq`) |
| `secret` | 13 |
| `complex_coding` | 13 |
| `specs_and_docs` | 12 |

The sites (`grep -n yq src/bash/run/spl-lane-mix.func.sh`): `:169`, `:170`
(tolerance, window), `:172` (one per vendor of `LANE_MIX_VENDORS`), `:174`
(backup), `:265` (`mistral_ui_allowed`), `:292` (`mistral_coding_allowed`),
`:574` (`_spl_lane_mix_cli`, one per vendor), `:600` (`_spl_lane_mix_auth`).
Every one reads the same file, `LANE_MIX_CNF`, under `.env.box`.

Timed (bash `time`, `TIMEFORMAT="%R %U %S"`), 10:28Z local box clock
(09:28Z), load 34.8..35.9:

- 10 picks (each with its fixture, which runs 1 more `yq`):
  **7.00 s** wall, 2.45 user, 1.59 sys: ~0.70 s a pick.
- 130 `yq -r '.env.box.agent_split.tolerance // 5' <copy of all.env.yaml>`:
  **4.01 s** wall (1.13 user, 0.75 sys): **31 ms** a call.

So 12-13 `yq` are ~0.37-0.40 s of a ~0.70 s pick (computed, not measured as
a second arm). `yq -r -o=json '.env.box | {"s": .agent_split, "k":
.agent_split_by_kind}'` on the same copy: 0.035 s, n=1: the subtree in one
call costs about one call.

### 2.5 `spl-lane-mix.tst.sh` with a logging `yq` stub

`PATH=<stub dir>:$PATH bash spl-lane-mix.tst.sh` on `e5f867463`; the stub
logs its argv and execs the real `yq`. Timed with bash `time`
(`TIMEFORMAT="%R %U %S"`), 09:27Z..09:34:26Z, load ~35 at start, 36.3 at
the end, n=1, beside other lanes' work:

- **387.8 s** wall, 167.5 user, 117.2 sys; rc 0, 128 PASS, 0 FAIL.
- **4,825** `yq` execs (`wc -l` of the log); 4,818 of them read
  `agent_split` or `agent_split_by_kind`.

At 31 ms a call (2.4) the `yq` execs are ~150 s of the run (computed, not
measured as a second arm). The test's own fixture and checks run some of
them (its cnf transform per setup, the real-cnf checks of section 0); the
lane counts which are picks.

### 2.6 wf 10: the last job of the run is WUI e2e shard 2/8

The 7 newest green `10_ci-quality.yml` runs on `master` that ran the gate
(`gh run list --workflow 10_ci-quality.yml --branch master --status success
--limit 12`; 3 runs of 37 s left out), `gh run view <id> --json jobs`, per
job `completedAt - startedAt`, success only (top 5 by mean):

| job | mean s | min | max | n |
|---|---|---|---|---|
| wui e2e 2/8 | **1,168** | 1,064 | 1,238 | 6 |
| hub: gofmt, vet, test, smoke, GCS | 1,070 | 879 | 1,223 | 7 |
| wui e2e 6/8 | 1,048 | 996 | 1,093 | 6 |
| wui e2e 4/8 | 984 | 906 | 1,075 | 6 |
| wui e2e 7/8 | 910 | 822 | 973 | 6 |

The e2e shards 1/8 and 5/8: 797 and 807 s. Per run, the job that ends last
(offsets from the run's first job start):

| run | head | span s | last e2e end | last other job end |
|---|---|---|---|---|
| 44253856248 | `f529b3091` | 1,419 | 1,418 (2/8) | 1,136 (hub) |
| 44261383265 | `330bfc390` | 1,395 | 1,394 (2/8) | 1,066 (orc) |
| 44263008046 | `f284b4148` | 1,409 | 1,408 (2/8) | 994 (orc) |
| 44265733431 | `e563bf623` | 1,293 | 1,292 (2/8) | 1,265 (hub) |
| 44269686338 | `2e55f493d` | 1,316 | 1,316 (2/8) | 897 (hub) |
| 44269882493 | `526155e00` | 1,283 | 1,282 (6/8) | 1,259 (hub) |
| 44256817746 | `fb16a1537` | 1,239 | no e2e | 1,239 (hub) |

Shard 2/8 ends the run in 5 of the 6 runs that ran e2e.

### 2.7 Why: 106 of the 367 e2e files CI runs have no weight

On `e5f867463`: `ls csi-spl-wui/tests/e2e/*.test.mjs | wc -l` -> 371;
`tests/e2e/ci-skip.txt` skips 4, so CI runs 367. `e2e-shard-weights.txt`
has 261 weight lines; **106** of the 367 have none (`comm -23 <selection>
<weighted names> | wc -l`) and take the median weight (`weightFor`,
`run-e2e-tests.mjs:99-102`). The file's last refresh is 2026-10-16 (its
header); its last added line is `bc685b890` (2026-11-10).
`run-e2e-tests.mjs`, `e2e-shard-weights.txt`, `ci-skip.txt` and
`tests/e2e/` are unchanged from `f284b4148` to `e5f867463` (`git log
--oneline f284b4148..e5f867463 -- <them>` -> 0 lines), so the 3 runs of
2.8 packed the same files with the same weights as `e5f867463`.

The suite's own check cannot see it: `e2e-shard-pack.test.mjs:133-149`
asserts the pack is within 0.05 of even on the file's OWN weights, where
every unweighted file counts as the median.

### 2.8 Repack: leave one run out

The per-file lines (`tests/e2e/<file> <secs>`, printed by
`run-e2e-tests.mjs:260`) of the 24 e2e shard jobs of runs 44263008046,
44265733431 and 44269686338 (`gh api
repos/<owner>/<repo>/actions/jobs/<id>/logs`): 367 files each, file sums
7,284, 7,051 and 7,119 s (an even split: 910, 881, 890 s a shard).

`loo.mjs` (scratch) imports `packShards`, `parseWeights` and `weightFor`
from `run-e2e-tests.mjs` of `e5f867463` and packs the 367 files into 8
shards twice per run R: with today's weights file, and with weights = the
median of the OTHER two runs (R's own times never enter its weights). Each
shard is scored with R's measured seconds:

| run R | today: max / min shard s | refreshed (leave-one-out): max / min | even |
|---|---|---|---|
| 44263008046 | **1,189** / 737 | **941** / 887 | 911 |
| 44265733431 | **1,064** / 749 | **909** / 865 | 881 |
| 44269686338 | **1,136** / 700 | **911** / 874 | 890 |

The "today" maxima are exactly the file sums in shard 2/8's logs of those
runs (1,189, 1,064, 1,136): the model reproduces CI's pack. The slowest
shard falls by 248, 155 and 225 s (mean -209 s, -18.5%), n=3.

What the run gains (computed, not measured): shard 2/8's job ran 27-33 s
longer than its file sum, and the e2e shards start at 153-197 s. New last
e2e end ≈ start + refreshed max + 31 s = 1,158 / 1,137 / 1,095 s against
the last other job's end 994 / 1,265 / 897 s, so the span would be 1,158 /
1,265 / 1,095 s against 1,409 / 1,293 / 1,316 s today: -251, -28, -221 s.
The hub job then ends some runs; it is not a row (plan section 6).

## 3. R3 reads

- Lane map, every machine, 09:24:00Z: `lane-map.sh --check
  csi-spl-wui/src/node/test/e2e-shard-weights.txt,csi-spl-wui/tests/unit/e2e-shard-pack.test.mjs,csi-spl-doc/doc/md/perf-round-17-plan.md,csi-spl-doc/doc/md/perf-round-17/editor.md
  --agent c-705` -> exit 4: 0 `owned by`, 3 `unknown:` (c-197 and c-762,
  rotate seats; c-422, the b16-01 row lane), all on the other box.
- 09:29:06Z: `--check csi-spl-orc/src/bash/run/spl-lane-mix.func.sh,csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh`
  -> exit 4, the same 3 `unknown:` lanes, 0 owned.
- Every worktree on this box (364 under the worktree root), 09:24:14Z:
  `git diff --name-only origin/master...HEAD` plus `git status --porcelain`,
  matched against `e2e-shard|run-e2e-tests|10_ci-quality|orc-shard-weights|changed-tests`
  -> 0 hits.
- Briefs changed since 2026-11-17T09:00Z under the dispatch and
  spawn-remote brief dirs: `grep -l 'e2e-shard-weights|e2e-shard-pack|run-e2e-tests'`
  -> 0; `grep -l spl-lane-mix` -> 1, the r60-03 reviewer (refactor round
  34, all its rows on `origin/master`), which only runs the test.
- Spawn queue, 09:20:15Z (`ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`): `1 queued, 1 placing`: the b16-01 row (ask
  4b4da10c; `spl-spawn-fill.func.sh` and its test) and a cnf bug lane (ask
  54c47853; its brief names `spl-tenant-host-provision.func.sh`,
  `spl-tenant-host-reconcile.func.sh`, `pre-push-gate.md`). Neither names a
  p17 row file.
- Refactor round 35 (`refactor-round-35-plan.md` v1.0): r61-01 landed
  (`cebfa7004`, `2e55f493d`); r61-02..06 not landed (`git log origin/master
  --oneline -E --grep='\(r61-'` -> 2 lines, both r61-01). Their files:
  `spl-box-quota.func.sh`, `spl-lane-rotate.func.sh`, `spl-watchdog.func.sh`,
  `install-box-crons.func.sh`, `spl-box-state-backup.func.sh`,
  `external-api-health.func.sh`, `spl-spawn-place.func.sh`,
  `spl-workspace-docs-purge.func.sh`, `prune-docker-images-install-cron.func.sh`,
  `setup-reverse-tunnel.func.sh`, `spl-desk-up.func.sh`, `spl-m3-e2e.func.sh`,
  `spl-desk-install-service.func.sh`, `no-literal-paths.baseline`. No p17
  row file is among them.
- Bug round 16 (`bug-round-16-plan.md` v1.0): b16-01 not landed; its files
  `spl-spawn-fill.func.sh`, `spl-spawn-fill.tst.sh`. Not a p17 row file.
- Perf round 16: both rows on `origin/master` (p16-01 `48b44328b`, p16-02
  `0905076cc`).

## 4. Panel (read 09:26:35Z..09:26:38Z)

- `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=hold`, grok weekly
  99% on both boxes.
- `BOX_PICK_KIND=agy` -> `pick=hold` (no box with a sample below its
  overflow mark).
- `BOX_PICK_KIND=mistral` and `claude` -> `pick=<the other box>` (74% <
  80%).
- `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder (`LEASE_CMD=show`, 09:26:35Z): `c-002`, on the
  other box.
