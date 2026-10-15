# Incident 2026-10-15: prd hub "no available instance", 07:31-07:36Z

> Generated from qto doc `531a3c05-6dd3-4d88-8c01-e771c06e0ac5`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Issue SPL-1981. Owner context: t1 topic 67754bb7 (max 2 instances, DB pool 4,
picked 2026-10-11).

<a id="ws-doc-1691bc59-0242-47f3-ba65-e065ac6a2d49"></a>
## 1. What happened

prd answered 429 "Rate exceeded." from 07:32 to 07:36Z. All requests ran on
revision `csi-spl-hub-prd-00714-ksm`, and no deploy or roll happened in the
window. The watchdog fenced both boxes (07:35:45Z / 07:35:50Z).

<a id="ws-doc-d94fe35f-0d93-4a4e-94e2-0de26077bdbb"></a>
## 2. What it was not

Measured with `ENV=prd REQ_SINCE=2026-10-15T07:10:00Z REQ_MINUTES=35`, tree
`befa5708f`, one window (n=1):

| candidate | measured | verdict |
|---|---|---|
| real traffic | 82..197 requests a minute during the 429s against 94..336 in the 20 min before it, and 7767 requests that hour against 7791 (05:00) and 9282 (09:00). Even the uptime checks got 429. | no |
| reconnect storm | WebSocket upgrades went from ~50 to 89..145 a minute, but only AFTER the 429s began. That rise is the boxes' backoff redials, not the trigger. | no, an effect |
| slow handler / DB | `container/max_request_concurrencies` p99 14..44 per instance against a limit of 1000; CPU p99 1..5 %; the slowest non-socket request in 07:10..07:40 took 0.52 s; no warn or error lines. | no |

`./run -a do_spl_hub_request_minutes` gives the per-minute table and the
callers. `./run -a do_spl_hub_run_metrics` gives instances, requests in
flight, CPU and response classes. Both are in csi-spl-orc and read-only.

<a id="ws-doc-165bd102-06f7-4728-b007-152481d6f15d"></a>
## 3. What it was: retired instances holding both max_instances slots

Cloud Run replaces hub instances by itself every ~20 min. A retired instance
gets no new requests but stays alive, and keeps counting against
`max_instances`, until its last open request ends. Box and browser
WebSockets had no end other than the 3600 s request timeout.

| instance | last request | SIGTERM ("hub draining") | held by |
|---|---|---|---|
| ...e3425a1f00 (normal) | 06:19:13 | 06:19:42 | its sockets closed within 29 s |
| ...69f9cffe89 | 07:22:45 | 07:41:12 | 11 box sockets + 1 browser socket, each 3601 s (the timeout) |
| ...f9ac3b1067 | 07:31:39 | 07:36:22 | open sockets |
| ...ac14e68338 (replacement) | started 07:31:51 | 07:31:58 | stopped: over max 2 |
| ...527e76d1b8 (replacement) | started 07:33:34 | 07:33:52 | stopped: over max 2 |

From 07:31:39 to 07:36:22, both slots were held by retired instances. Cloud
Run stopped every replacement within 7..17 s, so no instance took requests
(`instance_count` active = 2 throughout). The 07:22..07:24 blip (9 x 429) was
the same mechanism, with one slot.

<a id="ws-doc-e58cdefa-1569-4712-b2c6-940a89336b70"></a>
## 4. The fix: a hub-side socket max life

`SPOOL_HUB_WS_MAX_LIFE` (default `5m`, `0` = off) closes every `/v1/ws` and
`/v1/wui/ws` socket with close code 1012 and reason `max_life`. The close
comes after the max life minus up to a fifth (jittered). The box client
and the browser already redial on any close except 4409. Their redial lands
on a live instance, so a retired instance now holds its slot for at most
~5 min, not 60. With it, ...69f9cffe89 would have gone by ~07:27:45, and the
07:31:51 replacement would have had a slot.

The planned close must not flap presence. It is handled as a roll: no
"left" stamp. A box's offline frame, or a browser's online -1, waits 15 s
and is skipped when the peer has come back on that instance.

Cost: one re-hello per box per ~5 min (~30 box sockets, so ~6 hellos a
minute against the ~50 a minute the CLIs already make). A browser tab also
makes one catch-up read per ~5 min.

Tests: `internal/hub/ws_maxlife_test.go`. The control (no cap) leaves the
socket open, and both tests fail with the cap disarmed.

<a id="ws-doc-a0a7f4d5-0420-48dd-a2bc-b4adccd5f666"></a>
## 5. Capacity, for the owner (no change made)

The fix bounds the risk; it does not remove it. Two Cloud Run retirements
within 5 min would still leave no slot. Options for the dispatcher to put to
the owner (connections budget from topic 67754bb7: prd DB limit 22, pool 4
per instance):

1. Keep max 2 with this fix (8 of 22 connections). Watch
   `do_spl_hub_request_minutes` for any further burst.
2. max 3 (12 of 22 connections): a third slot absorbs one retired instance
   with no wait.
3. Lower Cloud Run `timeout_seconds` 3600 to e.g. 600. This is a platform
   cap with the same effect as the max life, but it also cuts any long REST
   call.
