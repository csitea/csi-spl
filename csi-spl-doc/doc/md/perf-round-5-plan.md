# DB + API round 5: plan (2026-10-12)

> Generated from qto doc `0ea82e64-bb64-4f71-9e4f-52cf823082f7`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Owner, t1 #refactoring eafc9b15:
- msg 9a9394b7: "DB and API improvements in speed, code refactoring round 5"
- msg f7499bb6: a panel of two agents per vendor kind.
- addendum 81732251: at least 30 practices, crossed with the measured sites, then "the 10 most beneficial actions".
- addendum d2c21d8b: "empirical evidence on what is worth doing and what is not worth doing".

This plan is the merge. It changes no product code. Each row below is one future lane, and no two rows share a file.

<a id="ws-doc-78eda414-65ed-4b5d-956d-0b87d2d1fb54"></a>
## 1. The panel and how the rows were chosen

| vendor | proposer file | reviewer file | reviewer covered |
|---|---|---|---|
| claude | [c1.md](perf-round-5/c1.md) (`a9b01ea3a`) | [c2-review.md](perf-round-5/c2-review.md) (`21cab2e78`) | g1, m1, a1 |
| grok | [g1.md](perf-round-5/g1.md) | [g2-review.md](perf-round-5/g2-review.md) (`9650eb667`) | c1, m1, a1 |
| agy | [a1.md](perf-round-5/a1.md) | [a2-review.md](perf-round-5/a2-review.md) (`948989634` for c1) | g1, m1, c1 |
| mistral | [m1.md](perf-round-5/m1.md) | none | m2's seat (m-329) twice reported a review as landed that was not on master; the orchestrator closed it under the two-tries rule |
| qwen | none | none | off in the instance settings |

**The rule.** A row is in the plan when three or more vendors agree on it. A
proposer counts as agreeing with its own rows. The two claude seats count as
one vendor. Without a mistral reviewer, three vendors means claude, grok and
agy together.

**The order.** Rows are ordered by measured gain, from the prd Query Insights
figures. Query Insights is the stand-in for `pg_stat_statements`, which is not
installed on prd; a2's text says `pg_stat_statements`, but the numbers came from
Insights. The sources are two independent 24 h windows (`do_spl_db_insights`):
- c1: `2026-10-11T16:53:47Z..2026-10-12T16:53:47Z`, 59 statements, n = 3 561 168 calls.
- g1: `2026-10-11T10:59Z..2026-10-12T10:59Z`.

Where both windows quote a statement, they agree within 15 %. A row whose
gain is a ceiling, not a measurement, goes last.

**The counts.** The panel proposed 39 actions in all:
- c1: 9.
- g1: 10. Seven are the same actions as c1's.
- m1: 10.
- a1: 10.

That is 9 + 3 + 10 + 10 = 32 distinct actions. 11 reached three vendors: c1's
9, g1 5.3 and a1 #5. g1 5.3 and c1 4.4 target the same statement, so they share
one row. That leaves **ten rows**.

**Bounds for every lane:**
- `db-f1-micro`, `max_connections` 25.
- The hub pool is **4 per prd instance**: `grep -o '"SPOOL_HUB_DB_MAX_CONNS": "[0-9]*"' csi-spl-cnf/csi-spl/prd/tf/030-cloud-run-hub.vars.tfvars` -> `"4"`. The code default is 8, and the brief said 8.
- FORCE RLS: a lane uses `inTenant`, `tenantBatch` or `asOperator`.
- Cloud Run `GOMAXPROCS=1`.
- The DB is 1.2 % busy on average (1 041.6 s of DB time per day). A row gains
  when it frees cache pages, pool slots or statement starts, not CPU alone.

<a id="ws-doc-468f902a-d520-4998-bfe6-b4870491085b"></a>
## 2. Rules for every lane

- Measure before and after, with the same method and the same n. A row whose gate says no is dropped and reported, never shipped.
- Touch only the row's files, plus new test files beside them. Re-run `lane-map.sh --check` before the first edit.
- A new migration takes the next free number at its push. The head is `0181_issue_events.sql` today. Forward-only, `lock_timeout` 5 s.
- A store or migration change runs `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- Done means: on master, deployed to dev AND prd with the served version checked, and the before/after numbers posted with their n.
- Do not run a write function (e.g. `topic_head_apply_marks`) on prd to measure it. Use a rolled-back lab on a private postgres:16-alpine.

<a id="ws-doc-24db6a43-e573-48d2-8874-d0e055bcfb2f"></a>
## 3. The ten actions, in run order

`api/` = `csi-spl-api/src/go/spool-hub-api/internal/`, `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`.

| # | id | action and practice | files (disjoint) | measured cost now (n) | expected gain | evidence for | evidence against | gate (drop if) | proof | agreed by |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P5-01 | **Unanswered sweep reads only the topics whose head moved**, heap-fetches the body only for human-last rows, and runs an hourly full reconcile. Practice: incremental checkpoint plus reconcile. | `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh` (`_spl_sweep_rows_sql`, :277) + `csi-spl-orc/src/bash/tests/unanswered-sweep*-pg.tst.sh` | 1 479 x 198.19 ms = 293 s/day, 28.1 % (c1); 1 473 x 216.81 ms (g1). Warm plan 57 ms, 15 456 pages/run (g1, n=1) | most of the 293 s: a minute touches the few moved topics instead of 1 971 tuples plus 13 495 index rows | largest statement in both windows; heads are on in prd (`SPOOL_HUB_TOPIC_HEADS: "on"`) | swapping only `DISTINCT ON` for heads saves 16 of the 57 ms; the cost is pages re-read every minute. Row-equality risk on expiry and on a mid-topic archive | the Insights mean stays above 80 ms at n >= 200 | same row set as today on a fixture and on one prd day (read-only, no bodies logged); Insights mean n >= 200 | grok, claude, agy |
| 2 | P5-02 | **`topic_head_apply_marks`: the add path stays O(index probes)**, with no rebuild and no second lock; rebuild only on a real miss or an `'r'` mark. Practice: a small deferred trigger. | NEW migration replacing the functions of `rdb/0144_topic_heads.sql` (:300 add, :370 apply) | 2 029 x 39.64 ms = 80 s/day, 7.7 %, against 1 306 inserts (c1); 2 530 x 38.75 ms (g1) | the add sits with the insert (21..34 ms), not 39 ms above it; rebuilds become visible on their own | the add can fall into `topic_head_rebuild` (a whole-topic scan) and always locks twice; the cost is new since heads shipped | if the 39 ms is `FOR UPDATE` wait, rewriting the SQL does nothing | a rolled-back lab split shows the add-only path already under 5 ms | lab split first, then the prd Insights mean n >= 500; lands before any other new write-path work (row 10's counter) | grok, claude, agy |
| 3 | P5-03 | **The relay tick runs each sweep at its deadline's cadence and reads queued rows as a set**: unanswered + re-escalate every 30 s, unacked every 15 s, queued + unheard every 5 s as one `to_box = ANY($2)` per tenant in one `queryTenantBatch`. The SQL predicates do not change. Practices: poll cadence = deadline; event-driven first; set-based reads. | `api/hub/relay.go`, `api/store/postgres.go` (`QueuedFor` only, :565), `api/store/acks.go` (`UnackedFor`, :61) + `api/hub/relay_test.go` | 5 statements = 1 244 083/day, 34.9 % of all statements, 85 s, plus their `set_config` (c1). Deadlines 120 s / 120 s / 60 s (`config.go:340,346`, `commit.go:22`); `Wake` (LISTEN/NOTIFY) is on (`config.go:329`) | **~61 s/day and ~0.75 M fewer statements** (g2's correction of c1's 97 s: 2.5 box reads per sweep unit, not 22 per tick) | the 120 s sweeps run 24x per deadline; the call counts come from one 24 h window | no screen waits; the reads are sub-ms (c2's reason against g1 5.10); an escalation can come up to 25 s later | escalation p95 (`delivered_at - received_at`) moves by more than 30 s: drop the cadence part, keep the set read | Insights calls of the 5 statements, one 24 h window before and after; fake-clock relay tests prove escalation still fires within grace + 30 s | claude, grok, agy |
| 4 | P5-04 | **Flow fold: one set anti-join against archived cards and read marks**, and the titles in one set read, instead of `NOT flowCoveredSQL` per window row. Practice: set anti-join over a correlated `EXISTS`. | `api/store/flow_fold.go` (`flowFoldSQL`, :312); `flowCoveredSQL` stays for `flowCountsSQL` | 83 x 598.17 ms = 50 s/day (c1); 51 x 629.73 ms (g1); a person waits ~0.6 s, holding 1 of 4 pool slots | up to the share of the 0.6 s that is the correlated subplan | the sweep's d-02 already showed this shape (one archived index scan, loops=1) | no EXPLAIN yet: if the time is the `flow_events_member_at` scan or the message join, the row does nothing | EXPLAIN (ANALYZE, BUFFERS) under a member scope, n >= 5, shows the subplan is not the time | EXPLAIN n >= 5 before and after, folded rows equal; `GET /v1/view/flow` p50 | grok, claude, agy |
| 5 | P5-05 | **The `search_sig` full compare runs on a Postgres version change, not on every hub deploy.** Record the version the last full check passed on. Practice: keep a long check off the hot pool and the deploy path. | `csi-spl-orc/src/bash/run/spl-search-sig-check.func.sh` (:52-53) + its test; `.github/workflows/20_hub-build-deploy.yml` (:627) | 18 x 2 407 ms = 43 s/day (c1); 25 x 2 476 ms (g1); each run holds 1 of 4 connections for 2.4 s | most of the 43 s and the 2.4 s pool stall per roll | the call count follows the deploy cadence; the stated drift reason is a major version (`hashtext`) | until spec 100 T013, `search_sig` is still a fallback: a skipped check is a hole if a deploy changes the function without a version change | the forced version-change run finds a different mismatch count from today's statement | runtime before and after, n = deploys in the window; one forced version-change run | grok, claude, agy |
| 6 | P5-06 | **The issue list stops selecting `description`**; opening an issue loads it with the by-number read. Practice: a list projects only what it paints. | `api/store/issues_postgres.go` (`issueCols` :15, `ListIssues` :318, a list projection apart from `GetIssue` :301); `csi-spl-wui/src/pages/issues.vue` (`choose` loads the one issue before the modal paints) | 1 502 x 12.07 ms = 18 s/day (c1); 1 049 x 16.76 ms (g1); no `LIMIT` | the detoast and bytes of `description` per list read, capped at 18 s | the sheet paints title, status and dates only | `choose` passes the list object to the modal (g2: `issues.vue` `form()` reads `d.description`), so the narrow list blanks the open issue without the one-issue read. Search and hours export keep the text | the mean falls by under 2 ms (EXPLAIN ANALYZE, BUFFERS) | EXPLAIN + payload bytes n >= 5; e2e: an opened issue shows its description; search hits keep the text | grok, claude, agy |
| 7 | P5-07 | **DM pointers: top-N inside each arm of the union**, keeping the fence against a whole-tenant backward scan and over-fetching for archived rows. Practice: push the top-N into the union arms. | `api/store/dm_pointers_postgres.go` (`dmPointersSQL`, :24); an index migration only if the EXPLAIN demands one | 40 x 421.88 ms = 17 s/day (c1); 64 x 437.48 ms (g1); a person waits ~0.4 s | the share of the 0.4 s that is pair history beyond the page | the CTE has no inner limit, so the outer `LIMIT` cannot stop an arm | `messages_to` is `(tenant_id, to_box, to_id, ts)` (`rdb/0001_hub_core.sql:80`) with no `received_at` (c2, g2), so a limit per arm still reads the pair heap; an index is a write cost on `messages`; an earlier naive limit mis-planned | EXPLAIN shows the time is the heap read and the index costs the insert more than it saves the read | same rows as today on a fixture whose newest lines are archived; EXPLAIN n >= 5 with a range plus a limit per arm | grok, claude, agy |
| 8 | P5-08 | **Release-note page by keyset on the version index**: number the page, not the whole table; the six long columns only when a note is opened. Practices: keyset pagination; projection. | `api/store/release_note_postgres.go` (`releaseNumberedSQL` :29, `ListReleaseNotes` :157) | 168 x 54.02 ms = 9 s/day (c1); 219 x 43.64 ms six hours earlier (g1): the mean grows with the table | O(page) instead of O(table); the mean stops growing | the page CTE limits the keys, then joins back to a `row_number()` over every versioned row | 0.9 % today; a stored sequence can drift from `row_number()` | page contents (version, sha, seq) differ from today's | EXPLAIN n >= 5 that stops at the page; equal pages | grok, claude, agy |
| 9 | P5-09 | **Typed structs for the WUI message and channel frames** instead of `map[string]any`, encoded once. Practice: typed structs on hot frames (round 4 G12). | `api/hub/wui.go` (:989 message frame, :1243 channel frame); the merge frame (`hub/merge.go:273`) only if it is the same struct and bench | `grep -c 'map\[string\]any' api/hub/wui.go` -> 7 (g2); no fresh bench yet | historical: G12 took presence from 62.2 µs / 420 allocs to 3.4 µs / 10 allocs, n=6 (`perf-round-4-plan.md` row 23); on `GOMAXPROCS=1` the fan-out shares the one P | the same practice measured a 42x alloc cut in round 4 | high test churn on the JSON shape; a1's merge frame has no call count | allocs fall by less than half in a new `go test -bench` at 1 / 10 / 50 sockets, n >= 6 | bench n >= 6 before and after; JSON byte-identical golden test | agy, claude, grok |
| 10 | P5-10 | **Channel GET: make the existing R2-5 304 gate reachable first; the maintained counter only if it is not.** Step 1: log `If-None-Match` and 304 on `GET /v1/view/channels` for 24 h. Step 2: the WUI sends the ETag it holds, and the channels view gets a stamp without `deliveries`. Step 3, only if the 304 share is under 20 %: g1 5.3's counter row with a drift oracle. Practices: a conditional read before the data reads; narrow invalidation; a maintained counter with an oracle. | `api/hub/view_stamp.go`, `api/store/change_stamp.go`, a NEW migration beside `rdb/0103_tenant_change_stamps.sql` (:123 `deliveries` trigger), `csi-spl-wui/src/utils/spool-client.mjs` (:551); step 3 only: `api/store/channels_postgres.go` (`countsRead` :363) + a NEW migration | 4 statements x 6 840 GETs = 18.44 ms per GET, ~126 s/day (c1). `changeStampSQL` is absent from all 59 statements in the window: no conditional read reached the gate in 24 h. `grep -c -E 'If-None-Match\|ETag\|etag' spool-client.mjs` -> 0 (g2). Stamp bumps 41 844/day vs 6 840 GETs | **unknown; 126 s/day is a ceiling, not a hit rate** (g2) | the gate is built and tested, and it never runs on prd; `countsRead` reads no `deliveries` (`sed -n 355,420p api/store/channels_postgres.go \| grep -c deliveries` -> 0) | the stamp may move between most GETs from real changes; `e908f41b` chose the index-only scan to avoid a drifting counter; a counter trigger rides a write path already at ~27 + ~39 ms | step 1's 304 share is under 20 %: go to step 3; step 3's trigger adds over 2 ms to the insert or the oracle disagrees: keep the index-only scan | 24 h log count; Insights calls of `countsRead` vs the GET count, before and after; for step 3, a rolled-back insert-cost lab like ap-08 | claude, agy, grok (304 path); grok, claude (c2), agy (counter) |

<a id="ws-doc-61813fbd-3d47-4078-8352-d6cd39e39b84"></a>
## 4. Disputed items, both sides in one line each

- **P5-03 gain:** c1 printed ~97 s and ~1.0 M statements; g2 recomputed ~61 s and ~0.75 M (2.5 box reads per sweep unit). The plan uses g2's figure, and c1 accepts it.
- **P5-10 rank:** a2 counts the 126 s as the gain; g2 says it is a ceiling, because the client sends no validator. The plan ranks it last and gates it on a measured 304 share.
- **P5-10 counter (g1 5.3):** c2 and a2 agree, gated on the insert cost; c1 and g2 want the 304 path measured first. Merged as step 3 of one row.
- **g1 5.7, the release-day scalar:** a2 agrees; c2 and g2 say it is already an index range past the `f:seen` mark (`release_notes_released_at`, `rdb/0177_flow_v2.sql:33`), with no EXPLAIN of its own. Two vendors: not in the plan.
- **g1 5.10, batching the three relay reads:** a2 agrees; c2 says two sub-ms round trips with no screen waiting. Its measured part lives inside P5-03. Not a row of its own.
- **m1 #1..#10:** a2 agrees; c2 and g2 say each is landed, live, dropped or self-refuted (see section 5). Two vendors (mistral, agy): not in the plan.
- **a1 #1..#4 and #6..#10:** agy only; c2 and g2 disagree (section 5).

<a id="ws-doc-48faac9d-cd91-4ab0-b910-14c4aea77233"></a>
## 5. Not worth doing, and why

Each line is a measurement or a past round's result.

| practice / proposal | why not | evidence |
|---|---|---|
| Flow-count debounce (ap-06, a1 #1) | no burst was measured; the badge p50 is already 4 ms | `0fd227cd9` (42 -> 4 ms p50); `flowCountsSQL` 7 831 x 9.09 ms (c1) |
| Re-parse `search_tsv` in the insert trigger (a1 #2) | cannot work: 0135 is a BEFORE trigger, so `search_tsv` is not computed yet | `rdb/0135_messages_search_sig.sql:55-64`; the ap-08 lab found no insert piece >= 10 ms (`f7536e327`) |
| Split the archived OR, walk subject index (ap-03, ap-09, m1 #10, a1 #3, #4) | topic heads replaced the walk on prd | `SPOOL_HUB_TOPIC_HEADS: "on"`; the 2026-10-06 plan measured the split 20x worse; topic-list reads are 92 x 44.96 ms and 150 x 23.48 ms (g1), outside the top |
| m1 #1..#9 (flow place key, archived lines by mark, autovacuum, heads, echo fix, insert batch, context-takeover deflate, `since=`, flow-scope) | already landed or live, or self-refuted | commits `0fd227cd9`, `4b14b1e77`, `8fc4fd7aa`, `71a2a4a92`, `180849fdf`, `f7536e327`, `ce9ed78c2` (g2 section 3); takeover was rejected for +258 MB heap at 200 sockets (`hub/wui.go` comment) |
| Flow fan-out as a delta (a1 #7) | 6.6 s/day, and a missed frame drifts the badge | a1: 310 x 21.31 ms |
| `file_count` column for search (a1 #8) | a write cost on every insert for 6 calls a day | a1: 6 x 320 ms; the JSON parse is not separated from the 320 ms |
| `withoutAgent` slice copy, merge frame alone (a1 #9, #6) | no measurement | g2 section 4 |
| Cache the checkov install (a1 #10) | already landed, and it is CI | `.github/workflows/65_iac-checkov.yml:51` (`actions/cache`, round 4 C3) |
| Box hello UPSERT rate | no screen waits; halving it doubles how long a dead box reads online | 135 886 x 0.32 ms = 43 s; `defaultPresenceEvery = 30 * time.Second`, TTL 2x (`hub/presence.go:24`) |
| A `set_config` campaign | the scope already rides in its statement's batch | 1 919 995 x 0.01 ms; `scopeBatch` in `api/store/rls.go` |
| `TenantsMissingPublicNotice` | 0.6 %, and the function is IMMUTABLE | 86 x 68.95 ms; `rdb/0173*.sql:39` |
| One home for the signed-human predicate | drift risk only, with no speed gain and no incident; fold it into P5-03 only if that lane edits all three statements | 3 copies in `api/store/fallback_postgres.go` (84, 115, 148) |
| A short cache in front of channel counts | the API plan's own gate ("only if above 20 ms") is missed | 14.02 ms (c1), 14.26 ms (g1) |
| `change_stamp` hot row, box beats | the means show no queue | `tenant_change_bump_one` 0.61 / 0.18 ms; `box_beats` 0.60 ms |
| `synchronous_commit` off | trades durability for an insert gap ap-08 already put on WAL and the network | `f7536e327` |
| Enable `pg_stat_statements` | restarts the instance: an owner call; Insights is the stand-in | 2026-10-06 plan |
| Read replica, prepared plans everywhere | the DB is 1.2 % busy; planning is 9 ms of the warm 57 ms sweep | c1 section 1; g1 warm plan |

<a id="ws-doc-99130e3f-c123-4f60-86c5-c10abf8171c9"></a>
## 6. Build lanes

Owner: consensus, then build, with no further go. Run order is section 3's
order. Rows 1..9 can run in parallel: their files are disjoint. Two
constraints:
- Row 2 lands before row 10's step 3: both touch the message write path, and
  row 2's insert measurement must be the only new write-path work in its window.
- Rows 2, 7 and 10 each take the next free migration number at push time.
