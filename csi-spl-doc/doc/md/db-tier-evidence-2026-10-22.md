# DB tier evidence: the 10-20 and 10-22 prd hub stalls (SPL-2880)

Epic SPL-2364, spec 146. Owner (t1 bd710173, msg 21a65d81): "well prove it
first, than we will increase". This page is the proof asked for. It changes
nothing: prd was read only, and the one load ran on dev.

## 1. Verdict

**A, our load on a too-small instance, is most of it; B, the platform's
storage, is not supported by any number here.** The share is not something
these metrics can split exactly. A is shown three ways and B by none:

1. In both stalls `cpu/utilization` sits flat at the shared core's ceiling
   (0.23..0.27 every minute) while the backends waiting on CPU go from 1..2 to
   5..11 and commits fall from 25..30/s to 4..16/s. Across all five prd windows
   the highest minute is 0.27: the instance cannot use more.
2. The instance swaps all the time and the stall windows swap 3..10x more:
   swap-in p50 150..234 pages/s against 22..66 on quiet days, with 120..340 MB
   in swap. `memory/utilization` reads 1.0 in every window, quiet or not (dev
   too), so it does not tell a stall from a quiet hour.
3. On dev, the same tier, a read-only CPU-and-memory load with **zero blocks
   read from disk** (its sorts spilled, so disk writes rose to 11/s, the level
   prd runs at on a quiet day with a 0.01 s sync) reproduced the signature in 2 minutes: CPU pinned at 0.25
   after one minute's burst to 0.65, CPU waits p50 6 (max 12), swap-in 0.6 ->
   74 pages/s, a 27-buffer checkpoint took 0.995 s to sync (quiet: 0.002..0.005
   s), 4 statement timeouts.

Against B: disk write ops during the stalls (p50 7..10/s) match the quiet
days (8..10/s); no Cloud SQL or Persistent Disk incident is listed for
europe-north1 in either window (section 4); and on 10-22 the CPU waits rose at
09:44, four minutes before the first slow checkpoint sync (09:48). A slow fsync
with the same write volume follows from a checkpointer that does not get the
CPU, and the dev run made one at a write rate prd handles every quiet day. A storage hiccup
underneath cannot be excluded: Cloud SQL exposes no disk latency series in the
set read here.

## 2. prd, stall windows against quiet ones

Read with `do_spl_db_window` (step 60 s, prd, read-only). n = minutes with a
point; Postgres series miss minutes during the stalls (the metrics agent is
starved too).

| series (p50, max) | 10-20 08:45-09:20 stall | 10-22 09:20-10:15 stall | 10-22 07:00-07:55 quiet | 10-21 09:20-10:15 quiet | 10-19 09:20-10:15 quiet |
|---|---|---|---|---|---|
| cpu/utilization | 0.251, 0.270 | 0.240, 0.261 | 0.170, 0.252 | 0.147, 0.228 | 0.164, 0.225 |
| backends waiting on CPU | 5, 6 (n=17) | 3, 11 (n=50) | 2, 2 | 1, 3 | 1, 2 |
| swap-in pages/s | 149, 267 | 234, 365 | 35, 351 | 22, 72 | 66, 225 |
| swap used MB | 125, 154 | 255, 341 | 196, 245 | 165, 204 | 183, 212 |
| commits/s | 16, 21 (n=16) | 25, 103 (n=50) | 22, 37 | 21, 38 | 22, 39 |
| backends | 9, 15 (n=18) | 13, 19 | 13, 14 | 7, 8 | 8, 9 |
| disk write ops/s | 7.3, 12 | 9.9, 21 | 8.8, 17 | 7.9, 13 | 9.9, 15 |
| disk read ops/s | 1.7, 3.7 | 1.9, 6.3 | 0.8, 32 | 0.7, 8.8 | 1.4, 13 |
| checkpoints n | 6 | 11 | 11 | 11 | 11 |
| checkpoint sync s (p50, max) | 0.272, 1.251 | 0.258, 2.255 | 0.010, 0.029 | 0.008, 0.018 | 0.010, 0.022 |
| checkpoint longest file sync s (max) | 0.495 | 0.506 | 0.004 | 0.006 | 0.004 |
| statement timeouts | 53 | 37 | 0 | 0 | 0 |

`cpu/reserved_cores` reads 1.0 in every window; it is not the shared core's
real share, which the flat 0.25 line is.

10-22 minute by minute (from the saved reads): 09:21-09:43 swap-in was
already 150..320 pages/s with CPU 0.17..0.26, CPU waits 1..3, commits
25..31/s and checkpoint sync 0.013..0.036 s: no stall. From 09:44 CPU stays at
0.23..0.26 every minute, CPU waits jump to 4..10, commits drop to 4..21/s
until 09:56,
statement timeouts start, and the checkpoint syncs read 1.016 (09:48), 0.503,
1.252, 2.255 s. Disk write ops stay at 7..16/s throughout.

## 3. dev, the bounded load

`do_spl_db_load_probe`, ENV=dev, 8 clients, 10 min (13:55:05-14:05:16Z),
read-only (BEGIN READ ONLY, default_transaction_read_only=on), one statement:
messages grouped per topic, bodies aggregated and sorted. pgbench: 3.7 tps
(1.7 s) in minute 1, then 0.2..0.5 tps (9..24 s) to the end; 421 transactions;
4 of 8 clients cancelled by the 30 s statement timeout.

| series (p50, max) | dev 13:43-13:54 quiet | dev 13:55-14:06 load |
|---|---|---|
| cpu/utilization | 0.096, 0.127 | 0.255, 0.652 (one minute, then 0.24..0.26) |
| backends waiting on CPU | 1, 2 | 6, 12 |
| swap-in pages/s | 0.6, 8.6 | 74, 215 |
| blocks read from disk /s | 0, 0 | 0, 0 |
| disk write ops/s | 2.8, 3.9 | 11, 70 |
| checkpoint sync s (max) | 0.005 (23 buffers) | 0.995 (27 buffers) |
| statement timeouts | 0 | 4 |

The bigger-tier clone run (brief step 3) was NOT done: it needs the owner's
go for its cost, and none was given to this lane.

## 4. GCP status history

`https://status.cloud.google.com/incidents.json`, read 2026-10-22 (8
incidents in the feed): one incident in range, 2026-10-20 06:00-12:10Z,
"Multiple services were experiencing issues in the europe-west2 region",
Cloud SQL and Persistent Disk among them, location **europe-west2 only**. For
europe-north1: none listed, on 10-20 or on 10-22.

## 5. The tier the numbers support

The stall needs two things fixed: a CPU share above 0.25 vCPU and enough
memory that the instance stops swapping (prd runs 120..340 MB in swap at
13..19 backends). That is a dedicated-core tier: `db-custom-1-3840` (1 vCPU,
3.75 GB) is the smallest, and the one spec 027 D5 named. `db-g1-small`
(shared, 1.7 GB) would end most of the swapping but stays a capped shared core
outside the Cloud SQL SLA.

Cost, monthly at 730 h, compute only (storage and backups unchanged):

- `db-f1-micro` today: $0.0105/h, about $7.7 (cloud.google.com/sql/pricing,
  as quoted in spec 072 research 19-20.review-g-177).
- `db-g1-small`: $0.035/h, about $25.6 (cloud.google.com/sql/pricing as
  indexed by a web search on 2026-10-22; the region of that rate is not shown).
- `db-custom-1-3840`: NOT read from the pricing page here (the page renders
  its table client-side and no read of it succeeded). The Enterprise list
  rates as remembered, unchecked: $0.0413 per vCPU-h + $0.0070 per GB-h ->
  $0.0676/h, about $49 a month; prd's REGIONAL availability bills the
  instance twice, about $99. Read the real europe-north1 rate on the pricing
  page or the calculator before the decision.

## 6. How to re-read it

```
cd csi-spl-orc
ENV=prd DBW_SINCE=2026-10-22T09:20:00Z DBW_MINUTES=55 ./run -a do_spl_db_window
ENV=dev DBL_MINUTES=10 DBL_CLIENTS=8 DRY_RUN=0 ./run -a do_spl_db_load_probe
```

`do_spl_db_window` prints, per Cloud Monitoring series, n / min / p50 / mean /
p95 / max over the window, then the Postgres log's checkpoints and statement
timeouts; `DBW_JSON_OUT=<dir>` keeps the raw reads, `DBW_JSON_IN=<dir>`
re-summarises them with no cloud call. `do_spl_db_load_probe` runs on dev only,
1..15 min, 1..12 clients, a dry run unless `DRY_RUN=0`.
