# Performance budgets

**Status: Implemented.** The harness is `perf-budget.py`. The action is
`do_spl_perf_budget`. The ceilings are `perf-budgets.json` in this directory.

## What is measured

| key | what it is |
|---|---|
| `ci_initial_gzip_kb` | Initial JS of a mock `nuxt generate`, gzip level 6, summed. The chunks are the ones `200.html` names with `src` or `modulepreload`. A file that is only a dynamic import is not included. Same chunk set as `csi-spl-wui/src/node/test/bundle-size.mjs`. |
| `dev_initial_gzip_kb` | The same sum for the document served by the env's WUI host. |
| first-load transfer | Recorded, not gated. Wall time to GET that document and then those chunks, 8 at a time, each on a new connection. That tail is this box's resolver, not a budget. |
| `view_me_p95_ms` | `GET /v1/view/me` reused-connection TTFB (`time_starttransfer`) |
| `view_channels_p95_ms` | `GET /v1/view/channels`, the same |
| `view_roster_p95_ms` | `GET /v1/view/roster`, the same |

The three view routes are the signed-in shell's first view reads (`access.ts`
loads `me`, `shell-bootstrap.mjs` loads channels and the roster). One sign-in,
then `PERF_N` samples (default 12) after `PERF_WARMUP` discards (default 1).
Each sample opens its own connection. p50 is recorded and is not a ceiling.
p95 is interpolated, so it is not the maximum of a short run.

## Ceilings

A value greater than its ceiling exits 1. A required value that was not
measured exits 1. A value equal to its ceiling passes.

The CI gzip ceiling is 222 KB, about 11 KB above the 211.4 KB generate measured for the Issues screen (commit 33891193, quality run 36226437490, n=1). The dev gzip ceiling is 1.10 times the live measurement, rounded up to 0.1 KB. View ceilings are reused-connection TTFB: the greater of twice the p95 and 1.25 times the slowest sample, rounded up. A new connection's DNS time is recorded on each sample and is not the fail line.

## Basis

Measured 2026-09-25T18:38:45Z. Harness tree `bbe04d263a6d` (the script was not
committed yet). Dev hub `0.5.7` commit `019d9e88ec9f`. Dev WUI commit
`f65d9e108b95`. Mock generate, n=1. At `bbe04d26` this script read 218.8 KB over 23 chunks
(`bundle-size.mjs` 219.5 KB). On the trunk this change rebases onto, after
the WUI commits that landed during the measurement, the same generate reads
198.6 KB over 21 chunks (`bundle-size.mjs` 199.2 KB). The two zlib builds
differ by under 1 KB. The ceiling applies to this script's sum on that newer
generate. The highlight runtime was not in the initial set.

| metric | basis | ceiling |
|---|---:|---:|
| ci initial gzip KB | 198.6 | 210 |
| ci initial gzip KB after the Issues screen | 211.4 | 222 |
| dev initial gzip KB | 219.5 | 241.5 |
| view me p95 ms | 1178.4 | 2357 |
| view channels p95 ms | 1149.7 | 2300 |
| view roster p95 ms | 1316.5 | 2633 |

Reused-connection view TTFB, n=12, warmup=1, 2026-09-25T19:50:48Z, hub `143229e55b28`. Scored samples had `time_namelookup` 0 and `time_connect` 0. p50/p95 ms: me 499.4/1178.4, channels 759.6/1149.7, roster 725.6/1316.5. The earlier new-connection p95s (me 3752, channels 927, roster 788) are not the gate. First-load on that same run was p50 22758 / p95 49980 ms and is not gated.

## Where it runs

- Dev (or prd) numbers: `ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_perf_budget` from `csi-spl-orc`. Dry run makes no request. `PERF_REQUIRE=none` records without comparing.
- CI: workflow 10, job `wui-e2e`, after the mock `nuxt generate`, runs `perf-budget.py bundle` and fails when `ci_initial_gzip_kb` is over 222. The quality gate stays offline, so the live timings are not part of that job.

## Control

`bash csi-spl-orc/src/bash/tests/perf-budget.tst.sh`. A report 0.1 KB over its
ceiling exits 1. An empty initial set exits 1 under a huge ceiling. A view
read that answers 500 exits non-zero and is not reported as a p95. A ceiling
of -1 against a successful stub measurement exits 1.

<!-- version: 0.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:40:26Z -->
