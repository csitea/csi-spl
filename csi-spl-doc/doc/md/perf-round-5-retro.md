# DB and API improvements in speed, code refactoring round 5 - retrospective

Measured 2026-10-19 on trunk **`2a620a160`** (`origin/master`) only.
Each count names the command that produced it; n=1 per command unless
stated; historical figures reported by round lanes are marked as not checked
today (or cite their source). This is R8 of [rounds-rulebook.md](rounds-rulebook.md);
section 5 is the input list for the next DB/API round. Times are UTC (commit dates
stored as `+03:00` are converted). Epic: SPL-2402, Task issue: SPL-2581.

Plan: [perf-round-5-plan.md](perf-round-5-plan.md), v1.0 `137178866`
(2026-10-12T17:23:58Z). Discussion and owner history: t1 topic `eafc9b15`
(`eafc9b15-0aa2-41e1-95f0-0e7a59623235`).

---

## 1. What landed and what was dropped

`git log origin/master -E --grep='(P5-[0-9]{2}|perf5|SPL-(1739|1740|1761|1812|1831))' --format='%h %cI %s'` ->
29 matching commits in repository history (18 implementation commits across the 9 live rows, 9 planning/seat commits leading to the merged plan, 1 panel review commit, and 1 retro commit).

The round defined 12 rows in total:
- **9 live rows** landed (P5-01, P5-02, P5-03, P5-05, P5-06, P5-07, P5-08, P5-10, P5-11) across 18 implementation commits.
- **2 dropped rows** evaluated and dropped by their gates (P5-04, P5-09) with 0 commits.
- **1 covered row** covered by another row's landing (P5-12 covered by P5-11, `41e4a4a09`).

*(Note: The before/after figures below were reported by the respective lanes during the round in commit messages and status posts, and are not checked today on origin/master unless explicitly noted; sources and sample sizes n are cited per row).*

| row | what | state | landed sha(s) | lane | reported before / after (n) |
|---|---|---|---|---|---|
| P5-01 | Unanswered sweep reads only moved topics; full reconcile hourly | **Live** | `74bfcaaab`, `f9f5690dd` | - | Full p50 40.8 ms (~15 k buffers) -> delta p50 5.5 ms (233 buffers), interleaved n=20; prd DB time per day -40 % (not checked today; source: commit `74bfcaaab`) |
| P5-02 | Topic head add stays index probes; new topics skip rebuild | **Live** | `18391f687` (rdb 0182) | c-873 | New topic drain p50 57.88 -> 3.52 ms, existing 6.41..6.70 -> 3.36..3.49 ms; lab pg16, n=30 (not checked today; source: commit `18391f687`) |
| P5-03 | Relay sweeps paced by deadline; queued rows as one set read | **Live** | `9b2e23359` | - | Prd Insights 24h, n=1 239 789 calls across 5 statements: 85.1 s/day -> 23.6 s/day (~61.5 s/day saved) (not checked today; source: commit `9b2e23359`) |
| P5-04 | Flow fold as one set anti-join | **Dropped** | None (no commit) | c-875@sat | Prd read-only EXPLAIN n=6: targeted subplans took only ~4.6 ms of ~90 ms warm (5 %) and 2 133 ms cold (0.2 %); dropped by gate (not checked today; source: lane c-875 report in topic `eafc9b15`) |
| P5-05 | search_sig full compare runs only on Postgres change | **Live** | `86aa493c8` | c-876 | Prd read-only n=5: full 824 ms warm (758..965) -> skip 5.6 ms mean (3.9..7.2) (not checked today; source: commit `86aa493c8`) |
| P5-06 | Issue list stops selecting description; modal loads by number | **Live** | `d99a0b3a3` (WUI), `f054c9b53` (API) | c-962 | Prd read-only EXPLAIN n=6: a large workspace mean 32.21 -> 4.06 ms (buffers 365 -> 141); t1 7.26 -> 4.75 ms (not checked today; source: commit `f054c9b53` and topic msg `57cae892`) |
| P5-07 | DM pointers probe archived lines lazily under page LIMIT | **Live** | `474df9fbb` | - | Prd t1 EXPLAIN warm: before n=5 57.4..87.2 ms (29 443 buffers, 2 511 probes) -> after n=6 22.0..31.4 ms (3 554 buffers, 20 probes) (not checked today; source: commit `474df9fbb`) |
| P5-08 | Release-note list numbers only its page | **Live** | `2abefb129` | - | Prd read-only EXPLAIN n=5: first page median 77 ms (5 714 rows sorted) -> 11.4 ms (136 rows read); deep page 9.3 ms (not checked today; source: commit `2abefb129`) |
| P5-09 | Typed structs for WUI frames | **Dropped** | None (no commit) | c-879@sat | Allocs fell less than half at 1/10/50 sockets (message frame -8 % at 10, -2 % at 50; channel frame -41 %); n=6; dropped by gate (not checked today; source: patch `c-879-p5-09.patch`) |
| P5-10 | Channel GET 304 gate reachable; narrow change stamp | **Live** | `4aa64b607` (rdb 0190), `b077fc75f`, `f317ec6a2`, `928e94489`, `67c6ff1e9`, `232887b65` (rdb 0196), `c63490453` | c-963, c-981 | 304 share on prd t1, n=4 1-hour windows: 0 % (0/739) initially -> 5.4 % (5/92) after read-marks fix -> 8.7 % (12/138) -> **78.6 %** (679/864) after rdb 0196 (not checked today; source: commits `4aa64b607`, `f317ec6a2`, `232887b65`, `c63490453`) |
| P5-11 | Flow page cuts flow_events page before joining messages | **Live** | `41e4a4a09`, `b56d1671f` | c-334 | Prd EXPLAIN warm, t1/HUM-10 first page, n=6: 84.5-102.7 ms (32 292 buffers) -> 20.2-21.8 ms (5 863 buffers); cold lab 66-98 -> 20-29 ms (not checked today; source: commit `41e4a4a09`) |
| P5-12 | Flow fold: page first, join after | **Covered** | `41e4a4a09` | - | Covered by P5-11 (`41e4a4a09` resolved the same misestimate by slicing flow_events before joining messages) (not checked today; source: commit `41e4a4a09`) |

---

## 2. Gate outcomes and dropped rows

The plan established empirical gates for each row (section 3 of `perf-round-5-plan.md`). Two rows were evaluated and dropped by their gates:

### P5-04: Flow fold set anti-join
- **Gate:** *"EXPLAIN (ANALYZE, BUFFERS) under a member scope, n >= 5, shows the subplan is not the time"*.
- **Reported measurement:** Lane `c-875@sat` on tree `137178866`, prd read-only `EXPLAIN (ANALYZE, BUFFERS)` of `flowFoldSQL()` for member t1/HUM-10 (6 633 live events), n=6 (not checked today on origin/master; source: lane c-875 report in topic `eafc9b15` at 2026-10-12 19:48:29 UTC):
  - Cold run: 2 133.0 ms total execution time; event x message join took 2 104.5 ms; covered subplans (SubPlans 1, 2, 4) took only ~4.6 ms (~0.2 % of total time).
  - Warm runs (2..6): 85.7..92.3 ms total execution time; join took 70.4..76.4 ms; covered subplans took only ~4.6 ms (~5 % of total time).
- **Outcome:** Dropped without commit. An anti-join targeting subplans could save at most ~4.6 ms of ~90 ms.
- **Discovery leading to P5-11 / P5-12:** Lane `c-875` identified that Postgres estimated `rows=29` for 6 633 member events, inducing a `Seq Scan on flow_events` and individual `messages_pkey` probes for all 6 633 events before the `LIMIT`. That insight defined the scope for P5-11.

### P5-09: Typed structs for WUI frames
- **Gate:** *"allocs fall by less than half in a new go test -bench at 1 / 10 / 50 sockets, n >= 6"*.
- **Reported measurement:** Lane `c-879@sat` on tree `e31015b51`, `GOMAXPROCS=1 go test ./internal/hub -bench 'BenchmarkFrame' -benchmem -count 6`, n=6 (not checked today on origin/master because the patch was uncommitted; source: patch `/var/tmp/claude/c-879-p5-09.patch` and dispatcher post in topic `eafc9b15` at 2026-10-12 20:35:09 UTC; today's `BenchmarkFanoutWUI-16` on origin/master was measured separately below in Input 2):
  - Message frame allocations: 1 socket: 56 -> 32 (-43 %); 10 sockets: 291 -> 267 (**-8 %**); 50 sockets: 1 324 -> 1 304 (**-2 %**).
  - Channel frame allocations: 1 socket: 42 -> 24 (-43 %); 10 sockets: 349 -> 205 (**-41 %**); 50 sockets: 1 710 -> 1 004 (**-41 %**).
- **Outcome:** Dropped without commit. Allocations did not fall by at least half at 10 or 50 sockets for either frame type. The channel frame encode-once patch was preserved for reference in `/var/tmp/claude/c-879-p5-09.patch`.

### P5-12: Flow fold page first, join after
- Proposed following the P5-04 discovery to stop full-scan probes before the page limit.
- **Outcome:** Covered by P5-11 (`41e4a4a09` and `b56d1671f`), which implemented page-cutting on `flow_events` prior to joining `messages`. No separate commit or migration was required.

---

## 3. Timeline: from plan to last landing

- **Plan landed:** `137178866` on 2026-10-12T20:23:58+03:00 (17:23:58 UTC).
- **First row landed:** `86aa493c8` (P5-05) on 2026-10-12T20:43:17+03:00 (17:43:17 UTC) — 19 minutes after plan landing.
- **Wave 1 evening completions (2026-10-12):**
  - 20:48:42+03:00 (17:48 UTC): P5-01 landed (`74bfcaaab`).
  - 22:16:06+03:00 (19:16 UTC): P5-07 landed (`474df9fbb`).
  - 22:22:55+03:00 (19:22 UTC): P5-08 landed (`2abefb129`).
  - 22:28:34+03:00 (19:28 UTC): P5-03 landed (`9b2e23359`).
  - 22:31:34+03:00 (19:31 UTC): P5-11 landed (`41e4a4a09`, `b56d1671f`).
  - 23:04:04+03:00 (20:04 UTC): P5-02 landed (`18391f687`, rdb 0182).
  Within 2 hours and 40 minutes of plan landing, 7 rows were landed on master.
- **Wave 2 completions (2026-10-14 morning):**
  - 01:46:55+03:00 (Oct 13 22:46 UTC): P5-06 WUI change landed (`d99a0b3a3`).
  - 02:13:28+03:00 (Oct 13 23:13 UTC): P5-06 API change landed (`f054c9b53`).
- **Wave 3 completions (2026-10-14 P5-10 iterations):**
  - 03:09:43+03:00 (00:09 UTC): P5-10 initial implementation landed (`4aa64b607`, rdb 0190).
  - 08:14:10+03:00 (05:14 UTC): P5-10 read-marks fix landed (`f317ec6a2`, SPL-1761).
  - 14:47:38+03:00 (11:47:38 UTC): P5-10 narrow channels stamp landed (`232887b65`, rdb 0196, SPL-1831).
  - 16:15:11+03:00 (13:15:11 UTC): P5-10 docs recorded (`c63490453`).
- **Total elapsed time:**
  - Plan to last code commit (`232887b65`): **42 hours, 23 minutes, 40 seconds** (~1.77 days).
  - Plan to last documentation commit (`c63490453`): **43 hours, 51 minutes, 13 seconds** (~1.83 days).

---

## 4. What went wrong in running the round

1. **Rows landed without posting to the discussion topic:**
   - On 2026-10-13 21:27:07 UTC, the dispatcher posted in topic `eafc9b15`: *"I post P5-06 and P5-10 here when they land."*
   - While P5-10's progress was continuously posted, P5-06 landed on 2026-10-14 at 02:13:28+03:00 (`f054c9b53`, SPL-1739), but its numbers were never reported to topic `eafc9b15` until the owner asked 5 days later on 2026-10-19 (*"so is this one ready"*). The dispatcher acknowledged in msg `57cae892`: *"32.2 -> 4.1 ms on one workspace, t1 7.3 -> 4.8 ms (n=6; not posted here before)"*.
   - P5-11 landed on 2026-10-12 at 22:31:34+03:00, but in the status table posted at 20:35:09 UTC, its before and after numbers were left blank.
2. **P5-12 was never closed in tracking:**
   - P5-12 was conceived as a follow-up to P5-04's discovery (*"flow fold: page first, join after"*).
   - When P5-11 (`41e4a4a09`) implemented the exact page-cutting solution, P5-12 was covered.
   - However, P5-12 remained listed as queued/in-progress across status posts (e.g. 2026-10-12 19:57:08, 20:35:09) and was never marked completed or formally closed until the final wrap-up post on 2026-10-19.
3. **No retrospective for a week:**
   - Rulebook R8 ([rounds-rulebook.md](rounds-rulebook.md)) specifies: *"After all 10 actions are served: One lane writes the round retrospective... and the dispatcher immediately requests the round <N+1> planner."*
   - The round's last code commit landed on 2026-10-14 at 14:47:38+03:00 (`232887b65`).
   - For 5 days (2026-10-14 to 2026-10-19), no retrospective was opened or queued, leaving the round open and unreviewed until the owner asked on 2026-10-19 (*"so is this one ready"*).

---

## 5. Five inputs for the next DB/API round (measured on `2a620a160`)

All metrics measured on `origin/master` commit **`2a620a160`** (`2a620a160dcb11d41d9203a53a3bc086576f0524`).

### Input 1: `ListReleaseNotes` Seq Scan over 7,130 rows in count subquery and 16 wide columns
- **Issue:** The shipped `ListReleaseNotes` query (`csi-spl-api/src/go/spool-hub-api/internal/store/release_note_postgres.go:162-173`) paginates via a `WITH page AS (...)` CTE, but evaluates `(SELECT count(*) FROM release_notes WHERE version IS NOT NULL)` directly in the main projection on every page request. Furthermore, it projects all 16 columns (`releaseNoteCols`, row width 422 bytes) including 6 large text fields (`lay_what`, `lay_how`, `lay_why`, `tech_what`, `tech_how`, `tech_why`).
- **Measurement command:**
  ```bash
  cd csi-spl-orc && ENV=prd SQL="EXPLAIN (ANALYZE, BUFFERS) WITH page AS (
      SELECT DISTINCT array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) AS k
      FROM release_notes
      WHERE version IS NOT NULL
      ORDER BY k DESC LIMIT 30
  )
  SELECT sha, coalesce(version, ''), committed_at, kind, area, subject,
      lay_what, lay_how, lay_why, tech_what, tech_how, tech_why, state, coalesce(reverts, ''), link, ingested_at,
      (SELECT count(*) FROM release_notes WHERE version IS NOT NULL)
      + 1 - row_number() OVER (ORDER BY array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) DESC, committed_at DESC, sha)
  FROM release_notes
  WHERE version IS NOT NULL
      AND array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) >= (SELECT min(k) FROM page)
      AND array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) <= (SELECT max(k) FROM page);" ./run -a do_spl_db_query
  ```
- **Measured value:** Total execution time **18.24 ms** (planning 2.78 ms, returning 106 rows for 30 versions). InitPlan 2 (Aggregate over `Seq Scan on release_notes release_notes_2`) takes **10.33 ms** (56.7 % of execution time) scanning all **7,130** rows (`shared hit=514`).
- **Target practice:** Extract narrow list projection (excluding the 6 long columns until note modal opens) and eliminate the per-request full table scan for version count (cache or estimate total version count).

### Input 2: Web UI frame serialization: `fanoutChannelFrame` uses `map[string]any` with per-socket encoding
- **Issue:** `csi-spl-api/.../internal/hub/wui.go` retains 7 occurrences of `map[string]any`. While message frames are pre-encoded once, `fanoutChannelFrame` (lines 1267, 1276) builds a `map[string]any` and re-encodes JSON per socket. P5-09 reported a 41 % allocation cut on channel frames with typed structs and encode-once semantics in uncommitted patch `c-879-p5-09.patch` (not checked today on master; today's benchmark measures `BenchmarkFanoutWUI-16` on `2a620a160` as shown below).
- **Measurement commands:**
  ```bash
  grep -n 'map\[string\]any' csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go | wc -l
  cd csi-spl-api/src/go/spool-hub-api && go test ./internal/hub -bench 'BenchmarkFanoutWUI' -benchmem -run '^$'
  ```
- **Measured values:**
  - Count: **7** occurrences of `map[string]any` in `wui.go`.
  - Benchmark: `BenchmarkFanoutWUI-16`: **2 408** iterations, **530 615 ns/op**, **29 144 B/op**, **285 allocs/op**.
- **Target practice:** Adopt typed struct and encode-once pattern for channel frames (`c-879-p5-09.patch`).

### Input 3: `topic_head_apply_marks` full message scan on 'r' marks
- **Issue:** While P5-02 replaced `topic_head_add` to use index probes, `topic_head_apply_marks` (`csi-spl-rdb/.../0144_topic_heads.sql:418`) retains `PERFORM topic_head_rebuild(re_tn, re_tk)` for 'r' marks (archiving, moving, or deleting a topic), triggering a complete scan of all messages belonging to those topics.
- **Measurement command:**
  ```bash
  cd csi-spl-orc && ENV=prd SQL="select count(*) from topic_heads; select count(*) from messages;" ./run -a do_spl_db_query
  ```
- **Measured values:**
  - Prd table row counts measured today: **6 972** rows in `topic_heads` and **48 069** rows in `messages`.
  - Historical lab rebuild figure: 45–55 ms per topic rebuild ($n=30$) (not checked today; source: dispatcher status post in topic `eafc9b15` at 2026-10-12 20:35:09 UTC; today's command counts prd rows only).
- **Target practice:** Incremental mark application for archive/move/delete operations without invoking full `topic_head_rebuild`.

### Input 4: Duplicated signed-human predicate in `api/store/fallback_postgres.go`
- **Issue:** The filter predicate `m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%' AND m.env_sig <> '' AND (m.channel IS NOT NULL OR (m.to_id NOT LIKE 'HUM-%' AND m.to_id NOT LIKE 'GST-%' AND m.to_id <> 'ALL-0'))` is duplicated verbatim across three separate queries (`UnheardPosts`, `UnansweredPosts`, and `ReescalatablePosts`).
- **Measurement command:**
  ```bash
  grep -n "m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'" csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go
  ```
- **Measured value:** Exactly **3** duplicate occurrences at lines 84, 115, and 148 in a **223-line** file.
- **Target practice:** Consolidate into a single package-level SQL fragment or helper to eliminate drift risk across relay fallback queries.

### Input 5: Go API statement coverage floor: `internal/payments` at 0.0 % headroom
- **Issue:** Several packages in `csi-spl-api` sit exactly on their coverage floor, creating flake risks during minor refactors.
- **Measurement command:**
  ```bash
  cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/
  ```
- **Measured value:** `coverage: 72.4% of statements` (matches exact floor of `72.4` in `csi-spl-api/src/bash/tests/go-coverage-floor.txt`, with **0.0 %** headroom).
- **Target practice:** Add unit tests for payment webhook error cases to raise statement coverage above 80 %.

---

## 6. Commands run to verify this retro

```bash
# Verify git history and commit hashes
git log origin/master -E --grep='(P5-[0-9]{2}|perf5|SPL-(1739|1740|1761|1812|1831))' --format='%h %cI %s'
git show -s --format='hash: %h%ndate: %cI%nauthor: %an <%ae>%nsubject: %s%n%b' 74bfcaaab f9f5690dd 18391f687 9b2e23359 86aa493c8 d99a0b3a3 f054c9b53 474df9fbb 2abefb129 41e4a4a09 b56d1671f 4aa64b607 b077fc75f f317ec6a2 928e94489 67c6ff1e9 232887b65 c63490453

# Verify discussion messages in topic eafc9b15
cd csi-spl-orc && ENV=prd SQL="select ts, from_id, body from messages where task_id='eafc9b15-0aa2-41e1-95f0-0e7a59623235' order by ts" ./run -a do_spl_db_query

# Input 1: EXPLAIN shipped ListReleaseNotes query on prd
cd csi-spl-orc && ENV=prd SQL="EXPLAIN (ANALYZE, BUFFERS) WITH page AS (
    SELECT DISTINCT array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) AS k
    FROM release_notes
    WHERE version IS NOT NULL
    ORDER BY k DESC LIMIT 30
)
SELECT sha, coalesce(version, ''), committed_at, kind, area, subject,
    lay_what, lay_how, lay_why, tech_what, tech_how, tech_why, state, coalesce(reverts, ''), link, ingested_at,
    (SELECT count(*) FROM release_notes WHERE version IS NOT NULL)
    + 1 - row_number() OVER (ORDER BY array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) DESC, committed_at DESC, sha)
FROM release_notes
WHERE version IS NOT NULL
    AND array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) >= (SELECT min(k) FROM page)
    AND array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1), string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) <= (SELECT max(k) FROM page);" ./run -a do_spl_db_query

# Input 2: WUI map[string]any count and Fanout benchmark
grep -n 'map\[string\]any' csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go | wc -l
cd csi-spl-api/src/go/spool-hub-api && go test ./internal/hub -bench 'BenchmarkFanoutWUI' -benchmem -run '^$'

# Input 3: Prd table counts for topic_heads and messages
cd csi-spl-orc && ENV=prd SQL="select count(*) from topic_heads; select count(*) from messages;" ./run -a do_spl_db_query

# Input 4: Check fallback_postgres.go duplicates and line count
grep -n "m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'" csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go
wc -l csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go

# Input 5: Check payments coverage
cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/
```
