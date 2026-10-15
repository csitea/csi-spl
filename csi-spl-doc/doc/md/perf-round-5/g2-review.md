# Perf round 5 — seat g2 (grok, reviewer)

> Generated from qto doc `cd307010-2513-4ef8-ab82-ed1ca453f885`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Seat `g2` reviews `c1` (claude), `m1` (mistral) and `a1` (agy). Doc only.
Commands below ran on tree `7ad80c2eb` from the repo root, n=1 each, read-only.
`issues.vue` lines were re-read on `origin/master` `fda858ca5`: `46b4bc2b4`
moved them, and `git diff --stat 7ad80c2eb fda858ca5` of the other cited
paths is empty. This seat did not re-query production. Production numbers are the proposers' and are cited as
theirs. c1's window is `2026-10-11T16:53:47Z .. 2026-10-12T16:53:47Z`
(`statements=59 calls=3561168`). g1's window is the cross-check c1 already
printed.

Short names: `A=csi-spl-api/src/go/spool-hub-api/internal`,
`R=csi-spl-rdb/src/sql/postgres/spool-hub`.

An action is AGREE when the site still exists, the work is not already
landed or superseded, and the gain is measured or the row carries a gate
that drops it when the measurement says no.

<a id="ws-doc-cb4442d0-2261-4821-95b4-1439c77aeb75"></a>
## 1. Summary

| seat | AGREE | DISAGREE | note |
|---|---:|---:|---|
| c1 | 9 | 0 | sites confirmed; 4.1's saving is ~61 s/day, not the 97 s current cost; 4.4 stays last until a 304 share exists |
| m1 | 0 | 10 | every row is landed, superseded, or has no measured gain |
| a1 | 1 | 9 | #5 is the remaining hot `map[string]any` frames; the other nine are superseded, unmeasured, or already cached |

<a id="ws-doc-4477a889-2d7f-4e2b-a98b-0a94a16dd6de"></a>
## 2. Review of c1

c1's pool correction holds: `grep -n DBMaxConns $A/config/config.go` ->
`envDefault:"8"` at line 268, and
`grep -o '"SPOOL_HUB_DB_MAX_CONNS": "[0-9]*"' csi-spl-cnf/csi-spl/prd/tf/030-cloud-run-hub.vars.tfvars`
-> `"4"`. A 2.4 s statement holds one of an instance's four connections.
A 0.28 ms statement does not.

<a id="ws-doc-490ad91b-be22-46d1-8b02-8101d3c741ca"></a>
### 4.1 Relay tick cadence and one set read per tenant: AGREE, with the saving corrected

The site is the 5 s tick. `sed -n 43,86p $A/hub/relay.go` shows `RunRelay`
calling `Relay` on every `QueueRelay` tick, and `Relay` calling `pushQueued`
plus `pushUnacked` once per held box, then `UnheardPosts` once per tenant.
`escalateUnanswered` at line 122 and `reescalate` at line 152 run in that
same tick. `grep -n QueueRelay $A/config/config.go` -> default `5s` at line
325; `UnansweredGrace` `120s` at 340; `ReescalateEvery` `120s` at 346;
`Wake` default `true` at 329. `ackTimeout` is 60 s (`$A/hub/commit.go:22`).

c1's call counts (one 24 h window): queued 387 958, unacked 389 766, and
the three sweeps 155 453 each. `387958/155453 = 2.50` box reads per sweep,
and `155453/(86400/5) = 9.0` sweep-units per 5 s tick. The sweeps are
already one read per tenant per process. Batching queued and unheard from
"22 per tick" down to "one per tenant" overstates the batch: 22.5 box
reads across 9 sweep-units is 2.5 reads per unit, so the set read removes
about 60 % of `QueuedFor`, about 6 s of its 10.4 s, not 21 of 22 reads.

The cadence change is the part with a measured cut. Unanswered and
re-escalate every 30 s remove 5/6 of 10 833 ms + 43 836 ms. Unacked every
15 s removes 2/3 of 14 151 ms. Together with the queued batch that is
about **61 s/day** of the 85 s those five statements cost, plus about
7 s of `set_config` on the ~0.75 M calls removed (c1's mean 0.01 ms).
The residual is about 0.49 M statements, not 0.25 M. No screen waits on
this tick. The means are sub-millisecond, so this does not free a pool
slot the way action 4.5 does. It does cut statement starts on a 25-connection
micro.

Keep c1's drop gate: drop the cadence part if escalation p95
(`delivered_at` minus `received_at`) moves by more than 30 s. The queued
and unheard set read can land even if the cadence is dropped. The SQL
predicates stay.

<a id="ws-doc-927c75e3-86f1-41ba-9c3d-22795a8344e9"></a>
### 4.2 Unanswered sweep reads changed topics only: AGREE

`grep -n 'WITH k AS MATERIALIZED' csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh`
-> line 277, `DISTINCT ON (m.tenant_id, m.task_id)` over
`received_at > now() - make_interval(days => :days)`, then a heap fetch of
`left(l.body, 400)` for a human-last row. c1: 1 479 × 198.19 ms = 293 s,
28.1 % of the window (g1: 1 473 × 216.81 ms). Both windows put this first.
`grep -n SPOOL_HUB_TOPIC_HEADS csi-spl-cnf/csi-spl/prd.env.yaml` -> line 290,
`"on"`, so the head rows the incremental read needs are the live path.
The install comment at `spl-unanswered-sweep.func.sh:44` records the
every-minute cron (`SWEEP_MIN_AGE=3`, `SWEEP_ESCALATE_AGE=5`).

Keep g1's section 6 sentence in the plan: the warm plan was 57 ms and
15 456 pages (g1, n=1). The cost is pages re-read every minute. Swapping
only `DISTINCT ON` for heads saves the small key, not the 198 ms. The
hourly full reconcile is the right guard for expiry and a mid-topic
archive. Drop if the insights mean stays above 80 ms at n >= 200, as c1 says.

<a id="ws-doc-264b1cdd-49e8-4046-96c0-59603a32c38e"></a>
### 4.3 `topic_head_apply_marks` add path stays O(probes): AGREE, lab first

`sed -n 300,314p $R/0144_topic_heads.sql` shows `topic_head_add` taking
`topic_head_lock`, then `topic_head_rebuild` when `last_at = '-infinity'`.
`topic_head_apply_marks` is line 370 and calls `topic_head_add` (line 415)
and `topic_head_rebuild` (line 418). c1: 2 029 applies × 39.64 ms = 80 s,
against 1 306 inserts in the same window, so many applies are not new
rows. If that 39 ms is lock wait, a SQL rewrite changes nothing. The
rolled-back lab split comes first. Drop if the add-only path is already
under 5 ms. This lane touches the message write path, so it lands before
any later counter trigger on the same path, and its insert measurement
is taken on a tree where it is the only new write-path work.

<a id="ws-doc-aa5a4aa4-c88e-4809-8612-1074578747cf"></a>
### 4.4 Channel 304 gate: AGREE as a measurement, ranked last

The gate exists and the client never reaches it.
`sed -n 45,47p $A/hub/view_stamp.go`:

```
inm := r.Header.Get("If-None-Match")
if !ok || inm == "" || r.URL.Query().Has("since") {
    return w, false
```

`grep -c -E 'If-None-Match|ETag|etag' csi-spl-wui/src/utils/spool-client.mjs`
-> 0. `listChannels` (`spool-client.mjs`, the `read=<ch>~<cursor>` query)
sends no validator, and the `read` query changes the URL when a mark
moves. `changeStampSQL` (`$A/store/change_stamp.go:37`) sums
`tenant_change_stamps` for the whole tenant. The `deliveries` trigger
that bumps that stamp is `$R/0103_tenant_change_stamps.sql:123`.
`sed -n 355,420p $A/store/channels_postgres.go | grep -c deliveries` -> 0,
so a delivery bumps a stamp the channel list does not read.

c1's ceiling, 6 840 GETs × 18.44 ms ≈ 126 s/day, is the cost of the four
statements if every GET became a 304. It is not a measured hit rate.
c1 already says the two causes are unproven, and that insights may fold
a rare statement into another row. Rank this row by the measured 304
share, after the log count, and drop it if that share is under 20 %.
Until the client sends `If-None-Match`, a stamp split has nothing to
match. The client file is outside the API and DB tree; the lane owns
that one WUI change or the row cannot gain anything. Do not build the
maintained channel counter in this lane.

<a id="ws-doc-a1d0ff68-7fe7-4ebb-bd08-1cdc1e426019"></a>
### 4.5 `search_sig` full compare off the per-deploy path: AGREE

`grep -n do_spl_search_sig_check .github/workflows/20_hub-build-deploy.yml`
-> line 627, on every hub deploy. The action header
(`spl-search-sig-check.func.sh:6-11`) says `hashtext` is not stable across
a Postgres major version. c1: 18 × 2 407 ms = 43 s, 4.2 % (g1: 25 ×
2 476 ms). Each run holds one of four connections for 2.4 s. Keep the
full compare on a server-version change. Record the server version the
last full check passed on, and skip it on an application deploy that
does not change that version.

<a id="ws-doc-2cd11144-153a-4648-bbae-bc0df11193cb"></a>
### 4.6 Flow fold as one anti-join: AGREE, EXPLAIN first

`flowFoldSQL` is `$A/store/flow_fold.go:312`. It selects `flowEventCols`,
which ends in `NOT flowCoveredSQL` (`$A/store/flow_postgres.go:103`).
`flowCoveredSQL` inlines `archivedHideSQL` plus two `read_marks`
EXISTS probes per window row (the second matches three mark keys). The same statement also runs a correlated
`left(r.body, 400) ... LIMIT 1` per distinct task in the page
(`flow_fold.go`, the `tt` CTE). c1: 83 × 598.17 ms = 50 s (g1: 51 ×
630 ms). This is the slow statement a person waits on, and it holds one
of four connections for about 0.6 s.

No EXPLAIN was run by c1, g1, or this seat (it needs a member id in the
doc). Drop the row if the correlated subplan is not where the time goes.
The lane's file is `flow_fold.go`. `flowCoveredSQL` stays for
`flowCountsSQL`.

<a id="ws-doc-9f19b71a-c6bb-4ac9-a9a8-4da9ecffa2fd"></a>
### 4.7 DM pointers, top-N per arm: AGREE, EXPLAIN first, drop if the time is the heap read

`sed -n 24,44p $A/store/dm_pointers_postgres.go` shows both arms of the
`UNION ALL` inside one `MATERIALIZED` CTE, with `ORDER BY c.received_at`
and `LIMIT $8` outside it. `grep -n "messages_to " $R/0001_hub_core.sql`
-> line 80, `(tenant_id, to_box, to_id, ts)`. An inner `LIMIT` ordered by
`received_at` still reads the pair's heap to sort it. The gain of a
limit per arm is not carrying `env` for the whole pair through the CTE.
c1: 40 × 421.88 ms = 17 s. If the EXPLAIN shows the heap read is the
time, the fix is an index, which is a write cost on `messages`. Measure
that insert cost and drop the row if it is not smaller than the read.
Same rows as today, including a fixture whose newest lines are archived.

<a id="ws-doc-7d7b026a-3bc9-4a37-9a15-d311caa47c47"></a>
### 4.8 Issue list omits `description`: AGREE, only with a one-issue read on open

`issueCols` at `$A/store/issues_postgres.go:15` includes `description`.
`ListIssues` at line 318 selects it at line 324, with no `LIMIT`.
`GetIssue` at line 301 selects the same `issueCols`. c1: 1 502 × 12.07 ms
= 18 s (g1: 1 049 × 16.76 ms). Callers of `ListIssues`:
`grep -n 'ListIssues(' $A/hub/*.go` -> `issues.go:595`, `calendar.go:615`,
`search.go:573`, `hours_export.go:100`.

The sheet paints the list row. On `fda858ca5`, `issues.vue` line 5 says
the description is only in the opened issue, and `choose` at line 1662
does `detail.value = issue` with the list object. `form()` at line 1496
then reads `d.description` off that object. `46b4bc2b4` also attaches
files through that same `detail` object. Omitting the column from
`issueCols` blanks the opened issue and also blanks `GetIssue`. The lane
splits the list projection from `GetIssue`, and `choose` loads the
by-number read before the modal paints. Search keeps a statement that
still returns the text. Drop if `EXPLAIN (ANALYZE, BUFFERS)` shows the
mean falling by under 2 ms (the column may be toasted and never
detoasted on the list).

<a id="ws-doc-b5edfda1-b3d8-45ef-a48f-28791a665298"></a>
### 4.9 Release-note page by keyset: AGREE

`releaseNumberedSQL` (`$A/store/release_note_postgres.go`, `row_number()
OVER` every versioned row) is evaluated by `ListReleaseNotes` for every
page: the page CTE limits the keys, then `WHERE k IN (SELECT k FROM page)`
joins back to the whole-table window. c1: 168 × 54.02 ms = 9 s, up from
g1's 43.64 ms (n=219) six hours earlier. The mean grows with the table.
Proof is equal page contents (version, sha, seq) and an EXPLAIN that
stops at the page. Small today, unbounded by design.

<a id="ws-doc-5bc1b70e-086e-41d3-ae17-2263b0759604"></a>
### c1's "not worth" list: AGREE with the drops this seat re-checked

- Box hello, 135 886 × 0.32 ms. The stamp interval is
  `defaultPresenceEvery = 30 * time.Second` (`hub/presence.go:24`). c1
  reads the offline TTL as twice that interval. Halving the stamp rate
  saves about 22 s and lengthens how long a dead box looks online. No
  screen waits.
- `set_config`, 1.92 M × 0.01 ms. It already rides in the statement batch.
  Action 4.1 removes a share of the calls. A campaign of its own has no
  extra round trip to remove.
- `TenantsMissingPublicNotice`, 86 × 68.95 ms. `grep -n IMMUTABLE $R/0173*.sql`
  -> line 39. 0.6 % is below a lane.
- One home for the signed-human predicate. `grep` of
  `from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'` under `$A/store` ->
  three lines, all in `fallback_postgres.go` (84, 115, 148). Real drift
  risk, no measured speed, no recorded incident. Leave it unless the
  relay lane already edits all three.
- g1 5.7, the release-day scalar inside `flowCountsSQL`. The scalar is
  bounded by the member's `f:seen` mark (`flow_postgres.go`, the
  `released_at > (SELECT s.at ... mark_key = 'f:seen')` subquery) and
  `release_notes_released_at` exists (`$R/0177_flow_v2.sql:33`). g1's own
  drop line is 2 ms and the subquery was not separated. Not a lane
  without that EXPLAIN.
- g1 5.10, batching the three fallback reads and still running all three
  scans. Two sub-millisecond round trips, no screen waits. Action 4.1 is
  the version with a measured cut.
- `synchronous_commit` off, turning on `pg_stat_statements` (an instance
  restart), and a read replica. The database is 1.2 % busy in c1's window
  (1 041.6 s of DB time per day).

<a id="ws-doc-503cb9cd-d476-43de-9b1c-ece8e63e25ae"></a>
## 3. Review of m1

m1's measurement table is the 2026-10-06 baseline. Flow counts at
11 229 × 77.1 ms is the pre-`0fd227cd9` number. c1 measures the same
statement at 7 831 × 9.09 ms on the current tree. Every proposed file
change is already on master, or the row names no measured gain.

1. **Seek on stored place/time: DISAGREE.** Landed. `0137_flow_events_place_key.sql`
   adds `place_key` and `cov_at` (`$R/0137_flow_events_place_key.sql:33`).
   Commits `5cebb1159` and `dc271bcc8` (ap-01a), `a8e372341` and
   `0fd227cd9` (ap-01b, 42 → 4 ms p50). m1's migration name `0136` is
   already `0136_tenant_settings_jsonb.sql` (`ls $R | grep ^0136`).
2. **Archived lines only for unmarked channels: DISAGREE.** Landed.
   `0576d2cdc` and `4b14b1e77` (ap-02).
3. **Messages autovacuum: DISAGREE.** Landed as `0138_messages_autovacuum.sql`
   (`8fc4fd7aa`, ap-04).
4. **Server-maintained topic summary: DISAGREE.** Landed. Topic heads are
   `SPOOL_HUB_TOPIC_HEADS: "on"` in prd (line 290 above). Spec 099,
   `71a2a4a92`.
5. **WUI channels GET per PUT: DISAGREE.** Landed. `180849fdf` (ap-05),
   with the later proof commit `4ebb0deb2`. The file is also outside an
   API and DB panel.
6. **Batch flow-event updates on insert: DISAGREE.** `f7536e327` records
   the ap-08 lab: no insert piece at or above 10 ms, and the row was dropped.
7. **Permessage-deflate with context takeover: DISAGREE.** Compression is
   live and takeover was rejected. `sed -n 221,230p $A/hub/wui.go` sets
   `CompressionNoContextTakeover`. The comment on that function records
   +258 MB heap at 200 sockets against a 512 MiB instance.
8. **Reconnect `since=`: DISAGREE.** Live. `grep -n '"since"' $A/hub/view_delta.go`
   -> line 67. Commits `ce9ed78c2` and `5e17e8ab4` (R2-2).
9. **Flow scope / plan cache: DISAGREE.** m1's own text says no A/B
   reproduced a slowdown. The 2026-10-06 plan left flow-scope as a read
   that runs only if it wins (`refactor-round-api-perf-plan-2026-10-06.md`
   commit table, the ap-01b row). No measured gain.
10. **Split the archived OR: DISAGREE.** The predicate is still in
    `archivedTopicHideSQL` (`$A/store/topic_archive_postgres.go:363`,
    `z.msg_id = a.task_id OR z.task_id = a.task_id`). The 2026-10-06 plan
    measured the split 20× worse under an operator scope (n=3) and kept it
    only if ap-07 was deferred. ap-07 shipped: with topic heads `on`,
    `view_postgres.go:136` serves `viewTopicsHeads`. The walk this OR sits
    on is not the production path. g1 measures the topic-list reads at
    92 × 44.96 ms and 150 × 23.48 ms, outside the top of total time.

A later review that marks all ten AGREE is agreeing with work that is
already on master. Those ten do not count toward the three-vendor bar
for a new lane.

<a id="ws-doc-a4f44711-1a04-497e-b36f-2a3fac1d73b0"></a>
## 4. Review of a1

a1's section 3 correctly lists ap-01a/b, ap-02, ap-04, ap-00 and ap-07
as done. The action list then reopens the rows the same plan left behind.
a1's insights were taken on tree `0adcd4a2b`.

1. **Debounce flow counts on wakes: DISAGREE.** The call is real:
   `$A/hub/wui_wake.go:61` calls `pushFlowCounts` on every mark wake.
   This is ap-06. The 2026-10-06 plan says the burst factor was not
   measured (line 233) and, after ap-05, "if it ever reopens, trailing-edge
   only" (line 55). `0fd227cd9` then took the badge p50 from 42 ms to 4 ms.
   a1's own totals (5 882 calls, 24.1 s, about 4.1 ms) do not show a burst.
   c1's window has the broader `flowCountsSQL` at 9.09 ms. No histogram of
   wakes per member, so there is no measured gain.
2. **Insert trigger reads `search_tsv`: DISAGREE.** The change cannot work
   as written. `$R/0135_messages_search_sig.sql:55-57` says a BEFORE
   trigger runs before the stored `search_tsv` is computed, which is why
   the function parses `NEW.body`. The trigger is
   `BEFORE INSERT OR UPDATE OF body` (line 64) and fires only when
   `length(NEW.body) >= 1024`. The ap-08 lab (`f7536e327`) found no insert
   piece at or above 10 ms. a1's "after the AFTER trigger" note describes
   a trigger this file does not have.
3. **Split the archived OR: DISAGREE.** Same predicate as m1 #10, same
   reason. Heads are the production list.
4. **Walk subject via a covering index: DISAGREE.** ap-09. The plan folds
   it into ap-07 (line 56). `subjectSQL` is the walk
   (`view_postgres.go` around the `first_msg` select). Production serves
   `viewTopicsHeads` (line 136). The walk is the off/shadow path
   (`view_topics_head.go:39`).
5. **Typed structs for the message and channel frames: AGREE, bench-gated.**
   The maps are still there. `grep -c 'map\[string\]any' $A/hub/wui.go` -> 7.
   The message frame is `wui.go:989` (`map[string]any{"type": "message"...}`)
   and the channel frame is `wui.go:1243`. Presence is already a struct:
   `channels.go:337` returns `presenceMsg`. Round 4 G12 measured the same
   practice at 62.2 µs → 3.4 µs and 420 → 10 allocs, n=6
   (`grep -n G12 csi-spl-doc/doc/md/perf-round-4-plan.md` -> line 46).
   That is the historical gain the addendum asks for. Gate: `go test -bench`
   of the message frame at 1 / 10 / 50 sockets, n>=6, JSON byte-identical.
   Drop if allocs fall by less than half. On `GOMAXPROCS=1` the fan-out
   shares the instance's one P, which is why the allocs matter.
6. **Typed struct for the merge frame: DISAGREE as its own row.** The map
   is real (`merge.go:273`, `map[string]any{"type": mergedFrame...}`).
   a1 gives no call count. Fold it into #5 only when it is the same struct
   and the same bench. A separate lane for an unmeasured merge frame is
   not worth doing.
7. **Flow fan-out pushes a delta: DISAGREE.** The recompute is real.
   `FlowFanout` at `$A/store/flow_postgres.go:250` is
   `CROSS JOIN LATERAL (flowCountsSQL ...)`. a1: 310 × 21.31 ms = 6.6 s/day.
   That is the same size as `TenantsMissingPublicNotice`, which c1 correctly
   leaves out. A delta badge drifts when a frame is missed. The correctness
   cost is larger than 6.6 s.
8. **`file_count` column: DISAGREE.** `fileRefs` is `$A/store/search.go:125`,
   called from `searchMsg` at line 136. a1: 6 calls × 320 ms. A column on
   `messages`, maintained by a trigger, for a route outside the top 20.
   The JSON parse is not separated from the 320 ms, so the gain is unknown
   and the write cost is on every insert.
9. **`withoutAgent` slice copy: DISAGREE.** The function is
   `$A/hub/channels.go:228`. The call a1 cites is line 316
   (`mine = withoutAgent(mine, m.From)`). Round 4's line 315 was
   `presenceFrame`, now a struct at line 337. No measurement. a1's own
   against-case says it shows up only in very large channels. Not worth
   doing.
10. **Cache the checkov install: DISAGREE.** Already landed, and it is CI
    rather than the API or the database. `.github/workflows/65_iac-checkov.yml`
    restores a venv with `actions/cache` (the step comment names round 4 C3,
    the install was ~32 s). `grep -n 'actions/cache' .github/workflows/65_iac-checkov.yml`
    -> line 51.

<a id="ws-doc-0bbe7c75-435e-437f-86d3-0843f440701c"></a>
## 5. What the merger should take from this seat

Ordered by measured gain. A gated row stays in this order only while its
gate is still open. Each row is one later lane, and the files do not overlap.

| # | action | gain | gate | files |
|---|---|---|---|---|
| 1 | c1 4.2 sweep, changed topics only | 293 s/day (n=1479 and n=1473) | drop if mean stays above 80 ms | `spl-unanswered-sweep.func.sh` |
| 2 | c1 4.3 add path of `topic_head_apply_marks` | 80 s/day (n=2029) | lab split first; drop if add-only is under 5 ms | new migration beside `0144` |
| 3 | c1 4.1 relay cadence, plus the per-tenant set read | ~61 s/day, ~0.75 M fewer statements | drop cadence if escalation p95 moves by more than 30 s | `hub/relay.go`, `store/postgres.go`, `store/acks.go` |
| 4 | c1 4.6 fold anti-join | 50 s/day (n=83), a person waits ~0.6 s | EXPLAIN first; drop if the subplan is not the time | `store/flow_fold.go` |
| 5 | c1 4.5 `search_sig` off the deploy path | 43 s/day (n=18), 2.4 s on one of four connections | keep the full scan on a Postgres version change | `spl-search-sig-check.func.sh`, workflow 20 |
| 6 | c1 4.8 issue list without `description` | 18 s/day (n=1502), capped | `choose` loads `GetIssue`; drop if the mean falls by under 2 ms | `store/issues_postgres.go`, `issues.vue` |
| 7 | c1 4.7 DM top-N per arm | 17 s/day (n=40), a person waits ~0.4 s | EXPLAIN first; drop if the time is the heap read and the index costs more | `store/dm_pointers_postgres.go` |
| 8 | c1 4.9 release-note keyset | 9 s/day (n=168), mean still growing | page contents stay equal | `store/release_note_postgres.go` |
| 9 | a1 #5 typed message and channel frames | round 4 G12, 420 → 10 allocs (n=6) | new bench n>=6; drop if allocs fall by less than half | `hub/wui.go` |
| 10 | c1 4.4 channel 304 | unknown; ceiling 126 s is not a hit rate | log `If-None-Match` and 304 for >= 24 h; drop if 304 share is under 20 % | `hub/view_stamp.go`, `0103` stamp family, `spool-client.mjs` |

Row 2 lands before any other new work on the message write path. Row 6
includes the one-issue read or it blanks the opened issue. Row 10 does
not jump the queue on the strength of the ceiling.

Disputed, one line each:

- c1 4.1 saving: c1 prints ~97 s and ~1.0 M statements removed; the same
  counts give ~61 s and ~0.75 M once queued is 2.5 reads per sweep rather
  than 22 reads per tick. The row still agrees.
- c1 4.4 rank: a2 treats 126 s as the gain. The client sends no validator
  (`spool-client.mjs` count 0), so the gain is unmeasured.
- m1 #1-#10: a2 agrees; c2 and g2 disagree. The code for each row is
  already on master, or the row names no measured gain.
- a1 #1-#4 and #6-#10: c2 and g2 disagree. #2 cannot run in the BEFORE
  trigger. #10 is already cached.

Not worth doing, from these three files: every m1 row; a1 #1 (no burst
measured, badge already ~4 ms p50); a1 #2 (BEFORE trigger, parse only for
bodies of 1024 bytes or more, ap-08 lab empty); a1 #3 and #4 (walk rows,
heads are on); a1 #6-#9 (no measured gain); a1 #10 (landed CI cache).
c1's own drop list in section 2 above stands.
