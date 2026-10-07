# 099 Topic head: panel opinion, seat claude-4 (the alternatives)

Seat: c-456, devil's advocate. Read on trunk `ae42081c6` (spec v0.1 on master
since `a44a267b4`). Opinion only: no spec, task or source file changed.

## 1. Verdict

**Accept with changes: build a narrow head first (the walk key and the
archived flags per topic, today's `summary()` kept), and store the summary
only if the narrow head's prd numbers leave it short.** The reason: in the lab
the narrow head buys about 75..85 % of the gain, with no stored count, kinds,
parties or subject, which is where most of the correctness risk of v0.1 sits.

## 2. The lab behind the verdict

One throwaway Go test in package `store`, not committed. It reuses the
builder's own `topicsSQL` pieces (`walkLatest`, `readerDoor`, `walkParties`,
`archivedTopicHideSQL`, `summary`), so each variant differs only in its walk.

- **Tree:** `ae42081c6`, all migrations through 0143.
- **Database:** postgres:16-alpine in docker, as the non-superuser
  CREATEROLE app role (the `hub-pg.tst.sh` shape, so RLS binds).
- **Session:** every statement under `pgScopeTenantNoJIT`, the hub's settings.
- **Data:** `seedTopics(22 000 messages, 1 500 topics)`, which gives 600 topics
  with a DM line. Then 380 archived rows, one per topic, near prd's 388
  archived cards.
- **Narrow head:** `lab_nh(tenant_id, task_id, last_at, dm_last_at)` and
  `lab_nhp(tenant_id, task_id, channel, last_at)`, built by `GROUP BY` over the
  unexpired lines, with the indexes of spec 3.1 and 3.2.
- **n:** 20 timed runs per cell after 3 warm-ups, one seed.
- **Equality:** `sameRows` of each variant against today's walk.

| shape | (a0) today's walk p50 / p95 ms | (c) walk + archived split (ap-03) | (b) narrow head + today's `summary()` | walk key only (a lower bound for the full head) | rows equal |
|---|---|---|---|---|---|
| `dm=true`, reader HUM-1, limit 51 | 135.9 / 158.8 | 118.5 / 133.7 | **28.6 / 41.0** | 13.8 / 24.2 | yes (c, b) |
| all, reader HUM-1, limit 51 | 110.8 / 120.5 | 113.2 / 153.4 | **31.4 / 70.6** | 14.2 / 25.3 | yes |
| `channel=c1`, limit 21 | 37.0 / 73.5 | 31.7 / 54.2 | **13.6 / 14.9** | 6.0 / 8.8 | yes |
| `dm=true&peer=AGT-1`, limit 21 | 198.9 / 262.0 | 178.7 / 255.2 | **31.4 / 40.1** | 23.2 / 38.4 | yes |

What the lab says:

1. The walk is the cost. Replacing it with a one-row-per-topic key cuts
   4.3..6.3x on the list shapes, with today's `summary()` unchanged and the
   rows equal.
2. The stored summary saves about 15 ms more per list in the lab. That is the
   gap between the (b) column and the walk-key-only column, which still reads
   no summary at all.
3. The archived split (ap-03) under the hub's settings is noise: from -13 % to
   +2 %, with a worse p95 on `all`.

Lab caveat: the seed is synthetic, with short topics (about 15 lines each).
prd's long topics (the lobby, long DMs) make `summary()` dearer, so the gap in
point 2 grows on prd. How much is not measured here, and T009 must measure it
(finding 1).

### 2.1 The four options against the plan's prd numbers

The prd baselines are from the perf plan. The (a) and (b) prd p50 figures are
my estimates: the lab ratio applied to the route p50. They are not
measurements.

| option | expected prd list p50 | write cost | correctness risk | build size |
|---|---|---|---|---|
| (a) head as specified | DM seed 269..354 -> about 30..60 ms; walks' 239.9 s/day -> about -90 % | Insert: two upserts with jsonb increments. Update or delete of 10 columns: a rebuild that re-aggregates the WHOLE topic, the subject included. A sweep chunk of up to 5 000 rows rebuilds every topic it touches. | high: door per line per part, party counts, `first_*` per part, the subject function's parity with Go, and the earliest expiry | 2 tables, 6 functions, 3 triggers, and the 28-case oracle against stored aggregates |
| (b) narrow head (walk key, per-channel `last_at`, archived flags) + today's `summary()` | about 60..90 ms (lab ratio 0.16..0.37 of today); walks about -75 % | Insert: one GREATEST upsert per head and per channel part. A rebuild is O(parts) index probes (max per key), never a topic aggregate. Edit, kind and party changes touch nothing. | low: only the order key and the archived flags are stored, and the count, kinds, parties and subject still come from `messages` | about 1/3 of (a): no jsonb, no subject function, no parties |
| (c) no table: an index or a rewrite of the walk | 0..-15 % (lab, ap-03 split). The walk still visits ~45 lines per listed topic (plan 3.3: 2 301 for 51) | 0 | low | small. It cannot remove the "is this the latest line" step without stored state. |
| (d) a cache in the hub | about today's p50 | 0 DB | medium (multi-instance invalidation) | medium |

Why (d) cannot win: the topics route already answers repeat reads with 304
from the tenant change stamp (`hub/view.go:50`, `hub/view_stamp.go`, R2-5).
The 446 lists measured in 8.4 h are the misses. `read_marks` bumps that same
stamp on every PUT (`rdb/0103_tenant_change_stamps.sql:145`), and a tab sends
one every 5 s. A hub cache would key on the same stamp and miss as often. A
messages-only stamp might raise both hit rates, but that is a separate,
unmeasured idea (I believe, unchecked).

## 3. Findings, most severe first

1. **The full summary in the head is the dear half, and it is unproven against
   the cheap half.** Spec sections 3.2, 4.2 and 5.2.
   - **Wrong or missing:** v0.1 stores `n`, `kinds`, `parties` and `first_*`
     per part. Every v0.1 case except the order and archived ones (E04, E05,
     E06, E21, E26, E27 and the party side of E07..E12) exists only to keep
     those aggregates right. The lab (section 2) shows the walk key alone
     carries most of the gain.
   - **Change for v1.0:** split the build in two phases.
     - **Phase 1:** `topic_heads` with `last_at`, `last_msg_id`, `dm_last_at`,
       `dm_last_msg_id`, `card_archived`, `archived_rows` and `valid_until`,
       plus one part row per channel (`last_at` only). The read takes the head
       walk, then today's `summary()`.
     - **Phase 2 (the stored summary):** only if phase 1's prd numbers (ap-00
       n=20 per shape, route p50 over 24 h) leave a list above an agreed
       target. I propose 100 ms p50. T009 also reports `summary()`'s share of
       each shape, so the phase 2 decision rests on a measurement.

2. **The migration number is taken many times over.** Spec section 3.
   - **Wrong:** the spec says "0138 (ap-01a takes 0136 and ap-04 0137)".
   - **Evidence:** on trunk, `ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1`
     prints `0143_messages_search_index.sql`. 0137 is
     `flow_events_place_key`, 0138 is `messages_autovacuum`, and 0136 is
     `tenant_settings_jsonb`.
   - **Change for v1.0:** "next free at rebase, 0144 today". Also drop the
     stale ap-01a and ap-04 numbers.

3. **The sweep chunk is 5 000 rows, not 500.** Spec sections 4.3 (sweep row),
   4.4 (lock time) and 7.3 C5.
   - **Evidence:** `store/postgres.go:598` is `const sweepChunk = 5000`.
   - **Why it matters:** with the statement-level `topic_head_del` trigger, one
     chunk rebuilds every topic it touches in a single transaction and holds
     every one of those head locks until commit. Under (a) each rebuild is a
     whole-topic aggregate.
   - Steady state is small: retention is 720 h (`config.go:304`), and prd has
     about 22 k live lines, so about 730 lines expire a day, about 5 per
     10-minute sweep. A backlog is the bad case: a hub that was down, or a
     retention cut.
   - **Change for v1.0:** state 5 000. Make C5 and 7.5 time a 5 000-row
     chunk spread over 1 000 topics, and print the longest head-lock hold.

4. **"About one head row per listed topic" holds only for unfiltered shapes.**
   Spec sections 1.2 and 5.2.
   - **Wrong:** the door, `peer=`/`Agent`, `Viewer` and the archived hide
     still reject heads one probe at a time. In v0.1 the door is an `EXISTS`
     over the topic's parts, and agent-to-agent DM topics fail it for a human
     reader.
   - **Evidence (lab):** the walk-key-only floor is 13.8 ms for the DM reader
     but 23.2 ms for `peer=AGT-1`, at the same limit-to-rows ratio. On prd the
     DM list for a human skips the fleet's agent-to-agent DMs (I believe,
     unchecked, that those are most of the DM topics).
   - **Change for v1.0:** T009 reports heads visited per listed row for each
     shape. If the DM shapes visit more than 3 heads per row, add a per-end DM
     key: one row per (member, topic) with `dm_last_at`, so the DM list seeks
     on the reader instead of filtering.

5. **`valid_until` should follow the walk key's line, not the earliest line**
   (narrow head). Spec sections 3.1 and 5.3.
   - **Why:** in (b) the summary already reads `messages` with the expiry
     filter. Only the order key can go stale, and the latest line expires
     before the older ones only when retention is mixed in one topic
     (`alerts` 168 h against 720 h, `hub/server.go:557`) or a moved line keeps
     its old `expires_at`.
   - **Change for v1.0:** `valid_until = expires_at` of the head's own
     `last_*` / `dm_last_*` line (and the same per channel part). The due set
     is then close to empty, and E21 (the subject moves when the first line
     expires) needs no due read at all.

6. **Hot-row serialisation on busy topics is not tested.** Spec sections 4.4
   and 7.5.
   - **Wrong:** `topic_head_add` takes the head row's lock and holds it until
     the insert commits, so two inserts into the lobby (or one busy DM)
     serialise for the length of the insert statement. The plan measures that
     statement at 46..86 ms mean (Insights, plan 3.2 row 9). Today two inserts
     into one topic take no common lock: 0103 spreads its stamp over 16 slots
     (`0103:22-45`).
   - **Gap:** 7.5 times a lone insert only.
   - **Change for v1.0:** C1 also reports wall time for 2 x 200 inserts into
     ONE topic, with and without the trigger, n=5 rounds. The 5 ms gate then
     applies to the added p95 under that contention.

7. **The tie-break index cannot serve `ORDER BY task_id::text`.** Spec section
   9, row 4.
   - **Why:** a uuid compares as 16 bytes, and its canonical text is
     fixed-width lowercase hex, so the two orders are the same. But the
     planner only knows that the index is ordered on `task_id`, not on
     `task_id::text`.
   - **Evidence:** in the lab the head walk ordered by the uuid
     (`l.task_id DESC`) returned rows equal to today's `task_id::text` order on
     all 4 shapes (n=1 seed).
   - **Change for v1.0:** the head statement orders and compares its cursor on
     the uuid, and E28 pins the equality. Drop the `(task_id::text)` index
     fallback.

8. **The third oracle and the case list are out of date.** Spec sections 4.3
   and 7.1.
   - **Wrong:** `test-results.md` 1.2 already showed that
     `oracleTopicsSQL` has no door, no archived hide and no NoIssues, so it
     cannot be the third answer. It also added E29 (`ArchiveChannel`) and E30.
   - **Change for v1.0:** name `refTopicsSQL` as the oracle and list
     E12b/E13b/E29/E30. Under (b), E04/E05/E06 (edit, kind) become "the head
     does not change", which is a cheaper and stronger assertion: `rev` stays
     the same.

9. **The memory store parity is unaffected.** Spec section 5.4.
   - `Memory.ViewTopics` (`store/view.go:191`) builds its rows live, and
     `TopicRow.Kinds` is read only as a count map (`hub/view.go:869`; that
     line and `store/view.go:221` are the only `.Kinds` reads of `TopicRow`).
     So neither (a) nor (b) needs a memory head.
   - **Change:** none, but say so in v1.0, so nobody builds a memory head.

## 4. Owner questions Q1..Q8

| # | answer | why |
|---|---|---|
| Q1 triggers | **agree** | Even more so under (b): the trigger watches `task_id`, `channel`, `received_at`, `expires_at` and `archived_at` only. An edit, a kind change and the search_sig backfill never fire it. |
| Q2 exact | **agree** | Under (b) it is almost free: the summary is read live, and only the order key needs a due read (finding 5). |
| Q3 shadow | **agree, with a change** | Gate on n, not on the clock: at least 500 compared requests covering all 6 route shapes of plan 3.1, 0 mismatches. At 1 in 10 of about 1 275 lists a day, 24 h gives about 127, too few for the rare shapes (`peer=` had n=9 in 8.4 h). Sample 1 in 2 on prd: the extra walks cost at most about 5 % of DB time while the shadow runs. |
| Q4 prd DDL | **agree** | The DDL lands before the hub, and the hub probes for the tables. |
| Q5 TaskIDs stays | **agree** | It is already one short probe per topic. |
| Q6 5 ms p95 | **agree, plus contention** | Finding 6: the same budget under 2-writer contention on one topic. |
| Q7 drop ap-03 / ap-09 | **ap-03: drop** (lab n=20: -13..+2 %, p95 worse on `all`). **ap-09: defer, do not drop** | Under (b) the subject LATERAL still runs (plan 3.3: 51 x 1.5 ms on prd). Re-measure it after phase 1. It folds away only if phase 2 is built. |
| Q8 daily verify | **agree** | Under (b) the verify is cheap: one max per key per topic. |

## 5. tasks.md: add, split, reorder

1. **T001:** done (the harness). Replace "pre-027 oracle" with `refTopicsSQL`
   in its text.
2. **New T001b, the lab as a committed perf cell:** add the "narrow head"
   and "walk key only" variants to `TestViewTopicsPerf` (`SPOOL_TEST_PERF=1`),
   so the section 2 table can be re-run by anyone. No product file.
3. **Split T002:**
   - **T002a (phase 1):** migration 0144: `topic_heads` (walk key, archived
     flags, `valid_until` of the key line), the per-channel part (`last_at`
     only), the add and rebuild functions, `topic_head_diff`, the backfill
     function, and 3 triggers on 5 columns. The tests as in v0.1, minus the
     subject function.
   - **T002b (phase 2, gated on T009a's numbers):** the summary columns, the
     `topic_head_subject` function and its parity test.
4. **T003:** the random test gives each seed its own database (test-results
   1.2.4: `Sweep` is global). C1 adds the contention timing (finding 6), and
   C5 uses a 5 000-row chunk (finding 3).
5. **T005:** under phase 1 the head read is the head walk plus today's
   `summary()`. `viewTopicsHeadSQL` reuses `summary(aggDoor)` unchanged, and
   no due-head branch is needed beyond the key-line expiry.
6. **Split T009:**
   - **T009a:** phase 1 rollout and its numbers, plus heads visited per row
     and `summary()`'s share per shape (findings 1, 4).
   - **T009b:** the phase 2 decision, made from T009a's numbers.
7. **Order:** T001b -> T002a -> T003 -> (T004, T006, T005) -> T008 -> T009a
   -> decision -> T002b -> T005b -> T009b. ap-09 stays parked until the
   decision, not dropped.
