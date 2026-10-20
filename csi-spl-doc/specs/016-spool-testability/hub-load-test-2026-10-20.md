# Hub load and soak test: what "1000 requests per instance" holds, measured

**Feature**: `016-spool-testability` · **Issue**: SPL-2658 (row SPL-2138, epic SPL-2129)
**Measured**: 2026-10-20 ~03:00–03:25Z · **Tree**: trunk `c89143908` + this change
**Action**: `cd csi-spl-orc && ENV=dev ./run -a do_spl_hub_load_test`

The outside review, item 2 (HUM-10, msg a0d2eafc): "NO LOAD OR SOAK TESTING
in CI. Concurrency default is 1000 requests per instance with a 1-hour
timeout; behavior under sustained load is unproven."

## 1. What existed before

| looked for | command | found |
|---|---|---|
| a load tool (k6, vegeta, hey, locust) | `git grep -liE '\b(k6\|vegeta\|soak\|load[-_ ]test)\b'` | specs and plans only; no driver, no workflow |
| Go benchmarks | `git grep -l 'func Benchmark' -- csi-spl-api` | 9 files in `internal/hub` (encode, fan-out, search, roster): in-process, no network, no Cloud Run |
| WUI perf | `csi-spl-wui/src/node/test/measure-wui-perf.mjs` | page metrics of a generated bundle over CDP; it never loads the hub |
| the hub's own request log | `do_spl_hub_route_latency`, `do_spl_hub_run_metrics` | read-only reports of what traffic did, no traffic of their own |

## 2. The hub's Cloud Run settings (cnf `csi-spl-cnf/csi-spl/all.env.yaml`, dev = prd)

| cnf key | value |
|---|---|
| `env.hub.cloud_run.concurrency` | 1000 |
| `env.hub.cloud_run.timeout_seconds` | 600 (SPL-2252; was 3600 when the review was written) |
| `env.hub.cloud_run.min_instances` / `max_instances` | 1 / 2 |
| `env.hub.cloud_run.cpu` / `memory` | "1" / 512Mi |
| `env.hub.env.SPOOL_HUB_EDGE_WS_CONNS_TOTAL` | 900 (sockets; REST keeps ~100 slots) |
| `env.hub.env.SPOOL_HUB_DB_MAX_CONNS` | 4 per instance (Cloud SQL db-f1-micro, 22 usable) |

dev overrides only `cloud_run.canary.enabled: true`
(`csi-spl-cnf/csi-spl/dev/tf/030-cloud-run-hub.vars.tfvars` lines 14–19 match).

## 3. What clients hit (prd request log)

`ENV=prd ROUTE_HOURS=24 ./run -a do_spl_hub_route_latency`: the read stopped at
its 50000-entry limit, so it covers 2026-10-19T20:44Z..2026-10-20T02:55Z.
REST by count: `GET /v1/pins` 11510 (the BOX route, box-token auth: a member
session reads 401, so it is not in the member set), `GET /v1/wui/revision`
2556, `GET /v1/health` 1983, `PUT /v1/me/reads` 1824, `GET /v1/view/channels`
989, `/v1/view/topics` 647, `/v1/view/issues` 572, `/api/v1/auth/session` 556,
`/v1/view/roster` 528, `/v1/view/flow` 455. Sockets: `/v1/ws` 22573,
`/v1/wui/ws` 884.

`ENV=prd REQ_SINCE=2026-10-19T21:10:00Z REQ_MINUTES=360 ./run -a do_spl_hub_run_metrics`
(n = 360 minutes):

| metric | peak |
|---|---|
| requests a minute | 436 (~7.3 rps); mean 130.7 (~2.2 rps) |
| p99 requests in flight per instance (`max_request_concurrencies`) | **39.98** of 1000 |
| p99 CPU utilisation | 0.05 (per instance), 0.06 summed |
| instances | 3 (a roll's overlap) |

## 4. The action

`do_spl_hub_load_test` (`csi-spl-orc/src/bash/run/spl-hub-load-test.func.sh`)
with its driver `csi-spl-orc/src/bash/scripts/hub-load-test.py` (python3
stdlib only, nothing installed):

- `ENV=dev` only; every other env, prd included, is refused before anything
  is read.
- Open loop: `LOAD_RPS` (default 20, cap 50) for `LOAD_SECONDS` (default 60,
  cap 900), at most `LOAD_CONCURRENCY` in flight (default 10, cap 50). A
  request is timed from when it was due, so a slow hub shows in the
  percentiles instead of slowing the sender.
- One sign-in as a test login (the probe member, or wf 23's probe admin in
  CI), then read-only GETs, round-robin over the member reads of section 3.
  No write path.
- Prints p50 / p95 / p99 / max per path and in total, error rate, status
  counts, then `do_spl_hub_run_metrics` for the run's window (instances,
  in flight, CPU, requests by class).
- Fails when the error rate is over `LOAD_MAX_ERR_PCT` (1 %) or the p95 over
  `LOAD_MAX_P95_MS` (500 ms = ~10 x the dev baseline below; a GitHub-hosted
  runner adds its round trip to europe-north1).
- Test: `csi-spl-orc/src/bash/tests/spl-hub-load-test.tst.sh` (a stub hub on
  loopback: 5xx, slow and refused-sign-in stubs fail it, a healthy one
  passes; the env refusal and the caps hold; the password is never printed).
- Weekly: `.github/workflows/24_hub-load-test.yml`, Mondays 04:41Z on
  `ubuntu-latest` (GitHub-hosted, not the box runners that serve trunk CI),
  dev only, the default load. A red run is the alert, as wf 00.

## 5. The runs on dev (from sat)

### 5.1 Default: 20 rps x 60 s, 10 in flight (start 2026-10-20T03:05:25Z)

The capture kept the run's last 60 lines: the `load:` line below is rebuilt
from the run's settings, and the column header (`path n p50 p95 p99 max err%
status`) is lost; the rows are verbatim.

```
load: 20 rps x 60 s = 1200 GETs, <= 10 in flight, 12 paths, session=yes; fail when err > 1 % or p95 > 400 ms
/v1/wui/revision                                200      9.4     13.9     17.4     31.8   0.00  {"200": 200}
/v1/health                                      200      9.4     15.0     19.5     39.0   0.00  {"200": 200}
/v1/view/channels                               100     48.4     61.2     95.2    100.6   0.00  {"200": 100}
/v1/view/topics                                 100     24.0     35.2     54.2     59.4   0.00  {"200": 100}
/v1/view/flow                                   100     17.2     24.3     56.6     77.7   0.00  {"200": 100}
/v1/view/issues                                 100     19.4     24.9     28.7     42.2   0.00  {"200": 100}
/v1/view/roster                                 100     15.4     23.4     39.1     41.8   0.00  {"200": 100}
/api/v1/auth/session                            100     14.7     20.8     29.1     42.0   0.00  {"200": 100}
/v1/me/reads                                    100     14.6     20.2     40.2     43.9   0.00  {"200": 100}
/version                                        100      9.3     14.6     17.9     33.4   0.00  {"200": 100}
TOTAL                                          1200     14.4     47.8     58.0    100.6   0.00  {"200": 1200}
achieved 20.01 rps over 60.0 s; late (every worker busy) 0
PASS

===== csi-spl hub run metrics: env=dev service=csi-spl-hub-dev (2026-10-20T03:00:25Z .. 2026-10-20T03:09:25Z)
--- container/instance_count (ALIGN_MAX per minutestate by state)
  min       active         idle
03:01         1.00         0.00
03:02         1.00         0.00
03:03         1.00         0.00
03:04         1.00         0.00
03:05         1.00         0.00
03:06         1.00         0.00
03:07         1.00         0.00
03:08         1.00         0.00
--- container/max_request_concurrencies (ALIGN_PERCENTILE_99 per minute by -)
  min    00783-piy
03:01         6.99
03:02        11.98
03:03         1.99
03:04         1.99
03:05         1.99
03:06         1.99
03:07         2.99
03:08         2.99
--- container/cpu/utilizations (ALIGN_PERCENTILE_99 per minute by -)
  min    00783-piy
03:01         0.02
03:02         0.02
03:03         0.01
03:04         0.01
03:05         0.01
03:06         0.01
03:07         0.05
03:08         0.02
--- request_count (ALIGN_SUM per minuteresponse_code_class by response_code_class)
  min          1xx          2xx          3xx          4xx
03:01        12.00       120.00        49.00         0.00
03:02         0.00        10.00         0.00         0.00
03:03         0.00         6.00         0.00         0.00
03:04         3.00         9.00         0.00         1.00
03:05         0.00        14.00         0.00         1.00
03:06         0.00       689.00         0.00         0.00
03:07         3.00       524.00         0.00         0.00
03:08         0.00         5.00         0.00         0.00
[exited with code 0]
```

### 5.2 Soak: 10 rps x 600 s, 10 in flight (start 2026-10-20T03:09:18Z)

The soak started before the default p95 threshold moved from 400 to 500 ms,
so it ran under 400. The default run did too.

```
load: 10 rps x 600 s = 6000 GETs, <= 10 in flight, 12 paths, session=yes; fail when err > 1 % or p95 > 400 ms
path                                              n      p50      p95      p99      max   err%  status
/v1/wui/revision                               1000      9.0     13.4     17.5     35.0   0.00  {"200": 1000}
/v1/health                                     1000      9.8     15.7     20.4     33.4   0.00  {"200": 1000}
/v1/view/channels                               500     47.8     78.3    109.6    157.5   0.00  {"200": 500}
/v1/view/topics                                 500     25.3     38.7     50.2    194.1   0.00  {"200": 500}
/v1/view/flow                                   500     17.6     32.4     48.0    112.7   0.00  {"200": 500}
/v1/view/issues                                 500     19.5     31.3     35.7     60.4   0.00  {"200": 500}
/v1/view/roster                                 500     14.5     22.4     26.6     49.9   0.00  {"200": 500}
/api/v1/auth/session                            500     14.8     21.5     27.4     34.0   0.00  {"200": 500}
/v1/me/reads                                    500     14.5     21.5     27.3     36.8   0.00  {"200": 500}
/version                                        500      9.6     15.4     18.6     31.3   0.00  {"200": 500}
TOTAL                                          6000     14.3     47.2     60.5    194.1   0.00  {"200": 6000}
achieved 10.0 rps over 599.9 s; late (every worker busy) 0
PASS

===== csi-spl hub run metrics: env=dev service=csi-spl-hub-dev (2026-10-20T03:04:18Z .. 2026-10-20T03:22:18Z)
--- container/instance_count (ALIGN_MAX per minutestate by state)
  min       active         idle
03:05         1.00         0.00
03:06         1.00         0.00
03:07         1.00         0.00
03:08         1.00         0.00
03:09         1.00         0.00
03:10         1.00         0.00
03:11         1.00         0.00
03:12         1.00         0.00
03:13         1.00         0.00
03:14         1.00         0.00
03:15         2.00         0.00
03:16         2.00         0.00
03:17         2.00         0.00
03:18         2.00         0.00
03:19         2.00         0.00
03:20         2.00         0.00
03:21         2.00         0.00
--- container/max_request_concurrencies (ALIGN_PERCENTILE_99 per minute by -)
  min    00783-piy    00786-vux
03:05         1.99            -
03:06         1.99            -
03:07         2.99            -
03:08         2.99            -
03:09         1.99            -
03:10         1.99            -
03:11         2.99            -
03:12         2.99            -
03:13         2.99            -
03:14         2.99            -
03:15         1.99         2.99
03:16         2.99         1.99
03:17         2.99         1.99
03:18         2.99         1.99
03:19         2.99         1.99
03:20         2.99         1.99
03:21         1.99         1.99
--- container/cpu/utilizations (ALIGN_PERCENTILE_99 per minute by -)
  min    00783-piy    00786-vux
03:05         0.01            -
03:06         0.01            -
03:07         0.05            -
03:08         0.02            -
03:09         0.01            -
03:10         0.01            -
03:11         0.04            -
03:12         0.04            -
03:13         0.04            -
03:14         0.04            -
03:15         0.04         0.03
03:16         0.03         0.01
03:17         0.03         0.01
03:18         0.04         0.01
03:19         0.03         0.01
03:20         0.03         0.01
03:21         0.01         0.01
--- request_count (ALIGN_SUM per minuteresponse_code_class by response_code_class)
  min          1xx          2xx          3xx          4xx
03:05         0.00        14.00         0.00         1.00
03:06         0.00       689.00         0.00         0.00
03:07         3.00       524.00         0.00         0.00
03:08         0.00         5.00         0.00         0.00
03:09         0.00         7.00         0.00         0.00
03:10         3.00       423.00         0.00         0.00
03:11         0.00       607.00         0.00         0.00
03:12         0.00       606.00         0.00         0.00
03:13         3.00       606.00         0.00         0.00
03:14         0.00       606.00         0.00         0.00
03:15         0.00       612.00         0.00         0.00
03:16         3.00       612.00         0.00         0.00
03:17         0.00       610.00         0.00         0.00
03:18         0.00       608.00         0.00         0.00
03:19         3.00       612.00         0.00         0.00
03:20         0.00       194.00         0.00         0.00
03:21         0.00        12.00         0.00         0.00
```

## 6. What the numbers say about "1000 requests per instance"

Measured, n = 2 runs (7200 GETs) from sat, plus prd's own 6 h:

- **Errors: 0 of 7200**, every answer a 200. The soak ran through a dev
  revision roll (wf 20 run 39361314886, canary on dev: `00786-vux` serves
  from 03:15) and lost no request.
- **Latency is flat over time**: p95 47.8 ms for 60 s at 20 rps, 47.2 ms for
  600 s at 10 rps; p99 58.0 / 60.5 ms. Nothing drifted over the 10 minutes.
- **One instance carried it**: no scale-out at 20 rps (the second instance at
  03:15 is the new revision of the roll, not load). p99 requests in flight
  per instance stayed at 2–3, p99 CPU 0.01–0.05 of the 1 vCPU.
- **prd's real peak is 40 in flight per instance**, 4 % of the 1000; its
  busiest minute is ~7.3 rps, so the dev default (20 rps) is ~3x prd's peak.

What this does **not** show: an instance holding 1000 requests. The action's
hard caps (50 rps, 50 in flight) keep it far below that on the shared dev
hub, and it loads REST only. Of the 1000 slots, up to 900 are sockets
(`SPOOL_HUB_EDGE_WS_CONNS_TOTAL`); a socket holds a slot for its whole life
(5 min, `SPOOL_HUB_WS_MAX_LIFE`), and sockets are the traffic that comes
near the number (`/v1/ws` 22573 upgrades in prd's 6 h above). A socket soak
(many held `/v1/ws` connections) is a separate row.

Not measured, so not claimed: where REST stops scaling on one instance. The
pool of 4 DB connections per instance (`SPOOL_HUB_DB_MAX_CONNS`) and the
1 vCPU are the candidates; the 5 % CPU at 20 rps says nothing about the
curve above 20 rps.

No concurrency change follows from these numbers. Changing
`hub.cloud_run.concurrency` is an owner-visible cnf row of its own, not part
of this test.
