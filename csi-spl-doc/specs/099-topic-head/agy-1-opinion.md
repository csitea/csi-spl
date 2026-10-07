# 099 Topic head: opinion of panelist agy-1

**Reviewer**: agy-1 (AntiGravity panelist 1, lane `a-459`)  
**Target Spec**: `csi-spl-doc/specs/099-topic-head/spec.md` (v0.1 draft)  
**Topic**: Spec 099 Panel Discussion (Step 2 of HUM-10 rule)  

---

## 1. Verdict

accept with changes: spec section 2 and sections 5.2/5.3 miss member-level key matching for Viewer/Agent, an index for Parent queries, Kinds ordering in oracle comparison, and due-head query partitioning under LIMIT.

---

## 2. Findings

### Finding 1: Viewer and Agent without box cannot use JSONB key lookup on `parties`
- **Spec section**: 2 (row 8), 3.2, 5.2.
- **What is wrong or missing**: Spec 5.2 specifies `Agent`/`Viewer` filter as an `EXISTS over parts in the message filters whose parties has the key (id@box, or any id@ key)`. But `topic_head_parts.parties` stores keys formatted as `"id@box": n` (`spec.md:101`). In Postgres JSONB, the `?` existence operator tests exact string equality; there is no prefix-match operator (`? LIKE 'id@%'`). When `Agent` is provided without `AgentBox`, or when `Viewer` is provided, today's walk checks `(from_id = id OR to_id = id)` across *any* box (`view_postgres.go:257-268`). Matching "any `id@` key" against `parties` requires dynamic key expansion `EXISTS (SELECT 1 FROM jsonb_object_keys(parties) k WHERE k LIKE id || '@%')`, which unpacks JSONB for every part candidate during the index scan.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go:257-268` (`walkParties`); PostgreSQL 16 documentation (§9.16 JSON Functions and Operators).
- **Proposed change for v1.0**: Add a `members` column to `topic_head_parts` (`members jsonb NOT NULL` formatted as `{"<id>": n}`, or `members text[] NOT NULL`). Then `Agent` without box and `Viewer` can perform direct, fast lookups: `members ? id` (or `id = ANY(members)`), while `parties ? 'id@box'` is used when `AgentBox` is specified.

### Finding 2: Missing index for `Parent` queries on `topic_head_parts` causes full tenant scans
- **Spec section**: 2 (row 9), 3.2, 5.2.
- **What is wrong or missing**: Today's `viewTopicsSQL` narrows child topics with `l.task_id IN (SELECT p.task_id FROM messages p WHERE p.tenant_id = tn AND p.parent_task_id = p::uuid)` using the index `messages_parent` (`0008_channels_threads.sql:36`). `topic_head_parts` defines `first_parent uuid NULL` (`spec.md:102`), but section 3.2 defines NO index on `first_parent`. When `q.Parent` is queried, an index scan on `(tenant_id, last_at DESC)` must evaluate `first_parent` across all topics in the tenant until LIMIT is reached, which causes high latency when child topics are sparse or older.
- **Evidence**: `csi-spl-rdb/src/sql/postgres/spool-hub/0008_channels_threads.sql:36`; `csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go:306-307`.
- **Proposed change for v1.0**: Add partial index to `topic_head_parts`: `(tenant_id, first_parent, last_at DESC, task_id DESC) WHERE first_parent IS NOT NULL`.

### Finding 3: Tenant-wide due-head probe degrades filtered/channel queries under LIMIT
- **Spec section**: 3.1, 5.2, 5.3, 9 (risk 6).
- **What is wrong or missing**: Section 5.3 states: "The statement takes the due heads of the tenant from `(tenant_id, valid_until)` and reads each the exact way today's `listed()` already does for `TaskIDs`... then merges them with the head rows by the walk key and applies the LIMIT". `topic_heads` index `(tenant_id, valid_until)` is tenant-wide (`spec.md:90`). If 200 topics in various channels expire, a query for `channel = 'crew' LIMIT 10` would probe all 200 due topics against `messages_task_received`, even if none belong to `'crew'`.
- **Evidence**: `csi-spl-doc/specs/099-topic-head/spec.md:278-286`; `view_postgres.go:340-347`.
- **Proposed change for v1.0**: For channel list queries, filter due candidates by joining `topic_head_parts` on `channel = q.Channel` (or checking part `valid_until`) before feeding task IDs into `listed()`. Furthermore, document that `Merge Append` merges the pre-sorted fresh index scan with the sorted due result under the `before=` cursor and `LIMIT`.

### Finding 4: Chronological `Kinds` slice in `TopicRow` vs `{kind: n}` JSONB breaks `sameRows` oracle comparison
- **Spec section**: 2 (row 4), 3.2, 7.1.
- **What is wrong or missing**: Spec 2 notes "the hub only counts kinds into a map (`hub/view.go:856`), so order does not matter". For HTTP API JSON, this is true. However, in unit tests, `sameRows` (`view_topics_test.go:141`) asserts `fmt.Sprint(x.Kinds) != fmt.Sprint(y.Kinds)`. In today's walk, `Kinds` is `array_agg(m.kind ORDER BY m.received_at, m.msg_id::text)` (`view_postgres.go:356`). Storing `{kind: n}` in `topic_head_parts` loses the message-by-message chronological interleaving. When T005 hooks `topicHeadRead` into `TestTopicHeadCases` (`topic_head_harness_test.go:495`), `sameRows` will fail.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/store/view_topics_test.go:141`; `csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go:356`; `csi-spl-api/src/go/spool-hub-api/internal/hub/view.go:869-871`.
- **Proposed change for v1.0**: Clarify in section 7.1 and tasks.md T003/T005 that `sameRows` must normalize `Kinds` into a frequency count map (matching hub semantics) rather than comparing stringified slices.

### Finding 5: `task_id::text DESC` in query prevents index scan on UUID `task_id DESC`
- **Spec section**: 2 (row 1), 3.1, 5.2, 9 (risk 4).
- **What is wrong or missing**: Spec 3.1 defines indexes on `(tenant_id, last_at DESC, task_id DESC)` where `task_id` is a `uuid` column. Today's walk orders by `l.received_at DESC, l.task_id::text DESC` (`view_postgres.go:323, 368`). If `viewTopicsHeadSQL` orders by `task_id::text DESC`, Postgres will not match the index on column `task_id` without an explicit sort node. Standard UUID binary comparison produces identical collation order to lowercase UUID text strings.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go:323, 368`; `csi-spl-doc/specs/099-topic-head/spec.md:88, 424`.
- **Proposed change for v1.0**: Define `viewTopicsHeadSQL` to order by `(last_at DESC, task_id DESC)` and cast `$before_task::uuid`, or define the index explicitly as `(tenant_id, last_at DESC, (task_id::text) DESC)`.

### Finding 6: Door per part vs door per line invariance needs explicit documentation
- **Spec section**: 2 (rows 1, 4), 5.2.
- **What is wrong or missing**: Spec section 2 contrasts "order key ignores the door" with "Count applies the door per line (`aggDoor`)", but does not explicitly prove whether a part is ever partly visible to a reader.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go:286-291` (`readerDoor`).
- **Analysis & Proposed change for v1.0**:
  - *Is a part ever partly visible to a reader?* **NO.** Every message in a part belongs to the same channel `c:<ch>` or the exact same DM pair `d:<id1> <id2>`. The read door predicate `(channel = ANY(pub) OR channel = ANY(mine) OR (channel IS NULL AND (from_id = rd OR to_id = rd)))` depends solely on the channel name or endpoint IDs. For any given reader `rd`, every line in `c:<ch>` evaluates identically, and every line in `d:<id1> <id2>` evaluates identically. A part is strictly 100% visible or 0% visible.
  - Document this invariance in section 2 and 5.2 so that future maintainers understand why `door(part)` on `topic_head_parts` exactly reproduces `aggDoor(line)` on `messages`.

### Finding 7: Asymmetry between `Roots`/`Parent` filter and summary `Parent`
- **Spec section**: 2 (rows 4, 7), 5.2.
- **What is wrong or missing**: In today's walk:
  1. The filter `q.Roots` / `q.Parent` inspects the first message under *message filters* (Channel, DM), **ignoring the read door** (`view_postgres.go:231-234`).
  2. The returned summary field `TopicRow.Parent` is extracted from the first message passing message filters **AND the read door** (`view_postgres.go:361-367`).
  A head row alone cannot answer this because `topic_heads` lacks parent columns.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go:231, 365`.
- **Proposed change for v1.0**: Section 5.2 must explicitly specify two distinct part evaluations:
  - For filter evaluation: pick the earliest part (`min(first_at, first_msg_id)`) matching message filters (no door) and check its `first_parent`.
  - For summary output: pick the earliest part matching message filters AND door, returning its `first_parent` as `TopicRow.Parent`.

### Finding 8: `TaskIDs` delta queries bypass heads in Phase 1
- **Spec section**: 2 (row 10), 5.4, 10 (Q5).
- **What is wrong or missing**: Spec Q5 keeps `TaskIDs` on today's `listed()` read over `messages`. While safe for phase 1, `TaskIDs` queries could be answered by `topic_heads` PK lookups `(tenant_id, task_id)` when `valid_until > now`, eliminating `messages` reads for delta polls.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go:199-201, 341-347`.
- **Proposed change for v1.0**: Accept Q5 for Phase 1 as proposed to minimize initial risk; schedule Phase 2 task to switch `TaskIDs` to `topic_heads` PK lookups.

---

## 3. Answers to Owner Questions (Spec Section 10)

- **Q1 (Triggers vs Go writers)**: **AGREE** with Triggers (4.1). Covering 14+ Go write sites, migrations, cascades, sweep purges, and manual psql operations in a single database-enforced mechanism prevents silent drift. Follows proven rdb 0103 precedent.
- **Q2 (Exact vs lag for expired lines)**: **AGREE** with Exact (5.3). Due heads read directly from `messages` maintain exact parity with today's walk at every second without waiting for the 10-minute sweep. The due set is small between sweeps, so the cost is negligible.
- **Q3 (Shadow before switch)**: **AGREE WITH CHANGES**. 24 h of shadow on prd is essential, but the shadow comparison in `hub/view.go` must normalize `Kinds` (comparing kind count maps rather than `[]string` slice order) to prevent spurious mismatch alerts.
- **Q4 (prd DDL and backfill go)**: **AGREE**. Apply 0138 DDL, backfill, verify, and shadow on dev first. c-001 executes prd steps after 24 h clean shadow on dev.
- **Q5 (Switch list shapes, leave TaskIDs)**: **AGREE**. Leaving `TaskIDs` on today's per-topic read keeps the initial cut simple and bounded.
- **Q6 (Insert cost budget)**: **AGREE**. Under 5 ms added p95 at 200k messages is an appropriate gate.
- **Q7 (Drop ap-03 and ap-09)**: **AGREE**. Both ap-03 and ap-09 optimize the recursive walk that topic heads eliminate. Once topic heads are `on`, both should be dropped.
- **Q8 (Daily verify in workflow 45)**: **AGREE**. Automating `do_spl_topic_head_verify` in daily backup workflow guarantees detection of any unexpected drift within 24 hours.

---

## 4. Tasks.md Adjustments

1. **T001**: Incorporate the five harness findings from `test-results.md` (replace `oracleTopicsSQL` with `refTopicsSQL`, include `ArchiveChannel` E29, archive mirrors E13, serial sweep E24).
2. **T002**:
   - Add `members` (`jsonb` or `text[]`) to `topic_head_parts` for exact member matching (`Agent` without box, `Viewer`).
   - Add partial index on `topic_head_parts`: `(tenant_id, first_parent, last_at DESC, task_id DESC) WHERE first_parent IS NOT NULL`.
   - Align `task_id` sorting as UUID in both indexes and queries.
3. **T003 / T005**: Update `sameRows` in oracle and shadow comparators to compare `Kinds` by count map rather than stringified slice.
4. **T005**: In `viewTopicsHeadSQL`, partition due-head probes by channel for channel list queries, and use `Merge Append` to combine pre-sorted fresh head index scans with due-head results under cursor and `LIMIT`.
