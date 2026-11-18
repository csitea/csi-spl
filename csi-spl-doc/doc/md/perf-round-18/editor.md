# Perf round 18: editor seat (c-856, claude)

Issue SPL-5903, epic SPL-2402, spec `csi-spl-doc/specs/027-spool-performance`,
round topic `5535ab88`; report to the dispatch lease holder on task
`dispatch-perf-r18`. The plan: [perf-round-18-plan.md](../perf-round-18-plan.md).

## 1. Done

- STEP 0: developer guide acked (blob `8b1916cd`), fetched.
- One sha for every baseline: **`897e67e13`** (`origin/master` at 15:10Z,
  2026-11-18). The CI numbers come from runs on older heads (2.1); every file
  the rows read is the same on those heads and on `897e67e13`:
  `git log --oneline 17f9cc2d2..897e67e13 -- .github/workflows/10_ci-quality.yml
  csi-spl-api/src/bash/tests/run-all-tests.sh
  csi-spl-api/src/bash/tests/cli-cross-build.tst.sh
  csi-spl-api/src/bash/tests/build-stripped.tst.sh
  csi-spl-orc/src/bash/scripts/ci-disk-guard.sh` -> 0 lines.
- Slug and window (rulebook 5.3), 15:10:21Z on `897e67e13`:
  `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(p17-plan')`
  -> `W=2026-11-18T11:38:14+01:00`;
  `git log origin/master --since="$W" --oneline -E --grep='\(p18-' | wc -l`
  -> `0`; `git ls-remote origin 'refs/heads/review/p18-*'
  'refs/heads/wip/*p18*' 'refs/heads/*-p18-*' | wc -l` -> `0`; no
  `perf-round-18*` path under `csi-spl-doc/doc/md` (`git ls-tree --name-only
  origin/master csi-spl-doc/doc/md/ | grep -E 'perf-round-1[78]'` -> the p17
  plan and its seat dir only).
- Floor, the rulebook 4.4 command on `897e67e13`, n=1:
  `perf 27 refactor 93 perf-share 22.5% floor-met`.
- Retro: there is no `perf-round-17-retro.md` on `897e67e13` (same
  `ls-tree` read). This seat does not invent its content.

## 2. Measurements

### 2.1 wf 10 after p17-01: the hub job is now the slowest job

The 8 newest green `10_ci-quality.yml` runs on `master` created after p17-01
landed (`b97a764ff`, 11:09Z) that ran the gate (`gh run list --workflow
10_ci-quality.yml --branch master --status success --limit 20`; two runs
that ran no gate job, 44306055240 and 44325586072, left out), heads `17f9cc2d2` .. `a58cc3434`.
`gh run view <id> --json jobs`, per job `completedAt - startedAt`, success
only (top 5 by mean):

| job | mean s | min | max | n |
|---|---|---|---|---|
| hub: gofmt, go vet, go test, smoke, GCS gate | **1,040** | 872 | 1,192 | 8 |
| wui e2e 2/8 | 998 | 901 | 1,068 | 7 |
| wui e2e 6/8 | 951 | 863 | 1,000 | 7 |
| wui e2e 5/8 | 947 | 895 | 1,043 | 7 |
| wui e2e 1/8 | 942 | 832 | 1,040 | 7 |

p17-01 worked: the e2e shard means now lie in 876..998 s (p17 editor 2.6:
2/8 was 1,168 s). The e2e path is `wui-generate` (mean 151 s, n=3) then a
shard (mean 942 s, n=24), so in a run that runs e2e the hub job is level
with it.

### 2.2 How often the hub job ends the run

The last 100 green wf 10 runs on `master` created since 2026-11-17T00:00Z
(`gh run list ... --limit 100`), `gh run view` each (3 answered HTTP 502 and
are left out); kept: a span of 300 s or more and a hub-suite job, **73 runs**
(`span.py`, scratch; n=1 read, deterministic for those runs). The hub-suite
job ends the run in **16 of 73**; 13 of the 16 ran no e2e (25 of the 73 ran
no e2e). Its margin over the next job: 6, 23, 45, 47, 62, 80, 119, 123, 147,
152, 161, 170, 184, 208, 215, 244 s.

### 2.3 Inside the hub job: cold Go builds

The step `run-all-tests.sh` is 1,016 s of the job's 1,040 s (mean, n=8). The
job has no Go build cache step (`hub-suite`, `10_ci-quality.yml:263-347`):
its hosted runner starts with an empty `GOCACHE`. `hub-pg` has one
(`:399-481`, key `go-race-pg-v2-...`). Section times from each job's log
(`gh api repos/<owner>/<repo>/actions/jobs/<id>/logs`, the gap between the
suite's own lines; `sect.py`, scratch), seconds, n=8:

| job id | head | build-stripped | build-warm-mod-cache | linux/amd64 | linux/arm64 | darwin/amd64 | darwin/arm64 | go vet | go test -race (+cover) | suite |
|---|---|---|---|---|---|---|---|---|---|---|
| 134767998959 | `17f9cc2d2` | 82 | 83 | 5 | 74 | 72 | 74 | 104 | 422 | 1,092 |
| 134778544231 | `e9e76cca1` | 79 | 81 | 5 | 74 | 73 | 76 | 106 | 417 | 1,082 |
| 134778678787 | `e9e76cca1` | 62 | 65 | 5 | 60 | 59 | 60 | 82 | 366 | 897 |
| 134789753950 | `3a7ae872b` | 76 | 80 | 5 | 73 | 73 | 75 | 102 | 415 | 1,065 |
| 134810970105 | `04ca1d897` | 78 | 82 | 5 | 76 | 74 | 75 | 105 | 419 | 1,084 |
| 134845559586 | `04ca1d897` | 53 | 55 | 3 | 51 | 51 | 52 | 72 | 337 | 795 |
| 134863988687 | `e1c6f870e` | 51 | 55 | 2 | 50 | 49 | 51 | 69 | 330 | 780 |
| 134875409529 | `a58cc3434` | 58 | 58 | 5 | 52 | 53 | 54 | 73 | 331 | 805 |

The in-run control: `cli-cross-build.tst.sh` builds `./cmd/spool` for 4
targets right after `build-stripped.tst.sh` built it for the host. The host
target (linux/amd64), whose packages are already in `GOCACHE`, takes **2..5
s**; each of the 3 other targets, cold, **49..76 s**. That is the cost of a
cold build of the spool binary, on the same runner, in the same minute.
`build-warm-mod-cache.tst.sh` runs on a throwaway `GOCACHE` by design
(`:40`) and gains nothing from a cache. `go test -race` includes the test
run itself (`internal/hub` alone 184.7 s in job 134875409529), so only its
compile part is cache-bound.

### 2.4 The same builds cold and warm on this box

`gocache-ab.sh <module> <out>` (scratch): on `897e67e13`, as the push user,
go1.26.10, `GOFLAGS="-mod=mod -trimpath" GOPROXY=off`, a fresh empty
`GOCACHE` per round, each step cold then warm (bash `time`, `TIMEFORMAT="%R
%U %S"`: wall user sys, seconds):

| round | arm | 1-min load | `go build` spool linux/arm64 | `go vet ./...` | `go test -race -count=1 -run '^$' -coverprofile ./...` (build only) |
|---|---|---|---|---|---|
| 1 | cold | 17.2 | 69.4 (341.0 / 40.6) | 100.3 (488.0 / 58.3) | 273.1 (861.8 / 85.6) |
| 1 | warm | 31.5 | 4.4 (5.2 / 1.2) | 1.9 (2.3 / 0.7) | 25.2 (88.2 / 12.4) |
| 2 | cold | 40.3 | 108.0 (356.2 / 41.1) | 139.7 (511.7 / 62.2) | 360.5 (938.6 / 87.8) |
| 2 | warm | 36.7 | 6.5 (6.2 / 0.9) | 2.4 (2.2 / 0.7) | 17.6 (83.9 / 11.5) |

n=2 per arm. The warm arm reuses the cache of the same sources; a CI
restore from an older entry (a restore-key hit after a Go change) recompiles
the changed packages and what imports them, so CI's warm share is at most
this one.

The box is shared with other lanes (its 1-minute load is named per round),
so these times are noisier than CI's; the ratio cold : warm is what this
section shows.

### 2.5 hub-pg frees disk it does not need

`hub-pg`'s step "Free disk on a hosted runner" (`10_ci-quality.yml:378-384`,
SPL-4777) removes .NET, Android, GHC and CodeQL before the cache restore.
Its time, from `gh api .../jobs/<id>` step times, the same 8 runs: mean
**100 s** (58..145, n=8), of a job mean of 724 s (559..962). Its own `df`
and the restore lines, in each of the 8 logs:

| job id | head | avail before the free-up | after | at the restore | cache (compressed) | `du -sh` GOCACHE |
|---|---|---|---|---|---|---|
| 134767999121 | `17f9cc2d2` | 88G | 110G | 108G | ~410 MB | 2.3G |
| 134778544753 | `e9e76cca1` | 88G | 110G | 108G | ~410 MB | 2.3G |
| 134778678729 | `e9e76cca1` | 88G | 110G | 108G | ~410 MB | 2.3G |
| 134789753688 | `3a7ae872b` | 88G | 110G | 108G | ~410 MB | 2.2G |
| 134810970002 | `04ca1d897` | 88G | 110G | 108G | ~409 MB | 2.2G |
| 134845559611 | `04ca1d897` | 88G | 110G | 108G | ~409 MB | 2.2G |
| 134863988929 | `e1c6f870e` | 88G | 110G | 108G | ~409 MB | 2.2G |
| 134875409507 | `a58cc3434` | 88G | 110G | 108G | ~409 MB | 2.2G |

The step was added when the race cache had grown to 6.2 GB compressed
(2026-11-04, the step's comment); the trim step and the `v2` key since keep
it at ~410 MB, 2.2 GB unpacked. The disk guard needs 10 GB
(`CI_DISK_NEED_GB`). 88 GB free before the step, n=8: the free-up is not
needed at today's size. `hub-pg` (mean 724 s) ends none of the 8 runs, so
this is the job's own time and runner time, not the run's span.

### 2.6 The e2e files: the long tail

The per-file lines of the 8 e2e shard jobs of run 44324913160
(`a58cc3434`): 367 files, sum 7,237 s, min 2, p10 3, median 11, p90 50, max
243 s. Top: `monitoring-costs.test.mjs` 243, `section-strip-scroll-hide`
223, `phone-back-matrix` 162, `add-to-note` 138, `topic-moved-link` 134.
No fixed per-file cost (min 2 s). A 200 s cut in one file is ~25 s a shard
once the weights follow (computed, not measured). Not probed further here.

## 3. R3 reads

- Lane map, every machine, 15:07:19Z: `lane-map.sh --check
  .github/workflows/10_ci-quality.yml,csi-spl-doc/doc/md/perf-round-18-plan.md,csi-spl-doc/doc/md/perf-round-18/editor.md
  --agent c-856` -> `free`, rc 0.
- Spawn queue, 15:07:33Z (`ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`): 8 queued, 1 placing: two bug rows (a WUI todo-url
  state row, a cross-workspace prio row), the bug round 18 planner (ask
  ddda5638), and 5 feature or doc lanes. None names `10_ci-quality.yml`.
- Briefs changed since 2026-11-17T15:00Z under the dispatch and spawn-remote
  brief dirs, 15:07:47Z: `grep -lE '10_ci-quality|csi-spl-api/src/bash/tests/run-all-tests'`
  -> 4 briefs (SPL-450's gate check, spec 169 T15 twice, a supply-chain CI
  bump); each only RUNS `run-all-tests.sh`, none edits the workflow.
- Refactor round 62 (`refactor-round-62-plan.md` v1.0): r62-01 landed
  (`b36b20577`); r62-02 not landed (`git log origin/master --oneline -E
  --grep='\(r62-'` -> r62-01 and the plan commits). Its files:
  `spl-spawn-place.func.sh`, `spl-spawn-after.tst.sh`,
  `spl-token-burn-collect.tst.sh`, `no-literal-paths.*`. No p18 row file.
- Bug round 18: planner queued (ask ddda5638), no plan on `897e67e13`. The
  live bug and doc lanes the brief names (SPL-5897, SPL-5901, SPL-5889,
  SPL-5884, SPL-5882) hold no p18 row file (the lane map above).

## 4. Panel (read 15:11:55Z)

- `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=hold`, grok weekly
  99% on both boxes.
- `BOX_PICK_KIND=agy` -> `pick=hold` (no box below its overflow mark; one
  box has no agy CLI).
- `BOX_PICK_KIND=mistral` -> `pick=<the other box>` (30% < 70%).
- `BOX_PICK_KIND=claude` -> `pick=hold` (one box 97% weekly, the other over
  its overflow mark).
- `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder (`LEASE_CMD=show`): `c-002`.

## 5. State

- v0.1 `2d644b9b6` on `review/c002-perf-round-18-planner` went to the holder
  c-002 at 15:27:34Z (msg 5f2a908e); c-002 queued the mistral seat (ask
  bf65f3d7, msg 357ead20).
- m-542 PASS on `2d644b9b6`, W none, N1..N5 (msg c45e2426, seat
  `f1f75bf51`).
- v1.0 = the rows of v0.1 unchanged, with the seat file and N1..N5 folded
  in (holder msg db5fb04a), pushed on `review/c002-perf-round-18-planner`;
  m-542 signs that sha, then it lands on `master` on the holder's GO, and the
  holder queues p18-01 (batch 1) and, after it lands, p18-02 (batch 2).
